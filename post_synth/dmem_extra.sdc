# dmem interface constraints, same style as the existing imem ones
set period 4.25
set in_max  [expr {0.30 * $period}]
set in_min  [expr {0.10 * $period}]
set out_max [expr {0.30 * $period}]
set out_min [expr {0.05 * $period}]

set dmem_in  [get_ports {dmem_req_ready dmem_resp_valid dmem_resp_rdata[*]}]
set dmem_out [get_ports {dmem_req_valid dmem_req_we dmem_req_addr[*] dmem_req_wdata[*] dmem_req_wstrb[*]}]

set_input_delay  -clock [get_clocks core_clk] -add_delay -max $in_max  $dmem_in
set_input_delay  -clock [get_clocks core_clk] -add_delay -min $in_min  $dmem_in
set_driving_cell -lib_cell BUF_X4 -library NangateOpenCellLibrary -pin Z $dmem_in

set_output_delay -clock [get_clocks core_clk] -add_delay -max $out_max $dmem_out
set_output_delay -clock [get_clocks core_clk] -add_delay -min $out_min $dmem_out
set_load -pin_load 5.0 $dmem_out
