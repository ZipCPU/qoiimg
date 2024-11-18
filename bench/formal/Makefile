################################################################################
##
## Filename:	bench/formal/Makefile
## {{{
## Project:	Quite OK image compression (QOI) Verilog implementation
##
## Purpose:	Direct the formal evaluation of the QOI encoder and decoder.
##
## Creator:	Dan Gisselquist, Ph.D.
##		Gisselquist Technology, LLC
##
################################################################################
## }}}
## Copyright (C) 2024, Gisselquist Technology, LLC
## {{{
## This program is free software (firmware): you can redistribute it and/or
## modify it under the terms of the GNU General Public License as published
## by the Free Software Foundation, either version 3 of the License, or (at
## your option) any later version.
##
## This program is distributed in the hope that it will be useful, but WITHOUT
## ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
## FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
## for more details.
##
## You should have received a copy of the GNU General Public License along
## with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
## target there if the PDF file isn't present.)  If not, see
## <http://www.gnu.org/licenses/> for a copy.
## }}}
## License:	GPL, v3, as defined and found on www.gnu.org,
## {{{
##		http://www.gnu.org/licenses/gpl.html
##
################################################################################
##
## }}}

all: compress encoder

.PHONY: compress qoi_compress
## {{{
compress: qoi_compress
qoi_compress: qoi_compress_prf/PASS
CDEPS := qoi_compress.sby ../../rtl/qoi_compress.v ../../rtl/qoi_skid.v faxivideo.v
qoi_compress_prf/PASS: $(CDEPS)
	sby -f qoi_compress.sby prf
## }}}

.PHONY: encoder qoi_encoder
## {{{
encoder: qoi_encoder

qoi_encoder: qoi_encoder_prf/PASS qoi_encoder_prfsof/PASS qoi_encoder_cvr/PASS
EDEPS := qoi_encoder.sby ../../rtl/qoi_encoder.v faxivideo.v
qoi_encoder_prf/PASS: $(EDEPS)
	sby -f qoi_encoder.sby prf
qoi_encoder_prfsof/PASS: $(EDEPS)
	sby -f qoi_encoder.sby prfsof
qoi_encoder_cvr/PASS: $(EDEPS)
	sby -f qoi_encoder.sby cvr
## }}}

.PHONY: decompress qoi_decompress
## {{{
decompress: qoi_decompress

qoi_decompress: qoi_decompress_prf/PASS # qoi_encoder_cvr/PASS
DDEPS := qoi_decompress.sby ../../rtl/qoi_decompress.v
qoi_decompress_prf/PASS: $(DDEPS)
	sby -f qoi_decompress.sby prf
# qoi_decompress_cvr/PASS: $(DDEPS)
#	sby -f qoi_decompress.sby cvr
## }}}
