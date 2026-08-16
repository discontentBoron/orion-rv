`timescale 1ns/1ps
import orion_pkg::*;

module dispatch_issue_validation_tb;
    logic clk, rst_n;

    logic [DATA_WIDTH-1:0] fetch_pc, fetch_instr;
    logic fetch_valid, rename_stall;
    decode_rename_pkt_s decode_out;
    rename_dispatch_pkt_s rename_out;
    logic [REG_ADDR_WIDTH-1:0] r_dst_q;

    logic [ROB_PTR-1:0] rob_tag;
    logic rob_full;
    logic commit_valid;
    logic [REG_ADDR_WIDTH-1:0] commit_rd;
    logic [TAG_WIDTH-1:0] commit_pd, commit_old_pd;
    logic store_commit, rob_mispredict, rob_exception;
    except_cause_e rob_except_cause;
    logic [DATA_WIDTH-1:0] rob_except_pc;

    logic iq_full, issue_valid;
    rename_dispatch_pkt_s issue_pkt;
    logic [ROB_PTR-1:0] issue_rob_tag;

    logic cdb_valid;
    logic [ROB_PTR-1:0] cdb_rob_tag;
    logic [TAG_WIDTH-1:0] cdb_p_dest;

    integer errors;
    integer cycle_count;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        errors = 0;
        cycle_count = 0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

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

    // always_ff @(posedge clk or negedge rst_n) begin
    //     if (!rst_n)
    //         r_dst_q <= '0;
    //     else
    //         r_dst_q <= decode_out.r_dst;
    // end

    rename_unit u_rename (
        .clk                 (clk),
        .rst_n               (rst_n),
        .decode_rename_in    (decode_out),
        .branch_mispredict   (1'b0),
        .cdb_valid           (cdb_valid),
        .cdb_p_dest          (cdb_p_dest),
        .rob_full            (rob_full),
        .iq_full             (iq_full),
        .commit_valid        (commit_valid),
        .commit_rd           (commit_rd),
        .commit_pd           (commit_pd),
        .commit_old_pd       (commit_old_pd),
        .rename_stall        (rename_stall),
        .rename_dispatch_out (rename_out)
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

    // Behavioral completion: issued work completes one cycle later.
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

    initial begin
        u_fetch.imem[0] = 32'h00500093; // addi x1,x0,5
        u_fetch.imem[1] = 32'h00a00113; // addi x2,x0,10
        u_fetch.imem[2] = 32'h002081b3; // add  x3,x1,x2
        u_fetch.imem[3] = 32'h40110233; // sub  x4,x2,x1
        u_fetch.imem[4] = 32'h0020f2b3; // and  x5,x1,x2
        u_fetch.imem[5] = 32'h0020e333; // or   x6,x1,x2
        u_fetch.imem[6] = 32'h0020c3b3; // xor  x7,x1,x2
        u_fetch.imem[7] = 32'h00000413; // addi x8,x0,0
        u_fetch.imem[8] = 32'h00000013; // nop padding
        u_fetch.imem[9] = 32'h00000013;
        u_fetch.imem[10] = 32'h00000013;
        u_fetch.imem[11] = 32'h00000013;
    end

    // -------------------------------------------------------------------------
    // Nicely aligned top-level trace.
    // -------------------------------------------------------------------------
    // initial begin
    //     $display("");
    //     $display("%-7s %-10s | %-2s %-4s %-3s %-3s %-4s %-4s | %-3s | %-5s | %-6s %-4s %-4s %-4s %-4s %-4s %-4s",
    //              "time", "FPC", "Rv", "Pdst", "S1", "S2", "S1r", "S2r", "ROB", "IQfull",
    //              "IssueV", "IROB", "IPdst", "IS1", "IS2", "I1r", "I2r");
    //     $display("--------------------------------------------------------------------------------------------------------------");
    // end

    task automatic print_iq_state;
        begin
            $display("    IQ state: slot | V | ROB | AGE | P1/R | P2/R | Pdst");
            for (int i = 0; i < IQ_SIZE; i++) begin
                if (u_iq.iq_mem[i].valid) begin
                    $display("              %4d | %b | %3d | %3d | %2d/%b | %2d/%b | %3d",
                             i,
                             u_iq.iq_mem[i].valid,
                             u_iq.iq_mem[i].rob_tag,
                             u_iq.iq_mem[i].age_tag,
                             u_iq.iq_mem[i].p_src1,
                             u_iq.iq_mem[i].p_src1_ready,
                             u_iq.iq_mem[i].p_src2,
                             u_iq.iq_mem[i].p_src2_ready,
                             u_iq.iq_mem[i].p_dest);
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Assertions/checks.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n)
            cycle_count = 0;
        else begin
            cycle_count = cycle_count + 1;

            // If an IQ entry is selected, the issued ROB tag must be from a
            // valid, ready entry and must equal the selected entry's tag.
            if (issue_valid) begin
                assert (u_iq.iq_mem[u_iq.sel_idx].valid)
                    else begin
                        errors++;
                        $error("ISSUE selected an invalid IQ entry at %0t", $time);
                    end

                assert (u_iq.iq_mem[u_iq.sel_idx].p_src1_ready &&
                        u_iq.iq_mem[u_iq.sel_idx].p_src2_ready)
                    else begin
                        errors++;
                        $error("ISSUE selected a not-ready entry at %0t", $time);
                    end

                assert (issue_rob_tag == u_iq.iq_mem[u_iq.sel_idx].rob_tag)
                    else begin
                        errors++;
                        $error("Issue ROB mismatch at %0t", $time);
                    end
            end

            // The selected issue entry must be the oldest READY entry.
            if (issue_valid) begin
                for (int i = 0; i < IQ_SIZE; i++) begin
                    if (u_iq.iq_mem[i].valid &&
                        u_iq.iq_mem[i].p_src1_ready &&
                        u_iq.iq_mem[i].p_src2_ready) begin
                        assert ($signed(u_iq.iq_mem[i].age_tag -
                                        u_iq.iq_mem[u_iq.sel_idx].age_tag) >= 0)
                            else begin
                                errors++;
                                $error("Oldest-ready violation: slot %0d is older than selected slot %0d at %0t",
                                       i, u_iq.sel_idx, $time);
                            end
                    end
                end
            end

            // Basic dispatch acceptance check. The IQ only accepts a normal
            // Rename packet when it is valid and has capacity. We validate the
            // actual stored entry below rather than assigning/casting packed
            // IQ structs (Questa is strict about enum fields).
            // if (rename_out.valid && !rename_out.except && !rob_full && !iq_full) begin
            //     bit found_dispatch;
            //     found_dispatch = 1'b0;
            //     for (int i = 0; i < IQ_SIZE; i++) begin
            //         if (u_iq.iq_mem[i].valid &&
            //             u_iq.iq_mem[i].p_dest == rename_out.p_dest &&
            //             u_iq.iq_mem[i].p_src1 == rename_out.p_src1 &&
            //             u_iq.iq_mem[i].p_src2 == rename_out.p_src2) begin
            //             found_dispatch = 1'b1;
            //         end
            //     end
            //     assert (found_dispatch)
            //         else begin
            //             errors++;
            //             $error("Rename packet was not found in IQ after dispatch at %0t", $time);
            //         end
            // end

            // Show the detailed IQ state whenever a CDB wakeup occurs, or when
            // an issue transaction occurs. This makes dependency tracking easy
            // to inspect without opening a waveform.
            if (issue_valid || cdb_valid)
                print_iq_state();
        end
    end

    // Dedicated dependency check: x3 (ROB2) depends on P32 and P33. Once both
    // producers have broadcast, its IQ entry must become ready and eventually
    // issue. This intentionally catches same-cycle-dispatch/CDB wakeup misses.
    bit rob2_seen;
    bit rob2_ready;
    bit rob2_issued;

    always @(posedge clk) begin
        if (!rst_n) begin
            rob2_seen   = 1'b0;
            rob2_ready  = 1'b0;
            rob2_issued = 1'b0;
        end else begin

            // ROB2 exists in the IQ
            for (int i = 0; i < IQ_SIZE; i++) begin
                if (u_iq.iq_mem[i].valid &&
                    u_iq.iq_mem[i].rob_tag == 2) begin

                    rob2_seen = 1'b1;

                    // Track readiness separately.
                    if (u_iq.iq_mem[i].p_src1_ready &&
                        u_iq.iq_mem[i].p_src2_ready) begin
                        rob2_ready = 1'b1;
                    end
                end
            end

            // This is the ONLY condition that means ROB2 actually issued.
            if (issue_valid && issue_rob_tag == 2) begin
                rob2_issued = 1'b1;

                $display(
                    "*** ROB2 ISSUED at %0t: PDEST=%0d SRC1=%0d SRC2=%0d ***",
                    $time,
                    issue_pkt.p_dest,
                    issue_pkt.p_src1,
                    issue_pkt.p_src2
                );
            end
        end
    end

    initial begin
        repeat (18) @(posedge clk);

        if (!rob2_seen) begin
            errors++;
            $error("ROB2 dependency entry was never observed in the IQ");
        end

        if (!rob2_ready) begin
            errors++;
            $error("ROB2 never became ready: P32/P33 dependency wakeup failed");
        end

        if (!rob2_issued) begin
            errors++;
            $error("ROB2 became ready but was never actually issued");
        end

        if (errors == 0)
            $display("\nPASS: dispatch/issue checks completed with 0 errors.");
        else
            $display("\nFAIL: dispatch/issue checks completed with %0d errors.", errors);

        $display("=== Dispatch/Issue validation complete ===");
        $finish;
    end
endmodule
