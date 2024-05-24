////////////////////////////////////////////////////////////////////////////////
//
// Filename:	qoi_encoder.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	Top level QOI image processing file.  This file is primarily
//		a wrapper around qoi_encoder.  It's purpose is threefold.
//	First, it converts from Xilinx's video format (TUSER=SOF, TLAST=HLAST)
//	to my video format (TUSER=HLAST, TLAST=VLAST).  This process also
//	counts the image size.  Second, it adds the QOI required header.
//	Once the header passes, the image pipe becomes a pass through to the
//	end of the image data.  The third purpose is then to add the required
//	QOI trailer to the image stream.
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
module	qoi_encoder #(
		// {{{
		parameter	[0:0]	OPT_TUSER_IS_SOF = 1'b0,
		parameter		DW = 64,
		localparam		DB = DW/8,
		localparam		LGDB = $clog2(DB)
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_reset,
		//
		input	wire		s_valid,
		output	wire		s_ready,
		input	wire	[23:0]	s_data,
		input	wire		s_last, s_user,
		//
		output	reg			o_qvalid,
		input	wire			i_qready,
		output	reg	[DW-1:0]	o_qdata,
		output	reg	[LGDB-1:0]	o_qbytes,
		output	reg			o_qlast
		// }}}
	);

	// Local declarations
	// {{{
	// STATE:
	//	NO_SYNC
	//	START	(Have seen the end of the current line/frame)
	//	SYNCD	(Have seen two end of lines/frames)
	localparam	[1:0]	S_NO_SYNC = 2'b00,
				S_START   = 2'b01,
				S_SYNCD   = 2'b10;

	wire		s_hlast;
	reg	[1:0]	h_state;
	reg	[15:0]	h_count, h_width;

	wire		syncd, s_vlast;
	reg	[1:0]	v_state;
	reg	[15:0]	v_count, v_height;

	wire		e_valid, e_ready;

	wire		enc_valid, enc_ready, enc_last;
	wire	[31:0]	enc_data;
	wire	[1:0]	enc_bytes;

	reg	[3:0]	frm_state;
	reg		frm_valid, frm_last;
	reg	[31:0]	frm_data;
	reg	[1:0]	frm_bytes;
	wire		frm_ready;


	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step #1: HSYNC
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	assign	s_hlast = (OPT_TUSER_IS_SOF) ? s_last : s_user;

	initial	h_state = S_NO_SYNC;
	always @(posedge i_clk)
	if (i_reset)
		h_state <= S_NO_SYNC;
	else if (s_valid && s_ready && s_last)
	case(h_state)
	S_NO_SYNC: h_state <= S_START;
	default: h_state <= S_SYNCD;
	endcase

	initial	{ h_count, h_width } = 0;
	always @(posedge i_clk)
	if (i_reset)
		{ h_count, h_width } <= 0;
	else if (s_valid && s_ready)
	begin
		if (s_hlast)
		begin
			h_count <= 0;
			h_width <= h_count + 1;
		end else
			h_count <= h_count + 1;
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step 2: VSYNC and SOF conversion
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	generate if (OPT_TUSER_IS_SOF)
	begin : GEN_VLAST
		wire	s_sof;
		reg	r_vlast, r_syncd;

		assign	s_sof = s_user;

		always @(posedge i_clk)
		if (i_reset)
			v_state <= S_NO_SYNC;
		else if (s_valid && s_ready && s_sof)
		case(v_state)
		S_NO_SYNC: v_state <= S_START;
		default: v_state <= S_SYNCD;
		endcase

		initial	{ v_count, v_height } = 0;
		always @(posedge i_clk)
		if (i_reset)
			{ v_count, v_height } <= 0;
		else if (s_valid && s_ready)
		begin
			if (s_sof)
			begin
				v_count  <= 0;
				v_height <= v_count;
			end else if (s_hlast)
				v_count <= v_count + 1;
		end

		initial	r_vlast = 0;
		always @(posedge i_clk)
		if (i_reset)
			r_vlast <= 0;
		else if (s_valid && s_ready)
		begin
			r_vlast <= (v_count + 1 == v_height);
			if (v_state != S_SYNCD)
				r_vlast <= 1'b0;
		end

		assign	s_vlast = r_vlast;

		always @(*)
		begin
			r_syncd = (v_state == S_SYNCD);
			if (v_state == S_START && s_valid && s_sof)
				r_syncd = 1'b1;

			if (h_state != S_SYNCD)
				r_syncd = 1'b0;
		end

		assign	syncd = r_syncd;
	end else begin : GEN_SIZES
		// No conversion required
		assign	s_vlast = s_last;

		// Still need to count the number of lines though ...
		always @(posedge i_clk)
		if (i_reset)
			v_state <= S_START;
		else if (s_valid && s_ready && s_vlast && s_hlast)
		case(v_state)
		S_NO_SYNC: v_state <= S_START;
		default: v_state <= S_SYNCD;
		endcase

		initial	{ v_count, v_height } = 0;
		always @(posedge i_clk)
		if (i_reset)
			{ v_count, v_height } <= 0;
		else if (s_valid && s_ready)
		begin
			if (s_hlast && s_vlast)
			begin
				v_count  <= 0;
				v_height <= v_count + 1;
			end else if (s_hlast)
				v_count <= v_count + 1;
		end

		assign	syncd = (h_state == S_SYNCD) && (v_state == S_SYNCD);
	end endgenerate

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step 3: Image encoder
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	assign	e_valid = syncd && s_valid;
	assign	s_ready = !syncd || e_ready;

	qoi_encoder
	u_encoder (
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.s_vid_valid(e_valid), .s_vid_ready(e_ready),
		.s_vid_data(s_data),
		.s_vid_hlast(s_hlast), .s_vid_vlast(s_vlast),
		//
		.m_valid(enc_valid), .m_ready(enc_ready),
		.m_data( enc_data), .m_bytes(enc_bytes),
		.m_last( enc_last)
	);

	assign	enc_ready = (frm_state == FRM_DATA)&&(!frm_valid || frm_ready);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step 4: state machine: header and trailer
	// {{{

	localparam [3:0]	FRM_IDLE      = 4'h0,
				FRM_START     = 4'h1,
				FRM_HDRMAGIC  = 4'h2,
				FRM_HDRWIDTH  = 4'h3,
				FRM_HDRHEIGHT = 4'h4,
				FRM_HDRFORMAT = 4'h5,
				FRM_DATA      = 4'h6,
				FRM_TRAILER   = 4'h7,
				FRM_LAST      = 4'h8;

	always @(posedge i_clk)
	if (i_reset || !syncd)
	begin
		frm_state <= FRM_IDLE;
		frm_valid <= 1'b0;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
	end else if (!frm_valid || frm_ready)
	case(frm_state)
	FRM_IDLE: begin
		if (syncd && s_valid)
			frm_state <= FRM_START;
		frm_valid <= 1'b0;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_START: begin
		frm_state <= FRM_HDRMAGIC;
		frm_valid <= 1'b1;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRMAGIC: begin
		frm_state <= FRM_HDRWIDTH;
		frm_valid <= 1'b1;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRWIDTH: begin
		frm_state <= FRM_HDRHEIGHT;
		frm_valid <= 1'b1;
		frm_data  <= { 16'h0, h_width };
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRHEIGHT: begin
		frm_state <= FRM_HDRFORMAT;
		frm_valid <= 1'b1;
		frm_data  <= { 16'h0, v_height };
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRFORMAT: begin
		frm_state <= FRM_DATA;
		frm_valid <= 1'b1;
		frm_data  <= { 8'd3, 8'd1, 16'h0 };
		frm_bytes <= 2'b10;
		frm_last  <= 1'b0;
		end
	FRM_DATA: begin
		if (enc_valid && enc_last)
			frm_state <= FRM_TRAILER;
		frm_valid <= enc_valid;
		case(enc_bytes)
		2'b00: frm_data  <= enc_data;
		2'b01: frm_data  <= { enc_data[31:24], 24'h0 };
		2'b10: frm_data  <= { enc_data[31:16], 16'h0 };
		2'b11: frm_data  <= { enc_data[31: 8],  8'h0 };
		endcase
		frm_bytes <= enc_bytes;
		frm_last  <= 1'b0;
		end
	FRM_TRAILER: begin
		frm_state <= FRM_LAST;
		frm_valid <= 1'b1;
		frm_data  <= 32'h0;
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_LAST: begin
		frm_state <= FRM_IDLE;
		frm_valid <= 1'b1;
		frm_data  <= 32'h01;
		frm_bytes <= 2'b00;
		frm_last  <= 1'b1;
		end
	default: begin
		frm_state <= FRM_IDLE;
		frm_valid <= 1'b0;
		frm_data  <= 32'b0;
		frm_bytes <= 2'b0;
		frm_last  <= 1'b0;
		end
	endcase

	// Verilator lint_off WIDTH
	assign	frm_ready = (!o_qvalid || i_qready)||(sr_fill < DB && !sr_last);
	// Verilator lint_on  WIDTH
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Step 5: Stream packing
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	reg	[DW+32-1:0]		sreg, new_data;
	reg	[$clog2(DW+32)-3:0]	sr_fill, new_fill;
	reg				sr_last, fl_last, flush;

	always @(*)
	begin
		new_fill = sr_fill;
		// Verilator lint_off WIDTH
		if (frm_valid && frm_ready)
		begin
			if (frm_bytes == 0)
				new_fill = new_fill + 2;
			else
				new_fill = new_fill + frm_bytes;
		end

		fl_last = sr_last;
		if (frm_valid && frm_ready && !sr_last
					&& (sr_fill + new_fill <= DB))
			fl_last = frm_last;

		flush = sr_last || frm_last;
		if (sr_fill >= DW/8)
			flush = 1'b1;
		if (frm_valid && frm_ready && (sr_fill + new_fill >= DB))
			flush = 1'b1;

		new_data = sreg| ({{(DW-32){1'b0}}, frm_data}
							<< (DW - (sr_fill*8)));
		// Verilator lint_on  WIDTH
	end

	always @(posedge i_clk)
	if (i_reset)
	begin
		sr_fill <= 0;
		o_qvalid <= 1'b0;
	end else if ((!o_qvalid || i_qready) && flush)
	begin
		o_qvalid <= 1'b1;
		// Verilator lint_off WIDTH
		sr_fill <= sr_fill + new_fill - DB;
		// Verilator lint_on  WIDTH
		if (sr_last)
			sr_fill <= (frm_valid) ? new_fill : 0;
		else if (fl_last)
			sr_fill <= 0;
	end else begin
		if (i_qready)
			o_qvalid <= 1'b0;
		if (frm_valid && frm_ready)
			sr_fill <= sr_fill + new_fill;
	end

	always @(posedge i_clk)
	if (i_reset)
		sreg <= 0;
	else if ((!o_qvalid || i_qready) && flush)
	begin
		if (sr_last)
			sreg <= (frm_valid) ? { frm_data, {(DW){1'b0}} } : {(DW+32){1'b0}};
		else if (fl_last)
			sreg <= 0;
		else if (frm_valid)
			sreg <= { new_data[31:0], {(DW){1'b0}} };
		else
			sreg <= 0;
	end else if (frm_valid && frm_ready)
		sreg <= new_data;

	always @(posedge i_clk)
	if (!o_qvalid || i_qready)
		o_qdata <= new_data[DW+31:32];

	always @(posedge i_clk)
	if (!o_qvalid || i_qready)
	begin
		// Verilator lint_off WIDTH
		if (sr_last)
			o_qbytes <= sr_fill[LGDB-1:0];
		else if (new_fill >= DB)
			o_qbytes <= 0;
		else
			o_qbytes <= new_fill;
		// Verilator lint_on  WIDTH
	end

	always @(posedge i_clk)
	if (i_reset || !syncd)
		sr_last <= 1'b0;
	else if ((!o_qvalid || i_qready) && flush)
		sr_last <= 1'b0;
	else if (frm_valid && frm_ready)
		sr_last <= frm_last;

	always @(posedge i_clk)
	if (!o_qvalid || i_qready)
		o_qlast <= fl_last;

	// }}}
endmodule
