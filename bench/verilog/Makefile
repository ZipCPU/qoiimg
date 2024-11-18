################################################################################
##
## Filename:	./bench/verilog/Makefile
## {{{
## Project:	Quite OK image compression (QOI) Verilog implementation
##
## Purpose:
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
all:	build
YYMMDD=`date +%Y%m%d`
CXX   := g++
FBDIR := .
VDIRFB:= $(FBDIR)/obj_dir
VOBJ := obj_dir
CPUDR := cpu
BASE  := tb_top

.DELETE_ON_ERROR:
.PHONY: build
build: $(VOBJ)/V$(BASE)__ALL.a
SUBMAKE := $(MAKE) --no-print-directory -C $(VOBJ) -f
ifeq ($(VERILATOR_ROOT),)
VERILATOR := verilator
else
VERILATOR := $(VERILATOR_ROOT)/bin/verilator
endif
VFLAGS = -Wall -Wno-TIMESCALEMOD --MMD -O3 -D --trace -Mdir $(VDIRFB) -y ../../rtl --assert -cc

## Generic pattern(s)
## {{{
$(VOBJ)/V$(BASE)__ALL.a: $(VOBJ)/V$(BASE).h
$(VOBJ)/V$(BASE).mk:  $(VOBJ)/V$(BASE).cpp
$(VOBJ)/V$(BASE).cpp: $(VOBJ)/V$(BASE).h
## }}}

$(VOBJ)/V%__ALL.a: $(VOBJ)/V%.mk
	+$(SUBMAKE) V$*.mk

$(VOBJ)/Vtb_top.h: tb_top.v
	$(VERILATOR) $(VFLAGS) tb_top.v
$(VOBJ)/V%.h: %.v
	$(VERILATOR) $(VFLAGS) $*.v

$(VOBJ)/V%.cpp: $(VOBJ)/V%.h
$(VOBJ)/V%.mk:  $(VOBJ)/V%.h
$(VOBJ)/V%.h: $(FBDIR)/%.v

.PHONY: clean
## {{{
clean:
	rm -rf $(VDIRFB)/*.mk
	rm -rf $(VDIRFB)/*.cpp
	rm -rf $(VDIRFB)/*.h
	rm -rf $(VDIRFB)/
## }}}

#
# Note Verilator's dependency created information, and include it here if we
# can
DEPS := $(wildcard $(VOBJ)/*.d)
ifneq ($(MAKECMDGOALS),clean)
ifneq ($(DEPS),)
include $(DEPS)
endif
endif
