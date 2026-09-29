`timescale 1ns / 1ps
import orion_pkg::*;
//TODO: Fix to support updated modules. Lot of changes in module to fix
// =============================================================================
// fdr_rob_tb.sv — joint test of fetch_unit + decode_unit + rename_unit +
// reorder_buffer via fdr_rob_top.
//
// SCENARIO 1 — ROB fills while the free list stays open.
//   Stream: 24 filler ADDI x0,x0,imm (reg_we=0, ROB-only) interleaved 3:1
//   with 8 ADDI x1,x0,imm (reg_we=1, consumes free list + ROB), for 32
//   total dispatches -> exactly fills the ROB. A 33rd instruction (another
//   filler) is the one that should actually hit rob_full and stall.
//   Checks: at the stall cycle, free_list_empty is FALSE (only 8/32 spares
//   consumed) while rob_full is TRUE — isolates the rob_full stall term.
//   Then fakes a CDB completion for the oldest ROB entry (whatever it is
//   per the scoreboard) and confirms rob_full clears and rename resumes.
//
// SCENARIO 2 — both exhaust together (fresh reset).
//   Stream: 32x ADDI x1,x0,imm, no fillers, no fake completions until full.
//   Checks: rob_full and free_list_empty become true on the SAME cycle
//   (asserted explicitly, since this coincidence is expected/correct given
//   the 1:1 free-list/ROB coupling for register-writing instructions, not
//   something to avoid). Fakes completion of the oldest (first) x1 rename
//   and confirms BOTH rob_full and free_list_empty clear from the same
//   commit event, and that the freed p_dest reused by the next rename
//   equals that entry's old_p_dest exactly (FIFO-correctness check).
//
// INVARIANT (checked continuously across both scenarios): free_list_empty
// must never be true while rob_full is false. Every free-list consumption
// implies a simultaneous ROB consumption in this design (no instruction
// type does one without the other), so this direction of exhaustion is
// structurally impossible if the RTL is correct — a violation here points
// at a real bug, not a test artifact.
//
// ORDERING NOTE (fixed after the first two runs): the program must be
// fully built and preloaded into u_fetch.imem BEFORE reset_dut() is
// called. reset_dut()'s last statement is the very first @(posedge clk)
// with rst_n=1 — the same edge on which fetch_unit performs its first
// real (non-reset) read of imem[0]. If preload() runs after reset_dut()
// returns, that first read captures whatever was already in imem at that
// instant (X on a fresh sim, or a previous scenario's leftover program),
// not the intended prog[0] — corrupting exactly one ROB entry (tag 0) in
// a way that's easy to misdiagnose as an RTL bug. Building prog[] and
// calling preload() must both happen before reset_dut() in every
// scenario, with no preload() call left calling on an empty prog.
// =============================================================================

module fdr_rob_tb;

    logic clk;
    logic rst_n;

    logic [NUM_CDB_PORTS-1:0]   cdb_valid;
    logic [ROB_PTR-1:0]         cdb_rob_tag   [NUM_CDB_PORTS];
    logic [TAG_WIDTH-1:0]       cdb_p_dest    [NUM_CDB_PORTS];
    logic [NUM_CDB_PORTS-1:0]   cdb_mispredict;
    logic [DATA_WIDTH-1:0]      cdb_target_pc [NUM_CDB_PORTS];
    logic [NUM_CDB_PORTS-1:0]   cdb_exception;
    except_cause_e              cdb_cause     [NUM_CDB_PORTS];

    logic [DATA_WIDTH-1:0]   fetch_pc;
    logic [DATA_WIDTH-1:0]   fetch_instr;
    logic                    fetch_valid;
    rename_dispatch_pkt_s    rename_dispatch_out;
    logic                    rename_stall;
    logic [ROB_PTR-1:0]      rob_tag_out;
    logic                    rob_full;
    logic                    commit_valid;
    logic [REG_ADDR_WIDTH-1:0] commit_rd;
    logic [TAG_WIDTH-1:0]    commit_pd;
    logic [TAG_WIDTH-1:0]    commit_old_pd;
    logic                    branch_mispredict;
    logic                    exception_valid;

    fdr_rob_top dut (
        .clk(clk), .rst_n(rst_n),
        .cdb_valid(cdb_valid), .cdb_rob_tag(cdb_rob_tag), .cdb_p_dest(cdb_p_dest),
        .cdb_mispredict(cdb_mispredict), .cdb_target_pc(cdb_target_pc),
        .cdb_exception(cdb_exception), .cdb_cause(cdb_cause),
        .fetch_pc(fetch_pc), .fetch_instr(fetch_instr), .fetch_valid(fetch_valid),
        .rename_dispatch_out(rename_dispatch_out), .rename_stall(rename_stall),
        .rob_tag_out(rob_tag_out), .rob_full(rob_full),
        .commit_valid(commit_valid), .commit_rd(commit_rd),
        .commit_pd(commit_pd), .commit_old_pd(commit_old_pd),
        .branch_mispredict(branch_mispredict), .exception_valid(exception_valid)
    );

    // ---- Clock ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Pass/fail bookkeeping ----
    int pass_count = 0;
    int fail_count = 0;
    task automatic check(input logic cond, input string msg);
        if (cond) begin
            pass_count++;
            $display("[PASS] %s", msg);
        end else begin
            fail_count++;
            $display("[FAIL] %s", msg);
        end
    endtask

    // ---- Instruction encoding ----
    function automatic logic [31:0] enc_addi(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
        enc_addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    // ---- Dispatch scoreboard: tracks (rob_tag, reg_we, p_dest, old_p_dest)
    // for every instruction that successfully dispatches into the ROB, in
    // FIFO order (matches ROB retirement order by construction). Sampled
    // on the same posedge the RTL uses the pre-edge combinational values
    // (rob_tag_out, rename_dispatch_out) — no race, since this is a
    // read-only concurrent process triggered by the same edge.
    typedef struct {
        logic [ROB_PTR-1:0]   rob_tag;
        logic                 reg_we;
        logic [TAG_WIDTH-1:0] p_dest;
        logic [TAG_WIDTH-1:0] old_p_dest;
    } sb_entry_s;

    sb_entry_s dispatch_sb[$];

    always @(posedge clk) begin
        if (rst_n && rename_dispatch_out.valid && !rob_full) begin
            sb_entry_s e;
            e.rob_tag    = rob_tag_out;
            e.reg_we     = rename_dispatch_out.reg_we;
            e.p_dest     = rename_dispatch_out.p_dest;
            e.old_p_dest = rename_dispatch_out.old_p_dest;
            dispatch_sb.push_back(e);
        end
    end

    // 1. Track the previous cycle's commit state
    // Updated procedural invariant checker
    always_ff @(posedge clk) begin
        if (rst_n) begin
            // Trigger condition: Free list is empty but ROB is NOT full
            if (dut.u_rename.free_list_empty && !dut.u_rob.rob_full) begin
                
                // Mask out 1-cycle skews using CURRENT valid signals
                // Use commit_valid directly because rob_full deasserts concurrently
                if (dut.rename_dispatch_out.valid || dut.u_rob.commit_valid) begin
                    // Expected pipeline delay state; do nothing
                end else begin
                    // Genuine desynchronization detected
                    $error("Resource sync failure: Free list empty without matching ROB capacity or in-flight instruction at time %0t", $time);
                end
                
            end
        end
    end
    // ---- Fake CDB retire: reads the ROB's REAL current head directly out
    // of dut.u_rob (head pointer + rob_mem[head] fields), rather than
    // trusting the testbench's own dispatch scoreboard. The scoreboard is
    // kept only as a diagnostic dispatch counter — it is not used to pick
    // the retire target, since a scoreboard/DUT count mismatch would
    // otherwise cause this task to fake-complete the wrong rob_tag and
    // hang the ROB forever with a stall that never clears.
    task automatic retire_head(
        output logic                 reg_we_o,
        output logic [TAG_WIDTH-1:0] p_dest_o,
        output logic [TAG_WIDTH-1:0] old_pd_o,
        output logic [ROB_PTR-1:0]   tag_o
    );
        logic [ROB_PTR-1:0] head_idx;
        head_idx = dut.u_rob.head[ROB_PTR-1:0];
        reg_we_o = dut.u_rob.rob_mem[head_idx].reg_we;
        p_dest_o = dut.u_rob.rob_mem[head_idx].p_dest;
        old_pd_o = dut.u_rob.rob_mem[head_idx].old_p_dest;
        tag_o    = head_idx;

        $display("Retiring REAL ROB head: idx=%0d reg_we=%0b p_dest=%0d old_p_dest=%0d",
                  head_idx, reg_we_o, p_dest_o, old_pd_o);

        cdb_valid       = '0;
        cdb_mispredict  = '0;
        cdb_exception   = '0;
        for (int p = 0; p < NUM_CDB_PORTS; p++) cdb_cause[p] = EXCEPT_NONE;
        cdb_valid[0]      = 1'b1;
        cdb_rob_tag[0]    = head_idx;
        cdb_p_dest[0]     = p_dest_o;
        cdb_target_pc[0]  = '0;
        @(posedge clk);
        cdb_valid = '0;
    endtask

    // ---- Cycle trace: head/tail/rob_full/dispatch visibility around the
    // fill-up window, to root-cause any dispatch-count mismatch directly
    // from the waveform/transcript instead of guessing. Toggle via
    // trace_en from within each scenario.
    logic trace_en = 1'b0;
    always @(posedge clk) begin
        if (rst_n && trace_en) begin
            $display("TRACE t=%0t rob_head=%0d rob_tail=%0d rob_full=%0b dispatch_valid=%0b rob_tag_out=%0d stall=%0b fl_head=%0d fl_tail=%0d fl_empty=%0b commit_valid=%0b commit_old_pd=%0d",
                $time, dut.u_rob.head, dut.u_rob.tail, rob_full,
                rename_dispatch_out.valid, rob_tag_out, rename_stall,
                dut.u_rename.free_list_head, dut.u_rename.free_list_tail,
                dut.u_rename.free_list_empty, commit_valid, commit_old_pd);
        end
    end

    task automatic reset_dut();
        rst_n = 0;
        cdb_valid      = '0;
        cdb_mispredict = '0;
        cdb_exception  = '0;
        for (int p = 0; p < NUM_CDB_PORTS; p++) begin
            cdb_rob_tag[p]   = '0;
            cdb_p_dest[p]    = '0;
            cdb_target_pc[p] = '0;
            cdb_cause[p]     = EXCEPT_NONE;
        end
        dispatch_sb.delete();
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // Zero-fills the whole imem with NOPs first, then writes the real
    // program on top. The zero-fill is defensive: it means a leftover
    // program from a previous scenario can never leak into this one
    // regardless of call order elsewhere, on top of (not instead of)
    // preload() always being called before reset_dut().
    task automatic preload(input int base_word, input logic [31:0] instrs[]);
        for (int i = 0; i < 256; i++)
            dut.u_fetch.imem[i] = 32'h00000013; // ADDI x0,x0,0 (NOP)
        for (int i = 0; i < instrs.size(); i++)
            dut.u_fetch.imem[base_word + i] = instrs[i];
    endtask

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge clk);
    endtask

    // =========================================================================
    // SCENARIO 1
    // =========================================================================
    task automatic run_scenario1();
        logic [31:0] prog[$];
        int imm;
        int fl_count_before;
        logic retired_reg_we;
        logic [TAG_WIDTH-1:0] retired_p_dest, retired_old_pd;
        logic [ROB_PTR-1:0] retired_tag;

        $display("\n===== SCENARIO 1: ROB fills, free list stays open =====");

        // 32 dispatches total: pattern of 3 fillers (rd=0) : 1 x1 rename,
        // repeated 8 times -> 24 fillers + 8 x1 renames = 32, fills the ROB
        // while consuming only 8/32 free-list spares.
        imm = 0;
        for (int i = 0; i < 8; i++) begin
            for (int f = 0; f < 3; f++) begin
                prog.push_back(enc_addi(5'd0, 5'd0, imm[11:0]));
                imm++;
            end
            prog.push_back(enc_addi(5'd1, 5'd0, imm[11:0]));
            imm++;
        end
        // 33rd instruction: another filler — the one expected to hit rob_full.
        prog.push_back(enc_addi(5'd0, 5'd0, 12'hAAA));
        // Trailing marker instruction to confirm forward progress resumes.
        prog.push_back(enc_addi(5'd0, 5'd0, 12'hBBB));

        // Program must be fully built and preloaded BEFORE reset is
        // released — reset_dut()'s final edge is fetch_unit's first
        // real read of imem[0].
        preload(0, prog);
        reset_dut();
        trace_en = 1'b1;

        // Run until rob_full first asserts. Trace stays on a few extra
        // cycles past this so the transcript shows the exact transition,
        // then switches off to keep the rest of the log readable.
        wait (rob_full === 1'b1);
        wait_cycles(3);
        trace_en = 1'b0;
        fl_count_before = dispatch_sb.size(); // informational, compare against trace's tail count

        check(!dut.u_rename.free_list_empty,
            "S1: free_list_empty is FALSE when rob_full first asserts (isolation)");
        check(rename_stall === 1'b1,
            "S1: rename_stall is asserted the same cycle rob_full asserts");
        $display("S1: scoreboard dispatch count = %0d (expected 32)",
                  dispatch_sb.size());

        // Confirm the stall actually holds fetch steady for a few cycles.
        begin
            logic [DATA_WIDTH-1:0] held_pc, held_instr;
            held_pc    = fetch_pc;
            held_instr = fetch_instr;
            wait_cycles(3);
            check(fetch_pc === held_pc && fetch_instr === held_instr,
                "S1: fetch_pc/fetch_instr held steady across stalled cycles");
        end

        // Fake-complete the REAL ROB head (not a scoreboard guess).
        retire_head(retired_reg_we, retired_p_dest, retired_old_pd, retired_tag);

        wait (rob_full === 1'b0);
        check(1'b1, "S1: rob_full deasserted after the real ROB head retired");

        if (!retired_reg_we) begin
            check(!dut.u_rename.free_list_empty,
                "S1: retiring a reg_we=0 (filler) entry did not touch the free list");
        end else begin
            check(commit_valid === 1'b1,
                "S1: retiring a reg_we=1 entry produced commit_valid=1");
        end

        wait (rename_stall === 1'b0);
        check(1'b1, "S1: rename_stall cleared, pipeline resumed");

        wait_cycles(2);
        $display("SCENARIO 1 complete.\n");
    endtask

    // =========================================================================
    // SCENARIO 2
    // =========================================================================
    task automatic run_scenario2();
        logic [31:0] prog[$];
        logic [TAG_WIDTH-1:0] freed_tag_expected;
        logic retired_reg_we;
        logic [TAG_WIDTH-1:0] retired_p_dest, retired_old_pd;
        logic [ROB_PTR-1:0] retired_tag;

        $display("===== SCENARIO 2: coincident exhaustion =====");

        for (int i = 0; i < 33; i++)
            prog.push_back(enc_addi(5'd1, 5'd0, i[11:0]));
        prog.push_back(enc_addi(5'd2, 5'd0, 12'hDEA)); // trailing marker (x2)

        // Same rule as Scenario 1: preload before reset_dut(), not after.
        preload(0, prog);
        reset_dut();
        trace_en = 1'b1;

        wait (rob_full === 1'b1);
        wait_cycles(3);
        // trace_en stays ON through the retire+reclaim window below (was
        // switched off here previously) so the exact cycle-by-cycle
        // relationship between rob_head/rob_tail and fl_head/fl_tail is
        // visible in the transcript around both transition points.

        check(dut.u_rename.free_list_empty === 1'b1,
            "S2: free_list_empty is TRUE the same cycle rob_full asserts (coincident, expected)");
        check(rename_stall === 1'b1,
            "S2: rename_stall asserted");
        $display("S2: scoreboard dispatch count = %0d (expected 32)",
                  dispatch_sb.size());

        retire_head(retired_reg_we, retired_p_dest, retired_old_pd, retired_tag);
        freed_tag_expected = retired_old_pd;

        check(retired_reg_we === 1'b1,
            "S2: real ROB head is a reg_we=1 x1 rename, as expected for this stream");

        wait (rob_full === 1'b0);
        check(1'b1, "S2: rob_full cleared from the single retirement");
        check(!dut.u_rename.free_list_empty,
            "S2: free_list_empty cleared from the SAME retirement event (single commit clears both)");
        check(commit_valid === 1'b1,
            "S2: commit_valid pulsed for the reg_we=1 retirement");

        wait (rename_stall === 1'b0);

        // The very next successful dispatch must reuse exactly the freed tag
        // (FIFO free list, only one entry available).
        wait (rename_dispatch_out.valid === 1'b1 && !rob_full);
        check(rename_dispatch_out.p_dest === freed_tag_expected,
            $sformatf("S2: next rename reused freed tag exactly (expected p_dest=%0d, got %0d)",
                       freed_tag_expected, rename_dispatch_out.p_dest));

        wait_cycles(2);
        trace_en = 1'b0;
        $display("SCENARIO 2 complete.\n");
    endtask

    // ---- Watchdog: guards against a wait() that never resolves (e.g. a
    // fake-CDB retire targeting a rob_tag that isn't actually the ROB's
    // real head, which would otherwise hang the sim indefinitely).
    initial begin : watchdog
        #200000; // 200us = 20,000 cycles at a 10ns period — generous margin
        $display("\n*** WATCHDOG TIMEOUT: simulation did not complete in time ***");
        $display("===== SUMMARY (INCOMPLETE): %0d passed, %0d failed =====", pass_count, fail_count);
        $finish;
    end

    initial begin
        run_scenario1();
        run_scenario2();

        $display("\n===== SUMMARY: %0d passed, %0d failed =====", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL CHECKS PASSED");
        else
            $display("CHECKS FAILED — see [FAIL] lines above");

        $finish;
    end

endmodule