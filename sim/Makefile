VLOG = vlog
VSIM = vsim
VLIB = vlib

#paths
RTL_FLIST = ../inputs/orion_rv_src_list.txt
TB_DIR  = ../src/tb/

#Default testbench
TB_FILE ?= top_tb
PLUS_ARGS ?= 
DEFINES ?=
#default
all: compile sim

#init library
lib:
	@if [ ! -d work ]; then $(VLIB) work; fi

#compile using the filelist
compile: lib
	$(VLOG) -sv $(DEFINES) -f $(RTL_FLIST)
	$(VLOG) -sv $(DEFINES) $(TB_DIR)/$(TB_FILE).sv
#run simulation
sim: compile
	$(VSIM) -c $(PLUS_ARGS) -do "run -all; quit" work.$(TB_FILE)
#Debug in gui with waveform
gui: compile
	$(VSIM) -voptargs="+acc" work.$(TB_FILE) 
#clean files
clean:
	rm -rf work vsim.wlf transcript
