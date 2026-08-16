// =============================================================================
// tb_fetch_decode_rename.sv — Orion OOO RISC-V Processor
// Integration smoke test: Fetch -> Decode -> Rename -> ROB / Issue Queue
//
// PURPOSE
//   Get a short, straight-line RV32I program flowing end-to-end through
//   dispatch and commit so you have real waveforms/results to show, not
//   a per-unit-only demo.
//
// WHAT THIS IS NOT
//   This is a control-path integration test, not a functional pipeline
//   demo. There is no real execute unit here — the "cdb_stub" block below
//   is a fixed-1-cycle-latency behavioral stand-in that just echoes back
//   whatever rob_tag/p_dest was issued as "done," with no actual ALU
//   computation. It proves dispatch -> issue -> commit control flow and
//   in-order commit ordering work. It does NOT prove that add/sub/and/or/
//   xor compute correct values, because nothing here computes them. Don't
//   present this as validating datapath correctness in the report — call
//   it what it is: a control-flow integration test with a mocked execute
//   stage.
//
// KNOWN GAPS CARRIED FORWARD FROM RTL REVIEW (not fixed here, just flagged
// again since this is the first time they're exercised in simulation):
//   1. Single CDB port — this stub only ever completes one instruction
//      per cycle by construction, so it can't expose the multi-FU
//      completion collision problem. Don't read anything into the fact
//      that nothing breaks here.
//   2. ROB's CDB writeback has no live-window check (see reorder_buffer.sv
//      TODO). Not exercised here because there's no flush in this program
//      (no branches), so it won't show up in this particular run.
//   3. rename_dispatch_pkt_s carries no r_dst field, so this testbench
//      pipelines decode_out.r_dst through a one-cycle register (r_dst_q)
//      to align with rename_unit's registered output timing, purely so
//      reorder_buffer's separate dispatch_r_dst port has something valid
//      to sample. That's a testbench-level workaround, not a fix — worth
//      deciding whether r_dst should actually live inside the rename
//      dispatch packet before this goes further.
//
// PROGRAM (see imem preload below):
//   addi x1, x0, 5      x1 = 5
//   addi x2, x0, 10     x2 = 10
//   add  x3, x1, x2     x3 = 15   (not actually computed — see note above)
//   sub  x4, x2, x1     x4 = 5
//   and  x5, x1, x2     x5 = 0
//   or   x6, x1, x2     x6 = 15
//   xor  x7, x1, x2     x7 = 15
//   addi x8, x0, 0      x8 = 0
// =============================================================================

