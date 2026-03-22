VLOG = vlog
VSIM = vsim
VLIB = vlib

#paths
RTL_FLIST = ../rtl/flist.f
TB_FILES  = ../tb/*.sv

#default
all: compile sim

#init library
lib:
	@if [ ! -d work ]; then $(VLIB) work; fi

#compile using the filelist
compile: lib
	$(VLOG) -sv -f $(RTL_FLIST)
	$(VLOG) -sv $(TB_FILES)
#run simulation
sim:
	$(VSIM) -c -do "run -all; quit" work.top_tb
#debug in gui with waveform
gui:
	$(VSIM) -voptargs="+acc" work.top_tb &
#clean files
clean:
	rm -rf work vsim.wlf transcript
