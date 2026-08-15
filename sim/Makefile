VLOG = vlog
VSIM = vsim
VLIB = vlib

#paths
RTL_FLIST = ../inputs/orion_rv_src_list.txt
TB_DIR  = ../src/tb/

#Default testbench
TB_FILE ?= top_tb

#default
all: compile sim

#init library
lib:
	@if [ ! -d work ]; then $(VLIB) work; fi

#compile using the filelist
compile: lib
	$(VLOG) -sv -f $(RTL_FLIST)
	$(VLOG) -sv $(TB_DIR)/$(TB_FILE).sv
#run simulation
sim: compile
	$(VSIM) -c -do "run -all; quit" work.$(TB_FILE)
#Debug in gui with waveform
gui: compile
	$(VSIM) -voptargs="+acc" work.$(TB_FILE) 
#clean files
clean:
	rm -rf work vsim.wlf transcript
