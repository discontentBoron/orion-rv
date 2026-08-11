// =============================================================================
// register_read_tb.sv  —  Orion Register Read Stage Testbench
//
// Compatible: Cadence Incisive/Xcelium, Synopsys VCS, Mentor Questa,
//             Icarus Verilog 12+ (iverilog -g2012)
//
// Groups:
//   A — Reset & sanity          ( 4 checks)
//   B — Basic PRF read          ( 8 checks)
//   C — x0 hardwired zero       ( 5 checks)
//   D — p_srcN_valid gating     ( 5 checks)
//   E — Flush                   ( 6 checks)
//   F — Pass-through fields     (13 checks)
//   G — Sequential/stress       (18 checks)
//   Total: 59 directed checks
// =============================================================================

`timescale 1ns/1ps

import orion_pkg::*;

module register_read_tb;

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------
logic                    clk;
logic                    rst_n;
rename_dispatch_pkt_s    dispatch_in;
logic                    flush;
logic [TAG_WIDTH-1:0]    cdb_tag;
logic [DATA_WIDTH-1:0]   cdb_data;
logic                    cdb_valid;
logic                    wb_en;
logic [TAG_WIDTH-1:0]    wb_tag;
logic [DATA_WIDTH-1:0]   wb_data;
regread_execute_pkt_s    execute_out;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
register_read dut (
    .clk(clk), .rst_n(rst_n),
    .dispatch_in(dispatch_in),
    .flush(flush),
    .cdb_tag(cdb_tag), .cdb_data(cdb_data), .cdb_valid(cdb_valid),
    .wb_en(wb_en), .wb_tag(wb_tag), .wb_data(wb_data),
    .execute_out(execute_out)
);

// ---------------------------------------------------------------------------
// Clock  100 MHz
// ---------------------------------------------------------------------------
initial clk = 0;
always  #5 clk = ~clk;

// ---------------------------------------------------------------------------
// Scoreboard
// ---------------------------------------------------------------------------
int pass_cnt, fail_cnt, tnum;

task automatic PASS(input string msg);
    $display("[PASS] T%0d: %s", tnum, msg);
    pass_cnt++; tnum++;
endtask

task automatic FAIL_MSG(input string msg);
    $display("[FAIL] T%0d: %s", tnum, msg);
    fail_cnt++; tnum++;
endtask

task automatic CK32(
    input logic [31:0] got,
    input logic [31:0] exp,
    input string       lbl
);
    if (got === exp) PASS(lbl);
    else begin
        $display("[FAIL] T%0d: %s  exp=0x%08h  got=0x%08h", tnum, lbl, exp, got);
        fail_cnt++; tnum++;
    end
endtask

task automatic CK1(input logic got, input logic exp, input string lbl);
    if (got === exp) PASS(lbl);
    else begin
        $display("[FAIL] T%0d: %s  exp=%0b  got=%0b", tnum, lbl, exp, got);
        fail_cnt++; tnum++;
    end
endtask

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
task automatic do_reset;
    rst_n = 0; dispatch_in = '0; flush = 0;
    wb_en = 0; wb_tag = '0; wb_data = '0;
    cdb_tag = '0; cdb_data = '0; cdb_valid = 0;
    repeat(3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
endtask

// Synchronous PRF write — set up at negedge, latch at posedge, clear after
task automatic prf_wr(input logic [5:0] tag, input logic [31:0] data);
    @(negedge clk);
    wb_en = 1; wb_tag = tag; wb_data = data;
    @(posedge clk); #1;
    wb_en = 0; wb_tag = '0; wb_data = '0;
endtask

// Drive minimal instruction: src1 tag, src2 tag, valid flags, pkt valid
// Output appears one clock later (registered output)
task automatic drv(
    input logic [5:0] s1, input logic [5:0] s2,
    input logic s1v,      input logic s2v,
    input logic pv
);
    @(negedge clk);
    dispatch_in         = '0;
    dispatch_in.valid   = pv;
    dispatch_in.p_src1  = s1; dispatch_in.p_src1_valid = s1v;
    dispatch_in.p_src2  = s2; dispatch_in.p_src2_valid = s2v;
    dispatch_in.p_dest  = 6'd1; dispatch_in.reg_we = 1;
    dispatch_in.exec_unit_uop = ADD;
    @(posedge clk); #1;
    dispatch_in = '0;
endtask

// ===========================================================================
// GROUP A — Reset & sanity
// ===========================================================================
task automatic test_A;
    $display("\n--- GROUP A: Reset & sanity ---");

    // A1 — valid=0 after reset
    do_reset; @(negedge clk);
    CK1(execute_out.valid, 1'b0, "A1: valid=0 after reset");

    // A2 — src data fields zeroed after reset
    CK32(execute_out.src1_data, 32'h0, "A2: src1_data=0 after reset");
    CK32(execute_out.src2_data, 32'h0, "A2: src2_data=0 after reset");

    // A3 — bubble (valid=0) packet → valid=0 out
    do_reset;
    drv(6'd5, 6'd6, 1'b1, 1'b1, 1'b0);
    @(negedge clk);
    CK1(execute_out.valid, 1'b0, "A3: bubble pkt valid=0 propagates");
endtask

// ===========================================================================
// GROUP B — Basic PRF read
// ===========================================================================
task automatic test_B;
    $display("\n--- GROUP B: Basic PRF read ---");

    // B1 — p_src1 read
    do_reset; prf_wr(6'd10, 32'hAABBCCDD);
    drv(6'd10, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'hAABBCCDD, "B1: p_src1 basic read");

    // B2 — p_src2 read
    do_reset; prf_wr(6'd20, 32'h11223344);
    drv(6'd0, 6'd20, 1'b0, 1'b1, 1'b1); @(negedge clk);
    CK32(execute_out.src2_data, 32'h11223344, "B2: p_src2 basic read");

    // B3 — both srcs simultaneously
    do_reset; prf_wr(6'd3, 32'hDEAD0001); prf_wr(6'd4, 32'hBEEF0002);
    drv(6'd3, 6'd4, 1'b1, 1'b1, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'hDEAD0001, "B3: both-src read src1");
    CK32(execute_out.src2_data, 32'hBEEF0002, "B3: both-src read src2");

    // B4 — all-ones pattern
    do_reset; prf_wr(6'd7, 32'hFFFFFFFF);
    drv(6'd7, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'hFFFFFFFF, "B4: all-ones value");

    // B5 — overwrite with zero
    do_reset; prf_wr(6'd8, 32'hABCDABCD); prf_wr(6'd8, 32'h00000000);
    drv(6'd8, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h00000000, "B5: overwrite with zero reads 0");

    // B6 — three writes same tag, latest wins
    do_reset;
    prf_wr(6'd15, 32'h11111111); prf_wr(6'd15, 32'h22222222); prf_wr(6'd15, 32'h33333333);
    drv(6'd15, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h33333333, "B6: latest after 3 writes");
endtask

// ===========================================================================
// GROUP C — x0 hardwired zero
// ===========================================================================
task automatic test_C;
    $display("\n--- GROUP C: x0 hardwired zero ---");

    // C1 — attempt write to tag 0, read back → must be 0
    do_reset;
    @(negedge clk); wb_en=1; wb_tag=6'd0; wb_data=32'hFFFFFFFF;
    @(posedge clk); #1; wb_en=0; wb_tag='0; wb_data='0;
    drv(6'd0, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h0, "C1: p_src1==0 reads 0 after write attempt");

    // C2 — p_src2==0 with valid=1
    do_reset; prf_wr(6'd5, 32'hABCDEF01);
    drv(6'd5, 6'd0, 1'b1, 1'b1, 1'b1); @(negedge clk);
    CK32(execute_out.src2_data, 32'h0, "C2: p_src2==0 reads 0");

    // C3 — write to tag 0 must not corrupt tag 1
    do_reset; prf_wr(6'd1, 32'h12345678);
    @(negedge clk); wb_en=1; wb_tag=6'd0; wb_data=32'hDEADBEEF;
    @(posedge clk); #1; wb_en=0; wb_tag='0; wb_data='0;
    drv(6'd1, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h12345678, "C3: tag0 write doesn't corrupt tag1");

    // C4 — both src tags == 0, both valid=1 → both outputs 0
    do_reset; drv(6'd0, 6'd0, 1'b1, 1'b1, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h0, "C4: both tag=0 valid=1 → src1=0");
    CK32(execute_out.src2_data, 32'h0, "C4: both tag=0 valid=1 → src2=0");
endtask

// ===========================================================================
// GROUP D — p_srcN_valid gating
// ===========================================================================
task automatic test_D;
    $display("\n--- GROUP D: p_srcN_valid gating ---");

    // D1 — src1_valid=0 gates src1_data to 0
    do_reset; prf_wr(6'd9, 32'hCAFEBABE);
    drv(6'd9, 6'd0, 1'b0, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h0, "D1: src1_valid=0 → src1_data=0");

    // D2 — src2_valid=0 gates src2_data to 0
    do_reset; prf_wr(6'd11, 32'hFACEFACE);
    drv(6'd0, 6'd11, 1'b0, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src2_data, 32'h0, "D2: src2_valid=0 → src2_data=0");

    // D3 — both valids=0
    do_reset; prf_wr(6'd12, 32'h87654321); prf_wr(6'd13, 32'h12348765);
    drv(6'd12, 6'd13, 1'b0, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'h0, "D3: both_valid=0 → src1=0");
    CK32(execute_out.src2_data, 32'h0, "D3: both_valid=0 → src2=0");
endtask

// ===========================================================================
// GROUP E — Flush
// ===========================================================================
task automatic test_E;
    $display("\n--- GROUP E: Flush ---");

    // E1 — flush=1 kills valid
    do_reset; prf_wr(6'd5, 32'h55555555);
    @(negedge clk); flush=1;
    dispatch_in.valid=1; dispatch_in.p_src1=6'd5; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk); CK1(execute_out.valid, 1'b0, "E1: flush kills valid");

    // E2 — after flush clears, next instr propagates normally
    do_reset; prf_wr(6'd6, 32'h66666666);
    @(negedge clk); flush=1;
    dispatch_in.valid=1; dispatch_in.p_src1=6'd6; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk);
    dispatch_in.valid=1; dispatch_in.p_src1=6'd6; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; dispatch_in='0;
    @(negedge clk);
    CK1 (execute_out.valid,     1'b1,       "E2: post-flush valid=1");
    CK32(execute_out.src1_data, 32'h66666666, "E2: post-flush data correct");

    // E3 — flush while both srcs valid
    do_reset; prf_wr(6'd17, 32'hABCDEF00); prf_wr(6'd18, 32'h00FEDCBA);
    @(negedge clk); flush=1;
    dispatch_in.valid=1;
    dispatch_in.p_src1=6'd17; dispatch_in.p_src1_valid=1;
    dispatch_in.p_src2=6'd18; dispatch_in.p_src2_valid=1;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk); CK1(execute_out.valid, 1'b0, "E3: flush both srcs → valid=0");

    // E4 — two consecutive flush pulses
    do_reset; prf_wr(6'd19, 32'h19191919);
    @(negedge clk); flush=1;
    dispatch_in.valid=1; dispatch_in.p_src1=6'd19; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; dispatch_in='0;
    dispatch_in.valid=1; dispatch_in.p_src1=6'd19; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk); CK1(execute_out.valid, 1'b0, "E4: consecutive flush → valid=0");

    // E5 — flush on bubble (valid=0 in) → still valid=0 out
    do_reset;
    @(negedge clk); flush=1; dispatch_in.valid=0;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk); CK1(execute_out.valid, 1'b0, "E5: flush on bubble stays valid=0");
endtask

// ===========================================================================
// GROUP F — Pass-through fields
// ===========================================================================
task automatic test_F;
    $display("\n--- GROUP F: Pass-through fields ---");
    do_reset;
    prf_wr(6'd21, 32'hA1B2C3D4);
    prf_wr(6'd22, 32'hE5F60708);

    @(negedge clk);
    dispatch_in.valid          = 1;
    dispatch_in.p_src1         = 6'd21; dispatch_in.p_src1_valid = 1;
    dispatch_in.p_src2         = 6'd22; dispatch_in.p_src2_valid = 1;
    dispatch_in.p_dest         = 6'd30;
    dispatch_in.old_p_dest     = 6'd29;
    dispatch_in.reg_we         = 1;
    dispatch_in.pc             = 32'hBEEF1234;
    dispatch_in.predicted_pc   = 32'hBEEF1238;
    dispatch_in.imm_val        = 32'hFFFFF001;
    dispatch_in.instr_class    = INSTR_LOAD;
    dispatch_in.func_unit_type = FU_LSU;
    dispatch_in.exec_unit_uop  = LW;
    dispatch_in.cause          = EXCEPT_ILLEGAL_INST;
    dispatch_in.except         = 1;
    @(posedge clk); #1; dispatch_in = '0;

    @(negedge clk);
    CK1 (execute_out.valid,        1'b1,           "F01: valid");
    CK32(execute_out.pc,           32'hBEEF1234,   "F02: pc");
    CK32(execute_out.predicted_pc, 32'hBEEF1238,   "F03: predicted_pc");
    CK32(execute_out.imm_val,      32'hFFFFF001,    "F04: imm_val");

    if (execute_out.p_dest    === 6'd30) PASS("F05: p_dest");
    else FAIL_MSG("F05: p_dest mismatch");

    if (execute_out.old_p_dest === 6'd29) PASS("F06: old_p_dest");
    else FAIL_MSG("F06: old_p_dest mismatch");

    CK1(execute_out.reg_we, 1'b1, "F07: reg_we");

    if (execute_out.instr_class    === INSTR_LOAD) PASS("F08: instr_class");
    else FAIL_MSG("F08: instr_class mismatch");

    if (execute_out.func_unit_type === FU_LSU) PASS("F09: func_unit_type");
    else FAIL_MSG("F09: func_unit_type mismatch");

    if (execute_out.exec_unit_uop  === LW) PASS("F10: exec_unit_uop");
    else FAIL_MSG("F10: exec_unit_uop mismatch");

    CK1(execute_out.except, 1'b1, "F11: except");

    if (execute_out.cause === EXCEPT_ILLEGAL_INST) PASS("F12: cause");
    else FAIL_MSG("F12: cause mismatch");

    CK32(execute_out.src1_data, 32'hA1B2C3D4, "F13: src1_data from PRF");
    CK32(execute_out.src2_data, 32'hE5F60708, "F14: src2_data from PRF");
endtask

// ===========================================================================
// GROUP G — Sequential / pipeline stress
// ===========================================================================
task automatic test_G;
    logic [31:0] earr [1:8];
    logic [31:0] garr [1:8];
    logic [31:0] o0, o1, o2, o3;

    $display("\n--- GROUP G: Sequential / pipeline stress ---");

    // G1 — 8 back-to-back instructions, each a different physical register
    do_reset;
    for (int i = 1; i <= 8; i++) begin earr[i] = 32'h1000_0000 | i; prf_wr(i[5:0], earr[i]); end
    for (int i = 1; i <= 8; i++) begin
        drv(i[5:0], 6'd0, 1'b1, 1'b0, 1'b1);
        @(negedge clk); garr[i] = execute_out.src1_data;
    end
    for (int i = 1; i <= 8; i++)
        CK32(garr[i], earr[i], $sformatf("G1: back-to-back instr%0d p%0d", i, i));

    // G2 — write then read on immediately following cycle
    do_reset; prf_wr(6'd40, 32'hDEADBEEF);
    drv(6'd40, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK32(execute_out.src1_data, 32'hDEADBEEF, "G2: write then immediate next-cycle read");

    // G3 — normal → flush → normal sequence
    do_reset; prf_wr(6'd25, 32'h25252525);
    drv(6'd25, 6'd0, 1'b1, 1'b0, 1'b1);
    @(negedge clk); CK1(execute_out.valid, 1'b1, "G3a: pre-flush valid=1");
    @(negedge clk); flush=1;
    dispatch_in.valid=1; dispatch_in.p_src1=6'd25; dispatch_in.p_src1_valid=1;
    @(posedge clk); #1; flush=0; dispatch_in='0;
    @(negedge clk); CK1(execute_out.valid, 1'b0, "G3b: flushed valid=0");
    drv(6'd25, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
    CK1 (execute_out.valid,     1'b1,       "G3c: post-flush valid=1");
    CK32(execute_out.src1_data, 32'h25252525, "G3d: post-flush data correct");

    // G4 — full PRF sweep: all 63 non-zero physical regs
    do_reset;
    for (int i = 1; i < PHY_REGS; i++) prf_wr(i[5:0], 32'hA000_0000 | i);
    for (int i = 1; i < PHY_REGS; i++) begin
        drv(i[5:0], 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk);
        CK32(execute_out.src1_data, 32'hA000_0000 | i, $sformatf("G4: PRF sweep p%0d", i));
    end

    // G5 — 4-instruction ordering stress
    do_reset;
    prf_wr(6'd50, 32'h50505050); prf_wr(6'd51, 32'h51515151);
    prf_wr(6'd52, 32'h52525252); prf_wr(6'd53, 32'h53535353);
    drv(6'd50, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk); o0 = execute_out.src1_data;
    drv(6'd51, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk); o1 = execute_out.src1_data;
    drv(6'd52, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk); o2 = execute_out.src1_data;
    drv(6'd53, 6'd0, 1'b1, 1'b0, 1'b1); @(negedge clk); o3 = execute_out.src1_data;
    CK32(o0, 32'h50505050, "G5: pipeline order instr0");
    CK32(o1, 32'h51515151, "G5: pipeline order instr1");
    CK32(o2, 32'h52525252, "G5: pipeline order instr2");
    CK32(o3, 32'h53535353, "G5: pipeline order instr3");
endtask

// ===========================================================================
// Main
// ===========================================================================
initial begin
    pass_cnt = 0; fail_cnt = 0; tnum = 1;

    $display("=======================================================");
    $display("  REGISTER READ STAGE — COMPREHENSIVE TESTBENCH");
    $display("=======================================================");

    test_A;
    test_B;
    test_C;
    test_D;
    test_E;
    test_F;
    test_G;

    repeat(5) @(posedge clk);

    $display("\n=======================================================");
    $display("  Total   : %0d", pass_cnt + fail_cnt);
    $display("  Passed  : %0d", pass_cnt);
    $display("  Failed  : %0d", fail_cnt);
    $display("  Result  : %s",
        (fail_cnt == 0) ? "*** ALL PASS ***" : "*** FAILURES DETECTED ***");
    $display("=======================================================");
    $finish;
end

// Watchdog
initial begin #2_000_000; $display("[TIMEOUT]"); $finish; end

endmodule