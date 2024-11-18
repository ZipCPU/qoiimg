////////////////////////////////////////////////////////////////////////////////
//
// Filename:	./bench/sim/main_tb.cpp
// {{{
// Project:	Quite OK image compression (QOI) Verilog implementation
//
// Purpose:	Given a PNG file (i.e. ./main_tb x.png), simulates the QOI
//		compression and decompression to produce x.qoi and x-out.png.
//	If all goes well, x.png should be identical to x-out.png.
//
//	Given that the encoder does not support any alpha channels, x.png must
//	either not include ALPHA, or if it does, all ALPHA pixels must be
//	0xff.
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
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <png.h>
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vtb_top.h"
// }}}

unsigned	get_pixel(unsigned char **row_pointers,
				unsigned tx_xpos, unsigned tx_ypos) {
	// {{{
	unsigned char	*rowp, *pixp;
	unsigned	p;

	rowp = row_pointers[tx_ypos];
	pixp = rowp + 3*tx_xpos;
	p = pixp[0] & 0x0ff;
	p = (p << 8) | (pixp[1] & 0x0ff);
	p = (p << 8) | (pixp[2] & 0x0ff);

	return p;
}
// }}}

void	usage(void) {
	fprintf(stderr, "USAGE: main_tb <image.png>\n");
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	Verilated::traceEverOn(true);
	FILE	*fpng, *fqoi;
	char	header[8], *qoi_name;
	const char *trace_file = "trace.vcd";
	unsigned	rx_xpos, rx_ypos, tx_xpos, tx_ypos, pixel,
			height, width, nxt_hlast, nxt_vlast, nxt_data;
	unsigned	m_tickcount;
	Vtb_top		*vtb;
	VerilatedVcdC	*m_trace;
	bool		is_png;
	void		*error_ptr = NULL;
	ssize_t		sz;

	if (argc != 2 || argv[1][0] == '-') {
		fprintf(stderr, "ERR: Wrong number of arguments\n");
		usage();
		exit(EXIT_FAILURE);
	}

	fpng = fopen(argv[1], "rb");
	if (NULL == fpng) {
		fprintf(stderr, "ERR: Could not open \'%s\'\n", argv[1]);
		exit(EXIT_FAILURE);
	}

	fprintf(stderr, "Opened %s for reading\n", argv[1]);

	qoi_name = strdup(argv[1]);
	strcpy(&qoi_name[strlen(qoi_name)-3], "qoi");
	fqoi = fopen(qoi_name, "w");

	sz = fread(header, 1, sizeof(header), fpng);
	is_png = (sz >= (ssize_t)sizeof(header))
		&& !png_sig_cmp((const unsigned char *)header, 0, sizeof(header));
	if (!is_png) {
		fprintf(stderr, "ERR: \'%s\' does not appear to be a PNG file\n", argv[1]);
		exit(EXIT_FAILURE);
	}

	png_structp	png_ptr;
	png_infop	info_ptr, end_info;
	png_bytepp	row_pointers;

	png_ptr = png_create_read_struct (PNG_LIBPNG_VER_STRING,
		(png_voidp)error_ptr, NULL, NULL);
	if (!png_ptr) {
		fprintf(stderr, "ERR: Could not create PNG structure\n");
		exit(EXIT_FAILURE);
	}

	info_ptr = png_create_info_struct (png_ptr);
	if (!info_ptr) {
		png_destroy_read_struct(&png_ptr,
				(png_infopp)NULL, (png_infopp)NULL);
		fprintf(stderr, "ERR: Could not create PNG INFO structure\n");
		exit(EXIT_FAILURE);
	}

	end_info = png_create_info_struct (png_ptr);
	if (!end_info) {
		png_destroy_read_struct(&png_ptr,
				&info_ptr, (png_infopp)NULL);
		fprintf(stderr, "ERR: Could not create PNG INFO structure\n");
		exit(EXIT_FAILURE);
	}

	if (setjmp(png_jmpbuf(png_ptr))) {
		fprintf(stderr, "ERR: PNG Long-jump to error\n");
		png_destroy_read_struct(&png_ptr, &info_ptr, &end_info);
		fclose(fpng);
		exit(EXIT_FAILURE);
	}

	png_init_io(png_ptr, fpng);
	png_set_user_limits(png_ptr, 65535, 65535);
	png_set_sig_bytes(png_ptr, sizeof(header));
	png_read_png(png_ptr, info_ptr,
				PNG_TRANSFORM_STRIP_ALPHA
				| PNG_TRANSFORM_PACKING
				| PNG_TRANSFORM_EXPAND
				| PNG_TRANSFORM_STRIP_16,
				NULL);
	// png_read_info(png_ptr, info_ptr);

	width  = png_get_image_width( png_ptr, info_ptr);
	height = png_get_image_height(png_ptr, info_ptr);

	printf("Image size: %4d x %4d\n", width, height);
	assert(width  > 4);
	assert(height > 4);

	// if (color_type == PNG_COLOR_TYPE_PALETTE)
	//	png-set_palette_to_rgb(png_ptr);

	row_pointers = png_get_rows(png_ptr, info_ptr);

	// png_destroy_read_struct(&png_ptr, &info_ptr, &end_info);
	// fclose(fpng);

	// Open a VCD file for tracing
	vtb = new Vtb_top;
	m_trace = new VerilatedVcdC;
	vtb->trace(m_trace, 99);
	m_trace->spTrace()->set_time_resolution("ns");
	m_trace->spTrace()->set_time_unit("ns");
	m_trace->open(trace_file);

	vtb->i_reset = 1;
	vtb->i_clk = 0;
	vtb->s_valid = 0;
	vtb->s_data = 0;
	vtb->s_hlast = 0;
	vtb->s_vlast = 0;
	vtb->m_ready = 1;
	m_tickcount = 0;
	vtb->eval();
	vtb->i_clk = 1;
	vtb->eval();
	if (m_trace) m_trace->dump(10*m_tickcount);
	vtb->i_clk = 0;
	vtb->eval();
	if (m_trace) m_trace->dump(10*m_tickcount+5);
	m_tickcount++;

	vtb->i_clk = 1;
	vtb->eval();
	vtb->i_reset = 0;
	if (m_trace) m_trace->dump(10*m_tickcount);
	vtb->i_clk = 0;
	vtb->eval();
	if (m_trace) m_trace->dump(10*m_tickcount+5);
	m_tickcount++;


	tx_xpos = 0; tx_ypos = 0;
	rx_xpos = 0; rx_ypos = 0;

	unsigned limitcount = height * width * 10;

if(0) {
	printf("PIX[  17, 3] = %06x\n", get_pixel(row_pointers,   17, 3));
	printf("PIX[  18, 3] = %06x\n", get_pixel(row_pointers,   18, 3));

	printf("PIX[1185, 3] = %06x\n", get_pixel(row_pointers, 1185, 3));
	printf("PIX[1186, 3] = %06x\n", get_pixel(row_pointers, 1186, 3));

	printf("PIX[  14, 4] = %06x\n", get_pixel(row_pointers,   14, 4));
	printf("PIX[  15, 4] = %06x\n", get_pixel(row_pointers,   15, 4));
	printf("PIX[   2,44] = %06x\n", get_pixel(row_pointers,    2, 44));
	printf("PIX[   3,44] = %06x\n", get_pixel(row_pointers,    3, 44));
	printf("PIX[   4,44] = %06x\n", get_pixel(row_pointers,    4, 44));

	printf("PIX[ 584,51] = %06x\n", get_pixel(row_pointers,  584, 51));
	printf("PIX[ 585,51] = %06x\n", get_pixel(row_pointers,  585, 51));
	printf("PIX[ 586,51] = %06x\n", get_pixel(row_pointers,  586, 51));
	printf("PIX[ 587,51] = %06x\n", get_pixel(row_pointers,  587, 51));
	printf("PIX[ 588,51] = %06x\n", get_pixel(row_pointers,  588, 51));
}

	while(!vtb->m_valid || !vtb->m_last) {
		// Generate pixel data for the encoder
		// {{{
		nxt_data = vtb->s_data; // row_pointers[y][x];
		nxt_hlast = vtb->s_hlast; // row_pointers[y][x];
		nxt_vlast = vtb->s_vlast; // row_pointers[y][x];
		if (!vtb->s_valid || vtb->s_ready) {
			nxt_data = get_pixel(row_pointers, tx_xpos, tx_ypos);
			nxt_hlast = (tx_xpos + 1) >= width;
			nxt_vlast = (tx_ypos + 1) >= height;
			if (++tx_xpos >= width) {
				tx_xpos = 0;
				if (++tx_ypos >= height)
					tx_ypos = 0;
			}
		}
		// }}}

		// Step the clock, setting the pixel data on pedge of it
		// {{{
		vtb->i_clk = 1;
		vtb->eval();
		// if (m_trace) m_trace->dump(10*m_tickcount);
		vtb->s_valid = 1;
		vtb->s_data  = nxt_data;
		vtb->s_vlast = nxt_vlast;
		vtb->s_hlast = nxt_hlast;
		vtb->eval();
		if (m_trace) m_trace->dump(10*m_tickcount);

		vtb->i_clk = 0;
		vtb->eval();
		if (m_trace) {
			m_trace->dump(10*m_tickcount + 5);
			m_trace->flush();
		}
		m_tickcount++;
		// }}}

		// End sim early if we use too many clock cycles
		// {{{
		if (m_tickcount >= limitcount) {
			fprintf(stderr, "FAIL!  Picture not produced\n");
			exit(EXIT_FAILURE);
		}
		// }}}

		// Generate a QOI file, for examining intermediate results
		// {{{
		if (vtb->qvalid && fqoi) {	// && vtb->qready
			unsigned	nb = vtb->qbytes;
			unsigned char	qb[8];

			if (vtb->qbytes == 0)
				nb = 8;
			for(unsigned k=0; k<nb; k++)
				qb[k] = (vtb->qdata >> ((7-k)*8)) & 0x0ff;
			fwrite(qb, 1, nb, fqoi);

			if (vtb->qlast) {
				fclose(fqoi);
				fqoi = NULL;
			}
		}
		// }}}

		// Compare the decompressed (compressed) image w/ the original
		// {{{
		if (vtb->m_valid && vtb->m_ready) {
			// COPY PIXEL DATA ...
			pixel = get_pixel(row_pointers, rx_xpos, rx_ypos);
			if (vtb->m_data != pixel) {
				fflush(stdout);
				fprintf(stderr, "ERR: (PNG pixel[%3d,%3d]) %06x != 0x%06x (pixel out)\n", rx_xpos, rx_ypos, pixel, vtb->m_data);
				fprintf(stderr, "... %06x, %06x, %06x, %06x, %06x, %06x\n",
					get_pixel(row_pointers, rx_xpos+1, rx_ypos),
					get_pixel(row_pointers, rx_xpos+2, rx_ypos),
					get_pixel(row_pointers, rx_xpos+3, rx_ypos),
					get_pixel(row_pointers, rx_xpos+4, rx_ypos),
					get_pixel(row_pointers, rx_xpos+5, rx_ypos),
					get_pixel(row_pointers, rx_xpos+6, rx_ypos));
				delete vtb;
				exit(EXIT_FAILURE);
			}
			assert(vtb->m_user == (((rx_xpos +1) >= width) ? 1:0));
			if (vtb->m_user)
				assert(vtb->m_last
					== (((rx_ypos +1) >= height) ? 1:0));
			//
			// THEN ...
			if (vtb->m_last && vtb->m_user) { // VLAST && HLAST
				// We're about to exit
			} else if (vtb->m_user) {	// HLAST
				rx_xpos = 0;
				rx_ypos++;
			} else
				rx_xpos++;
		}
		// }}}
	}

	if(fqoi != NULL)
		fclose(fqoi);
	printf("SUCCESS!\n");
	exit(EXIT_SUCCESS);
}
