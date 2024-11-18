////////////////////////////////////////////////////////////////////////////////
//
// Filename:	./rtl/qoi_encoder.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	Top level QOI image processing file.  This file is primarily
//		a wrapper around qoi_compress.  It's purpose is threefold.
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
		parameter	[0:0]	OPT_LOWPOWER = 1'b0,
		parameter	[15:0]	LGFRAME=16,
		parameter		DW = 64,
		localparam		DB = DW/8,
		localparam		LGDB = $clog2(DB)
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_reset,
		//
		input	wire			s_valid,
		output	wire			s_ready,
		input	wire	[23:0]		s_data,
		input	wire			s_last, s_user,
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
	reg	[LGFRAME-1:0]	h_count, h_width;

	wire		syncd, s_vlast;
	reg	[1:0]	v_state;
	reg	[LGFRAME-1:0]	v_count, v_height;

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
	else if (s_valid && s_ready && s_hlast)
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
		// {{{
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
		else if (s_valid && s_ready && s_hlast)
		begin
			r_vlast <= (v_count + 2 >= v_height);
			if (v_state != S_SYNCD)
				r_vlast <= 1'b0;
			else if (r_vlast && s_hlast)
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
		// }}}
	end else begin : GEN_SIZES
		// {{{
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
		// }}}
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

