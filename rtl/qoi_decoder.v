////////////////////////////////////////////////////////////////////////////////
//
// Filename:	qoi_decoder.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	Top level QOI image processing file.  This file is primarily
//		a wrapper around qoi_decompress.  It's purpose is threefold.
//
//	1. Strips the header from the incoming stream, copying width and height
//		information
//	2. Act as a gearbox on the incoming data stream, feeding single pixel
//		codewords to the decoder.
//	3. Recovers pixel data from the decoder
//	4. Adds TLAST and TUSER based on the given width and height information
//	5. Recognizes the video trailer, and ends decoding when seen.
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
module	qoi_decoder #(
		// {{{
		parameter	[0:0]	OPT_TUSER_IS_SOF = 1'b0,
		parameter		DW = 64,
		localparam		DB = DW/8,
		localparam		LGDB = $clog2(DB),
		localparam		LGFRAME = 32,
		localparam	[LGFRAME-1:0]	DEF_WIDTH = 800,
		localparam	[LGFRAME-1:0]	DEF_HEIGHT = 600
		// }}}
	) (
		// {{{
		input	wire			i_clk, i_reset,
		//
		input	reg			i_qvalid,
		output	wire			o_qready,
		input	reg	[DW-1:0]	i_qdata,
		input	reg	[LGDB-1:0]	i_qbytes,
		// qlast is a nice idea, but ... it's redundant.  How should
		// qlast be handled when there's already a last indicator within
		// the data stream as it is?
		// input reg			i_qlast
		//
		output	wire			m_valid,
		input	wire			m_ready,
		output	wire	[23:0]		m_data,
		output	wire			m_last, m_user,
		// }}}
	);

	// Local declarations
	// {{{
	localparam	[2:0]	DC_SYNC   = 0,
				DC_WIDTH  = 1,
				DC_HEIGHT = 2,
				DC_FORMAT = 3,
				DC_DATA   = 4;
				DC_TAIL   = 5;
	localparam	SRW = 56 + DW;

	reg	[2:0]		state;
	reg	[LGFRAME-1:0]	r_width, r_height;

	reg	[SRW-1:0]	sreg;
	wire	[LGDB:0]	wide_qbytes;
	reg			eoi_marker;

	reg		pre_valid, pre_last;
	reg	[39:0]	pre_data;
	wire		pre_ready;

	reg		in_valid, in_last;
	reg	[39:0]	in_data;

	reg			m_hlast, m_vlast, m_eof;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Strip off the image header and trailer, grabbing the height and width
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// 1. Reset the decompression algorithm.  Hold it in reset.
	// 2. Search for the SYNC, "qoif".
	//	Insist that this SYNC be aligned with a 32b word.
	//	If the image doesn't have it, wait until it shows up.
	// 3. Grab the header data (height/width) next.
	// 4. Ignore the next two bytes.
	//	Unpacking only 2 bytes will necessitate gearbox integration here
	// 5. For each code word, grab an appropriately sized word
	//	Count pixels--horizontal and vertical--going into the decoder.
	// 6. After HEIGHT * WIDTH - 1 pixels, mark decoder word as *LAST*.
	//	Ignore everything that might follow.
	// 7. Once HLAST+VLAST take place, reset the qoi_decompress module
	// 8. Go back to step 2, to search for the SYNC again
	//

	// nxt_step
	// {{{
	always @(*)
	begin
		if (state == DC_SYNC)
		begin
			// if (sreg[DW+32-1:DW] == "qoif")
			//	step = 4;
			if (sreg[SRW-8-1:SRW-32] == "qoi")
				nxt_step = 1;
			else if (sreg[SRW-16-1:SRW-32] == "qo")
				nxt_step = 2;
			else if (sreg[SRW-24-1:SRW-32] == "q")
				nxt_step = 3;
			else
				nxt_step = 4;
		end // else if (state == DC_SIZE)
		//	nxt_step = 4;
		else if (state == DC_FORMAT)
			nxt_step = 2;
		else if (state == DC_DATA)
		begin
			casez(sreg[SRW-1:SRW-8])
			8'b1111_1110: nxt_step = 4;
			8'b1111_1111: nxt_step = 5;
			8'b10??_????: nxt_step = 2;
			default:	nxt_step = 1;
			endcase
		end else
			nxt_step = 4;
	end
	// }}}

	always @(*)
		eoi_marker = (sreg[SRW-1:SRW-64] == 64'h01);

	// state
	// {{{
	always @(posedge i_clk)
	if (i_reset)
		state <= DC_SYNC;
	else case(state)
	DC_SYNC: if ((sreg_nvalid >= 4) && (sreg[DW+31-1:DW] == "qoif"))
		state <= DC_WIDTH;
	DC_WIDTH: if (sreg_nvalid >= 4)
		state <= DC_HEIGHT;
	DC_HEIGHT: if (sreg_nvalid >= 4)
		state <= DC_FORMAT;
	DC_FORMAT: if (sreg_nvalid >= 2)
		state <= DC_DATA;
	DC_DATA: begin
		if(sreg_nvalid >= 8 && eoi_marker && (!pre_valid || pre_ready))
			state <= DC_TAIL;
		// if (i_qvalid && o_qready && i_qlast)
		//	state <= DC_TAIL;
	DC_TAIL: if (m_valid && m_ready && m_eof)
		state <= DC_SYNC;
	endcase
	// }}}

	// r_width, r_height
	// {{{
	initial	r_width  = DEF_WIDTH;
	initial	r_height = DEF_HEIGHT;
	always @(posedge i_clk)
	if (i_reset)
	begin
		r_width  <= DEF_WIDTH;
		r_height <= DEF_HEIGHT;
	end else if (sreg_nvalid >= 4)
	begin
		if (state == DC_WIDTH)
			r_width <= sreg[SRW-32 +: LGFRAME];
		if (state == DC_HEIGHT)
			r_height <= sreg[SRW-32 +: LGFRAME];
	end
	// }}}

	// sreg_nvalid
	// {{{
	assign	wide_qbytes = (i_qbytes == 0) ? DB : { 1'b0, i_qbytes };

	always @(*)
	case{ (i_qvalid && o_qready), (sr_valid && sr_ready) })
	2'b00: nxt_nvalid = sreg_nvalid;
	2'b10: nxt_nvalid = sreg_nvalid + wide_qbytes;
	2'b01: nxt_nvalid = sreg_nvalid - nxt_step;
	2'b11: nxt_nvalid = sreg_nvalid + wide_qbytes - nxt_step;
	endcase

	always @(posedge i_clk)
	if (i_reset)
		sreg_nvalid <= 0;
	else
		sreg_nvalid <= nxt_nvalid;
	// }}}

	// sr_last
	// {{{
	always @(posedge i_clk)
	if (i_reset || (m_valid && m_ready && m_eof))
		sr_last <= 0;
	else begin
		// if (i_qvalid && i_qready && i_qlast)
		//	sr_last <= 1'b1;
		if (sr_valid && sr_ready && sreg_nvalid >= 8 && eoi_marker)
			sr_last <= 1'b1;
		// if (state != DC_DATA)
		//	sr_last <= 1'b0;
	end
	// }}}

	// sreg
	// {{{
	always @(posedge i_clk)
	if (i_reset || sr_last)
		sreg <= 0;
	else case{ (i_qvalid && o_qready), (sr_valid && sr_ready) })
	2'b00: begin end
	2'b10: sreg <= sreg | (i_qdata << (SRW - sreg_nvalid*8));
	2'b01: sreg <= sreg << (8*nxt_step);
	2'b11: sreg <= (sreg << (8*nxt_step)) | (i_qdata << (SRW-(8*nxt_nvalid)));
	endcase
	// }}}

	assign	sr_valid = (state == DC_DATA) && (sreg_nvalid >= 8);
	assign	sr_ready = !pre_valid || pre_ready || (state != DC_DATA);
	assign	o_qready = (state != DC_TAIL) && (SRW-sreg_nvalid >= DB);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// The *PRE*-pipeline stage -- used for recognizing EOI
	// {{{
	always @(posedge i_clk)
	if (i_reset)
		pre_valid <= 1'b0;
	else if (sr_valid && sr_ready)
		pre_valid <= (sreg_nvalid >= 8)&& (state == DC_DATA);
	else if (pre_ready)
		pre_valid <= 1'b0;

	always @(posedge i_clk)
	if (sr_valid && sr_ready)
		pre_data <= sreg[SRW-1:SRW-40];

	assign	pre_last = sreg_last;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// The feed stage
	// {{{
	always @(posedge i_clk)
	if (i_reset)
		in_valid <= 1'b0;
	else if (pre_valid && pre_ready)
		in_valid <= pre_valid && (state != DC_TAIL);
	else if (in_ready)
		in_valid <= 1'b0;

	always @(posedge i_clk)
	if (pre_valid && pre_ready)
		in_data <= pre_data;

	always @(posedge i_clk)
	if (pre_valid && pre_ready)
		in_last <= pre_last;

	assign	in_ready = (sr_nvalid >= 8)&&(!pre_valid || pre_ready);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Decompress
	// {{{
	////////////////////////////////////////////////////////////////////////
	//

	qoi_decompress #(
		.LGWID(16)
	) u_decompress (
		// {{{
		.i_clk(i_clk),
		.i_reset(i_reset || lcl_reset || (m_valid && m_eof)),
		//
		.i_width(r_width),
		.i_height(r_height),
		//
		.s_valid(in_valid),
		.s_ready(in_ready),
		.s_data(in_data),
		.s_last(in_last),
		//
		.m_valid(d_valid),
		.m_ready(d_ready),
		.m_data(d_pixel),
		.m_last(d_last)
		// }}}
	);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Add TLAST + TUSER (Either HLAST+VLAST, or HLAST+SOF)
	// {{{
	always @(posedge i_clk)
	if (i_reset)
		m_valid <= 1'b0;
	else if (!m_valid || m_ready)
		m_valid <= d_valid || (lcl_reset && midframe);

	always @(posedge i_clk)
	if (i_reset)
		lcl_reset <= 1'b0;
	else if (m_valid && m_ready && m_eof)
		lcl_reset <= 1'b0;
	else if (d_valid && d_ready && d_last)
		lcl_reset <= 1'b1;

	always @(posedge i_clk)
	if (d_valid && d_ready)
		m_data <= d_pixel;

	always @(posedge i_clk)
	if (i_reset)
	begin
		xpos <= 0;
		ypos <= 0;
		midframe <= 1'b0;
		m_hlast <= 0;
		m_vlast <= 0;
	end else if (m_valid && m_ready)
	begin
		xpos <= xpos + 1;
		midframe <= 1'b1;
		m_hlast <= (xpos + 2 >= r_width);
		if (xpos + 1 >= r_width)
		begin
			m_hlast <= 1'b0;
			xpos <= 0;
			m_vlast <= (ypos + 2 >= r_height);
			if (ypos + 1 >= r_height)
			begin
				m_vlast <= 1'b0;
				ypos <= 0;
				midframe <= 1'b0;
			end
		end
	end

	assign	m_eof = m_hlast && m_vlast;

	generate if (OPT_TUSER_IS_SOF)
	begin : GEN_SOF
		reg	m_sof;
		always @(posedge i_clk)
		if (i_reset)
			m_sof <= 1'b1;
		else if (m_valid && m_ready)
			m_sof <= m_eof;

		assign	m_last = m_hlast;
		assign	m_user = m_sof;
	end else begin : GEN_EOF
		assign	m_last = m_eof;
		assign	m_user = m_hlast;
	end endgenerate

	// }}}
endmodule
