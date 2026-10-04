# -----------------------------------------------------------------------------
# wave_dcache.do : organised waveform for dcache_tb (Questa / ModelSim)
# Usage (after vsim -voptargs="+acc" work.dcache_tb):
#     do wave_dcache.do
# -----------------------------------------------------------------------------
onerror {resume}
quietly WaveActivateNextPane {} 0
delete wave *

set TB  /dcache_tb
set DUT /dcache_tb/dut
set BK  /dcache_tb/u_backing

# ---------------------------------------------------------------- clock / reset
add wave -noupdate -group {00 Clock/Reset} -color White  $TB/clk
add wave -noupdate -group {00 Clock/Reset} -color White  $TB/rst_n
add wave -noupdate -group {00 Clock/Reset} -radix unsigned $TB/cyc

# ---------------------------------------------------------------- the two agents + arbitration
add wave -noupdate -group {01 Agents/Arbitration} -color Cyan   $TB/lsu_req_valid
add wave -noupdate -group {01 Agents/Arbitration} -color Cyan   -radix hex $TB/lsu_req_addr
add wave -noupdate -group {01 Agents/Arbitration} -color Cyan   $TB/lsu_req_ready
add wave -noupdate -group {01 Agents/Arbitration} -color Orange $TB/sb_valid
add wave -noupdate -group {01 Agents/Arbitration} -color Orange -radix hex $TB/sb_addr
add wave -noupdate -group {01 Agents/Arbitration} -color Orange -radix hex $TB/sb_wdata
add wave -noupdate -group {01 Agents/Arbitration} -color Orange -radix binary $TB/sb_wstrb
add wave -noupdate -group {01 Agents/Arbitration} -color Orange $TB/sb_pop
add wave -noupdate -group {01 Agents/Arbitration} -color Yellow $TB/sb_lock_q
add wave -noupdate -group {01 Agents/Arbitration} -color Yellow $TB/sel_sb

# ---------------------------------------------------------------- core side of the cache
add wave -noupdate -group {02 DUT core side} -color Gold  $DUT/req_valid
add wave -noupdate -group {02 DUT core side} -color Gold  $DUT/req_we
add wave -noupdate -group {02 DUT core side} -color Gold  -radix hex $DUT/req_addr
add wave -noupdate -group {02 DUT core side} -color Gold  -radix hex $DUT/req_wdata
add wave -noupdate -group {02 DUT core side} -color Gold  -radix binary $DUT/req_wstrb
add wave -noupdate -group {02 DUT core side} -color Green $DUT/req_ready
add wave -noupdate -group {02 DUT core side} -color Violet $DUT/resp_valid
add wave -noupdate -group {02 DUT core side} -color Violet -radix hex $DUT/resp_rdata

# ---------------------------------------------------------------- FSM + captured request
add wave -noupdate -group {03 DUT FSM} -color Yellow $DUT/state
add wave -noupdate -group {03 DUT FSM} $DUT/accept_ld
add wave -noupdate -group {03 DUT FSM} $DUT/accept_st
add wave -noupdate -group {03 DUT FSM} -radix hex $DUT/addr_q
add wave -noupdate -group {03 DUT FSM} -radix unsigned $DUT/idx_q
add wave -noupdate -group {03 DUT FSM} -radix hex $DUT/tag_q
add wave -noupdate -group {03 DUT FSM} -radix unsigned $DUT/word_q
add wave -noupdate -group {03 DUT FSM} -radix hex $DUT/wdata_q
add wave -noupdate -group {03 DUT FSM} -radix binary $DUT/wstrb_q

# ---------------------------------------------------------------- lookup / hit
add wave -noupdate -group {04 DUT lookup/hit} -radix hex $DUT/t_dout
add wave -noupdate -group {04 DUT lookup/hit} -radix hex $DUT/d_dout
add wave -noupdate -group {04 DUT lookup/hit} -radix binary $DUT/hit_w
add wave -noupdate -group {04 DUT lookup/hit} $DUT/hit
add wave -noupdate -group {04 DUT lookup/hit} $DUT/hit_way
add wave -noupdate -group {04 DUT lookup/hit} -radix hex $DUT/sel_data
add wave -noupdate -group {04 DUT lookup/hit} $DUT/victim_way
add wave -noupdate -group {04 DUT lookup/hit} $DUT/miss_way_q
add wave -noupdate -group {04 DUT lookup/hit} $DUT/resp_valid_q

