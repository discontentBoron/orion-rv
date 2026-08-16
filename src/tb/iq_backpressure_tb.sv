// =============================================================================
// iq_backpressure_recovery_tb.sv — Orion OOO RISC-V Processor
// Focused test: IQ full -> Rename holds packet -> IQ frees -> joint recovery
//
// This test validates both directions of the Rename/ROB/IQ backpressure path:
//   1. IQ becomes full.
//   2. Rename/Fetch stall.
//   3. The EXACT registered Rename packet is held unchanged.
//   4. No new ROB allocation occurs while IQ remains full.
//   5. A controlled CDB unlock frees IQ entries.
//   6. The held Rename packet is accepted by BOTH ROB and IQ.
//   7. Fetch resumes after the held packet is released.
//
// Important sampling rule:
//   ROB/IQ allocate with nonblocking assignments.  Therefore, the joint ROB/IQ
//   membership check is performed one delta/cycle after the acceptance edge.
// =============================================================================

`timescale 1ns/1ps
import orion_pkg::*;

module iq_backpressure_tb;

    logic clk;
    logic rst_n;

    // -------------------------------------------------------------------------
    // Fetch / Decode
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] fetch_pc, fetch_instr;
    logic                  fetch_valid;
    decode_rename_pkt_s     decode_out;

    // -------------------------------------------------------------------------
    // Rename
    // -------------------------------------------------------------------------
    logic                   rename_stall;
    rename_dispatch_pkt_s   rename_out;

    // -------------------------------------------------------------------------
    // ROB
    // -------------------------------------------------------------------------
    logic [ROB_PTR-1:0]     rob_tag;
    logic                   rob_full;
    logic                   commit_valid;
    logic [REG_ADDR_WIDTH-1:0] commit_rd;
    logic [TAG_WIDTH-1:0]   commit_pd, commit_old_pd;
    logic                   store_commit;
    logic                   rob_mispredict;
    logic                   rob_exception;
    except_cause_e          rob_except_cause;
    logic [DATA_WIDTH-1:0]  rob_except_pc;

    // -------------------------------------------------------------------------
    // Issue Queue
    // -------------------------------------------------------------------------
    logic                   iq_full;
    logic                   issue_valid;
    rename_dispatch_pkt_s   issue_pkt;
    logic [ROB_PTR-1:0]     issue_rob_tag;

    // -------------------------------------------------------------------------
    // Controlled CDB unlock
    // -------------------------------------------------------------------------
    logic                   cdb_valid;
    logic [ROB_PTR-1:0]     cdb_rob_tag;
    logic [TAG_WIDTH-1:0]   cdb_p_dest;
    logic                   unlock_active;

    // -------------------------------------------------------------------------
    // Test state
    // -------------------------------------------------------------------------
    integer errors = 0;
    // integer stall_cycles = 0;

    logic                   saw_iq_full;
    logic                   saw_rename_stall;
    logic                   saw_fetch_stall;
    logic                   saw_iq_full_clear;
    logic                   saw_fetch_resume;

    logic                   iq_full_q;

    // Backpressure snapshot: this MUST be the registered Rename packet,
    // not fetch_pc.  Fetch is ahead of Rename by the pipeline latency.
    logic                   held_valid;
    logic [DATA_WIDTH-1:0]  held_pc;
    logic [TAG_WIDTH-1:0]   held_pdest;
    logic [TAG_WIDTH-1:0]   held_psrc1;
    logic [TAG_WIDTH-1:0]   held_psrc2;
    logic                   held_psrc1_valid;
    logic                   held_psrc2_valid;
    logic [ROB_PTR-1:0]     resumed_rob_tag;

    logic [ROB_PTR:0]       rob_tail_at_iq_full;
    logic                   captured_iq_full_state;

    logic                   recovery_accept_seen;
    logic                   joint_alloc_checked;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------------
    fetch_unit #(.IMEM_DEPTH(256)) u_fetch (
        .clk            (clk),
        .rst_n          (rst_n),
        .stall          (rename_stall),
        .redirect_valid (1'b0),
        .redirect_pc    ('0),
        .fetch_pc       (fetch_pc),
        .fetch_instr    (fetch_instr),
        .fetch_valid    (fetch_valid)
    );

    decode_unit u_decode (
        .fetch_pc    (fetch_pc),
        .fetch_instr (fetch_instr),
        .fetch_valid (fetch_valid),
        .decode_out  (decode_out)
    );

    // NOTE: r_dst must NOT be tracked with an independent, stall-unaware
    // 1-cycle delay of decode_out.r_dst -- during an IQ/ROB-full hold,
    // rename_dispatch_out stays pinned to the held packet for multiple
    // cycles while decode_out keeps combinationally reflecting whatever
    // instruction is currently latched at Fetch. An out-of-band r_dst_q
    // register that samples decode_out.r_dst every cycle desyncs from the
    // held rename_dispatch_out on the release cycle, handing ROB the WRONG
    // r_dst for the packet it dispatches that cycle. r_dst is now captured
    // and held inside rename_unit itself, under the exact same conditions
    // as the rest of the registered rename transaction.

    rename_unit u_rename (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .decode_rename_in      (decode_out),
        .branch_mispredict     (1'b0),
        .cdb_valid             (cdb_valid),
        .cdb_p_dest            (cdb_p_dest),
        .rob_full              (rob_full),
        .iq_full               (iq_full),
        .commit_valid          (commit_valid),
        .commit_rd             (commit_rd),
        .commit_pd             (commit_pd),
        .commit_old_pd         (commit_old_pd),
        .rename_stall          (rename_stall),
        .rename_dispatch_out   (rename_out)
    );

    reorder_buffer u_rob (
        .clk               (clk),
        .rst_n             (rst_n),
        // .dispatch_r_dst    (rename_out_r_dst),
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
        .iq_full           (iq_full),
        .rob_full          (rob_full),
        .cdb_valid         (cdb_valid),
        .cdb_p_dest        (cdb_p_dest),
        .branch_mispredict (rob_mispredict),
        .exception_valid   (rob_exception),
        .issue_valid       (issue_valid),
        .issue_pkt         (issue_pkt),
        .issue_rob_tag     (issue_rob_tag)
    );

    // -------------------------------------------------------------------------
    // CDB unlock sequence
    // -------------------------------------------------------------------------
    // Start with CDB disabled so dependent instructions fill the IQ and create
    // the stall.  Once that state is captured, broadcast P32/P33 to wake them.
    initial begin
        cdb_valid    = 1'b0;
        cdb_rob_tag  = '0;
        cdb_p_dest   = '0;
        unlock_active = 1'b0;

        wait (captured_iq_full_state);
        repeat (4) @(posedge clk);
        unlock_active = 1'b1;

        // Hold each broadcast stable around the next active clock edge.
        @(negedge clk);
        cdb_valid   = 1'b1;
        cdb_rob_tag = ROB_PTR'(0);
        cdb_p_dest  = TAG_WIDTH'(32);  // P32 completes.

        @(negedge clk);
        cdb_rob_tag = ROB_PTR'(1);
        cdb_p_dest  = TAG_WIDTH'(33);  // P33 completes.

        @(negedge clk);
        cdb_valid   = 1'b0;
        cdb_rob_tag = '0;
        cdb_p_dest  = '0;
    end

    // -------------------------------------------------------------------------
    // Program
    // -------------------------------------------------------------------------
    function automatic [31:0] enc_add(
        input int rd, input int rs1, input int rs2
    );
        enc_add = {
            7'b0000000, rs2[4:0], rs1[4:0], 3'b000,
            rd[4:0], 7'b0110011
        };
    endfunction

    function automatic [31:0] enc_addi(
        input int rd, input int rs1, input int imm
    );
        enc_addi = {
            imm[11:0], rs1[4:0], 3'b000,
            rd[4:0], 7'b0010011
        };
    endfunction

    initial begin
        // Two producers that initially issue but have no CDB completion.
        u_fetch.imem[0] = enc_addi(1, 0, 1); // x1 -> P32
        u_fetch.imem[1] = enc_addi(2, 0, 2); // x2 -> P33

        // Dependent instructions fill the IQ.  With CDB disabled, these
        // entries remain waiting on P32/P33.
        for (int i = 0; i < 16; i++) begin
            int rd;
            rd = 3 + i;
            if (rd > 31)
                rd = 3 + (i % 8);
            u_fetch.imem[2+i] = enc_add(rd, 1, 2);
        end

        // Instruction after the blocked Rename packet, used only to confirm
        // Fetch actually resumes and advances after recovery.
        u_fetch.imem[18] = enc_addi(9, 0, 9);
        u_fetch.imem[19] = enc_addi(10, 0, 10); // x10 should get P51
        u_fetch.imem[20] = enc_addi(11, 0, 11); // x11 should get P52
        u_fetch.imem[21] = enc_addi(12, 0, 12); // x12 should get P53
        u_fetch.imem[22] = 32'h00000013; // NOP
    end

    // -------------------------------------------------------------------------
    // Human-readable trace
    // -------------------------------------------------------------------------
    initial begin
        $display("time  FPC       | Rv RenamePC  Pdst | ROB | IQfull Stall | Issue IROB");
        $display("-----------------------------------------------------------------------");
    end
    initial begin
        saw_iq_full = 0;
        saw_rename_stall = 0;
        saw_fetch_stall = 0;
        saw_iq_full_clear = 0;
        saw_fetch_resume = 0;
        held_valid = 0;
        recovery_accept_seen = 0;
        joint_alloc_checked = 0;
        captured_iq_full_state = 0;
        errors = 0;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            $display(
                "%4t  %08h | %b  %08h  %2d | %2d |   %b      %b  |   %b     %2d",
                $time,
                fetch_pc,
                rename_out.valid,
                rename_out.pc,
                rename_out.p_dest,
                rob_tag,
                iq_full,
                rename_stall,
                issue_valid,
                issue_rob_tag
            );

            if (iq_full)
                saw_iq_full = 1'b1;

            if (rename_stall)
                saw_rename_stall = 1'b1;

            if (iq_full && rename_stall)
                saw_fetch_stall = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Capture IQ-full point and freeze ROB allocation check.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            rob_tail_at_iq_full    = '0;
            captured_iq_full_state = 1'b0;
        end else begin
            if (iq_full && !captured_iq_full_state) begin
                rob_tail_at_iq_full    = u_rob.tail;
                captured_iq_full_state = 1'b1;

                $display(
                    "*** IQ FULL at %0t: Fetch PC=0x%08h, held Rename PC=0x%08h, ROB tail=%0d ***",
                    $time, fetch_pc, rename_out.pc, u_rob.tail
                );
            end

            if (captured_iq_full_state && iq_full && !saw_iq_full_clear) begin
                assert (u_rob.tail == rob_tail_at_iq_full)
                    else begin
                        errors++;
                        $error(
                            "ROB tail advanced while IQ was full at %0t: was %0d, now %0d",
                            $time, rob_tail_at_iq_full, u_rob.tail
                        );
                    end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Capture the EXACT Rename packet being held by backpressure.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && !held_valid && rename_out.valid && rename_stall) begin
            held_valid       = 1'b1;
            held_pc          = rename_out.pc;
            held_pdest       = rename_out.p_dest;
            held_psrc1       = rename_out.p_src1;
            held_psrc2       = rename_out.p_src2;
            held_psrc1_valid = rename_out.p_src1_valid;
            held_psrc2_valid = rename_out.p_src2_valid;

            $display(
                "*** HOLD CAPTURE at %0t: PC=0x%08h PDEST=%0d S1=%0d S2=%0d ***",
                $time, held_pc, held_pdest, held_psrc1, held_psrc2
            );
        end else if (rst_n && held_valid && !recovery_accept_seen && rename_stall) begin
            assert (rename_out.pc == held_pc)
                else begin
                    errors++;
                    $error("Held Rename PC changed during stall at %0t", $time);
                end
            assert (rename_out.p_dest == held_pdest)
                else begin
                    errors++;
                    $error("Held Rename PDEST changed during stall at %0t", $time);
                end
            assert (rename_out.p_src1 == held_psrc1)
                else begin
                    errors++;
                    $error("Held Rename PSRC1 changed during stall at %0t", $time);
                end
            assert(rename_out.p_src2_valid == held_psrc2_valid)
                else begin
                    errors++;
                    $error("Held Rename PSRC2_VALID changed during stall");
                end

            if (held_psrc2_valid) begin
                assert(rename_out.p_src2 === held_psrc2)
                    else begin
                        errors++;
                        $error("Held Rename PSRC2 changed during stall");
                    end
            end
                    end
                end

    // -------------------------------------------------------------------------
    // Detect IQ-full falling edge.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            iq_full_q <= 1'b0;
        else
            iq_full_q <= iq_full;
    end

    always @(posedge clk) begin
        if (rst_n && captured_iq_full_state && iq_full_q && !iq_full && !saw_iq_full_clear) begin
            saw_iq_full_clear = 1'b1;
            $display(
                "*** IQ FULL CLEARED at %0t: IQ slot became available ***",
                $time
            );
        end
    end

    // -------------------------------------------------------------------------
    // Detect the acceptance edge of the held Rename packet.
    //
    // At this posedge, rename_out is still the HELD packet (pre-NBA), while
    // !iq_full && !rob_full means both consumers can accept it.  Capture the
    // allocation tag here; inspect the actual ROB/IQ contents one cycle later.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && held_valid && saw_iq_full_clear &&
            !recovery_accept_seen && rename_out.valid &&
            (rename_out.pc == held_pc) &&
            (rename_out.p_dest == held_pdest) &&
            !rob_full && !iq_full) begin

            recovery_accept_seen = 1'b1;
            resumed_rob_tag      = rob_tag;

            $display(
                "*** HELD PACKET ACCEPTED at %0t: PC=0x%08h PDEST=%0d ROB_TAG=%0d ***",
                $time, held_pc, held_pdest, resumed_rob_tag
            );
        end
    end

    // -------------------------------------------------------------------------
    // One-cycle-later joint ROB/IQ allocation check.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        bit in_rob;
        bit in_iq;
        if (rst_n && recovery_accept_seen && !joint_alloc_checked) begin
            #1;
            in_rob = 1'b0;
            in_iq  = 1'b0;

            // ROB entry must contain the exact held Rename packet.
            if (u_rob.rob_mem[resumed_rob_tag].pc == held_pc &&
                u_rob.rob_mem[resumed_rob_tag].p_dest == held_pdest) begin
                in_rob = 1'b1;
            end

            // IQ must contain an entry with the same ROB tag and packet identity.
            for (int i = 0; i < IQ_SIZE; i++) begin
                if (u_iq.iq_mem[i].valid &&
                    u_iq.iq_mem[i].rob_tag == resumed_rob_tag &&
                    u_iq.iq_mem[i].pc == held_pc &&
                    u_iq.iq_mem[i].p_dest == held_pdest) begin
                    in_iq = 1'b1;
                end
            end

            assert (in_rob)
                else begin
                    errors++;
                    $error(
                        "Held packet was not found in ROB after acceptance: PC=0x%08h ROB=%0d",
                        held_pc, resumed_rob_tag
                    );
                end

            assert (in_iq)
                else begin
                    errors++;
                    $error(
                        "Held packet was not found in IQ after acceptance: PC=0x%08h ROB=%0d",
                        held_pc, resumed_rob_tag
                    );
                end

            if (in_rob && in_iq)
                $display(
                    "*** JOINT ACCEPT VERIFIED at %0t: held packet is in BOTH ROB[%0d] and IQ ***",
                    $time, resumed_rob_tag
                );

            joint_alloc_checked = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Detect Fetch resumption using the blocked Rename PC, not fetch_pc at the
    // moment IQ became full.  Fetch is ahead, so the held packet's PC is the
    // correct transaction identity.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && recovery_accept_seen && !saw_fetch_resume) begin
            if (fetch_pc != held_pc) begin
                saw_fetch_resume = 1'b1;
                $display(
                    "*** FETCH RESUMED at %0t: fetch_pc=0x%08h (held packet PC=0x%08h) ***",
                    $time, fetch_pc, held_pc
                );
            end
        end
    end

    // -------------------------------------------------------------------------
    // Final checks
    // -------------------------------------------------------------------------
    initial begin
        repeat (60) @(posedge clk);

        assert (saw_iq_full)
            else begin
                errors++;
                $error("IQ never became full");
            end

        assert (saw_rename_stall)
            else begin
                errors++;
                $error("Rename never asserted stall when IQ was full");
            end

        assert (saw_fetch_stall)
            else begin
                errors++;
                $error("Fetch stall was never observed while IQ was full");
            end

        assert (captured_iq_full_state)
            else begin
                errors++;
                $error("IQ-full state was never captured");
            end

        assert (saw_iq_full_clear)
            else begin
                errors++;
                $error("iq_full never cleared after the CDB unlock sequence");
            end

        assert (held_valid)
            else begin
                errors++;
                $error("No valid Rename packet was captured during backpressure");
            end

        assert (recovery_accept_seen)
            else begin
                errors++;
                $error("Held Rename packet was never accepted after IQ recovered");
            end

        assert (joint_alloc_checked)
            else begin
                errors++;
                $error("Joint ROB/IQ allocation was never checked");
            end

        assert (saw_fetch_resume)
            else begin
                errors++;
                $error("Fetch never resumed after backpressure recovery");
            end

        if (errors == 0)
            $display(
                "\nPASS: IQ backpressure stalls, holds the exact Rename packet, and recovers with joint ROB/IQ acceptance."
            );
        else
            $display(
                "\nFAIL: IQ backpressure recovery test completed with %0d errors.",
                errors
            );

        $finish;
    end

endmodule