`ifdef	FORMAL
	(* anyseq *)	reg	f_ready, f_last, f_valid;
	(* anyseq *)	reg	[31:0]	f_data;
	(* anyseq *)	reg	[1:0]	f_bytes;

	assign	e_ready   = f_ready;
	assign	enc_valid = f_valid;
	assign	enc_data  = f_data;
	assign	enc_bytes = f_bytes;
	assign	enc_last  = f_last;
`else
	qoi_compress
	u_compress (
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
`endif

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
		frm_valid <= 1'b0;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRMAGIC: begin
		if (!o_qvalid && !sr_last)
		begin
		frm_state <= FRM_HDRWIDTH;
		frm_valid <= 1'b1;
		frm_data  <= "qoif";
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end end
	FRM_HDRWIDTH: begin
		frm_state <= FRM_HDRHEIGHT;
		frm_valid <= 1'b1;
		frm_data  <= { {(32-LGFRAME){1'b0}}, h_width };
		frm_bytes <= 2'b00;
		frm_last  <= 1'b0;
		end
	FRM_HDRHEIGHT: begin
		frm_state <= FRM_HDRFORMAT;
		frm_valid <= 1'b1;
		frm_data  <= { {(32-LGFRAME){1'b0}}, v_height };
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
	assign	frm_ready = ((!o_qvalid || i_qready)&&sr_fill <= DB)||(sr_fill < DB && !sr_last);
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
				new_fill = new_fill + 4;
			else
				new_fill = new_fill + frm_bytes;
		end

		fl_last = sr_last;
		if (frm_valid && frm_ready && !sr_last
					&& (new_fill <= DB))
			fl_last = frm_last;

		flush = sr_last || frm_last;
		if (sr_fill >= DW/8)
			flush = 1'b1;
		if (frm_valid && frm_ready && (new_fill >= DB))
			flush = 1'b1;

		new_data = sreg| ({{(DW){1'b0}}, frm_data}
							<< (DW - (sr_fill*8)));
		// Verilator lint_on  WIDTH
	end

	initial	o_qvalid = 0;
	initial	sr_fill = 0;
	always @(posedge i_clk)
	if (i_reset)
	begin
		sr_fill <= 0;
		o_qvalid <= 1'b0;
	end else if ((!o_qvalid || i_qready) && flush)
	begin
		o_qvalid <= 1'b1;
		// Verilator lint_off WIDTH
		sr_fill <= new_fill - DB;
		// Verilator lint_on  WIDTH
		if (sr_last)
			sr_fill <= (frm_valid) ? new_fill : 0;
		else if (fl_last)
			sr_fill <= 0;
	end else begin
		if (i_qready)
			o_qvalid <= 1'b0;
		if (frm_valid && frm_ready)
			sr_fill <= new_fill;
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
			sreg <= { sreg[31:0], {(DW){1'b0}} };
	end else if (frm_valid && frm_ready)
		sreg <= new_data;

	always @(posedge i_clk)
	if ((!o_qvalid || i_qready)&&(!OPT_LOWPOWER || flush))
		o_qdata <= new_data[DW+31:32];

	always @(posedge i_clk)
	if ((!o_qvalid || i_qready)&&(!OPT_LOWPOWER || flush))
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
		sr_last <= frm_valid && frm_ready && frm_last && !fl_last;
	else if (frm_valid && frm_ready)
		sr_last <= frm_last;

	always @(posedge i_clk)
	if (!o_qvalid || i_qready)
		o_qlast <= fl_last;

	// }}}
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal properties
// {{{
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	reg	f_past_valid;
	(* anyconst *) reg	[LGFRAME-1:0]	f_width, f_height;
	reg	[LGFRAME-1:0]	fs_xpos, fs_ypos;
	reg			f_known_height, fs_hlast, fs_vlast, fs_sof;

	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(*)
	if (!f_past_valid)
		assume(i_reset);
	////////////////////////////////////////////////////////////////////////
	//
	// (Video) Stream properties
	// {{{
	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assume(!s_valid);
	else if ($past(s_valid && !s_ready))
	begin
		assume(s_valid);
		assume($stable(s_data));
		assume($stable(s_last));
		assume($stable(s_user));
	end

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assume(!enc_valid);
	else if ($past(enc_valid && !enc_ready))
	begin
		assume(enc_valid);
		assume($stable(enc_data));
		assume($stable(enc_bytes));
		assume($stable(enc_last));
	end

	faxivideo #(
		.LGDIM(LGFRAME),
		.OPT_TUSER_IS_SOF(OPT_TUSER_IS_SOF)
	) fvid (
		// {{{
		.i_clk(i_clk), .i_reset_n(!i_reset),
		//
		.S_VID_TVALID(s_valid),
		.S_VID_TREADY(s_ready),
		.S_VID_TDATA(s_data),
		.S_VID_TLAST(s_last),
		.S_VID_TUSER(s_user),
		//
		.i_width(f_width), .i_height(f_height),
		.o_xpos(fs_xpos), .o_ypos(fs_ypos),
		.f_known_height(f_known_height),
		.o_hlast(fs_hlast), .o_vlast(fs_vlast), .o_sof(fs_sof)
		// }}}
	);

	always @(*)
	begin
		assume(fs_xpos < f_width);
		assume(fs_ypos < f_height);
	end

	always @(*)
	if (!i_reset && s_valid)
	begin
		if (OPT_TUSER_IS_SOF)
		begin
			assume( s_last == fs_hlast);
			assume( s_user == fs_sof);
		end else begin
			assume( s_last == (fs_vlast && fs_hlast));
			assume( s_user == fs_hlast);
		end
	end

	always @(posedge i_clk)
	if (!i_reset)
	begin
		assert(h_state != 2'b11);
		if (h_state != S_NO_SYNC)
			assert(h_count == fs_xpos);
		if (h_state == S_SYNCD)
			assert(h_width == f_width);
		assert(h_count <= fs_xpos);
	end

	always @(posedge i_clk)
	if (!i_reset)
	begin
		assert(v_state != 2'b11);
		// if (v_state != S_NO_SYNC) assert(h_state != S_NO_SYNC);
		// if (v_state == S_SYNCD) assert(h_state == S_SYNCD);
		if (OPT_TUSER_IS_SOF)
		begin
			if (v_state != S_NO_SYNC)
			begin
				if (!fs_sof)
					assert(v_count == fs_ypos);
				else
					assert(v_count == f_height);
			end
			if (v_state == S_SYNCD)
				assert(v_height == f_height);
			if (v_state == S_SYNCD)
				assert(s_vlast == (fs_ypos +1 >= f_height));
			if (v_count > 0)
				assert(h_state != S_NO_SYNC);
			if (h_count == 0 && v_state == S_START)
				assert(h_state != S_NO_SYNC);
			if (!fs_sof)
				assert(v_count == fs_ypos);
		end else begin
			if (v_state != S_NO_SYNC)
				assert(v_count == fs_ypos);
			if (v_state == S_SYNCD)
				assert(v_height == f_height);
		end
	end

	always @(posedge i_clk)
	if (!i_reset && syncd && s_valid)
	begin
		assert(s_hlast == fs_hlast);
		assert(!s_hlast || s_vlast == fs_vlast);
	end

	always @(posedge i_clk)
	if (!i_reset && syncd && OPT_TUSER_IS_SOF)
		assert(s_vlast == (fs_ypos+1 >= f_height));

	always @(posedge i_clk)
	if (!i_reset && OPT_TUSER_IS_SOF && v_state != S_SYNCD)
		assert(!s_vlast);

	/*
	always @(posedge i_clk)
	if (!i_reset)
	begin
		if (v_height != 0 || f_known_height)
			assert(v_height == f_height);
		assert(v_count == fs_ypos);
	end
	*/
	////////////////////////////////////////////////////////////////////////
	//
	// Encoder stage properties
	// {{{
	reg	[31:0]	enc_count;

	initial	enc_count = 0;
	always @(posedge i_clk)
	if (i_reset)
		enc_count <= 0;
	else if (enc_valid && enc_ready)
	begin
		if (enc_last)
			enc_count <= 0;
		else if (enc_bytes == 0)
			enc_count <= enc_count + 4;
		else
			enc_count <= enc_count + enc_bytes;
	end

	always @(posedge i_clk)
	if (!i_reset && enc_count != 0)
		assert(frm_state == FRM_DATA);

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Framing stage properties
	// {{{
	reg	[31:0]	frm_count;

	initial	frm_count = 0;
	always @(posedge i_clk)
	if (i_reset)
		frm_count <= 0;
	else if (frm_valid && frm_ready)
	begin
		if (frm_last)
			frm_count <= 0;
		else if (frm_bytes == 0)
			frm_count <= frm_count + 4;
		else
			frm_count <= frm_count + frm_bytes;
	end

	always @(*)
	if (!i_reset && frm_valid)
	case(frm_bytes)
	2'b00: begin end
	2'b01: assert(frm_data[23:0] == 24'h0);
	2'b10: assert(frm_data[15:0] == 16'h0);
	2'b11: assert(frm_data[ 7:0] == 24'h0);
	default: begin end
	endcase

	always @(*)
	if (!i_reset)
	begin
		if (frm_state != FRM_DATA)
			assert(enc_count == 0);
		else begin
			assert(enc_count + 14 == frm_count
				+ (frm_valid ? (frm_bytes + (frm_bytes == 0 ? 4:0)) : 0));
		end
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Shift register
	// {{{

	always @(posedge i_clk)
	if (!i_reset && (!o_qvalid || !o_qlast) && !sr_last)
		assert(frm_count == fq_count + sr_fill + (o_qvalid ? 8:0));

	always @(posedge i_clk)
	if (!i_reset && !frm_valid)
		assert(!frm_last);

	always @(posedge i_clk)
	if (!i_reset && sr_last)
	begin
		assert(sr_fill > 0);
		assert(!o_qvalid || !o_qlast);
	end

	always @(posedge i_clk)
	if (!i_reset && o_qvalid && o_qlast)
	begin
		assert(!sr_last);
		assert(sr_fill == 0);
		assert(!frm_valid);
		assert(frm_state < FRM_HDRWIDTH);
	end

	always @(posedge i_clk)
	if (!i_reset && (sr_last || (o_qvalid && o_qlast)))
	begin
		case(frm_state)
		FRM_IDLE: assert(!frm_valid && frm_count == 0);
		FRM_START: assert(frm_count == 0);
		FRM_HDRMAGIC: assert(frm_count == 0);
		FRM_HDRWIDTH: begin end
		FRM_HDRHEIGHT: assert(frm_state == FRM_HDRHEIGHT && frm_count == 8 && !sr_last);
		default: assert(0);
		endcase
		assert(!frm_valid);
		assert(frm_count == 0);
	end

	always @(posedge i_clk)
	if (!i_reset) case(frm_state)
	FRM_IDLE: if (frm_valid) assert(frm_last && frm_bytes == 0); else assert(frm_count==0);
	FRM_START: assert(syncd && !frm_valid && frm_count == 0);
	FRM_HDRMAGIC: assert(syncd && !frm_valid && frm_count == 0 && frm_bytes==0);
	FRM_HDRWIDTH: assert(!o_qvalid && sr_fill == 0 && syncd && frm_valid && frm_count == 0 && frm_bytes==0);
	FRM_HDRHEIGHT: assert(!o_qvalid && syncd && frm_valid && frm_count == 4 && frm_bytes==0 && !sr_last);
	FRM_HDRFORMAT: assert((!o_qvalid || !o_qlast) && syncd && frm_valid && frm_count == 8 && !sr_last);
	FRM_DATA: assert(syncd && !sr_last && !frm_last);
	FRM_TRAILER: assert(syncd && frm_valid && !frm_last && !sr_last);
	FRM_LAST: assert(syncd && frm_valid && !frm_last && frm_bytes==0 && !sr_last);
	default: assert(0);
	endcase

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// (Compressed) Stream properties
	// {{{
	reg	[31:0]	fq_count;

	always @(posedge i_clk)
	if (!f_past_valid || $past(i_reset))
		assert(!o_qvalid);
	else if ($past(o_qvalid && !i_qready))
	begin
		assert(o_qvalid);
		assert($stable(o_qdata));
		assert($stable(o_qbytes));
		assert($stable(o_qlast));
	end

	always @(posedge i_clk)
	if (f_past_valid && !$past(i_reset) && o_qvalid)
		assert(o_qlast || o_qbytes == 0);

	initial	fq_count = 0;
	always @(posedge i_clk)
	if (i_reset)
		fq_count <= 0;
	else if (o_qvalid && i_qready)
	begin
		if (o_qlast)
			fq_count <= 0;
		else
			fq_count <= fq_count + DW/8;
	end

	always @(*)
		assume(fq_count < 32'hef00_0000);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Contract byte
	// {{{

	(* anyconst *)	reg	[31:0]	fc_index;
	(* anyconst *)	reg	[7:0]	fc_byte;

	reg	[31:0]	fenc_index, fsr_count;
	reg	[7:0]	fenc_byte;
	reg	[31:0]	enc_wide, frm_wide;
	reg	[DW-1:0]	fq_wide;
	reg	[DW+32-1:0]	fsr_empty, fsr_wide;

	always @(*)
		assume(fc_index >= 12+2);

	always @(*)
		fenc_index = fc_index - 14;

	always @(*)
	begin
		enc_wide = enc_data << (8*(fenc_index - enc_count));
		fenc_byte = enc_wide[31:24];

		fsr_count = frm_count - sr_fill;

		frm_wide = frm_data << (8*(fc_index - frm_count));
		fsr_wide = sreg << (8*(fc_index - fsr_count));
		fq_wide = o_qdata << (8*(fc_index - fq_count));
	end

	always @(*)
	if (!i_reset && enc_valid && (enc_count < fenc_index))
		assume(!enc_last);

	always @(*)
	if (!i_reset && enc_count + (enc_valid ? 4:0) < fenc_index)
		assume(!enc_last);

	always @(*)
	if (!i_reset && enc_valid && (enc_count <= fenc_index)
			&&((enc_bytes == 0 && enc_count+ 4 > fenc_index)
			|| (enc_bytes != 0 && enc_count+ enc_bytes > fenc_index)))
	begin
		assume(fenc_byte == fc_byte);
		assume(!enc_last);
	end

	always @(*)
	if (!i_reset && frm_state == FRM_DATA)
	begin
		assert(frm_count >= 12);
		if (frm_count < 14)
		begin
			assert(frm_valid);
			assert(frm_count == 12);
			assert(frm_bytes == 2);
			assert(enc_count == 0);
		end
	end

	always @(*)
	if (!i_reset && frm_state > FRM_DATA)
		assert(frm_count > fc_index);

	always @(*)
	if (!i_reset && frm_valid && (frm_count <= fc_index)
			&&((frm_bytes == 0 && fc_index < frm_count+ 4)
			|| (frm_bytes != 0 && fc_index < frm_count+ frm_bytes)))
	begin
		assert(frm_wide[31:24] == fc_byte);
	end

	always @(*)
	if (!i_reset && !sr_last && sr_fill > 0 && (fsr_count <= fc_index)
					&&(fc_index < fsr_count + sr_fill))
	begin
		assert(fsr_wide[DW+32-1:DW+24] == fc_byte);
	end

	always @(*)
	if (!i_reset && o_qvalid && !o_qlast && (fq_count <= fc_index)
			&&((o_qbytes == 0 && fc_index < fq_count+ 4)
			|| (o_qbytes != 0 && fc_index < fq_count+ o_qbytes)))
	begin
		assert(fq_wide[DW-1:DW-8] == fc_byte);
	end

	always @(*)
		fsr_empty = sreg << (sr_fill * 8);;

	always @(*)
	if(!i_reset)
	begin
		assert(sr_fill <= (DW+32)/8);
		assert(fsr_empty == 0);
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Cover checks
	// {{{

	always @(*)
	if (!i_reset && o_qvalid)
	begin
		cover(fq_count > 0);
		cover(fq_count > 8);
		cover(fq_count > 40 && o_qvalid && o_qlast);
	end

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// "Careless" assumptions
	// {{{
	// always @(*) assume(i_qready);
	// always @(*) assume(enc_valid);

	// }}}

	// }}}
`endif
// }}}
endmodule
