`timescale 1ns/1ps
import orion_pkg::*;

module div_tb;

    logic clk;
    logic rst_n;
    logic flush;

    regread_execute_pkt_s regread_in;
    execute_wb_pkt_s      div_wb_out;
    logic                 div_ready;

    integer errors = 0;
    integer checks = 0;

    div dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (flush),
        .regread_in (regread_in),
        .div_wb_out (div_wb_out),
        .div_ready  (div_ready)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n      = 1'b0;
        flush      = 1'b0;
        regread_in = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------
    // Reset check
    // -------------------------------------------------------------------
    task automatic check_reset;
        checks++;
        if (div_ready !== 1'b1) begin
            errors++;
            $error("[RESET] expected div_ready=1 out of reset, got %b", div_ready);
        end else if (div_wb_out.valid !== 1'b0) begin
            errors++;
            $error("[RESET] expected div_wb_out.valid=0 out of reset, got %b", div_wb_out.valid);
        end else begin
            $display("[%0t] RESET          PASS  div_ready=1, div_wb_out.valid=0", $time);
        end
    endtask

    // -------------------------------------------------------------------
    // Directed, one-at-a-time op test.
    // Drives a single instruction into regread_in, then polls div_wb_out.valid
    // (rather than assuming a fixed latency), since div has both a 0-cycle
    // fast path and a 33-cycle slow path. Returns the number of polling
    // iterations it took (busy_cycles) so callers can assert exact latency
    // where relevant. Optionally checks that div_ready stays low the whole
    // time it is waiting (check_busy_ready).
    // -------------------------------------------------------------------
    task automatic run_op(
        input exec_unit_opcode_e uop,
        input logic [31:0]       src1,
        input logic [31:0]       src2,
        input logic [31:0]       pc_in,
        input logic [TAG_WIDTH-1:0] p_dest,
        input logic [TAG_WIDTH-1:0] old_p_dest,
        input logic [ROB_PTR-1:0]   rob_tag,
        input logic              reg_we,
        input logic              except_in,
        input logic [31:0]       expected_result,
        input logic              check_busy_ready,
        input string             name,
        output int               busy_cycles
    );
        int timeout;

        wait (div_ready === 1'b1);
        @(negedge clk);
        regread_in.valid         = 1'b1;
        regread_in.exec_unit_uop = uop;
        regread_in.func_unit_type= FU_MULDIV;
        regread_in.instr_class   = INSTR_ALU;
        regread_in.src1_data     = src1;
        regread_in.src2_data     = src2;
        regread_in.p_src1_valid  = 1'b1;
        regread_in.p_src2_valid  = 1'b1;
        regread_in.imm_val       = 32'hDEAD_DEAD;  // MULDIV ops never use imm_val
        regread_in.pc            = pc_in;
        regread_in.p_dest        = p_dest;
        regread_in.old_p_dest    = old_p_dest;
        regread_in.rob_tag       = rob_tag;
        regread_in.reg_we        = reg_we;
        regread_in.except        = except_in;
        regread_in.cause         = except_in ? EXCEPT_ILLEGAL_INST : EXCEPT_NONE;

        @(posedge clk);   // accept sampled here (div_ready && valid)
        #1;
        @(negedge clk);
        regread_in.valid = 1'b0;  // present a bubble behind it

        // busy_cycles counts the number of posedges consumed strictly after
        // the accept edge until div_wb_out.valid appears (0 for the fast
        // path, since valid appears on the accept edge itself).
        timeout = 0;
        while (div_wb_out.valid !== 1'b1 && timeout < 40) begin
            @(posedge clk);
            #1;
            timeout++;
            if (check_busy_ready && div_wb_out.valid !== 1'b1 && div_ready !== 1'b0) begin
                errors++;
                $error("[%s] div_ready expected 0 while dividing (cycle %0d), got %b",
                       name, timeout, div_ready);
            end
        end
        busy_cycles = timeout;

        checks++;
        if (timeout >= 40) begin
            errors++;
            $error("[%s] TIMEOUT waiting for div_wb_out.valid", name);
        end else begin
            if (div_wb_out.result !== expected_result) begin
                errors++;
                $error("[%s] result mismatch: expected 0x%08h, got 0x%08h",
                       name, expected_result, div_wb_out.result);
            end
            if (div_wb_out.p_dest !== p_dest) begin
                errors++;
                $error("[%s] p_dest mismatch: expected %0d, got %0d", name, p_dest, div_wb_out.p_dest);
            end
            if (div_wb_out.old_p_dest !== old_p_dest) begin
                errors++;
                $error("[%s] old_p_dest mismatch: expected %0d, got %0d", name, old_p_dest, div_wb_out.old_p_dest);
            end
            if (div_wb_out.rob_tag !== rob_tag) begin
                errors++;
                $error("[%s] rob_tag mismatch: expected %0d, got %0d", name, rob_tag, div_wb_out.rob_tag);
            end
            if (div_wb_out.reg_we !== reg_we) begin
                errors++;
                $error("[%s] reg_we mismatch: expected %b, got %b", name, reg_we, div_wb_out.reg_we);
            end
            if (div_wb_out.pc !== pc_in) begin
                errors++;
                $error("[%s] pc mismatch: expected 0x%08h, got 0x%08h", name, pc_in, div_wb_out.pc);
            end
            if (div_wb_out.except !== except_in) begin
                errors++;
                $error("[%s] except mismatch: expected %b, got %b", name, except_in, div_wb_out.except);
            end
            if (except_in && div_wb_out.except_cause !== EXCEPT_ILLEGAL_INST) begin
                errors++;
                $error("[%s] except_cause mismatch: expected EXCEPT_ILLEGAL_INST, got %0d",
                       name, div_wb_out.except_cause);
            end

            if (errors == 0)
                $display("[%0t] %-18s PASS  result=0x%08h p_dest=%0d rob_tag=%0d busy_cycles=%0d",
                          $time, name, div_wb_out.result, div_wb_out.p_dest, div_wb_out.rob_tag, busy_cycles);
        end

        @(negedge clk);
        regread_in = '0;
    endtask

    // Convenience wrapper for callers that don't care about busy_cycles/ready checks.
    task automatic run_simple(
        input exec_unit_opcode_e uop,
        input logic [31:0]       src1,
        input logic [31:0]       src2,
        input logic [31:0]       pc_in,
        input logic [TAG_WIDTH-1:0] p_dest,
        input logic [TAG_WIDTH-1:0] old_p_dest,
        input logic [ROB_PTR-1:0]   rob_tag,
        input logic              reg_we,
        input logic              except_in,
        input logic [31:0]       expected_result,
        input string             name
    );
        int unused_cycles;
        run_op(uop, src1, src2, pc_in, p_dest, old_p_dest, rob_tag, reg_we, except_in,
               expected_result, 1'b0, name, unused_cycles);
    endtask

    initial begin
        @(posedge rst_n);
        check_reset();
        @(negedge clk);

        // =================================================================
        // 1. Basic signed DIV/REM: all sign combinations, 20 and 6
        //    20/6  = 3  rem 2
        //   -20/6  = -3 rem -2
        //    20/-6 = -3 rem 2
        //   -20/-6 = 3  rem -2
        // =================================================================
        run_simple(DIV, 32'd20,          32'd6,          32'h1000, 6'd10, 6'd1, 5'd1,
                   1'b1, 1'b0, 32'd3,          "DIV_pp");
        run_simple(REM, 32'd20,          32'd6,          32'h1004, 6'd11, 6'd2, 5'd2,
                   1'b1, 1'b0, 32'd2,          "REM_pp");
        run_simple(DIV, 32'hFFFF_FFEC /*-20*/, 32'd6,     32'h1008, 6'd12, 6'd3, 5'd3,
                   1'b1, 1'b0, 32'hFFFF_FFFD /*-3*/, "DIV_np");
        run_simple(REM, 32'hFFFF_FFEC /*-20*/, 32'd6,     32'h100C, 6'd13, 6'd4, 5'd4,
                   1'b1, 1'b0, 32'hFFFF_FFFE /*-2*/, "REM_np");
        run_simple(DIV, 32'd20, 32'hFFFF_FFFA /*-6*/,     32'h1010, 6'd14, 6'd5, 5'd5,
                   1'b1, 1'b0, 32'hFFFF_FFFD /*-3*/, "DIV_pn");
        run_simple(REM, 32'd20, 32'hFFFF_FFFA /*-6*/,     32'h1014, 6'd15, 6'd6, 5'd6,
                   1'b1, 1'b0, 32'd2,          "REM_pn");
        run_simple(DIV, 32'hFFFF_FFEC /*-20*/, 32'hFFFF_FFFA /*-6*/, 32'h1018, 6'd16, 6'd7, 5'd7,
                   1'b1, 1'b0, 32'd3,          "DIV_nn");
        run_simple(REM, 32'hFFFF_FFEC /*-20*/, 32'hFFFF_FFFA /*-6*/, 32'h101C, 6'd17, 6'd8, 5'd8,
                   1'b1, 1'b0, 32'hFFFF_FFFE /*-2*/, "REM_nn");

        // =================================================================
        // 2. "Same bits, four ops" test: src1=0x80000001, src2=5.
        //    Signed:   -2147483647 / 5 = -429496729 rem -2
        //    Unsigned:  2147483649 / 5 =  429496729 rem 4
        // Same input bits, DIV/REM must disagree with DIVU/REMU.
        // =================================================================
        run_simple(DIV,  32'h8000_0001, 32'd5, 32'h2000, 6'd20, 6'd9,  5'd9,
                   1'b1, 1'b0, 32'hE666_6667, "SAMEBITS_DIV");
        run_simple(REM,  32'h8000_0001, 32'd5, 32'h2004, 6'd21, 6'd10, 5'd10,
                   1'b1, 1'b0, 32'hFFFF_FFFE, "SAMEBITS_REM");
        run_simple(DIVU, 32'h8000_0001, 32'd5, 32'h2008, 6'd22, 6'd11, 5'd11,
                   1'b1, 1'b0, 32'h1999_9999, "SAMEBITS_DIVU");
        run_simple(REMU, 32'h8000_0001, 32'd5, 32'h200C, 6'd23, 6'd12, 5'd12,
                   1'b1, 1'b0, 32'd4,          "SAMEBITS_REMU");

        // =================================================================
        // 3. Divide by zero, all four ops
        //    DIV[U] x/0  -> all 1s
        //    REM    x/0  -> dividend (signed passthrough)
        //    REMU   x/0  -> dividend (unsigned passthrough)
        // =================================================================
        run_simple(DIV,  32'd5, 32'd0, 32'h3000, 6'd30, 6'd13, 5'd13,
                   1'b1, 1'b0, 32'hFFFF_FFFF, "DIVZERO_DIV");
        run_simple(DIVU, 32'd5, 32'd0, 32'h3004, 6'd31, 6'd14, 5'd14,
                   1'b1, 1'b0, 32'hFFFF_FFFF, "DIVZERO_DIVU");
        run_simple(REM,  32'd5, 32'd0, 32'h3008, 6'd32, 6'd15, 5'd15,
                   1'b1, 1'b0, 32'd5,          "DIVZERO_REM");
        run_simple(REMU, 32'hFFFF_FFFF, 32'd0, 32'h300C, 6'd33, 6'd16, 5'd16,
                   1'b1, 1'b0, 32'hFFFF_FFFF, "DIVZERO_REMU");

        // =================================================================
        // 4. INT_MIN / -1 overflow special case (DIV/REM only)
        //    DIV 0x80000000 / -1 -> 0x80000000 (mandated by RISC-V spec)
        //    REM 0x80000000 / -1 -> 0
        // =================================================================
        run_simple(DIV, 32'h8000_0000, 32'hFFFF_FFFF, 32'h4000, 6'd40, 6'd17, 5'd17,
                   1'b1, 1'b0, 32'h8000_0000, "INTMIN_DIV");
        run_simple(REM, 32'h8000_0000, 32'hFFFF_FFFF, 32'h4004, 6'd41, 6'd18, 5'd18,
                   1'b1, 1'b0, 32'd0,          "INTMIN_REM");

        // =================================================================
        // 5. Exception passthrough - must produce a result immediately,
        //    with result forced to 0 and the exception/cause propagated.
        // =================================================================
        run_simple(DIV, 32'd10, 32'd2, 32'h5000, 6'd50, 6'd19, 5'd19,
                   1'b0, 1'b1, 32'd0, "EXCEPT_PASSTHRU");

        // =================================================================
        // 6. Latency checks: fast path must resolve with 0 busy cycles and
        //    div_ready must never drop; slow (real division) path must take
        //    exactly 33 cycles after the accept edge, with div_ready held
        //    low throughout.
        // =================================================================
        begin
            int cyc;
            run_op(DIV, 32'd7, 32'd0, 32'h6000, 6'd60, 6'd20, 5'd20,
                   1'b1, 1'b0, 32'hFFFF_FFFF, 1'b1, "LATENCY_FASTPATH", cyc);
            checks++;
            if (cyc !== 0) begin
                errors++;
                $error("[LATENCY_FASTPATH] expected 0 busy cycles, got %0d", cyc);
            end else begin
                $display("[%0t] LATENCY_FASTPATH  PASS  0 busy cycles as expected", $time);
            end

            run_op(DIVU, 32'd100, 32'd7, 32'h6004, 6'd61, 6'd21, 5'd21,
                   1'b1, 1'b0, 32'd14, 1'b1, "LATENCY_SLOWPATH", cyc);
            checks++;
            if (cyc !== 33) begin
                errors++;
                $error("[LATENCY_SLOWPATH] expected 33 busy cycles, got %0d", cyc);
            end else begin
                $display("[%0t] LATENCY_SLOWPATH  PASS  33 busy cycles as expected", $time);
            end
        end

        // =================================================================
        // 7. Back-to-back throughput on the fast path (divide-by-zero DIV).
        //    Since fast-path ops never leave DIV_IDLE, div_ready must stay
        //    high the whole time and results must appear one cycle after
        //    each request, in order, with no bubble needed.
        // =================================================================
        begin
            logic [TAG_WIDTH-1:0]  exp_pdest [0:2];
            logic [ROB_PTR-1:0]    exp_robtag[0:2];
            int i;

            exp_pdest[0]  = 6'd25; exp_robtag[0] = 5'd22; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_pdest[1]  = 6'd26; exp_robtag[1] = 5'd23; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_pdest[2]  = 6'd27; exp_robtag[2] = 5'd24; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."

            wait (div_ready === 1'b1);
            @(negedge clk);
            for (i = 0; i < 3; i++) begin
                checks++;
                if (div_ready !== 1'b1) begin
                    errors++;
                    $error("[THROUGHPUT %0d] expected div_ready=1 on fast path, got %b", i, div_ready);
                end

                regread_in.valid         = 1'b1;
                regread_in.exec_unit_uop = DIV;
                regread_in.func_unit_type= FU_MULDIV;
                regread_in.instr_class   = INSTR_ALU;
                regread_in.src1_data     = 32'd1 + i;
                regread_in.src2_data     = 32'd0;   // divide by zero -> fast path
                regread_in.p_src1_valid  = 1'b1;
                regread_in.p_src2_valid  = 1'b1;
                regread_in.imm_val       = 32'd0;
                regread_in.pc            = 32'h7000 + 4*i;
                regread_in.p_dest        = exp_pdest[i];
                regread_in.old_p_dest    = 6'd0;
                regread_in.rob_tag       = exp_robtag[i];
                regread_in.reg_we        = 1'b1;
                regread_in.except        = 1'b0;
                regread_in.cause         = EXCEPT_NONE;

                @(posedge clk);
                #1;

                // Result for instruction i is available on the same edge
                // that accepted it (single-cycle-through fast path).
                checks++;
                if (div_wb_out.valid !== 1'b1 || div_wb_out.result !== 32'hFFFF_FFFF ||
                    div_wb_out.p_dest !== exp_pdest[i] || div_wb_out.rob_tag !== exp_robtag[i]) begin
                    errors++;
                    $error("[THROUGHPUT %0d] expected valid=1 result=0xFFFFFFFF p_dest=%0d rob_tag=%0d, got valid=%b result=0x%08h p_dest=%0d rob_tag=%0d",
                        i, exp_pdest[i], exp_robtag[i],
                        div_wb_out.valid, div_wb_out.result, div_wb_out.p_dest, div_wb_out.rob_tag);
                end else begin
                    $display("[%0t] THROUGHPUT[%0d]  PASS  result=0x%08h p_dest=%0d rob_tag=%0d (back-to-back, fast path)",
                            $time, i, div_wb_out.result, div_wb_out.p_dest, div_wb_out.rob_tag);
                end
                @(negedge clk);
            end
            regread_in = '0;
        end

        // =================================================================
        // 8. Flush mid-division: issue a real (slow-path) division, let it
        //    run for a few cycles, then flush. The op must never reach
        //    writeback, internal counters/regs must clear, and div_ready
        //    must recover the cycle after flush.
        // =================================================================
        begin
            int f;
            logic saw_bad_valid;
            saw_bad_valid = 1'b0;

            wait (div_ready === 1'b1);
            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = DIVU;
            regread_in.func_unit_type= FU_MULDIV;
            regread_in.instr_class   = INSTR_ALU;
            regread_in.src1_data     = 32'd999;
            regread_in.src2_data     = 32'd2;      // real division -> goes DIV_BUSY
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.p_dest        = 6'd60;
            regread_in.rob_tag       = 5'd30;
            regread_in.reg_we        = 1'b1;

            @(posedge clk);   // accepted, now moving into DIV_BUSY
            #1;
            @(negedge clk);
            regread_in.valid = 1'b0;

            // Let a handful of shift/subtract cycles elapse while busy.
            repeat (5) @(posedge clk);
            #1;
            checks++;
            if (div_ready !== 1'b0) begin
                errors++;
                $error("[FLUSH] expected div_ready=0 mid-division before flush, got %b", div_ready);
            end

            @(negedge clk);
            flush = 1'b1;
            @(posedge clk);   // flush applied
            #1;
            @(negedge clk);
            flush = 1'b0;

            checks++;
            if (div_ready !== 1'b1) begin
                errors++;
                $error("[FLUSH] expected div_ready=1 the cycle after flush, got %b", div_ready);
            end
            checks++;
            if (dut.bit_cnt !== 6'd0 || dut.rem !== 33'd0 || dut.quot !== 32'd0 || dut.divisor !== 32'd0) begin
                errors++;
                $error("[FLUSH] internal state not cleared: bit_cnt=%0d rem=%0d quot=%0d divisor=%0d",
                       dut.bit_cnt, dut.rem, dut.quot, dut.divisor);
            end

            // Confirm the flushed instruction (rob_tag=30) never reaches
            // writeback, over a window well past the 33-cycle divide latency.
            for (f = 0; f < 40; f++) begin
                @(posedge clk);
                #1;
                checks++;
                if (div_wb_out.valid === 1'b1 && div_wb_out.rob_tag === 5'd30) begin
                    saw_bad_valid = 1'b1;
                    errors++;
                    $error("[FLUSH] flushed instruction (rob_tag=30) incorrectly reached writeback with valid=1");
                end
                @(negedge clk);
            end

            if (!saw_bad_valid)
                $display("[%0t] FLUSH             PASS  flushed division never reached writeback, div_ready recovered", $time);
        end

        // =================================================================
        // 9. Flush coinciding with a fresh accept: flush must win, nothing
        //    should be latched, and div_ready must remain 1 throughout.
        // =================================================================
        begin
            wait (div_ready === 1'b1);
            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = DIV;
            regread_in.func_unit_type= FU_MULDIV;
            regread_in.instr_class   = INSTR_ALU;
            regread_in.src1_data     = 32'd50;
            regread_in.src2_data     = 32'd5;
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.p_dest        = 6'd62;
            regread_in.rob_tag       = 5'd31;
            regread_in.reg_we        = 1'b1;
            flush = 1'b1;

            @(posedge clk);   // flush should suppress the would-be accept
            #1;
            checks++;
            if (div_ready !== 1'b1) begin
                errors++;
                $error("[FLUSH_VS_ACCEPT] expected div_ready=1 (op never latched), got %b", div_ready);
            end
            checks++;
            if (dut.bit_cnt !== 6'd0) begin
                errors++;
                $error("[FLUSH_VS_ACCEPT] expected bit_cnt=0 (no division started), got %0d", dut.bit_cnt);
            end

            @(negedge clk);
            flush = 1'b0;
            regread_in = '0;

            if (errors == 0)
                $display("[%0t] FLUSH_VS_ACCEPT   PASS  simultaneous flush+accept never latched the op", $time);
        end

        $display("\n=====================================================");
        if (errors == 0)
            $display("PASS: div : %0d checks, 0 errors.", checks);
        else
            $display("FAIL: div : %0d checks, %0d errors.", checks, errors);
        $display("=====================================================");
        $finish;
    end

endmodule