////////////////////////////////////////////////////////////////////////////////
//
// Filename:	./rtl/qoi_decompress.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	Decodes the compressed data within a QOI image.  By the time
//		we get the data, the header and trailer have already been
//	stripped from the image, and the values given to us are QOI code words.
//	All QOI code words will have their first byte in the MSB.  Not all
//	QOI codeword bytes will be valid.
//
//	The challenge here is the pipeline--particularly because we have to
//	take only a single clock cycle to read from memory (unlike software),
//	and we won't immediately know what address to read from.  Sure, if this
//	is a memory pixel, we'll read from the right address-but how will we
//	write pixel values to the right address if we haven't already
//	calculated their indexes first?  Hence, pipeline scheduling is our
//	most complex task.
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
`default_nettype none
// }}}
module	qoi_decompress (
		input	wire		i_clk, i_reset,
		// QOI compressed input stream
		// {{{
		input	wire		s_valid,
		output	wire		s_ready,
		input	wire	[39:0]	s_data,
		input wire		s_last,
		// }}}
		// Pixel stream output
		// {{{
		output	wire		m_valid,
		input	wire		m_ready,
		output	wire	[23:0]	m_data,
		// We have no knowledge of height or width here.  Hence the
		// video last signal only indicates the last pixel in the
		// frame, not the last pixel in a line or any other such thing.
		// The decoder shell should take care of the rest of the video
		// sync signals.
		output	wire		m_last
		// }}}
	);

	// Local declarations
	// {{{
	localparam	[2:0]	C_RGB   = 0,
				C_RGBA  = 1,
				C_TABLE = 2,
				C_DELTA = 3,
				C_REPEAT= 4;

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
	reg	[5:0]	s2_index, s2_alpha, s2_run;

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

	assign	s_ready = (!s1_valid || s1_ready);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// s1
	// {{{

	initial	s1_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		{ s1_valid, s1_last } <= 0;
	else if (!s1_valid || s1_ready)
		{ s1_valid, s1_last } <= { s_valid, s_last };

	wire	[3:0]	s_dred, s_dblu;
	wire	[5:0]	s_dgrn;

	assign	s_dgrn = s_data[37:32] ^ 6'd32;
	assign	s_dred = s_data[31:28] ^ 4'd8;
	assign	s_dblu = s_data[27:24] ^ 4'd8;

	// Red - green
	assign	dr_sum = { {(4){s_dred[3]}}, s_dred[3:0] }
					+ { {(2){s_dgrn[5]}}, s_dgrn[5:0] };
	// Blue - green
	assign	db_sum = { {(4){s_dblu[3]}}, s_dblu[3:0] }
					+ { {(2){s_dgrn[5]}}, s_dgrn[5:0] };

	wire	[5:0]	s_delta;

	assign	s_delta = {
			s_data[37:36] ^ 2'b10,
			s_data[35:34] ^ 2'b10,
			s_data[33:32] ^ 2'b10 };

	always @(posedge i_clk)
	if (s_valid && s_ready)
	begin
		case(s_data[39:38])
		2'b00: begin	// Table lookup
			// {{{
			s1_code <= C_TABLE;
			s1_pix  <= { s_data[39:32], 24'h0 };
			//
			s1_prer <= 6'h0;
			s1_preg <= 6'h0;
			s1_preb <= 6'h0;
			s1_prea <= 6'h0;
			end
			// }}}
		2'b01: begin
			s1_code <= C_DELTA;
			s1_pix[31:24] <= { {(6){s_delta[5]}}, s_delta[5:4]};
			s1_pix[23:16] <= { {(6){s_delta[3]}}, s_delta[3:2]};
			s1_pix[15: 8] <= { {(6){s_delta[1]}}, s_delta[1:0]};
			// dR * 3
			s1_prer <= { {(3){s_delta[5]}}, s_delta[5:4], 1'b0 }
				+ { {(4){s_delta[5]}}, s_delta[5:4] };
			// dG * 5
			s1_preg <= { {(2){s_delta[3]}}, s_delta[3:2], 2'b00 }
				+ { {(4){s_delta[3]}}, s_delta[3:2] };
			// dR * 7
			s1_preb <= { {(1){s_delta[1]}}, s_delta[1:0], 3'b000 }
				- { {(4){s_delta[1]}}, s_delta[1:0] };
			// Alpha stays the same
			s1_prea <= 0;
			end
		2'b10: begin	// LUNA
			// {{{
			s1_code <= C_DELTA;
			//
			s1_pix[31:24] <= dr_sum;
			s1_pix[23:16] <= { {(2){s_dgrn[5]}}, s_dgrn[5:0]};
			s1_pix[15: 8] <= db_sum;
			s1_pix[ 7: 0] <= 0;
			// dR * 3
			s1_prer <= { dr_sum[4:0], 1'b0 } + dr_sum[5:0];
			// dG * 5
			s1_preg <= { s_dgrn[5:0] } + { s_dgrn[3:0], 2'b00 };
			s1_preb <= { db_sum[2:0], 3'b0 } - db_sum[5:0];
			s1_prea <= 0;
			end
			// }}}
		2'b11: if (s_data[39:32] == 8'hfe)
			begin // RGB
				// {{{
				s1_code <= C_RGB;
				s1_pix  <= { s_data[31: 8], 8'h0 };
				// R * 3
				s1_prer <= { s_data[28:24], 1'b0 } + s_data[29:24];
				// G * 5
				s1_preg <= { s_data[19:16], 2'b0 } + s_data[21:16];
				// B * 7
				s1_preb <= { s_data[10: 8], 3'b0 } - s_data[13: 8];
				// A * 11 = (255 * 11), but only on the first case
				//	1011 0000 0000
				//	1111 1111 0101
				//	--------------
				//	1010 1111 0101 -> 11 0101 -> 48+5 = 53
				// s1_prea <= 55; // This is an offset
				// }}}
			end else if (s_data[39:32] == 8'hff)
			begin // RGB + Alpha
				// {{{
				s1_code<= C_RGBA;
				s1_pix <=  s_data[31: 0];
				// R *  3
				s1_prer<={ s_data[28:24], 1'b0 }+ s_data[29:24];
				// G *  5
				s1_preg<={ s_data[19:16], 2'b0 }+ s_data[21:16];
				// B *  7
				s1_preb<={ s_data[10: 8], 3'b0 }- s_data[13: 8];
				// A * 11 = (A << 3) + (A << 1) + A // 1011
				s1_prea<={ s_data[ 2: 0], 3'b0 }
					+{ s_data[ 4: 0], 1'b0 }+ s_data[ 5: 0];
				// }}}
			end else begin // (Keep as run and length)
				s1_code <= C_REPEAT;
				s1_pix <= { s_data[39:32], 24'h0 };
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

	initial	s2_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		{ s2_valid, s2_last } <= 0;
	else if (!s2_valid || s2_ready)
		{ s2_valid, s2_last } <= { s1_valid, s1_last };

	always @(posedge i_clk)
	if (i_reset)
		s2_alpha <= 6'h35;
	else if (s1_valid && s1_ready && s1_code == C_RGBA)
		s2_alpha <= s1_prea;
	// else if (s3_valid && s3_code == C_TABLE)
	//	s2_alpha <= s3_lookup[7:0] + (s3_lookup[7:0] << 1)
	//			+ (s3_lookup[7:0] << 3);

	always @(posedge i_clk)
	if (i_reset)
		s2_pix <= 0;
	else if (s1_valid && s1_ready)
	begin
		if (s1_code == C_TABLE)
			s2_pix  <= 0;
		else if (s1_code != C_REPEAT)
			s2_pix  <= s1_pix;
	end

	always @(posedge i_clk)
	if (s1_valid && s1_ready)
	begin
		s2_code <= s1_code;
		s2_run  <= (s1_code == C_REPEAT) ? s1_pix[29:24] : 6'h0;
		case(s1_code)
		C_RGB:    s2_index <= s1_prer + s1_preg + s1_preb;// + s2_alpha;
		C_RGBA:   s2_index <= s1_prer + s1_preg + s1_preb + s1_prea;
		C_TABLE:  s2_index <= s1_pix[29:24];
		C_DELTA:  s2_index <= s1_prer + s1_preg + s1_preb;// + s2_index;
		C_REPEAT: s2_index <= s2_index;
		default: begin end
		endcase
	end

	assign	s2_ready = !s3_valid || s3_ready;
	// }}}	
	////////////////////////////////////////////////////////////////////////
	//
	// s3: Table lookup
	// {{{

	initial	s3_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		{ s3_last, s3_valid } <= 0;
	else if (!s3_valid || s3_ready)
		{ s3_last, s3_valid } <= { s2_last, s2_valid };

	always @(posedge i_clk)
	if (s2_valid && s2_ready && s2_code == C_TABLE)
		s3_lookup <= tbl[s2_index];

	assign	s3_write_index = (s2_code == C_RGB) ? (s2_index + s2_alpha)
			:(s2_code < C_TABLE) ? s2_index : (s3_index + s2_index);
	always @(*)
	begin
		s3_write_value = s3_raw;
		case(s2_code)
		C_RGB:   s3_write_value[31:8] = s2_pix[31:8];
		C_RGBA:  s3_write_value = s2_pix[31:0];
		C_TABLE: s3_write_value = s3_pixel;	// Could be anything ...
		C_DELTA: begin
			s3_write_value[31:24]= s2_pix[31:24]+ s3_pixel[31:24];
			s3_write_value[23:16]= s2_pix[23:16]+ s3_pixel[23:16];
			s3_write_value[15: 8]= s2_pix[15: 8]+ s3_pixel[15: 8];
			s3_write_value[ 7: 0]= s3_pixel[7:0];
			end
		default: begin end // s3_write_value = s2_pix;
		endcase
	end

	always @(posedge i_clk)
	if (s2_valid && s2_ready && (s2_code != C_TABLE && !s2_code[2]))
		tbl[s3_write_index] <= s3_write_value;

	always @(posedge i_clk)
	begin
		if (s2_valid && s2_ready)
		begin
			s3_code <= s2_code;
			if (s2_code == C_TABLE)
				s3_index <= s2_index;
			else if (s2_code != C_REPEAT)
				s3_index <= s3_write_index;


			if (s2_code == C_REPEAT)
			begin
				s3_run <= s2_run;
				if (s3_code == C_TABLE)
					s3_raw <= s3_lookup;
			end else begin
				s3_run <= 0;
				s3_raw  <= s3_write_value;
			end
		end

		if (i_reset)
		begin
			s3_raw   <= 32'h00ff;
			s3_code  <= C_RGBA;
			s3_index <= 6'h35;
		end
	end

	assign	s3_pixel = (s3_code == C_TABLE) ? s3_lookup : s3_raw;
	assign	s3_ready = !s4_valid || (s4_ready && s4_count == 0);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// s4: Repeats
	// {{{

	initial	s4_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		{ s4_last, s4_valid } <= 0;
	else if (!s4_valid || s4_ready)
	begin
		{ s4_last, s4_valid } <= { s3_last, s3_valid };
		// s4_last <= (s3_valid && s3_last && s3_run == 0);
	end else if (s4_count > 0)
	begin
		s4_valid <= !s4_last;
		// s4_last <= (s4_count <= 1) && s4_lcl_last;
	end

	always @(posedge i_clk)
	if (i_reset)
		s4_count <= 0;
	else if (s3_valid && s3_ready)
	begin
		if (s3_code != C_REPEAT)
			s4_count <= 0;
		else
			s4_count <= s3_run;
	end else if ((!m_valid || m_ready) && s4_count > 0)
		s4_count <= s4_count - 1;

	always @(posedge i_clk)
	if (s3_valid && s3_ready && s3_code != C_REPEAT)
		s4_pixel <= s3_pixel;

	assign	s4_ready = (!m_valid || m_ready)&&(s4_count == 0);
	// }}}

	assign	m_valid = s4_valid;
	assign	m_data  = s4_pixel[31:8];
	assign	m_last  = s4_last && (s4_count == 0);

	// Keep Verilator happy
	// {{{
	// Verilator lint_off UNUSED
	wire	unused;
	assign	unused = &{ 1'b0, s4_pixel[7:0] };
	// Verilator lint_on  UNUSED
	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
// Formal properties
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	reg	f_past_valid;

	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(i_reset);

	////////////////////////////////////////////////////////////////////////
	//
	// S_* input properties
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assume(!s_valid);
	else if ($past(s_valid && !s_ready))
	begin
		assume(s_valid);
		assume($stable(s_data));
		assume($stable(s_last));
	end

	// No two table look ups to the same element in a row

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S1
	// {{{
	reg	[39:0]	f1_raw;

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!s1_valid);
	else if ($past(s1_valid && !s1_ready))
	begin
		assert(s1_valid);
		assert($stable(s1_code));
		assert($stable(s1_last));
		assert($stable(s1_pix));
		assert($stable(s1_prer));
		assert($stable(s1_preg));
		assert($stable(s1_preb));
		assert($stable(s1_prea));

		assert($stable(f1_raw));
	end

	always @(posedge i_clk)
	if (s_valid && s_ready)
		f1_raw <= s_data;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S2
	// {{{
	reg	[39:0]	f2_raw;

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!s2_valid);
	else if ($past(s2_valid && !s2_ready))
	begin
		assert(s2_valid);
		assert($stable(s2_code));
		assert($stable(s2_last));
		assert($stable(s2_pix));
		assert($stable(s2_index));
		assert($stable(s2_alpha));
		assert($stable(s2_run));

		assert($stable(f2_raw));
	end

	always @(posedge i_clk)
	if (s1_valid && s1_ready)
		f2_raw <= f1_raw;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S3
	// {{{
	reg	[39:0]	f3_raw;

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!s3_valid);
	else if ($past(s3_valid && !s3_ready))
	begin
		assert(s3_valid);
		assert($stable(s3_code));
		assert($stable(s3_last));
		assert($stable(s3_pixel));
		assert($stable(s3_raw));
		assert($stable(s3_run));
		assert($stable(s3_index));
		assert($stable(s3_lookup));

		assert($stable(f3_raw));
	end

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
		f3_raw <= f2_raw;

	reg	[5:0]	f2_index, f3_index;

	always @(*)
	begin
		f2_index = s3_write_value[31:24] + (s3_write_value[31:24]<<1)
			+ s3_write_value[23:16] + (s3_write_value[23:16]<<2)
			- s3_write_value[15: 8] + (s3_write_value[15: 8]<<3);
		// + ALPHA * 11
		f2_index = f2_index + s3_write_value[7:0]
			+ (s3_write_value[7:0] << 1)
			+ (s3_write_value[7:0] << 3);

		f3_index = s3_lookup[31:24] + (s3_lookup[31:24]<<1)
			+ s3_lookup[23:16] + (s3_lookup[23:16]<<2)
			- s3_lookup[15: 8] + (s3_lookup[15: 8]<<3);
		// + ALPHA * 11
		f3_index = f3_index + s3_lookup[7:0]
			+ (s3_lookup[7:0] << 1)
			+ (s3_lookup[7:0] << 3);
	end

	always @(*)
	if (!i_reset && s2_valid && (s2_code != C_TABLE && s2_code != C_REPEAT))
	begin
		assert(f2_index == s3_write_index);
	end

	always @(*)
	if (s3_code == C_TABLE)
	begin
		assume(f3_index == s3_index);
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Never Alpha
	// {{{
	(* anyconst *)	reg	fnvr_alpha;

	always @(*)
		assume(fnvr_alpha);

	always @(*)
	if (!i_reset && fnvr_alpha && s_valid)
		assume(s_data[39:32] != 8'hff);

	always @(*)
	if (!i_reset && fnvr_alpha && s1_valid)
		assert(s1_code != C_RGBA);

	always @(*)
	if (!i_reset && fnvr_alpha && s2_valid)
		assert(s2_code != C_RGBA);

	always @(*)
	if (!i_reset && fnvr_alpha && s2_valid && (s2_code != C_TABLE && s2_code != C_REPEAT))
	begin
		assert(s3_write_value[7:0] == 8'hff);
	end

	always @(*)
	if (!i_reset && fnvr_alpha && s3_valid)
	begin
		assert(s3_code != C_RGBA);
		assume(s3_lookup[7:0] == 8'hff);
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// "Careless" assumptions
	// {{{
	always @(*)
	if(s_valid)
		assume(s_data[39:38] != 2'b10);
	// always @(*)
	// if(s_valid)
	//	assume(s_data[39:38] != 2'b01);
	always @(*)
	if(!i_reset && s1_valid)
		assert(f1_raw[39:38] != 2'b10);
	always @(*)
	if(!i_reset && s2_valid)
		assert(f2_raw[39:38] != 2'b10);
	always @(*)
	if(!i_reset && s3_valid)
		assert(f3_raw[39:38] != 2'b10);

	always @(*)
		assume(m_ready);

	always @(posedge i_clk)
	if (!f_past_valid && !$past(i_reset) && $past(s_valid && s_last))
		assume(s_valid);
	// }}}

`endif	// FORMAL
// }}}
endmodule
