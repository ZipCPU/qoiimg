////////////////////////////////////////////////////////////////////////////////
//
// Filename:	rtl/qoi_recorder.v
// {{{
// Project:	Quite OK image compression (QOI)
//
// Purpose:	To write one (or more) video images to memory.  We'll use the
//		QOI compression scheme to get the bandwidth down.  Once
//	written, the total capture size may be queried and/or reset for another
//	capture.  Design generates no backpressure when not in use--allowing
//	raw video data to stream through.
//
// Registers:
//	0: Status/Control
//		Busy
//		Number of frames desired / number of frames remaining
//	4: Address (MSB when not LITTLE ENDIAN)
//	8: Address (LSB when not LITTLE ENDIAN)
//	C: Data length allowed
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
module	qoi_recorder #(
		// {{{
		parameter [0:0]	OPT_COMPRESS = 1'b1,
		parameter [0:0]	OPT_TUSER_IS_SOF = 1'b0,
		parameter	ADDRESS_WIDTH = 32,
		parameter	DW = 64,
		parameter	AW = ADDRESS_WIDTH-$clog2(DW/8),
		parameter	LGFIFO = 8
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_reset,
		input	wire		i_pix_clk,
		// Control inputs
		// {{{
		input	wire		i_wb_cyc, i_wb_stb, i_wb_we,
		input	wire	[1:0]	i_wb_addr,
		input	wire	[31:0]	i_wb_data,
		input	wire	[3:0]	i_wb_sel,
		output	wire		o_wb_stall,
		output	reg		o_wb_ack,
		output	reg	[31:0]	o_wb_data,
		// }}}
		// Video input interface
		// {{{
		input	wire		s_vid_valid,
		output	wire		s_vid_ready,
		input	wire	[23:0]	s_vid_data,
		input	wire		s_vid_user, s_vid_last,
		// }}}
		// Outgoing WB/DMA interface
		// {{{
		output	wire			o_dma_cyc, o_dma_stb, o_dma_we,
		output	wire	[AW-1:0]	o_dma_addr,
		output	wire	[DW-1:0]	o_dma_data,
		output	wire	[DW/8-1:0]	o_dma_sel,
		input	wire			i_dma_stall,
		input	wire			i_dma_ack,
		input	wire	[DW-1:0]	i_dma_data,
		input	wire			i_dma_err
		// }}}
		// }}}
	);

	// Local declarations
	// {{{
	localparam	ADDR_CTRL= 0,
			ADDR_MSW = 1,
			ADDR_LSW = 2;

	wire	soft_dma_reset;

	wire	sel_valid, sel_ready, sel_last;
	wire	[DW-1:0]		sel_data;
	wire	[$clog2(DW/8)-1:0]	sel_bytes;

	wire				pix_valid, pix_ready, pix_last;
	wire	[DW-1:0]		pix_data;
	wire	[$clog2(DW/8):0]	pix_bytes;

	wire				pxm_valid, pxm_ready, pxm_last;
	wire	[DW-1:0]		pxm_data;
	wire	[$clog2(DW/8):0]	pxm_bytes;

	wire				fifo_valid, fifo_ready, fifo_last;
	wire	[DW-1:0]		fifo_data;
	wire	[$clog2(DW/8):0]	fifo_bytes;
	reg				fifo_flush;

	wire	afifo_full, afifo_empty;
	wire	fifo_full,  fifo_empty, fifo_read;

	reg	[63:0]			wide_dma_address;
	reg	[15:0]			nframes;
	reg	[AW+$clog2(DW/8)-1:0]	dma_address;
	wire	[AW+$clog2(DW/8)-1:0]	base_addr;

	reg	dma_request, vid_sync, dma_active;
	wire	dma_busy, dma_err;

	reg	pix_reset, pix_reset_pipe;

	always @(posedge i_pix_clk)
	if (i_reset)
		{ pix_reset, pix_reset_pipe } <= -1;
	else
		{ pix_reset, pix_reset_pipe } <= { pix_reset_pipe, 1'b0 };

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// (Optionally) compress our video data
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	generate if (OPT_COMPRESS)
	begin : GEN_QOI_COMPRESSION
		wire	[DW-1:0]		lcl_data;
		wire	[$clog2(DW/8)-1:0]	lcl_bytes;

		qoi_encoder #(
			.OPT_TUSER_IS_SOF(OPT_TUSER_IS_SOF),
			.DW(DW)
		) u_compress_video (
			// {{{
			.i_clk(i_pix_clk),
			.i_reset(pix_reset),
			//
			.s_valid(s_vid_valid),
			.s_ready(s_vid_ready),
			.s_data(s_vid_data),
			.s_last(s_vid_last),
			.s_user(s_vid_user),
			//
			.o_qvalid(sel_valid),
			.i_qready(sel_ready),
			.o_qdata(lcl_data),
			.o_qbytes(lcl_bytes),
			.o_qlast(sel_last)
			// }}}
		);

		assign	sel_data  = lcl_data;
		assign	sel_bytes = lcl_bytes;

	end else begin : NO_COMPRESSION
		wire	s_vid_hlast, s_vid_vlast;

		assign	s_vid_hlast = s_vid_user;
		assign	s_vid_vlast = s_vid_last;

		assign	sel_valid = s_vid_valid;
		assign	s_vid_ready = sel_ready;
		assign	sel_data = { s_vid_data, {(DW-24){1'b0}} };
		assign	sel_bytes = 3;
		assign	sel_last = s_vid_hlast && s_vid_vlast;

	end endgenerate
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Reshape pixels to the full memory width
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	zipdma_rxgears #(
		.BUS_WIDTH(DW),
		.OPT_LITTLE_ENDIAN(1'b0)
	) u_rxgears (
		.i_clk(i_pix_clk), .i_reset(pix_reset),
		.i_soft_reset(soft_dma_reset),
		.S_VALID(sel_valid),
		.S_READY(sel_ready),
		.S_DATA( sel_data),
		.S_BYTES({ (sel_bytes == 0 ? 1'b1:1'b0), sel_bytes }),
		.S_LAST( sel_last),
		//
		.M_VALID(pix_valid),
		.M_READY(pix_ready),
		.M_DATA( pix_data),
		.M_BYTES(pix_bytes),
		.M_LAST( pix_last)
	);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Cross to the bus clock domain
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// Need to cross here from the pixel clock to the memory clock domain.
	//
	// No particular FIFO depth is required here, since we're just going
	// straight to another FIFO.  That second FIFO will have the depth.
	// Our purpose is just to make sure we can accomplish maximum throughput
	// if desired, and hence a min depth of 8 samples or so.
	//

	afifo #(
		.LGFIFO(3), .WIDTH(2+$clog2(DW/8)+DW)
	) u_afifo (
		.i_wclk(i_pix_clk), .i_wr_reset_n(!pix_reset),
		.i_wr(pix_valid),
			.i_wr_data({ pix_last, pix_bytes, pix_data }),
			.o_wr_full(afifo_full),
		.i_rclk(i_clk), .i_rd_reset_n(!i_reset),
		.i_rd(pxm_ready),
			.o_rd_data({ pxm_last, pxm_bytes, pxm_data }),
			.o_rd_empty(afifo_empty)
	);

	assign	pxm_valid = !afifo_empty;
	assign	pix_ready = !afifo_full;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Run everything into a FIFO
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	wire	[LGFIFO:0]	fifo_fill;

	sfifo #(
		.BW(DW+$clog2(DW/8)+2), .LGFLEN(LGFIFO)
	) u_fifo (
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_wr(pxm_valid),
		.i_data({ pxm_last, pxm_bytes, pxm_data }),
		.o_full(fifo_full),
		.o_fill(fifo_fill),
		//
		.i_rd(fifo_read),
		.o_data({ fifo_last, fifo_bytes, fifo_data }),
		.o_empty(fifo_empty)
	);

	assign	pxm_ready  = !fifo_full;
	assign	fifo_valid = !fifo_empty;
	assign	fifo_read  = (fifo_ready || !dma_active) && fifo_flush;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Synchronize
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (i_reset)
		vid_sync <= 1'b1;
	else if (fifo_read && !fifo_empty && fifo_last)
		vid_sync <= 1'b1;
	else if (fifo_read && !fifo_empty && !dma_active)
		vid_sync <= 1'b0;

	always @(posedge i_clk)
	if (i_reset)
		dma_active <= 1'b0;
	else if (!dma_active)
	begin
		if ((dma_request || dma_busy) && vid_sync)
			dma_active <= !fifo_read || fifo_empty;
	end else if (fifo_read && !fifo_empty && fifo_last && !dma_request)
		dma_active <= 1'b0;

	always @(posedge i_clk)
	if (i_reset)
		fifo_flush <= 1'b0;
	else if (fifo_read && fifo_empty)
		fifo_flush <= 1'b0;
	else if (pxm_valid && pxm_last)
		fifo_flush <= 1'b1;
	else if (fifo_fill[LGFIFO:LGFIFO-1] != 2'b00)
		fifo_flush <= 1'b1;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Write the final results to memory
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	zipdma_s2mm #(
		.ADDRESS_WIDTH(ADDRESS_WIDTH), .BUS_WIDTH(DW)
	) u_dma (
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_request(dma_request), .o_busy(dma_busy), .o_err(dma_err),
		// Always increment.  Size is always the full bus size.
		.i_inc(1'b1), .i_size(2'b00), .i_addr(base_addr),
		//
		.S_VALID(fifo_valid && dma_active && fifo_flush),
				.S_READY(fifo_ready),
		.S_DATA(fifo_data), .S_BYTES(fifo_bytes), .S_LAST(fifo_last),
		//
		.o_wr_cyc(o_dma_cyc), .o_wr_stb(o_dma_stb), .o_wr_we(o_dma_we),
		.o_wr_addr(o_dma_addr), .o_wr_data(o_dma_data),
			.o_wr_sel(o_dma_sel),
		.i_wr_stall(i_dma_stall), .i_wr_ack(i_dma_ack),
			.i_wr_data(i_dma_data),
		.i_wr_err(i_dma_err)
	);
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Control bus handling
	// {{{
	assign	o_wb_stall = 1'b0;
	assign	soft_dma_reset = 1'b0;

	always @(posedge i_clk)
	if (i_reset)
	begin
		nframes <= 0;
		dma_request <= 0;
	end else if (dma_err || (o_dma_cyc && i_dma_err))
	begin
		dma_request <= 0;
		nframes <= 0;
	end else begin
		if (dma_active && fifo_read && !fifo_empty && fifo_last)
		begin
			if (nframes > 0)
				nframes <= nframes - 1;
			if (nframes <= 1)
				dma_request <= 0;
		end

		if (i_wb_stb && !o_wb_stall && !dma_request && i_wb_addr == 0
				&& i_wb_sel[1:0] == 2'b11
				&& i_wb_data[15:0] != 0 && dma_address != 0)
		begin
			nframes <= i_wb_data[15:0];
			dma_request <= 1'b1;
		end
	end

	always @(*)
	begin
		wide_dma_address = { {(64-AW-$clog2(DW/8)){1'b0}}, dma_address };
		if (i_wb_stb && !o_wb_stall && i_wb_we && i_wb_addr == ADDR_LSW)
		begin
			if (i_wb_sel[0])
				wide_dma_address[ 7: 0] = i_wb_data[ 7: 0];
			if (i_wb_sel[1])
				wide_dma_address[15: 8] = i_wb_data[15: 8];
			if (i_wb_sel[2])
				wide_dma_address[23:16] = i_wb_data[23:16];
			if (i_wb_sel[3])
				wide_dma_address[31:24] = i_wb_data[31:24];
		end

		if (i_wb_stb && !o_wb_stall && i_wb_we && i_wb_addr == ADDR_MSW)
		begin
			if (i_wb_sel[0])
				wide_dma_address[39:32] = i_wb_data[ 7: 0];
			if (i_wb_sel[1])
				wide_dma_address[47:40] = i_wb_data[15: 8];
			if (i_wb_sel[2])
				wide_dma_address[55:48] = i_wb_data[23:16];
			if (i_wb_sel[3])
				wide_dma_address[63:56] = i_wb_data[31:24];
		end

		wide_dma_address[63:AW+$clog2(DW/8)] = 0;
	end

	always @(posedge i_clk)
	if (i_reset)
	begin
		dma_address <= 0;
	end else begin
		if (dma_active && fifo_read && !fifo_empty)
		begin
			// Verilator lint_off WIDTH
			dma_address <= dma_address + fifo_bytes;
			// Verilator lint_on  WIDTH
		end

		if (i_wb_stb && !o_wb_stall && !dma_busy && !dma_request
				&& (i_wb_addr == 1 || i_wb_addr == 2))
		begin
			dma_address[AW+$clog2(DW/8)-1:0] <= wide_dma_address[AW+$clog2(DW/8)-1:0];
		end
	end

	assign	base_addr = dma_address;

	initial	o_wb_data = 0;
	always @(posedge i_clk)
	if (i_wb_stb)
	begin
		case(i_wb_addr)
		ADDR_CTRL: o_wb_data
			<= { dma_request, dma_busy, dma_err, dma_active,
				vid_sync, 11'h0, nframes };
		ADDR_LSW: o_wb_data <= wide_dma_address[31:0];
		ADDR_MSW: o_wb_data <= wide_dma_address[63:32];
		default: o_wb_data <= 0;
		endcase
	end

	always @(posedge i_clk)
	if (i_reset)
		o_wb_ack <= 1'b0;
	else
		o_wb_ack <= i_wb_stb && !o_wb_stall;

	// }}}

	// Keep Verilator happy
	// {{{
	// Verilator coverage_off
	// Verilator lint_off UNUSED
	wire	unused = &{ 1'b0, i_wb_cyc, fifo_fill };
	// Verilator lint_on  UNUSED
	// Verilator coverage_on
	// }}}
endmodule
