set CLK_PERIOD 3.333

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.150 [get_clocks clk]

# Async active-low reset -- not a timing path
set_false_path -from [get_ports rst_n]

set_max_fanout 16 [current_design]
# Cap transition times to prevent slow, weak nets (200ps)
set_max_transition 0.200 [current_design]

set IN_DELAY  [expr {$CLK_PERIOD * 0.2}]
set OUT_DELAY [expr {$CLK_PERIOD * 0.25}]

set all_in_no_clk_rst [remove_from_collection [all_inputs] \
                          [get_ports {clk rst_n}]]

set_input_delay  $IN_DELAY  -clock clk$all_in_no_clk_rst
set_output_delay $OUT_DELAY -clock clk [all_outputs]

set_clock_uncertainty -setup 0.1 [get_clocks clk]
set_clock_uncertainty -hold 0.05 [get_clocks clk]
set_clock_transition 0.1 [get_clocks clk]
