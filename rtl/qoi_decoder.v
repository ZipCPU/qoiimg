////////////////////////////////////////////////////////////////////////////////
//
// Filename:	qoi_decoder.v
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
module	qoi_decoder #(
		// {{{
		parameter	[0:0]	OPT_TUSER_IS_SOF = 1'b0,
		parameter		DW = 64,
		localparam		DB = DW/8,
		localparam		LGDB = $clog2(DB)
		// }}}
	) (
		// {{{
		input	wire			i_clk, i_reset,
		//
		input	reg			i_qvalid,
		output	wire			o_qready,
		input	reg	[DW-1:0]	i_qdata,
		input	reg	[LGDB-1:0]	i_qbytes,
		input	reg			i_qlast
		//
		output	wire			m_valid,
		input	wire			m_ready,
		output	wire	[23:0]		m_data,
		output	wire			m_last, m_user,
		// }}}
	);

	////////////////////////////////////////////////////////////////////////
	//
	// Gearbox
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// Assume
	// - All incoming data is packed.  That is, 1) bits [DW-1:DW-8] are
	//   *always* valid if *VALID is true, and 2) [DW-1:0] are always valid
	//   whenever *VALID && !*LAST.
	// - DW >= 32, so we only need to gear down--never up
	//
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

	always @(*)
	begin
		if (state == DC_SYNC)
		begin
			// if (sreg[DW+32-1:DW] == "qoif")
			//	step = 4;
			if (sreg[DW+24-1:DW] == "qoi")
				nxt_step = 1;
			else if (sreg[DW+16-1:DW] == "qo")
				nxt_step = 2;
			else if (sreg[DW+16-1:DW] == "q")
				nxt_step = 3;
			else
				nxt_step = 4;
		end // else if (state == DC_SIZE)
		//	nxt_step = 4;
		else if (state == DC_FORMAT)
			nxt_step = 2;
		else if (state == DC_DATA)
		begin
			casez(sreg[DW+32-1:DW+24])
			8'b1111_1110: nxt_step = 4;
			8'b1111_1111: nxt_step = 5;
			8'b10??_????: nxt_step = 2;
			default:	nxt_step = 1;
			endcase
		end else
			nxt_step = 4;
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Decompress
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Add TLAST + TUSER (Either HLAST+VLAST, or HLAST+SOF)
endmodule