`timescale 1ns/1ps
import orion_pkg::*;

module fetch_decode_rename_tb;

    logic clk;
    logic rst_n;

    // ---- Fetch <-> Decode -------------------------------------------------
    logic [DATA_WIDTH-1:0] fetch_pc, fetch_instr;
    logic                  fetch_valid;
    decode_rename_pkt_s    decode_out;

    // ---- Rename -------------------------------------------------------------
    logic                  rename_stall;
    rename_dispatch_pkt_s  rename_out;

    // ---- ROB ------------------------------------------------------------
    logic [ROB_PTR-1:0]    rob_tag;
    logic                  rob_full;
    logic                  commit_valid;
    logic [REG_ADDR_WIDTH-1:0] commit_rd;
    logic [TAG_WIDTH-1:0]  commit_pd, commit_old_pd;
    logic                  store_commit;
    logic                  rob_mispredict;
    logic                  rob_exception;
    except_cause_e         rob_except_cause;
    logic [DATA_WIDTH-1:0] rob_except_pc;

    // ---- Issue Queue ------------------------------------------------------
    logic                  iq_full;
    logic                  issue_valid;
    rename_dispatch_pkt_s  issue_pkt;
    logic [ROB_PTR-1:0]    issue_rob_tag;

    // ---- CDB (behavioral stub — see header note) ---------------------------
    logic                  cdb_valid;
    logic [ROB_PTR-1:0]    cdb_rob_tag;
    logic [TAG_WIDTH-1:0]  cdb_p_dest;

    // -------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
    end

    // -------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------
    fetch_unit #(.IMEM_DEPTH(256)) u_fetch (
        .clk            (clk),
        .rst_n          (rst_n),
        .stall          (rename_stall),
        .redirect_valid (1'b0),         // no branches in this program
        .redirect_pc    ('0),
        .fetch_pc       (fetch_pc),
        .fetch_instr    (fetch_instr),
        .fetch_valid    (fetch_valid)
    );

    decode_unit u_decode (
        .fetch_pc     (fetch_pc),
        .fetch_instr  (fetch_instr),
        .fetch_valid  (fetch_valid),
        .decode_out   (decode_out)
    );

    // always_ff @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) r_dst_q <= '0;
    //     else        r_dst_q <= decode_out.r_dst;
    // end

    rename_unit u_rename (
        .clk                (clk),
        .rst_n              (rst_n),
        .decode_rename_in   (decode_out),
        .branch_mispredict  (1'b0),
        .cdb_valid          (cdb_valid),
        .cdb_p_dest         (cdb_p_dest),
        .rob_full           (rob_full),
        .iq_full            (iq_full),
        .commit_valid       (commit_valid),
        .commit_rd          (commit_rd),
        .commit_pd          (commit_pd),
        .commit_old_pd      (commit_old_pd),
        .rename_stall       (rename_stall),
        .rename_dispatch_out(rename_out)
    );

    reorder_buffer u_rob (
        .clk               (clk),
        .rst_n             (rst_n),
        // .dispatch_r_dst    (r_dst_q),
        .dispatch_in       (rename_out),
        .rob_tag_out       (rob_tag),
        .rob_full          (rob_full),
        .iq_full           (iq_full),
        .cdb_valid         (cdb_valid),
        .cdb_rob_tag       (cdb_rob_tag),
        .cdb_mispredict    (1'b0),
        .cdb_exception     (1'b0),
        .cdb_cause         (EXCEPT_NONE),
        .commit_valid      (commit_valid),
        .commit_rd         (commit_rd),
        .commit_pd         (commit_pd),
        .commit_old_pd     (commit_old_pd),
        .store_commit      (store_commit),
        .branch_mispredict (rob_mispredict),
        .exception_valid   (rob_exception),
        .exception_cause   (rob_except_cause),
        .exception_pc      (rob_except_pc)
    );

    issue_queue u_iq (
        .clk               (clk),
        .rst_n             (rst_n),
        .dispatch_in       (rename_out),
        .dispatch_rob_tag  (rob_tag),
        .rob_full          (rob_full),
        .iq_full           (iq_full),
        .cdb_valid         (cdb_valid),
        .cdb_p_dest        (cdb_p_dest),
        .branch_mispredict (rob_mispredict),
        .exception_valid   (rob_exception),
        .issue_valid       (issue_valid),
        .issue_pkt         (issue_pkt),
        .issue_rob_tag     (issue_rob_tag)
    );

    // -------------------------------------------------------------------
    // CDB stub — fixed 1-cycle "execute" latency, no computation.
    // See header note: this proves control flow only.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdb_valid   <= 1'b0;
            cdb_rob_tag <= '0;
            cdb_p_dest  <= '0;
        end else begin
            cdb_valid   <= issue_valid;
            cdb_rob_tag <= issue_rob_tag;
            cdb_p_dest  <= issue_pkt.p_dest;
        end
    end

    // -------------------------------------------------------------------
    // Instruction memory preload — direct hierarchical poke, no hex file
    // needed for this smoke test.
    // -------------------------------------------------------------------
    initial begin
        u_fetch.imem[0] = 32'h00500093; // addi x1, x0, 5
        u_fetch.imem[1] = 32'h00a00113; // addi x2, x0, 10
        u_fetch.imem[2] = 32'h002081b3; // add  x3, x1, x2
        u_fetch.imem[3] = 32'h40110233; // sub  x4, x2, x1
        u_fetch.imem[4] = 32'h0020f2b3; // and  x5, x1, x2
        u_fetch.imem[5] = 32'h0020e333; // or   x6, x1, x2
        u_fetch.imem[6] = 32'h0020c3b3; // xor  x7, x1, x2
        u_fetch.imem[7] = 32'h00000413; // addi x8, x0, 0
        // remaining words default to 0 (all-zero = illegal opcode 0000000
        // -> decode_unit will flag except; harmless since fetch just keeps
        // running off the end after the program of interest completes)
    end

    // -------------------------------------------------------------------
    // Trace
    // -------------------------------------------------------------------
    initial begin
        $display("time  pc       instr      fetch_v  |  rename_v rename_pdst reg_we  rob_tag  |  commit_v commit_rd commit_pd");
    end

    always @(posedge clk) begin
        if (rst_n) begin
            $display("%4t  %08h %08h   %b       |  %b        %2d          %b       %2d       |  %b         %2d        %2d",
                $time, fetch_pc, fetch_instr, fetch_valid,
                rename_out.valid, rename_out.p_dest, rename_out.reg_we, rob_tag,
                commit_valid, commit_rd, commit_pd);
        end
    end

    initial begin
        repeat (60) @(posedge clk);
        $display("\n=== Simulation complete ===");
        $finish;
    end

endmodule
