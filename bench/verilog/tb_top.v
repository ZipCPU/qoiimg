////////////////////////////////////////////////////////////////////////////////
//
// Filename:	./bench/verilog/tb_top.v
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	
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
module	tb_top #(
		parameter	DW=64
	) (
		input	wire	i_clk, i_reset,
		// Video stream input
		// {{{
		input	wire		s_valid,
		output	wire		s_ready,
		input	wire	[23:0]	s_data,
		input	wire		s_hlast,
		input	wire		s_vlast,
		// }}}
		// QOI compressed output stream
		// {{{
		output	wire		qvalid,
		output	wire [DW-1:0]	qdata,
		output	wire [$clog2(DW/8)-1:0]	qbytes,
		output	wire		qlast,
		// }}}
		// Video stream output
		// {{{
		output	reg		m_valid,
		input	wire		m_ready,
		output	reg	[23:0]	m_data,
		output	reg		m_user, m_last
		// }}}
	);

	wire	w_qvalid, qready;

	qoi_encoder
	u_encoder (
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.s_valid(s_valid),
		.s_ready(s_ready),
		.s_data(s_data),
		.s_last(s_vlast && s_hlast),
		.s_user(s_hlast),
		//
		.o_qvalid(w_qvalid),
		.i_qready(qready),
		.o_qdata(qdata),
		.o_qbytes(qbytes),
		.o_qlast(qlast)
	);

	assign	qvalid = w_qvalid && qready;

	qoi_decoder
	u_decoder (
		.i_clk(i_clk), .i_reset(i_reset),
		//
		.i_qvalid(w_qvalid),
		.o_qready(qready),
		.i_qdata(qdata),
		.i_qbytes(qbytes),
		// .i_qlast(qlast),
		//
		.m_valid(m_valid),
		.m_ready(m_ready),
		.m_data(m_data),
		.m_last(m_last),
		.m_user(m_user)
	);

endmodule
