////////////////////////////////////////////////////////////////////////////////
//
// Filename:	./rtl/qoi_compress.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	This encoder turns image data into compressed image data.  It
//		doesn't handle header or trailer insertions.  As such, it
//	requires an external wrapper (somewhere) to guarantee proper formatting.
//
//	This implementation does not handle ALPHA.
//
//	The input is an AXI video stream, save two signals:
//	HLAST: true on the last pixel of every line.
//	VLAST: true on either the last line, or the last pixel of the last line.
//	  Hence HLAST && VLAST is the (reliable/guaranteed) signal for the last
//	  pixel in any frame.
//
//	The output is an AXI byte stream containing between 1-4 bytes per beat,
//	with the first byte always packed into the MSB (i.e. big endian), and
//	other bytes packed immediately following.
//	BYTES: Contains the number of valid bytes in each beat, with 2'b0
//	  representing a full 4-byte word.
//	LAST: True on the last DATA beat of any image.
//	Line boundaries are not preserved in this implementation.
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
module	qoi_compress (
		input	wire	i_clk, i_reset,
		// Video stream input
		// {{{
		input	wire		s_vid_valid,
		output	wire		s_vid_ready,
		input	wire	[23:0]	s_vid_data,
		input	wire		s_vid_hlast,
		input	wire		s_vid_vlast,
		// }}}
		// QOI compressed output stream
		// {{{
		output	reg		m_valid,
		input	wire		m_ready,
		output	reg	[31:0]	m_data,
		output	reg	[1:0]	m_bytes,
		output	reg		m_last
		// }}}
	);

	// Local declarations
	// {{{
	wire		skd_valid, skd_ready, skd_hlast, skd_vlast;
	wire	[23:0]	skd_data;

	reg		s1_valid, s1_last;
	reg	[5:0]	s1_rhash, s1_ghash, s1_bhash;
	reg	[23:0]	s1_pixel;
	wire		s1_ready;

	reg		s2_valid, s2_last;
	reg	[5:0]	s2_tbl_index;
	reg	[23:0]	s2_pixel;
	reg	[7:0]	s2_gdiff;
	wire		s2_ready;

	reg		s3_valid, s3_last, s3_tbl_valid, s3_rptvalid;
	reg	[23:0]	s3_pixel, s3_tbl_pixel;
	reg	[5:0]	s3_repeats, s3_tblidx;
	reg	[7:0]	s3_rdiff, s3_gdiff, s3_bdiff, s3_rgdiff, s3_bgdiff;
	wire		s3_continue, s3_ready;

	reg	[63:0]	tbl_valid;
	reg	[23:0]	tbl_pixel	[0:63];

	reg		s4_valid, s4_tblset, s4_rptset, s4_last,
			s4_small, s4_bigdf;
	reg	[5:0]	s4_tblidx, s4_repeats, s4_gdiff;
	reg	[23:0]	s4_pixel;
	reg	[3:0]	s4_rgdiff, s4_bgdiff;
	reg	[1:0]	s4_rdiff, s4_bdiff;
	wire		s4_ready;

	wire		gbl_ready;
	reg		gbl_last;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Skidbuffer
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	qoi_skid #(
`ifdef	FORMAL
		.OPT_PASSTHROUGH(1'b1),
`endif
		.OPT_OUTREG(1'b0), .DW(2+24)
	) u_skid (
		// {{{
		.i_clk(i_clk), .i_reset(i_reset),
		.i_valid(s_vid_valid), .o_ready(s_vid_ready),
		.i_data({ s_vid_hlast, s_vid_vlast, s_vid_data }),
		.o_valid(skd_valid), .i_ready(skd_ready),
		.o_data({ skd_hlast, skd_vlast, skd_data })
		// }}}
	);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #1: Pre-calculate hash data
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	s1_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		s1_valid <= 0;
	else if (skd_valid && skd_ready)
		s1_valid <= skd_valid;
	else if (s1_ready)
		s1_valid <= 0;

	initial	s1_last = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		s1_last <= 0;
	else if (skd_valid && skd_ready)
		s1_last <= skd_hlast && skd_vlast;
	else if (s1_ready)
		s1_last <= 0;

	initial	s1_pixel = 0;
	always @(posedge i_clk)
	if (i_reset)
		s1_pixel <= 0;
	else if (skd_valid && skd_ready)
		s1_pixel <= skd_data;
	else if (s1_ready && s1_last)
		s1_pixel <= 0;

	always @(posedge i_clk)
	if (skd_valid && skd_ready)
	begin
		s1_rhash <= skd_data[21:16] + { skd_data[20:16], 1'b0 };
		s1_ghash <= skd_data[13: 8] + { skd_data[11: 8], 2'b0 };
		s1_bhash <= { skd_data[2:0], 3'h0} - skd_data[ 5: 0];
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #2: Finish calculating the hash table index
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	s2_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		s2_valid <= 0;
	else if (s1_valid && s1_ready)
		s2_valid <= 1'b1;
	else if (s2_ready)
		s2_valid <= 1'b0;

	initial	s2_pixel = 0;
	always @(posedge i_clk)
	if (i_reset)
		s2_pixel <= 0;
	else if (s1_valid && s1_ready)
		s2_pixel <= s1_pixel;
	else if (s2_ready && s2_last)
		s2_pixel <= 0;

	always @(posedge i_clk)
	if (i_reset)
		s2_last <= 1'b0;
	else if (s1_valid && s1_ready)
		s2_last <= s1_last;
	else if (s2_ready)
		s2_last <= 1'b0;

	always @(posedge i_clk)
	if (s1_valid && s1_ready)
	begin
		s2_tbl_index <= s1_rhash + s1_ghash + s1_bhash + 6'h35;

		s2_gdiff <= s1_pixel[15: 8] - s2_pixel[15: 8];
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #3: Hash table lookup, calc differences, count repeats
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	s3_valid = 0;
	always @(posedge i_clk)
	if (i_reset)
		s3_valid <= 0;
	else if (s2_valid && s2_ready)
		s3_valid <= 1'b1;
	else if (s3_ready)
		s3_valid <= 1'b0;

	initial	s3_rptvalid = 0;
	initial	s3_repeats  = 0;
	always @(posedge i_clk)
	if (i_reset)
	begin
		s3_repeats   <= 0;
		s3_rptvalid  <= 0;
	end else if (s2_valid && s2_ready)
	begin
		if (!s3_continue)
		begin
			s3_rptvalid <= s3_rptvalid && (s3_pixel == s2_pixel);
			s3_repeats <= 0;
		end else if (!s3_rptvalid)
		begin
			s3_rptvalid  <= 1;
			s3_repeats <= 0;
		end else begin
			s3_rptvalid  <= 1;
			s3_repeats <= s3_repeats + 1;
		end
	end else if (s3_valid && s3_ready && s3_last)
	begin
		s3_repeats   <= 0;
		s3_rptvalid  <= 0;
	end

	// Table lookup
	// {{{
	always @(posedge i_clk)
	if (s2_valid && s2_ready)
		s3_tbl_valid <= tbl_valid[s2_tbl_index];

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
		s3_tbl_pixel <= tbl_pixel[s2_tbl_index];
	// }}}

	// Write back to the table
	// {{{
	initial	tbl_valid = 0;
	always @(posedge i_clk)
	if (i_reset)
		tbl_valid <= 0;
	else if (s2_valid && s2_ready && s2_last)
		tbl_valid <= 0;
	else if (s2_valid && s2_ready)
		tbl_valid[s2_tbl_index] <= 1'b1;

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
		tbl_pixel[s2_tbl_index] <= s2_pixel;
	// }}}

	// s3_(everything else): tblidx, xdiff, xgdiff, xlast, && pixel
	// {{{
	initial	s3_pixel = 0;
	always @(posedge i_clk)
	if (i_reset)
		s3_pixel <= 0;
	else if (s2_valid && s2_ready)
		s3_pixel <= s2_pixel;
	else if (s3_ready && s3_last)
		s3_pixel <= 0;

	always @(posedge i_clk)
	if (i_reset)
		s3_last <= 1'b0;
	else if (s2_valid && s2_ready)
		s3_last <= s2_last;
	else if (s3_ready)
		s3_last <= 1'b0;

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
	begin
		s3_tblidx <= s2_tbl_index;

		s3_rdiff <= s2_pixel[23:16] - s3_pixel[23:16];
		// s3_gdiff <= s2_pixel[15: 8] - s3_pixel[15: 8];
		s3_gdiff <= s2_gdiff;
		s3_bdiff <= s2_pixel[ 7: 0] - s3_pixel[ 7: 0];

		s3_rgdiff <= (s2_pixel[23:16] - s3_pixel[23:16]) - s2_gdiff;
		s3_bgdiff <= (s2_pixel[ 7: 0] - s3_pixel[ 7: 0]) - s2_gdiff;
	end
	// }}}

	assign	s3_continue = (s3_pixel == s2_pixel) &&(s3_repeats < 6'd61)
					&& !s3_last;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #4: Hash table compare, difference check
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	s4_valid = 0;
	always @(posedge i_clk)
	if (i_reset)
		s4_valid <= 0;
	else if (s3_valid && s3_ready)
		s4_valid <= (!s3_rptvalid || !s3_continue);
	else if (s4_ready)
		s4_valid <= 1'b0;

	initial	s4_pixel = 0;
	always @(posedge i_clk)
	if (i_reset)
		s4_pixel <= 0;
	else if (s3_valid && s3_ready && (!s3_rptvalid || !s3_continue))
		s4_pixel <= s3_pixel;
	else if (s4_ready && s4_last)
		s4_pixel <= 0;

	always @(posedge i_clk)
	if (i_reset)
		s4_last <= 1'b0;
	else if (s3_valid && s3_ready)
		s4_last <= s3_last;
	else if (s4_ready)
		s4_last <= 1'b0;

	initial	s4_rptset  = 0;
	initial	s4_repeats = 0;
	initial	s4_repeats = 0;
	always @(posedge i_clk)
	if (s3_valid && s3_ready)
	begin
		s4_tblset <= (s3_pixel == s3_tbl_pixel) && s3_tbl_valid
						&& (s3_tblidx != s4_tblidx);
		s4_tblidx <= s3_tblidx;

		s4_rptset  <= s3_rptvalid && !s3_continue;
		s4_repeats <= s3_repeats;

		s4_small <= ((&s3_rdiff[7:1]) || (s3_rdiff <= 1))
			&&  ((&s3_gdiff[7:1]) || (s3_gdiff <= 1))
			&&  ((&s3_bdiff[7:1]) || (s3_bdiff <= 1));
		s4_bigdf <= ((&s3_gdiff[7:5]) || (s3_gdiff <= 8'd31))	// 6b
			&& ((&s3_rgdiff[7:3]) || (s3_rgdiff <= 8'd7))	// 4b
			&& ((&s3_bgdiff[7:3]) || (s3_bgdiff <= 8'd7));	// 4b

		s4_rdiff <= s3_rdiff[1:0];
		s4_gdiff <= s3_gdiff[5:0];
		s4_bdiff <= s3_bdiff[1:0];
		//
		s4_rgdiff <= s3_rgdiff[3:0];
		s4_bgdiff <= s3_bgdiff[3:0];
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #5: Encode the output
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	initial	m_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		m_valid <= 1'b0;
	else if (!m_valid || m_ready)
		m_valid <= s4_valid && s4_ready;

	always @(posedge i_clk)
	if (i_reset)
		m_last <= 1'b0;
	else if (s4_valid && s4_ready)
		m_last <= s4_last;
	else if (m_ready)
		m_last <= 1'b0;

	always @(posedge i_clk)
	if (s4_valid && s4_ready)
	begin
		if (s4_rptset)
		begin
			m_data <= { 2'b11, s4_repeats, 24'h0 };
			m_bytes <= 2'd1;
		end else if (s4_tblset)
		begin
// $display("Encode: TBL[%02x] for %06x", s4_tblidx, s4_pixel);
			m_data <= { 2'b00, s4_tblidx, 24'h0 };
			m_bytes <= 2'd1;
		end else if (s4_small)
		begin
			m_data <= { 2'b01, s4_rdiff[1:0], s4_gdiff[1:0],
					s4_bdiff[1:0], 24'h0 };
			m_data[29:28] <= s4_rdiff[1:0] + 2'b10;
			m_data[27:26] <= s4_gdiff[1:0] + 2'b10;
			m_data[25:24] <= s4_bdiff[1:0] + 2'b10;
			m_bytes <= 2'd1;
		end else if (s4_bigdf)
		begin
			m_data <= { 2'b10, s4_gdiff[5:0],
				s4_rgdiff[3:0],
				s4_bgdiff[3:0], 16'h0 };
			m_data[29:24] <= s4_gdiff[5:0] + 6'h20;
			m_data[23:20] <= s4_rgdiff[3:0] + 4'h8;
			m_data[19:16] <= s4_bgdiff[3:0] + 4'h8;
			m_bytes <= 2'd2;
		end else begin
			m_data <= { 8'hfe, s4_pixel };
			m_bytes <= 2'd0;
		end
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Pipeline control (i.e. ready signals)
	// {{{

	assign	skd_ready = skd_valid && (!m_valid || m_ready) && !gbl_last;
	assign	s1_ready = gbl_ready;
	assign	s2_ready = gbl_ready;
	assign	s3_ready = gbl_ready;
	assign	s4_ready = gbl_ready;
	// assign	s4_ready = (!s4_valid || m_ready)
	//			&& (s2_valid || s3_last) && s3_valid;
	assign	gbl_ready = (skd_valid || gbl_last) && (!m_valid || m_ready);

	initial	gbl_last = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		gbl_last <= 1'b0;
	else if (skd_valid && skd_ready)
		gbl_last <= skd_hlast && skd_vlast;
	else if (m_valid && m_ready && m_last)
		gbl_last <= 1'b0;
	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal properties
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	reg	f_past_valid;
	(* anyconst *)	reg	[23:0]	fnvr_pixel;
	(* anyconst *)	reg	[5:0]	fc_index;
	reg		fc_valid;
	reg	[23:0]	fc_pixel;

	reg	[5:0]	f1_rhash, f1_ghash, f1_bhash;
	reg	[31:0]	f1_pcount;

	reg	[5:0]	f2_rhash, f2_ghash, f2_bhash, f2_index;
	reg	[7:0]	f2_gdiff;
	reg	[31:0]	f2_pcount;

	reg	[5:0]	f3_rhash, f3_ghash, f3_bhash, f3_index;
	reg	[7:0]	f3_gdiff, f3_rdiff, f3_bdiff;;
	reg	[7:0]	f3_rgdiff, f3_bgdiff;
	reg	[31:0]	f3_pcount;

	reg	[5:0]	f4_rhash, f4_ghash, f4_bhash, f4_index;
	reg	[7:0]	f4_gdiff, f4_rdiff, f4_bdiff;;
	reg	[7:0]	f4_rgdiff, f4_bgdiff;
	reg	[31:0]	f4_pcount;

	reg	[23:0]	fm_pixel, flst_pixel, fm_luna, fm_delta;
	reg	[31:0]	fm_pcount;
	reg	[ 7:0]	fm_vg;

	(* anyconst *)	reg	fnvr_last;


	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(i_reset);
	////////////////////////////////////////////////////////////////////////
	//
	// Global Pipeline handling assertions
	// {{{
	always @(*)
	if (f_past_valid)
	case({ s1_valid, s2_valid, s3_valid, s4_valid })
	4'b0000: assert(f1_pcount == 0);
	4'b1000: begin
		assert(f1_pcount == 1);
		assert(!m_valid);
		assert(!m_last);
		assert(!s1_last);
		end
	4'b1100: begin
		assert(f1_pcount == 2);
		assert(f2_pcount == 1);
		assert(!m_valid && !m_last && !s2_last && !s1_last);
		assert(!m_last);
		assert(!s2_last);
		assert(!s1_last);
		end
	4'b1110: begin
		assert(f1_pcount >= 3);
		// assert(!m_valid);
		assert(!m_last);
		assert(!s4_last);
		assert(!s3_last);
		assert(!s2_last);
		assert(s1_last == gbl_last);
		end
	4'b1111: begin
		assert(f1_pcount >= 4);
		assert(!s3_rptvalid || s3_repeats == 0);
		assert(!m_last);
		assert(!s4_last);
		assert(!s3_last);
		assert(!s2_last);
		assert(s1_last == gbl_last);
		end
	4'b0110: begin
		assert(f1_pcount == 0);
		assert(f2_pcount >= 3);
		assert(gbl_last);
		assert(s2_last);
		assert(!s3_last);
		assert(s3_rptvalid);
		assert(!m_last);
		// assert(!s4_last);
		end
	4'b0111: begin
		assert(f1_pcount == 0);
		assert(f2_pcount >= 3);
		assert(gbl_last);
		assert(s2_last);
		assert(!s3_last);
		assert(!s4_last);
		assert(!s3_rptvalid || s3_repeats == 0);
		assert(!m_last);
		end
	4'b0010: begin
		assert(f1_pcount == 0);
		assert(f3_pcount >= 3);
		assert(gbl_last);
		assert(s3_last);
		assert(!m_last);
		end
	4'b0011: begin
		assert(f1_pcount == 0);
		assert(f3_pcount >= 3);
		assert(gbl_last);
		assert(s3_last);
		assert(!s4_last);
		assert(!s3_rptvalid || s3_repeats == 0);
		assert(!m_last);
		end
	4'b0001: begin
		assert(gbl_last);
		assert(s4_last);
		assert(!s3_rptvalid && s3_repeats == 0);
		assert(!m_last);
		end
	default: assert(0);
	endcase

	always @(*)
	if (f_past_valid && !s1_valid && !s2_valid && !s3_valid && !s4_valid
			&& (!m_valid || !m_last))
		assert(!gbl_last);

	always @(*)
	if(f_past_valid && (s1_last || s2_last || s3_last || s4_last || m_last))
		assert(gbl_last);

	always @(*)
	if (f_past_valid)
	begin
		if (!s1_valid) assert(!s1_last);
		if (!s2_valid) assert(!s2_last);
		if (!s3_valid) assert(!s3_last);
		if (!s4_valid) assert(!s4_last);
		if (!m_valid)  assert(!m_last);
	end

	always @(*)
	if (!s3_valid) assume(!skd_valid || !skd_hlast || !skd_vlast);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Incoming properties
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assume(!s_vid_valid);
	else if ($past(s_vid_valid && !s_vid_ready))
	begin
		assume(s_vid_valid);
		assume($stable(s_vid_data));
		assume($stable(s_vid_hlast));
		assume($stable(s_vid_vlast));
	end

	always @(*)
	if (s_vid_valid)
		assume(s_vid_data != fnvr_pixel);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S1 assertions
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!s1_valid);
	else if ($past(s1_valid && !s1_ready))
	begin
		assert(s1_valid);
		assert($stable(s1_rhash));
		assert($stable(s1_ghash));
		assert($stable(s1_bhash));
		assert($stable(s1_last));
		assert($stable(s1_pixel));
	end

	always @(*)
	if (s1_valid)
		assert(s1_pixel != fnvr_pixel);

	always @(*)
	begin
		f1_rhash = (s1_pixel[23:16] << 1) + s1_pixel[23:16];
		f1_ghash = (s1_pixel[15: 8] << 2) + s1_pixel[15: 8];
		f1_bhash = (s1_pixel[ 7: 0] << 3) - s1_pixel[ 7: 0];
	end

	always @(*)
	if (s1_valid)
	begin
		assert(f1_rhash == s1_rhash);
		assert(f1_ghash == s1_ghash);
		assert(f1_bhash == s1_bhash);
	end

	initial	f1_pcount = 0;
	always @(posedge i_clk)
	if (i_reset)
		f1_pcount <= 0;
	else if (s1_valid && s1_ready && s1_last)
		f1_pcount <= (skd_valid && skd_ready) ? 1:0;
	else if (skd_valid && skd_ready)
		f1_pcount <= f1_pcount + 1;

	always @(*)
	if (f1_pcount == 0)
		assert(s1_pixel == 0);

	always @(*)
	if (&f1_pcount)
		assume(s1_valid && s1_last);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S2 assertions
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
	begin
		assert(!s2_valid);
		assert(s2_pixel == 0);
	end else if ($past(s2_valid && !s2_ready))
	begin
		assert(s2_valid);
		assert($stable(s2_tbl_index));
		assert($stable(s2_last));
		assert($stable(s2_gdiff));
		assert($stable(s2_pixel));
	end

	always @(*)
	if (s2_valid)
		assert(s2_pixel != fnvr_pixel);

	always @(*)
	begin
		f2_rhash = (s2_pixel[23:16] << 1) + s2_pixel[23:16];
		f2_ghash = (s2_pixel[15: 8] << 2) + s2_pixel[15: 8];
		f2_bhash = (s2_pixel[ 7: 0] << 3) - s2_pixel[ 7: 0];

		f2_index = f2_rhash + f2_ghash + f2_bhash + 6'h35;
		f2_gdiff = s2_pixel[15: 8] - s3_pixel[15: 8];
	end


	always @(posedge i_clk)
	if (s2_valid)
	begin
		assert(f2_index == s2_tbl_index);
		assert(f2_gdiff == s2_gdiff);
	end

	initial	f2_pcount = 0;
	always @(posedge i_clk)
	if (i_reset)
		f2_pcount <= 0;
	else if (s2_valid && s2_ready && s2_last)
		f2_pcount <= (s1_valid && s1_ready) ? 1 : 0;
	else if (s1_valid && s1_ready)
		f2_pcount <= f2_pcount + 1;

	always @(*)
	if (s2_valid && !s2_last)
		assert(f2_pcount < 32'hffff_ffff);


	always @(*)
	if (f2_pcount == 0)
		assert(s2_pixel == 0);

	always @(*)
	if (s2_valid && s2_last)
		assert(f1_pcount == 0);

	always @(*)
	if (!s2_valid || !s2_last)
		assert(f1_pcount == f2_pcount + (s1_valid ? 1:0));

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S3 assertions
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
	begin
		assert(!s3_valid);
		assert(s3_pixel == 0);
	end else if ($past(s3_valid && !s3_ready))
	begin
		assert(s3_valid);

		// Table lookup
		assert($stable(s3_tbl_valid));
		assert($stable(s3_tbl_pixel));
		assert($stable(s3_tblidx));

		assert($stable(s3_rptvalid));

		assert($stable(s3_pixel));
		assert($stable(s3_last));

		assert($stable(s3_rdiff));
		assert($stable(s3_gdiff));
		assert($stable(s3_bdiff));
		assert($stable(s3_rgdiff));
		assert($stable(s3_bgdiff));
	end

	always @(*)
	if (s3_valid)
		assert(s3_pixel != fnvr_pixel);

	always @(*)
	if (!s3_rptvalid)
		assert(s3_repeats == 0);
	else
		assert(s3_repeats <= 6'h3d);

	always @(*)
	begin
		f3_rhash = (s3_pixel[23:16] << 1) + s3_pixel[23:16];
		f3_ghash = (s3_pixel[15: 8] << 2) + s3_pixel[15: 8];
		f3_bhash = (s3_pixel[ 7: 0] << 3) - s3_pixel[ 7: 0];

		f3_index = f3_rhash + f3_ghash + f3_bhash + 6'h35;
		f3_gdiff = s3_pixel[15: 8] - s4_pixel[15: 8];

		f3_rdiff = s3_pixel[23:16] - s4_pixel[23:16];
		f3_bdiff = s3_pixel[ 7: 0] - s4_pixel[ 7: 0];

		f3_rgdiff = (s3_pixel[23:16] - s4_pixel[23:16]) - s3_gdiff;
		f3_bgdiff = (s3_pixel[ 7: 0] - s4_pixel[ 7: 0]) - s3_gdiff;
	end

	always @(*)
	if (s3_valid)
	begin
		assert(s3_tblidx == f3_index);
		if (!s3_rptvalid)
		begin
			assert(s3_rdiff  == f3_rdiff);
			assert(s3_gdiff  == f3_gdiff);
			assert(s3_bdiff  == f3_bdiff);

			assert(s3_rgdiff  == f3_rgdiff);
			assert(s3_bgdiff  == f3_bgdiff);

			assert(s3_pixel != s4_pixel);
		end else
			assert(s3_pixel == s4_pixel);
	end else if (f3_pcount == 0)
		assert(s3_pixel == 0);
	else
		assert(s3_pixel == s4_pixel);

	initial	f3_pcount = 0;
	always @(posedge i_clk)
	if (i_reset)
		f3_pcount <= 0;
	else if (s3_valid && s3_ready && s3_last)
		f3_pcount <= (s2_valid && s2_ready) ? 1 : 0;
	else if (s2_valid && s2_ready)
		f3_pcount <= f3_pcount + 1;

	always @(*)
	if (s3_valid && !s3_last)
		assert(f3_pcount < 32'hffff_ffff);

	always @(*)
	if (f3_pcount == 0)
		assert(s3_pixel == 0);

	always @(*)
	if (s3_valid && s3_last)
		assert(f2_pcount == 0);

	always @(*)
	if (!s3_valid || !s3_last)
		assert(f2_pcount == f3_pcount + (s2_valid ? 1:0));

	always @(*)
	if (!s3_valid && (!s4_valid || !s4_last))
		assert(s3_pixel == s4_pixel);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// S4 assertions
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
	begin
		assert(!s4_valid);
		assert(s4_pixel == 0);
	end else if ($past(s4_valid && !s4_ready))
	begin
		assert(s4_valid);
		assert($stable(s4_tblset));
		assert($stable(s4_rptset));
		assert($stable(s4_last));
		assert($stable(s4_small));
		assert($stable(s4_bigdf));
		assert($stable(s4_tblidx));
		assert($stable(s4_repeats));
		assert($stable(s4_pixel));
		assert($stable(s4_rgdiff));
		assert($stable(s4_bgdiff));
		assert($stable(s4_rdiff));
		assert($stable(s4_gdiff));
		assert($stable(s4_bdiff));
	end

	always @(*)
	if (s4_valid)
		assert(s4_pixel != fnvr_pixel);

	always @(*)
	if (s4_rptset)
	begin
		assert(s4_repeats <= 6'h3d);
		if (s4_valid)
			assert(s4_pixel == fm_pixel);
	end else if (s4_valid)
		assert(s4_pixel != fm_pixel);

	always @(*)
	begin
		f4_rhash = (s4_pixel[23:16] << 1) + s4_pixel[23:16];
		f4_ghash = (s4_pixel[15: 8] << 2) + s4_pixel[15: 8];
		f4_bhash = (s4_pixel[ 7: 0] << 3) - s4_pixel[ 7: 0];

		f4_index = f4_rhash + f4_ghash + f4_bhash + 6'h35;
		f4_gdiff = s4_pixel[15: 8] - fm_pixel[15: 8];

		f4_rdiff = s4_pixel[23:16] - fm_pixel[23:16];
		f4_bdiff = s4_pixel[ 7: 0] - fm_pixel[ 7: 0];

		f4_rgdiff = (s4_pixel[23:16] - fm_pixel[23:16]) - f4_gdiff;
		f4_bgdiff = (s4_pixel[ 7: 0] - fm_pixel[ 7: 0]) - f4_gdiff;
	end

	always @(*)
	if (s4_valid)
	begin
		if (s4_small && !s4_rptset)
		begin
			assert(f4_rdiff == { {(6){s4_rdiff[1]}}, s4_rdiff });
			assert(f4_gdiff == { {(6){s4_gdiff[1]}},s4_gdiff[1:0]});
			assert(f4_bdiff == { {(6){s4_bdiff[1]}}, s4_bdiff });
		end

		if (s4_bigdf && !s4_rptset)
		begin
			assert(f4_rgdiff == { {(4){s4_rgdiff[3]}}, s4_rgdiff });
			assert(f4_gdiff  == { {(2){s4_gdiff[5] }}, s4_gdiff });
			assert(f4_bgdiff == { {(4){s4_bgdiff[3]}}, s4_bgdiff });
		end
	end

	initial	f4_pcount = 0;
	always @(posedge i_clk)
	if (i_reset)
		f4_pcount <= 0;
	else if (s4_valid && s4_ready && s4_last)
		f4_pcount <= 0;
	else if (s3_valid && s3_ready && (!s3_rptvalid || !s3_continue))
		f4_pcount <= f4_pcount + 1 + s3_repeats;

	always @(*)
	if (!s4_valid && (!m_valid || !m_last))
		assert(s4_pixel == fm_pixel);

	always @(*)
	if (s4_valid && s4_rptset)
		assert(f4_pcount >= s4_repeats+1);

	always @(*)
	if (s4_valid && !s4_last)
		assert(f4_pcount < 32'hffff_ffff);

	always @(*)
	if (f4_pcount == 0)
		assert(s4_pixel == 0);

	always @(*)
	if (s4_valid && s4_last)
	begin
		assert(f3_pcount == 0);
	end else
		assert(f4_pcount <= f3_pcount);

	always @(*)
	if (!s4_valid || !s4_last)
		assert(f3_pcount == f4_pcount+ ((s3_valid || s3_rptvalid ? 1:0))
			+ s3_repeats);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Final result assertions
	// {{{
	//
	// Rules:
	//	(AXI Stream rules ...)
	//	Cannot have two table entries to the same index in a row
	//	No references to ALPHA
	//	The decoded pixel must not equal the never pixel
	//	The decoded pixel must equal the requested pixel
	//		* 8'hff, then fm_pixel == m_data[23:0]
	//		* 2'b11, then fm_pixel must equal table pixel
	//			(or table must've been overwritten)
	//			(Proven at step 3, not step 4 or m* step)
	//		* 2'b00, Last pixel must be the repeating pixel value
	//		*!2'b00, Last pixel must be different from the current
	//			one
	//		* 2'b01, Decoded pixel must match
	//		* 2'b10, Decoded pixel must match
	//		* (No incoming last, no outgoing last)
	//		* # pixels in == # pixels out

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!m_valid);
	else if ($past(m_valid && !m_ready))
	begin
		assert(m_valid);
		assert($stable(m_data));
		assert($stable(m_bytes));
		assert($stable(m_last));
	end

	initial	fm_pixel = 0;
	always @(posedge i_clk)
	if (i_reset)
		fm_pixel <= 0;
	else begin
		if (m_valid && m_ready && m_last)
			fm_pixel <= 0;
		if (s4_valid && s4_ready)
			fm_pixel <= s4_pixel;
	end

	always @(*)
	if (m_valid)
	case(m_data[31:30])
	2'b11: begin
		assert(m_data[31:24] != 8'hff);
		if (m_data[31:24] == 8'hfe)
		begin
			assert(m_bytes == 2'd0);
			assert(m_data[23:0] != fnvr_pixel);
			assert(m_data[23:0] == fm_pixel);
			assert(m_data[23:0] != flst_pixel);
		end else begin
			// Repeated pixel
			assert(m_bytes == 2'd1);
			assert(fm_pixel == flst_pixel);
		end end
	2'b00: begin
		assert(m_bytes == 2'd1);
		// if (m_data[29:24] == fc_index) assert(fc_valid);
		end
	2'b01: begin
		assert(m_bytes == 2'd1);
		assert(fm_delta == fm_pixel);
		end
	2'b10: begin
		assert(m_bytes == 2'd2);
		assert(fm_luna == fm_pixel);
		end
	endcase

	always @(*)
	if(m_valid)
		assert(fm_pixel != fnvr_pixel);

	always @(*)
	if(m_valid)
	case(m_bytes)
	2'b00: begin end
	2'b01: assert(m_data[23:0] == 24'h0);
	2'b10: assert(m_data[15:0] == 16'h0);
	2'b11: assert(m_data[ 7:0] ==  8'h0);
	endcase

	initial	fm_pcount = 0;
	always @(posedge i_clk)
	if (i_reset)
		fm_pcount <= 0;
	else if (m_valid && m_ready && m_last)
		fm_pcount <= 0;
	else if (s4_valid && s4_ready)
	begin
		if (s4_rptset)
			fm_pcount <= fm_pcount + s4_repeats + 1;
		else
			fm_pcount <= fm_pcount + 1;
	end

	always @(*)
	if (!m_valid || !m_last)
		assert(f4_pcount == fm_pcount + (s4_valid ? 1:0)
				+ ((s4_valid && s4_rptset) ? s4_repeats : 0));

	initial	flst_pixel = 0;
	always @(posedge i_clk)
	if (i_reset || (m_valid && m_ready && m_last))
		flst_pixel <= 0;
	else if (m_valid && m_ready)
		flst_pixel <= fm_pixel;

	always @(*)
	if (!m_valid)
		assert(flst_pixel == fm_pixel);

	always @(*)
	begin
		fm_delta[23:16] = flst_pixel[23:16] + m_data[29:28] - 2;
		fm_delta[15: 8] = flst_pixel[15: 8] + m_data[27:26] - 2;
		fm_delta[ 7: 0] = flst_pixel[ 7: 0] + m_data[25:24] - 2;

		fm_vg = m_data[29:24] - 32;
		fm_luna[23:16] = flst_pixel[23:16] + fm_vg - 8 + m_data[23:20];
		fm_luna[15: 8] = flst_pixel[15: 8] + fm_vg;
		fm_luna[ 7: 0] = flst_pixel[ 7: 0] + fm_vg - 8 + m_data[19:16];
	end

	always @(*)
	if (fm_pcount == 0)
	begin
		assert(fm_pixel == 0);
		assert(flst_pixel == 0);
	end

	always @(*)
	if (m_valid && !m_last)
		assert(fm_pcount < 32'hffff_ffff);

	always @(*)
	if (fnvr_last)
		assume(!s_vid_valid || !s_vid_hlast || !s_vid_vlast);

	always @(*)
	if (f_past_valid && fnvr_last)
	begin
		assert(!gbl_last);
		assert(!s1_last);
		assert(!s2_last);
		assert(!s3_last);
		assert(!s4_last);
		assert(!m_last);
	end


	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Table checking
	// {{{
	reg		f3_tbl_valid;
	reg	[23:0]	f3_tbl_pixel;

	initial	fc_valid = 0;
	always @(posedge i_clk)
	if (i_reset)
		fc_valid <= 0;
	else if (s2_valid && s2_ready && s2_last)
		fc_valid <= 0;
	else if (s2_valid && s2_ready && s2_tbl_index == fc_index)
		fc_valid <= 1'b1;

	always @(*)
		assert(tbl_valid[fc_index] == fc_valid);


	always @(posedge i_clk)
	if (s2_valid && s2_ready && s2_tbl_index == fc_index)
		fc_pixel <= s2_pixel;

	always @(*)
	if (fc_valid)
		assert(tbl_pixel[fc_index] == fc_pixel);

	always @(posedge i_clk)
	if (s2_valid && s2_ready && s2_tbl_index == fc_index)
		f3_tbl_valid <= fc_valid;

	always @(posedge i_clk)
	if (s2_valid && s2_ready && s2_tbl_index == fc_index)
		f3_tbl_pixel <= fc_pixel;

	always @(*)
	if (s3_valid && s3_tblidx == fc_index && !s3_last)
	begin
		assert(fc_valid);
		assert(fc_pixel == s3_pixel);
		assert(f3_tbl_valid == s3_tbl_valid);
		assert(!s3_tbl_valid || f3_tbl_pixel == s3_tbl_pixel);
	end

	always @(*)
	if (s4_valid && s4_tblidx == fc_index && !s4_last
			&&(!s3_valid || !s3_last))
	begin
		if (s3_valid && s3_tblidx == fc_index)
		begin
			assert(fc_pixel == s3_pixel);
		end else if (s4_tblset)
		begin
			assert(fc_valid);
			assert(fc_pixel == s4_pixel);
			if (m_valid && s4_tblset)
			begin
				// assert(m_data[31:24] != { 2'b00, fc_index });
			end
		end
	end

	always @(*)
	if (m_valid && m_data[31:30] == 2'b00)
	begin
		// Can't have two TBL code words to the same table entry on
		// two consecutive code words--should do repeats instead
		// assert(s4_valid || !s4_tblset || s4_tblidx != m_data[29:24]);
		// if (!s4_valid) assert(fm_pixel == s4_pixel);
		if (!m_last && (!s4_valid || (!s4_last && s4_tblidx != m_data[29:24]))
			&& (fc_index == m_data[29:24])
			&& (!s3_valid || (!s3_last && s3_tblidx != m_data[29:24] && !s4_last)))
		begin
			assert(fc_valid);
			assert(fc_pixel == fm_pixel);
		end
	end

	always @(*)
	if (s3_valid && s3_last)
		assert(tbl_valid == 0);

	always @(*)
	if (s4_valid && s4_last)
		assert(tbl_valid == 0);

	always @(*)
	if (m_valid && m_last)
		assert(tbl_valid == 0);

	//	assert($stable(s3_tbl_pixel));
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Careless assumptions
	// {{{

	// always @(*) assume(!s3_rptvalid);
	// }}}
`endif
// }}}
endmodule
