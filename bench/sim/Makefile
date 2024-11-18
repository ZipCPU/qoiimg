################################################################################
##
## Filename:	./bench/sim/Makefile
## {{{
## Project:	Quite OK image compression (QOI) Verilog implementation
##
## Purpose:	To coordinate the build of a cycle accurate, Verilator based,
##		simulation of the main module.  Access to the simulation is
##	provided via the same software commands that will access the board, save
##	that the parameters are a touch different.  (See the access software for
##	more information ...)
##
## Creator:	Dan Gisselquist, Ph.D.
##		Gisselquist Technology, LLC
##
################################################################################
## }}}
## Copyright (C) 2022-2024, Gisselquist Technology, LLC
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
.PHONY: all
# Make certain the "all" target is the first and therefore the default target
all:
CXX	:= g++
OBJDIR	:= obj-pc
RTLD	:= ../verilog
VOBJDR	:= $(RTLD)/obj_dir
VERILATOR_ROOT ?= $(shell bash -c 'verilator -V|grep VERILATOR_ROOT | head -1 | sed -e " s/^.*=\s*//"')
VROOT	:= $(VERILATOR_ROOT)
VDEFS   := $(shell $(VVERSION))
VINCD   := $(VROOT)/include
VINC	:= -I$(VINCD) -I$(VINCD)/vltstd -I$(VOBJDR)
INCS	:= -I$(RTLD) $(VINC)
LIBS    := -lpng -lpthread
VSRCS := verilated.cpp verilated_threads.cpp verilated_vcd_c.cpp
VOBJS := $(addprefix $(OBJDIR)/,$(subst .cpp,.o,$(VSRCS)))
CFLAGS	:= -g -O3 -std=gnu++14 -faligned-new -Wall $(INCS)
##

PROGRAMS := main_tb
# Now the return to the "all" target, and fill in some details
all:	$(PROGRAMS)

$(OBJDIR)/%.o: %.cpp
	$(mk-objdir)
	$(CXX) $(CFLAGS) $(VDEFS) $(INCS) -c $< -o $@

$(OBJDIR)/%.o: $(VINCD)/%.cpp
	$(mk-objdir)
	$(CXX) $(CFLAGS) $(INCS) -c $< -o $@


$(OBJDIR)/main_tb.o: $(VOBJDR)/Vtb_top.h
MAINOBJS := $(OBJDIR)/main_tb.o
main_tb: $(MAINOBJS) $(VOBJS) $(VOBJDR)/Vtb_top__ALL.a
	$(CXX) $(CFLAGS) $^ $(VOBJDR)/Vtb_top__ALL.a -lpng -lpthread -o $@

#
# The "clean" target, removing any and all remaining build products
#
.PHONY: clean
clean:
	rm -f *.vcd
	rm -f $(PROGRAMS)
	rm -rf $(OBJDIR)/

#
# The "depends" target, to know what files things depend upon.  The depends
# file itself is kept in $(OBJDIR)/depends.txt
#
define build-depends
	$(mk-objdir)
	@echo "Building dependency file"
	@$(CXX) $(CFLAGS) $(INCS) -MM $(SOURCES) > $(OBJDIR)/xdepends.txt
	@sed -e 's/^.*.o: /$(OBJDIR)\/&/' < $(OBJDIR)/xdepends.txt > $(OBJDIR)/depends.txt
	@rm $(OBJDIR)/xdepends.txt
endef

.PHONY: depends
depends: tags
	$(build-depends)

$(OBJDIR)/depends.txt: depends

#
define	mk-objdir
	@bash -c "if [ ! -e $(OBJDIR) ]; then mkdir -p $(OBJDIR); fi"
endef


#
# The "tags" target
#
tags:	$(SOURCES) $(HEADERS)
	@echo "Generating tags"
	@ctags $(SOURCES) $(HEADERS)


ifneq ($(MAKECMDGOALS),clean)
# -include $(OBJDIR)/depends.txt
endif
