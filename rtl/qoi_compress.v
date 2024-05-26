////////////////////////////////////////////////////////////////////////////////
//
// Filename:	rtl/qoi_compress.v
// {{{
// Project:	Quite OK image compression (QOI)
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

	reg		s1_valid, s1_hlast, s1_vlast;
	reg	[5:0]	s1_rhash, s1_ghash, s1_bhash;
	reg	[23:0]	s1_pixel;
	wire		s1_ready;

	reg		s2_valid, s2_hlast, s2_vlast;
	reg	[5:0]	s2_tbl_index;
	reg	[23:0]	s2_pixel;
	wire		s2_ready;

	reg		s3_valid, s3_hlast, s3_vlast, s3_tbl_valid, s3_rptvalid;
	reg	[23:0]	s3_pixel, s3_tbl_pixel;
	reg	[5:0]	s3_repeats, s3_tblidx;
	reg	[7:0]	s3_rdiff, s3_gdiff, s3_bdiff, s3_rgdiff, s3_bgdiff;
	wire		s3_continue, s3_ready;

	reg	[63:0]	tbl_valid;
	reg	[23:0]	tbl_pixel	[0:63];

	reg		s4_valid, s4_tblset, s4_rptset, s4_hlast, s4_vlast,
			s4_small, s4_bigdf;
	reg	[5:0]	s4_tblidx, s4_repeats, s4_gdiff;
	reg	[23:0]	s4_pixel;
	reg	[3:0]	s4_rgdiff, s4_bgdiff;
	reg	[1:0]	s4_rdiff, s4_bdiff;
	wire		s4_ready;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Skidbuffer
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	qoi_skid #(
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

	assign	skd_ready = !s1_valid || s1_ready;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #1: Pre-calculate hash data
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		s1_valid <= 0;
	else if (!s1_valid || s1_ready)
		s1_valid <= skd_valid;

	always @(posedge i_clk)
	if (skd_valid && skd_ready)
	begin
		s1_rhash <= skd_data[21:16] + { skd_data[20:16], 1'b0 };
		s1_ghash <= skd_data[13: 8] + { skd_data[11: 8], 2'b0 };
		s1_bhash <= { skd_data[2:0], 3'h0} - skd_data[ 5: 0];

		s1_hlast <= skd_hlast;
		s1_vlast <= skd_vlast;
		s1_pixel <= skd_data;
	end

	assign	s1_ready = !s2_valid || s2_ready;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #2: Finish calculating the hash table index
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		s2_valid <= 0;
	else if (!s2_valid || s2_ready)
		s2_valid <= s1_valid;

	always @(posedge i_clk)
	if (s1_valid && s1_ready)
	begin
		s2_tbl_index <= s1_rhash + s1_ghash + s1_bhash + 6'h35;

		s2_hlast <= s1_hlast;
		s2_vlast <= s1_vlast;
		s2_pixel <= s1_pixel;
	end

	assign	s2_ready = !s3_valid || s3_ready;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #3: Hash table lookup, calc differences, count repeats
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		s3_valid <= 0;
	else if (!s3_valid || s3_ready)
		s3_valid <= s2_valid;

	always @(posedge i_clk)
	if (i_reset)
	begin
		s3_repeats   <= 0;
		s3_rptvalid  <= 0;
	end else if (s2_valid && s2_ready)
	begin
		if (!s3_continue)
		begin
			s3_rptvalid <= 0;
			s3_repeats <= 0;
		end else if (!s3_rptvalid)
		begin
			s3_rptvalid  <= 1;
			s3_repeats <= 0;
		end else begin
			s3_rptvalid  <= 1;
			s3_repeats <= s3_repeats + 1;
		end
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
	always @(posedge i_clk)
	if (i_reset)
		tbl_valid <= 0;
	else if (s3_valid && s3_ready && s2_hlast && s2_vlast)
		tbl_valid <= 0;
	else if (s2_valid && s2_ready)
		tbl_valid[s2_tbl_index] <= 1'b1;

	always @(posedge i_clk)
	if (s2_valid && s2_ready)
		tbl_pixel[s2_tbl_index] <= s2_pixel;
	// }}}

	// s3_(everything else): tblidx, xdiff, xgdiff, xlast, && pixel
	// {{{
	always @(posedge i_clk)
	if (s2_valid && s2_ready)
	begin
		s3_tblidx <= s2_tbl_index;

		s3_rdiff <= s2_pixel[23:16] - s3_pixel[23:16];
		s3_gdiff <= s2_pixel[15: 8] - s3_pixel[15: 8];
		s3_bdiff <= s2_pixel[ 7: 0] - s3_pixel[ 7: 0];

		s3_rgdiff <= s2_pixel[23:16] - s3_pixel[15: 8];
		s3_bgdiff <= s2_pixel[ 7: 0] - s3_pixel[15: 8];

		s3_hlast <= s2_hlast;
		s3_vlast <= s2_vlast;
		s3_pixel <= s2_pixel;
	end
	// }}}

	assign	s3_continue = (s3_pixel == s2_pixel) &&(s3_repeats < 6'd61)
					&& !s3_hlast;
	assign	s3_ready = !s4_valid || s4_ready;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #4: Hash table compare, difference check
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		s4_valid <= 0;
	else if (!s4_valid || s4_ready)
		s4_valid <= s3_valid && (!s3_rptvalid || !s3_continue);

	always @(posedge i_clk)
	if (s3_valid && s3_ready)
	begin
		s4_tblset <= (s3_pixel == s3_tbl_pixel) && s3_tbl_valid;
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
		s4_bgdiff <= s3_rgdiff[3:0];

		s4_hlast <= s3_hlast;
		s4_vlast <= s3_vlast;
		s4_pixel <= s3_pixel;
	end

	assign	s4_ready = (!s4_valid || m_ready)
				&& (s2_valid || s3_hlast) && s3_valid;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #5: Encode the output
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		m_valid <= 1'b0;
	else if (!m_valid || m_ready)
		m_valid <= s4_valid && s4_ready;

	always @(posedge i_clk)
	if (s4_valid && s4_ready)
	begin
		if (s4_rptset)
		begin
			m_data <= { 2'b11, s4_repeats, 24'h0 };
			m_bytes <= 2'd1;
		end else if (s4_tblset)
		begin
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

		m_last <= s4_hlast && s4_vlast;
	end
	// }}}
endmodule
