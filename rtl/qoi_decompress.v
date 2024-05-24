////////////////////////////////////////////////////////////////////////////////
//
// Filename:	rtl/qoi_decompress.v
// {{{
// Project:	Quite OK image compression (QOI)
//
// Purpose:
//
//	1. Start calculating table index: R*3 + G*5 + B*7 + A*11
//		8'hfe: If pixel is known ...
//			Code = 0
//			Pre-R = R*3
//			Pre-G = G*5
//			Pre-B = R*7
//			Pre-A = (Prior value of A)
//			Mark as non-offset
//		8'hff: Same, except ...
//			Code = 1
//			Pre-A = A*11 = A * 16 - A * 4 - A * 1
//		2'b00: (Keep as index)
//			Code = 2
//		2'b01: Mark as offset
//			Pre-R = dR*3
//			Pre-G = dG*5
//			Pre-B = dB*7
//			Pre-A = 0
//			Code = 3
//		2'b10: Mark as offset
//			Pre-R = (dR + dG)*3
//			Pre-G = dG*5
//			Pre-B = (dB + dG)*7
//			Pre-A = 0
//			Code = 3
//		2'b11: (Keep as run and length)
//			Code = 4
//	2. Calculate the table entry
//		If run
//			Tbl-Idx = last_index
//		else if index
//			Tbl-Idx = index
//		else if offset
//			Tbl-IDX = pre-R + pre-G + pre-B + last_index
//		else
//			Tbl-IDX = pre-R + pre-G + pre-B
//	3. Table write / lookup
//		If run
//			(skip)
//			(pixel is already valid)
//		else if index
//			pixel = tbl[index]
//		else if offset
//			pixel <= pixel + offset
//			tbl[index] <= pixel + offset
//		else
//			tbl[index] <= pipeline_pixel
//	4. Run
//		if (run_count > 0)
//			run_count <= run_count - 1;
//		else if (run)
//			run_pixel <= run_pixel;
//			run_count <= run_count;
//		else
//			run_pixel <= pixel;
//			run_count <= 0;
//			
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2024, Gisselquist Technology, LLC
// {{{
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
// }}}
// License:	GPL, v3, as defined and found on www.gnu.org,
// {{{
//		http://www.gnu.org/licenses/gpl.html
//
////////////////////////////////////////////////////////////////////////////////
//
// }}}
module	qoi_decompress #(
		parameter	LGWID = 12
	) (
		input	wire		i_clk, i_reset,
		// Image configuration
		// {{{
		input	wire	[LGWID-1:0]	i_width, i_height,
		// }}}
		// QOI compressed input stream
		// {{{
		input	wire		s_valid,
		output	wire		s_ready,
		input	wire	[39:0]	s_data,
		input	wire	[1:0]	s_bytes,
		input	wire		s_last,
		// }}}
		// Video stream output
		// {{{
		output	wire		m_vid_valid,
		input	wire		m_vid_ready,
		output	wire	[23:0]	m_vid_data,
		output	wire		m_vid_hlast,
		output	wire		m_vid_vlast
		// }}}
	);

	// Local declarations
	// {{{
	reg		g_valid, r_last, g_last;
	wire		g_ready;
	reg	[63:0]	g_data, g_next;
	reg	[31:0]	s_trim;
	reg	[2:0]	g_size;
	wire	[2:0]	s_size;
	reg	[3:0]	g_load, s_shift;

	reg		s1_valid, s1_last;
	wire		s1_ready;
	wire	[7:0]	dr_sum, db_sum;	// Red and blue differentials
	reg	[2:0]	s1_code;
	reg	[31:0]	s1_pix;
	reg	[5:0]	s1_prer, s1_preg, s1_preb, s1_prea;

	reg		s2_valid, s2_last;
	wire		s2_ready;
	reg	[2:0]	s2_code;
	reg	[31:0]	s2_pix;
	reg	[5:0]	s2_index, s2_alpha;

	reg		s3_valid, s3_last;
	wire		s3_ready;
	reg	[2:0]	s3_code;
	reg	[31:0]	s3_lookup, s3_write_value, s3_raw;
	wire	[31:0]	s3_pixel;
	wire	[5:0]	s3_write_index;
	reg	[5:0]	s3_run;
	reg	[5:0]	s3_index;

	reg	[31:0]	tbl	[0:63];

	reg		s4_valid, s4_last;
	wire		s4_ready;
	reg	[5:0]	s4_count;
	reg	[31:0]	s4_pixel;

	reg	[LGWID-1:0]	s4_hcount, s4_vcount;
	reg			s4_hlast, s4_vlast;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Gearbox
	// {{{

	// FIXME: We should be detecting the 0x00, 0x00, ... 0x01
	// synchronization here.  We aren't.

	//
	// One issue is we don't know how good and reliable s_last will be.
	// It might be that s_last is set on the last *byte* we have stored
	// in memory, but counter to spec not on the last *pixel*.  It might
	// also be that s_last is set on the last *word* of memory, but not
	// the last *code-word* of the data.  So, let's make some choices:
	//
	// 1. Decoding restarts on the word following any
	//			s_valid & s_ready & s_last
	// 2. Decoding stops on the second 0x00 in a row, and waits for resync
	//	FIXME!  We are not doing this at present
	// 3. Resync takes place following any 0x00, 0x00, 0x01 sequence.
	//	FIXME!  We're not doing this
	// 4. If a partial resync sequence is received, such as 0x01_xxxxxx,
	//	then the rest of the word may be ignored.
	//	(This isn't even a FIXME, since without #2 or #3 above, this
	//	is a rather meaningless criteria.)
	// 5. Decoding pauses on any 0x00 word, to know if the next 0x00 byte
	//	is 0x00.  If it is, the first of the two 0x00 bytes is marked
	//	as the last byte in the sequence.
	//	FIXME!  We're not doing this
	// 6. The following pipeline may need to truncate the image one cycle
	//	early
	//
	// The result will be a decoded image size that may be longer than the
	// true image size by one table lookup pixel, but no more.

	always @(posedge i_clk)
	if (i_reset)
		g_valid <= 0;
	else if (s_valid && s_ready)
	begin
		if (g_valid && g_ready)
			g_valid <= (g_load >= 8 + g_size);
		else
			g_valid <= g_load >= 4;
		if (s_last)
			g_valid <= 1'b1;
	end else if (g_valid && g_ready)
	begin
		if (r_last)
			g_valid <= (g_load > { 1'b0, g_size });
		else
			g_valid <= (g_load >= 4 + g_size);
	end

	always @(*)
	begin
		if (g_data[39:32] == 8'hfe)
			g_size = 4;
		else if (g_data[39:32] == 8'hfe)
			g_size = 5;
		else if (g_data[39:38] == 2'd2)
			g_size = 2;
		else
			g_size = 1;
	end

	assign	s_size = (s_bytes == 0) ? 4 : { 1'b0, s_bytes };

	always @(posedge i_clk)
	if (i_reset)
		g_load <= 0;
	else case({ (s_valid && s_ready), (g_valid && g_ready) })
	2'b00: begin end
	2'b10: g_load <= g_load + s_size;
	2'b01: g_load <= g_load          - g_size;
	2'b11: g_load <= g_load + s_size - g_size;
	endcase

	always @(*)
	if (g_valid && g_ready)
		s_shift = 4-g_load+g_size;
	else
		s_shift = 4-g_load;

	always @(*)
	begin
		s_trim = s_data;
		case(s_bytes)
		2'b00: s_trim = s_data;
		2'b01: s_trim[23:0] = 24'h0;
		2'b10: s_trim[15:0] = 16'h0;
		2'b11: s_trim[ 7:0] =  8'h0;
		endcase
	end

	always @(*)
	case({ (s_valid && s_ready), (g_valid && g_ready) })
	2'b00: g_next = g_data;
	2'b01: g_next = g_data << (g_size * 8);
	2'b10: g_next = g_data | ({ 32'h0, s_trim } << (8*s_shift));
	2'b11: g_next = (g_data << (g_size * 8))
				| ({ 32'h0, s_trim } << (8*s_shift));
	endcase

	always @(posedge i_clk)
	if (i_reset)
		g_data <= 0;
	else
		g_data <= g_next;

	always @(posedge i_clk)
	if (i_reset)
		r_last <= 0;
	else if (s_valid && s_ready)
		r_last <= s_last;
	else if (g_valid && g_ready && g_last)
		r_last <= 1'b0;

	always @(posedge i_clk)
	if (i_reset)
		g_last <= 0;
	else if (s_valid && s_ready)
	begin
		g_last <= 0;
		if (!s_last)
			g_last <= 0;
		else if (g_load == 1)
			g_last <= (g_next[63:56] == 8'hff);
		else if (s_bytes == 0 && g_load == 0)
			g_last <= (s_data[31:24] == 8'hfe);
		// else if (g_load == 0)
		//	g_last <= (s_data[31:30] == 8'hfe);
		else
			g_last <= s_last;
	end else if (g_valid && g_ready)
		g_last <= 1'b0;

	assign	s_ready = (!g_valid || (g_ready && (g_load <= 4 + g_size)));
	assign	g_ready = !s1_valid || s1_ready;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// s1
	// {{{
	always @(posedge i_clk)
	if (i_reset)
		{ s1_valid, s1_last } <= 0;
	else if (!s1_valid || s1_ready)
		{ s1_valid, s1_last } <= { g_valid, g_last };

	assign	dr_sum = { {(4){g_data[55]}}, g_data[55:52] } + { {(2){g_data[61]}}, g_data[61:56] };
	assign	db_sum = { {(4){g_data[51]}}, g_data[51:48] } + { {(2){g_data[61]}}, g_data[61:56] };

	always @(posedge i_clk)
	if (g_valid && g_ready)
	begin
		case(g_data[63:62])
		2'b00: begin	// Table lookup
			if (g_data[63:56] == 8'hfe)
			begin
			s1_code <= 0;
			s1_pix  <= { g_data[55:32], 8'h0 };
			s1_prer <= { g_data[52:48], 1'b0 } + g_data[53:48];
			s1_preg <= { g_data[43:40], 2'b0 } + g_data[45:40];
			s1_preb <= { g_data[34:32], 3'b0 } - g_data[37:32];
			s1_prea <= 0;	// This is an offset
			end else if (g_data[63:56] == 8'hff)
			begin
				s1_code<= 1;
				s1_pix <=  g_data[55:24];
				s1_prer<={ g_data[52:48], 1'b0 }+ g_data[53:48];
				s1_preg<={ g_data[43:40], 2'b0 }+ g_data[45:40];
				s1_preb<={ g_data[34:32], 3'b0 }- g_data[37:32];
				s1_prea<={ g_data[26:24], 3'b0 }
					+{ g_data[28:24], 1'b0 }+ g_data[29:24];
			end else begin
				s1_code <= 2;
				s1_pix  <= { g_data[63:56], 24'h0 };
				// Count
				s1_prer <= 0;
				s1_preg <= 0;
				s1_preb <= 0;
				s1_prea <= 0;
			end end
		2'b01: begin
			s1_code <= 3;
			s1_pix <= { {(6){g_data[61]}}, g_data[61:60],
					{(6){g_data[59]}}, g_data[59:58],
					{(6){g_data[57]}}, g_data[57:56],
					8'h0 };
			s1_prer <= { {(3){g_data[61]}}, g_data[61:60], 1'b0 }
				+ { {(4){g_data[61]}}, g_data[61:60] };
			s1_preg <= { {(2){g_data[59]}}, g_data[59:58], 2'b00 }
				+ { {(4){g_data[59]}}, g_data[59:58] };
			s1_preb <= { {(1){g_data[57]}}, g_data[57:56], 3'b000 }
				- { {(4){g_data[57]}}, g_data[57:56] };
			s1_prea <= 0;
			end
		2'b10: begin
			s1_code <= 3;
			s1_pix  <= { dr_sum,
					{(2){g_data[61]}}, g_data[61:56],
					db_sum, 8'h0 };
			s1_prer <= { dr_sum[4:0], 1'b0 } + dr_sum[5:0];
			s1_preg <= { g_data[61:56] }
				+ { g_data[59:56], 2'b00 };
			s1_preb <= { db_sum[2:0], 3'b0 } - db_sum[5:0];
			s1_prea <= 0;
			end
		2'b11: begin // (Keep as run and length)
			s1_code <= 4;
			s1_pix <= { g_data[63:56], 24'h0 };
			s1_prer <= 0;
			s1_preg <= 0;
			s1_preb <= 0;
			s1_prea <= 0;
			end
		endcase
	end

	assign	s1_ready = !s2_valid || s2_ready;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// s2
	// {{{

	always @(posedge i_clk)
	if (i_reset)
		{ s2_valid, s2_last } <= 0;
	else if (!s2_valid || s2_ready)
		{ s2_valid, s2_last } <= { s1_valid, s1_last };

	always @(posedge i_clk)
	if (i_reset)
		s2_alpha <= 6'h3f + 6'h3e + 6'h38;
	else if (s2_valid && s2_ready && s1_code == 1)
		s2_alpha <= s1_prea;

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
	begin
		s2_code <= s1_code;
		s2_pix  <= s1_pix;
		case(s1_code)
		0: s2_index <= s1_prer + s1_preg + s1_preb + s2_alpha;
		1: s2_index <= s1_prer + s1_preg + s1_preb + s1_prea;
		2: s2_index <= s1_pix[29:24];
		3: s2_index <= s1_prer + s1_preg + s1_preb + s2_index;
		4: s2_index <= s2_index;
		endcase
	end

	assign	s2_ready = !s3_valid || s3_ready;
	// }}}	
	////////////////////////////////////////////////////////////////////////
	//
	// s3: Table lookup
	// {{{

	always @(posedge i_clk)
	if (i_reset)
		{ s3_last, s3_valid } <= 0;
	else if (!s3_valid || s3_ready)
		{ s3_last, s3_valid } <= { s2_last, s2_valid };

	always @(posedge i_clk)
	if (s2_valid && s2_ready && s2_code == 2)
		s3_lookup <= tbl[s2_index];

	assign	s3_write_index = (s2_code < 2) ? s2_index : (s3_index + s2_index);
	always @(*)
	begin
		case(s2_code[1:0])
		0: s3_write_value = s2_pix;
		1: s3_write_value = { s2_pix[31:8], s3_pixel[7:0] };
		2: s3_write_value = s3_pixel;	// Could be anything ...
		3: begin
			s3_write_value[31:24]= s2_pix[31:24]+ s3_pixel[31:24];
			s3_write_value[23:16]= s2_pix[23:16]+ s3_pixel[23:16];
			s3_write_value[15: 8]= s2_pix[15: 8]+ s3_pixel[15: 8];
			s3_write_value[ 7: 0]= s3_pixel[31:24];
			end
		default: s3_write_value = s2_pix;
		endcase
	end

	always @(posedge i_clk)
	if (s2_valid && s2_ready && (s2_code != 2 && !s2_code[2]))
		tbl[s3_write_index] <= s3_write_value;

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
	begin
		s3_code <= s2_code;
		s3_raw  <= s3_write_value;
		if (s2_code == 2)
			s3_index <= s2_index;
		else
			s3_index <= s3_write_index;

		if (s2_code == 4)
			s3_run <= s2_pix[29:24];
		else
			s3_run <= 0;
	end

	assign	s3_pixel = (s3_code == 2) ? s3_lookup : s3_raw;
	assign	s3_ready = !s4_valid || (s4_ready && s4_count == 0);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// s4: Repeats
	// {{{

	always @(posedge i_clk)
	if (i_reset)
		{ s4_last, s4_valid } <= 0;
	else if (!s4_valid || s4_ready)
	begin
		{ s4_last, s4_valid } <= { s3_last, s3_valid };
		// s4_last <= (s3_valid && s3_last && s3_run == 0);
	end else if (s4_count > 0)
	begin
		s4_valid <= !s4_vlast || !s4_hlast;
		// s4_last <= (s4_count <= 1) && s4_lcl_last;
	end

	always @(posedge i_clk)
	if (i_reset)
		s4_count <= 0;
	else if (s3_valid && s3_ready)
	begin
		if (s3_code != 4)
			s4_count <= 0;
		else
			s4_count <= s3_run;
	end else if (s4_ready && s4_count > 0)
	begin
		if (s4_hlast && s4_vlast)
			s4_count <= 0;
		else
			s4_count <= s4_count - 1;
	end

	always @(posedge i_clk)
	if (s3_valid && s3_ready)
		s4_pixel <= s3_pixel;

	always @(posedge i_clk)
	if (i_reset)
	begin
		s4_hcount <= 0;
		s4_hlast  <= 0;
	end else if (s4_valid && s4_ready)
	begin
		if (s4_hlast)
		begin
			s4_hcount <= 0;
			s4_hlast  <= 0;
		end else if ((s3_valid && s3_ready && s3_last && s3_run == 0)
					|| ((s4_count == 1) && s4_last))
		begin
			s4_hcount <= s4_hcount + 1;
			s4_hlast  <= 1;
		end else begin
			s4_hcount <=  s4_hcount + 1;
			s4_hlast  <= (s4_hcount + 2 >= i_width);
		end
	end

	always @(posedge i_clk)
	if (i_reset)
	begin
		s4_vcount <= 0;
		s4_vlast  <= 0;
	end else if (s4_valid && s4_ready)
	begin
		if (s4_hlast && s4_vlast)
		begin
			s4_vcount <= 0;
			s4_vlast  <= 0;
		end else if ((s3_valid && s3_last && s3_run == 0)
					|| ((s4_count == 1) && s4_last))
		begin
			s4_vlast  <= 1;
		end else if (s4_hlast)
		begin
			s4_vcount <=  s4_vcount + 1;
			s4_vlast  <= (s4_vcount + 2 >= i_height);
		end
	end

	assign	s4_ready = !m_vid_valid || m_vid_ready;
	// }}}

	assign	m_vid_valid = s4_valid;
	assign	m_vid_data  = s4_pixel[31:8];
	assign	m_vid_hlast = s4_hlast;
	assign	m_vid_vlast = s4_vlast;

	// Verilator lint_off UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, s4_pixel[7:0] };
	// Verilator lint_on  UNUSED
endmodule
