
set_units -time ns -capacitance pF

# 300 MHz = 3.333 ns period. 
set clock_period 3.33
set clock_name "clk"
create_clock -name $clock_name -period $clock_period -waveform "0 [expr $clock_period / 2.0]" [get_ports clk]

set_clock_uncertainty 0.15 [get_clocks $clock_name]
set_clock_transition 0.05 [get_clocks $clock_name]

set in_delay_val [expr $clock_period * 0.3]
set out_delay_val [expr $clock_period * 0.3]

set_output_delay $out_delay_val -clock $clock_name [all_outputs]

set_driving_cell -lib_cell INV_X1 -pin ZN \
    [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]

set_driving_cell -lib_cell INV_X1 -pin ZN [get_ports rst_n]
set_load 0.010 [all_outputs]

set_max_fanout 32 [current_design]

set_max_fanout 8 [get_nets branch_mispredict]
set_max_fanout 8 [get_nets rst_n]

set_max_transition 0.200 [current_design]