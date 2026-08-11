onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /issue_queue_tb/clk
add wave -noupdate /issue_queue_tb/rst_n
add wave -noupdate /issue_queue_tb/dispatch_in.valid
add wave -noupdate /issue_queue_tb/iq_full
add wave -noupdate /issue_queue_tb/cdb_valid
add wave -noupdate /issue_queue_tb/cdb_p_dest
add wave -noupdate /issue_queue_tb/branch_mispredict
add wave -noupdate /issue_queue_tb/exception_valid
add wave -noupdate /issue_queue_tb/issue_valid
add wave -noupdate /issue_queue_tb/dut/free_slot_idx
add wave -noupdate /issue_queue_tb/dut/free_slot_valid
add wave -noupdate /issue_queue_tb/dut/valid_vec
add wave -noupdate /issue_queue_tb/dut/dispatch_rob_tag
add wave -noupdate /issue_queue_tb/dispatch_in.p_src1
add wave -noupdate /issue_queue_tb/dispatch_in.p_src2
add wave -noupdate /issue_queue_tb/dispatch_in.p_src1_valid
add wave -noupdate /issue_queue_tb/dispatch_in.p_src2_valid
add wave -noupdate /issue_queue_tb/dispatch_in.p_src1_rdy
add wave -noupdate /issue_queue_tb/dispatch_in.p_src2_rdy
add wave -noupdate /issue_queue_tb/dispatch_in.p_dest
add wave -noupdate {/issue_queue_tb/dut/iq_mem[0].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[1].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[2].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[3].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[4].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[5].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[6].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[7].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[8].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[9].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[10].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[11].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[12].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[13].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[14].valid}
add wave -noupdate {/issue_queue_tb/dut/iq_mem[15].valid}
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {140000 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 257
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {0 ps} {386960 ps}