# ---------------------------------------------------------------- store path
add wave -noupdate -group {05 DUT store path} $DUT/st_first_q
add wave -noupdate -group {05 DUT store path} $DUT/st_hit_q
add wave -noupdate -group {05 DUT store path} $DUT/st_way_q

# ---------------------------------------------------------------- SRAM macro controls (both ways)
add wave -noupdate -group {06 DUT SRAM ctrl} -radix binary $DUT/d_en
add wave -noupdate -group {06 DUT SRAM ctrl} -radix binary $DUT/d_we
add wave -noupdate -group {06 DUT SRAM ctrl} -radix binary $DUT/d_wmask_c
add wave -noupdate -group {06 DUT SRAM ctrl} -radix hex    $DUT/d_addr_c
add wave -noupdate -group {06 DUT SRAM ctrl} -radix hex    $DUT/d_din_c
add wave -noupdate -group {06 DUT SRAM ctrl} -radix binary $DUT/t_en
add wave -noupdate -group {06 DUT SRAM ctrl} -radix binary $DUT/t_we
add wave -noupdate -group {06 DUT SRAM ctrl} -radix hex    $DUT/t_addr_c
add wave -noupdate -group {06 DUT SRAM ctrl} -radix hex    $DUT/t_din_c

# ---------------------------------------------------------------- refill progress
add wave -noupdate -group {07 DUT refill} -radix unsigned $DUT/beat_q

# ---------------------------------------------------------------- backing-store interface
add wave -noupdate -group {08 Backing interface} -color Gold   $DUT/mem_req_valid
add wave -noupdate -group {08 Backing interface} -color Green  $DUT/mem_req_ready
add wave -noupdate -group {08 Backing interface} -color Gold   $DUT/mem_req_we
add wave -noupdate -group {08 Backing interface} -color Gold   -radix hex $DUT/mem_req_addr
add wave -noupdate -group {08 Backing interface} -color Gold   -radix hex $DUT/mem_req_wdata
add wave -noupdate -group {08 Backing interface} -color Gold   -radix binary $DUT/mem_req_wstrb
add wave -noupdate -group {08 Backing interface} -color Violet $DUT/mem_resp_valid
add wave -noupdate -group {08 Backing interface} -color Violet -radix hex $DUT/mem_resp_data
add wave -noupdate -group {08 Backing interface} -color Violet $DUT/mem_resp_last

# ---------------------------------------------------------------- backing model internals
add wave -noupdate -group {09 Backing model} $BK/st
add wave -noupdate -group {09 Backing model} -radix unsigned $BK/wait_cnt
add wave -noupdate -group {09 Backing model} -radix unsigned $BK/beat
add wave -noupdate -group {09 Backing model} $BK/wr_armed
add wave -noupdate -group {09 Backing model} -radix unsigned $BK/wr_wait

# ---------------------------------------------------------------- scoreboard
add wave -noupdate -group {10 Scoreboard} -color Red -radix unsigned $TB/errors
add wave -noupdate -group {10 Scoreboard} $TB/ld_out
add wave -noupdate -group {10 Scoreboard} -radix hex $TB/ld_exp
add wave -noupdate -group {10 Scoreboard} $TB/wr_seen
add wave -noupdate -group {10 Scoreboard} -radix unsigned $TB/loads_done
add wave -noupdate -group {10 Scoreboard} -radix unsigned $TB/stores_done
add wave -noupdate -group {10 Scoreboard} -radix unsigned $TB/refill_cnt
add wave -noupdate -group {10 Scoreboard} -radix unsigned $TB/wr_cnt

# ---------------------------------------------------------------- wide state (collapsed by default)
add wave -noupdate -group {11 Valid/LRU (wide)} -radix binary $DUT/valid
add wave -noupdate -group {11 Valid/LRU (wide)} -radix binary $DUT/lru

# ---------------------------------------------------------------- view settings
configure wave -namecolwidth 250
configure wave -valuecolwidth 90
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -timelineunits ns
configure wave -gridoffset 0
configure wave -gridperiod 5
WaveRestoreZoom {0 ns} {1500 ns}
update
