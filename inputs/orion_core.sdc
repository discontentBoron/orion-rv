###############################################################################
# Clock
###############################################################################
set PERIOD 5.0
create_clock -name core_clk -period $PERIOD [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks core_clk]
set_clock_transition  0.1  [get_clocks core_clk]

###############################################################################
# Reset — async, not a synchronous data path
###############################################################################
set_false_path -from [get_ports rst_n]

###############################################################################
# Real functional I/O — crosses the chip boundary to memory
###############################################################################
set ext_in  {imem_rdata dmem_req_ready dmem_resp_valid dmem_resp_rdata}
set ext_out {imem_addr dmem_req_valid dmem_req_we dmem_req_addr dmem_req_wdata dmem_req_wstrb}

set_input_delay  -clock core_clk -max [expr {0.6*$PERIOD}] [get_ports $ext_in]
set_input_delay  -clock core_clk -min [expr {0.1*$PERIOD}] [get_ports $ext_in]
set_output_delay -clock core_clk -max [expr {0.3*$PERIOD}] [get_ports $ext_out]
set_output_delay -clock core_clk -min [expr {0.05*$PERIOD}] [get_ports $ext_out]

set_driving_cell -lib_cell BUF_X4 [get_ports $ext_in]
set_load [expr {4 * [load_of NangateOpenCellLibrary_slow_ccs/BUF_X4/A]}] [get_ports $ext_out]


###############################################################################
# Design rule guards — helps CTS/route converge later, not just timing
###############################################################################
set_max_transition 0.5 [current_design]
set_max_fanout 16 [current_design]

###############################################################################
# OpenRAM macro, if/when it lands — don't optimize into the black box
###############################################################################
# set_dont_touch [get_cells u_*sram*]
