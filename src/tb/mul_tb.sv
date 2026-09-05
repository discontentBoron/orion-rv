`timescale 1ns/1ps
import orion_pkg::*;

module mul_tb;

    logic clk;
    logic rst_n;
    logic flush;

    regread_execute_pkt_s regread_in;
    execute_wb_pkt_s      mul_wb_out;

    integer errors = 0;
    integer checks = 0;

    mul dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush       (flush),
        .regread_in  (regread_in),
        .mul_wb_out  (mul_wb_out)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst_n = 1'b0;
        flush = 1'b0;
        regread_in = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------
    // Directed, one-at-a-time op test. Same shape as alu_tb.sv's run_one.
    // -------------------------------------------------------------------
    task automatic run_one(
        input exec_unit_opcode_e uop,
        input [DATA_WIDTH-1:0]   src1,
        input [DATA_WIDTH-1:0]   src2,
        input [DATA_WIDTH-1:0]   pc_in,
        input [TAG_WIDTH-1:0]    p_dest,
        input [TAG_WIDTH-1:0]    old_p_dest,
        input [ROB_PTR-1:0]      rob_tag,
        input                    reg_we,
        input                    except_in,
        input [DATA_WIDTH-1:0]   expected_result,
        input string             name
    );
        @(negedge clk);
        regread_in.valid        = 1'b1;
        regread_in.exec_unit_uop = uop;
        regread_in.func_unit_type = FU_MULDIV;
        regread_in.instr_class  = INSTR_ALU;
        regread_in.src1_data    = src1;
        regread_in.p_src1_valid = 1'b1;
        regread_in.p_src2_valid = 1'b1;
        regread_in.src2_data    = src2;
        regread_in.imm_val      = 32'hDEAD_DEAD;  // MULDIV ops never use imm_val
        regread_in.pc           = pc_in;
        regread_in.p_dest       = p_dest;
        regread_in.old_p_dest   = old_p_dest;
        regread_in.rob_tag      = rob_tag;
        regread_in.reg_we       = reg_we;
        regread_in.except       = except_in;
        regread_in.cause        = except_in ? EXCEPT_ILLEGAL_INST : EXCEPT_NONE;

        @(posedge clk);   // Mul-S1 captures this instruction
        @(negedge clk);
        regread_in.valid = 1'b0;  // present a bubble behind it

        @(posedge clk);   // Mul-S2 registers the result -> visible now
        #1;

        checks++;
        if (mul_wb_out.valid !== 1'b1) begin
            errors++;
            $error("[%s] expected valid=1, got %b", name, mul_wb_out.valid);
        end
        if (mul_wb_out.result !== expected_result) begin
            errors++;
            $error("[%s] result mismatch: expected 0x%08h, got 0x%08h",
                   name, expected_result, mul_wb_out.result);
        end
        if (mul_wb_out.p_dest !== p_dest) begin
            errors++;
            $error("[%s] p_dest mismatch: expected %0d, got %0d", name, p_dest, mul_wb_out.p_dest);
        end
        if (mul_wb_out.old_p_dest !== old_p_dest) begin
            errors++;
            $error("[%s] old_p_dest mismatch: expected %0d, got %0d", name, old_p_dest, mul_wb_out.old_p_dest);
        end
        if (mul_wb_out.rob_tag !== rob_tag) begin
            errors++;
            $error("[%s] rob_tag mismatch: expected %0d, got %0d", name, rob_tag, mul_wb_out.rob_tag);
        end
        if (mul_wb_out.reg_we !== reg_we) begin
            errors++;
            $error("[%s] reg_we mismatch: expected %b, got %b", name, reg_we, mul_wb_out.reg_we);
        end
        if (mul_wb_out.pc !== pc_in) begin
            errors++;
            $error("[%s] pc mismatch: expected 0x%08h, got 0x%08h", name, pc_in, mul_wb_out.pc);
        end
        if (mul_wb_out.except !== except_in) begin
            errors++;
            $error("[%s] except mismatch: expected %b, got %b", name, except_in, mul_wb_out.except);
        end

        if (errors == 0)
            $display("[%0t] %-14s PASS  result=0x%08h p_dest=%0d rob_tag=%0d",
                      $time, name, mul_wb_out.result, mul_wb_out.p_dest, mul_wb_out.rob_tag);

        @(negedge clk);
        regread_in = '0;
    endtask

    initial begin
        @(posedge rst_n);
        @(negedge clk);

        // --- Basic sanity: small positive operands ---
        run_one(MUL,   32'd6, 32'd7, 32'h0, 6'd10, 6'd3, 5'd1, 1'b1, 1'b0, 32'd42, "MUL_6x7");

        // --- Zero operand ---
        run_one(MUL,   32'd0, 32'hFFFF_FFFF, 32'h0, 6'd11, 6'd4, 5'd2, 1'b1, 1'b0, 32'd0, "MUL_zero");

        // --- MUL is sign-independent on its low 32 bits: A=-3, B=5 ---
        run_one(MUL,   32'hFFFF_FFFD /*-3*/, 32'd5, 32'h0, 6'd12, 6'd5, 5'd3, 1'b1, 1'b0, 32'hFFFF_FFF1 /*-15*/, "MUL_neg");

        // --- MULH: -3 * 5 = -15 (both operands signed) ---
        run_one(MULH,  32'hFFFF_FFFD /*-3*/, 32'd5, 32'h0, 6'd13, 6'd6, 5'd4, 1'b1, 1'b0, 32'hFFFF_FFFF /* upper32 of -15 */, "MULH_neg");

        // --- INT_MIN boundary: A=0x80000000 (-2^31), B=1 ---
        run_one(MUL,   32'h8000_0000, 32'd1, 32'h0, 6'd14, 6'd7, 5'd5, 1'b1, 1'b0, 32'h8000_0000, "MUL_INTMIN");
        run_one(MULH,  32'h8000_0000, 32'd1, 32'h0, 6'd15, 6'd8, 5'd6, 1'b1, 1'b0, 32'hFFFF_FFFF, "MULH_INTMIN");
        run_one(MULHU, 32'h8000_0000, 32'd1, 32'h0, 6'd16, 6'd9, 5'd7, 1'b1, 1'b0, 32'h0000_0000, "MULHU_INTMIN");

        // -------------------------------------------------------------
        // The sharpest signedness check: identical bit pattern
        // (0xFFFFFFFF, 0xFFFFFFFF) fed to all four ops. As signed values
        // both operands equal -1 (product = +1, upper32 = 0). As unsigned
        // values both equal 4294967295 (product upper32 = 0xFFFFFFFE).
        // MULHSU treats only rs1 as signed (-1) and rs2 as unsigned
        // (4294967295), giving a THIRD distinct answer. All four ops must
        // therefore disagree with each other despite receiving the exact
        // same bits.
        // -------------------------------------------------------------
        run_one(MUL,    32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0, 6'd17, 6'd10, 5'd8,  1'b1, 1'b0, 32'h0000_0001, "SAME_BITS_MUL");
        run_one(MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0, 6'd18, 6'd11, 5'd9,  1'b1, 1'b0, 32'h0000_0000, "SAME_BITS_MULH");
        run_one(MULHSU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0, 6'd19, 6'd12, 5'd10, 1'b1, 1'b0, 32'hFFFF_FFFF, "SAME_BITS_MULHSU");
        run_one(MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0, 6'd20, 6'd13, 5'd11, 1'b1, 1'b0, 32'hFFFF_FFFE, "SAME_BITS_MULHU");

        // --- Exception passthrough ---
        run_one(MUL, 32'd2, 32'd3, 32'h0, 6'd21, 6'd14, 5'd12, 1'b0, 1'b1, 32'd6, "EXCEPT_PASSTHRU");

        // -------------------------------------------------------------
        // Throughput test: 4 back-to-back instructions, no bubbles.
        // -------------------------------------------------------------
        // -------------------------------------------------------------
        begin
            logic [DATA_WIDTH-1:0] exp_result [0:3];
            logic [TAG_WIDTH-1:0]  exp_pdest  [0:3];
            logic [ROB_PTR-1:0]    exp_robtag [0:3];
            int i;

            exp_result[0] = 32'd0;  exp_pdest[0] = 6'd40; exp_robtag[0] = 5'd0;  // 0*4 // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[1] = 32'd5;  exp_pdest[1] = 6'd41; exp_robtag[1] = 5'd1;  // 1*5 // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[2] = 32'd12; exp_pdest[2] = 6'd42; exp_robtag[2] = 5'd2;  // 2*6 // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[3] = 32'd21; exp_pdest[3] = 6'd43; exp_robtag[3] = 5'd3;  // 3*7 // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."

            @(negedge clk);
            for (i = 0; i < 4; i++) begin
                // Set up instruction i
                regread_in.valid         = 1'b1;
                regread_in.exec_unit_uop = MUL;
                regread_in.func_unit_type = FU_MULDIV;
                regread_in.instr_class   = INSTR_ALU;
                regread_in.src1_data     = i;
                regread_in.p_src1_valid  = 1'b1;
                regread_in.p_src2_valid  = 1'b1;
                regread_in.src2_data     = 4 + i;
                regread_in.imm_val       = 32'd0;
                regread_in.pc            = 32'h2000 + 4*i;
                regread_in.p_dest        = exp_pdest[i];
                regread_in.old_p_dest    = 6'd0;
                regread_in.rob_tag       = exp_robtag[i];
                regread_in.reg_we        = 1'b1;
                regread_in.except        = 1'b0;
                regread_in.cause         = EXCEPT_NONE;

                @(posedge clk);   // Latch instruction i into ms1
                #1;

                // After this posedge, result of instruction (i-1) is available (if i>0)
                if (i > 0) begin
                    checks++;
                    if (mul_wb_out.valid !== 1'b1 || mul_wb_out.result !== exp_result[i-1] ||
                        mul_wb_out.p_dest !== exp_pdest[i-1] || mul_wb_out.rob_tag !== exp_robtag[i-1]) begin
                        errors++;
                        $error("[THROUGHPUT %0d] expected result=%0d p_dest=%0d rob_tag=%0d, got valid=%b result=%0d p_dest=%0d rob_tag=%0d",
                            i-1, exp_result[i-1], exp_pdest[i-1], exp_robtag[i-1],
                            mul_wb_out.valid, mul_wb_out.result, mul_wb_out.p_dest, mul_wb_out.rob_tag);
                    end else begin
                        $display("[%0t] THROUGHPUT[%0d] PASS  result=%0d p_dest=%0d rob_tag=%0d (back-to-back, in order)",
                                $time, i-1, mul_wb_out.result, mul_wb_out.p_dest, mul_wb_out.rob_tag);
                    end
                end
                @(negedge clk);
            end

            // Now we have sent all 4 instructions, check the last one (i=3)
            @(posedge clk);
            #1;
            checks++;
            if (mul_wb_out.valid !== 1'b1 || mul_wb_out.result !== exp_result[3] ||
                mul_wb_out.p_dest !== exp_pdest[3] || mul_wb_out.rob_tag !== exp_robtag[3]) begin
                errors++;
                $error("[THROUGHPUT %0d] expected result=%0d p_dest=%0d rob_tag=%0d, got valid=%b result=%0d p_dest=%0d rob_tag=%0d",
                    3, exp_result[3], exp_pdest[3], exp_robtag[3],
                    mul_wb_out.valid, mul_wb_out.result, mul_wb_out.p_dest, mul_wb_out.rob_tag);
            end else begin
                $display("[%0t] THROUGHPUT[%0d] PASS  result=%0d p_dest=%0d rob_tag=%0d (back-to-back, in order)",
                        $time, 3, mul_wb_out.result, mul_wb_out.p_dest, mul_wb_out.rob_tag);
            end
            @(negedge clk);
            regread_in = '0;
        end
        // -------------------------------------------------------------
        // Flush test: instruction issued, flush asserted while it's still
        // in flight (in Mul-S1). Must never reach Writeback with valid=1.
        // -------------------------------------------------------------
        begin
            int f;
            logic saw_bad_valid;
            saw_bad_valid = 1'b0;

            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = MUL;
            regread_in.func_unit_type = FU_MULDIV;
            regread_in.instr_class   = INSTR_ALU;
            regread_in.src1_data     = 32'd999;
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.src2_data     = 32'd2;
            regread_in.p_dest        = 6'd60;
            regread_in.rob_tag       = 5'd30;
            regread_in.reg_we        = 1'b1;

            @(posedge clk);   // now in Mul-S1
            #1;
            @(negedge clk);
            regread_in.valid = 1'b0;
            flush = 1'b1;

            for (f = 0; f < 3; f++) begin
                @(posedge clk);
                #1;
                checks++;
                if (mul_wb_out.valid === 1'b1 && mul_wb_out.rob_tag === 5'd30) begin
                    saw_bad_valid = 1'b1;
                    errors++;
                    $error("[FLUSH] flushed instruction (rob_tag=30) incorrectly reached Writeback with valid=1");
                end
                @(negedge clk);
                flush = 1'b0;
            end

            if (!saw_bad_valid)
                $display("[%0t] FLUSH          PASS  flushed instruction never reached Writeback with valid=1", $time);
        end

        $display("\n=====================================================");
        if (errors == 0)
            $display("PASS: mul_2c : %0d checks, 0 errors.", checks);
        else
            $display("FAIL: mul_2c : %0d checks, %0d errors.", checks, errors);
        $display("=====================================================");
        $finish;
    end

endmodule