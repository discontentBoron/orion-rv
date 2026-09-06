`timescale 1ns/1ps
import orion_pkg::*;

module alu_tb;

    logic clk;
    logic rst_n;
    logic flush;

    regread_execute_pkt_s regread_in;
    execute_wb_pkt_s      alu_wb_out;

    integer errors = 0;
    integer checks = 0;

    alu dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush       (flush),
        .regread_in  (regread_in),
        .alu_wb_out  (alu_wb_out)
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
    // Directed, one-at-a-time op test.
    // Presents one instruction for exactly one cycle, lets it drain through
    // both pipeline stages, then checks the registered output.
    // -------------------------------------------------------------------
    task automatic run_one(
        input exec_unit_opcode_e uop,
        input [DATA_WIDTH-1:0]   src1,
        input                    src2_valid,
        input [DATA_WIDTH-1:0]   src2,
        input [DATA_WIDTH-1:0]   imm,
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
        regread_in.func_unit_type = FU_ALU;
        regread_in.instr_class  = INSTR_ALU;
        regread_in.src1_data    = src1;
        regread_in.p_src1_valid = 1'b1;
        regread_in.p_src2_valid = src2_valid;
        regread_in.src2_data    = src2;
        regread_in.imm_val      = imm;
        regread_in.pc           = pc_in;
        regread_in.p_dest       = p_dest;
        regread_in.old_p_dest   = old_p_dest;
        regread_in.rob_tag      = rob_tag;
        regread_in.reg_we       = reg_we;
        regread_in.except       = except_in;
        regread_in.cause        = except_in ? EXCEPT_ILLEGAL_INST : EXCEPT_NONE;

        @(posedge clk);   // Execute-1 captures this instruction
        @(negedge clk);
        regread_in.valid = 1'b0;  // present a bubble behind it

        @(posedge clk);   // Execute-2 registers the result -> visible now
        #1;

        checks++;
        if (alu_wb_out.valid !== 1'b1) begin
            errors++;
            $error("[%s] expected valid=1, got %b", name, alu_wb_out.valid);
        end
        if (alu_wb_out.result !== expected_result) begin
            errors++;
            $error("[%s] result mismatch: expected %0d (0x%08h), got %0d (0x%08h)",
                   name, expected_result, expected_result, alu_wb_out.result, alu_wb_out.result);
        end
        if (alu_wb_out.p_dest !== p_dest) begin
            errors++;
            $error("[%s] p_dest mismatch: expected %0d, got %0d", name, p_dest, alu_wb_out.p_dest);
        end
        if (alu_wb_out.old_p_dest !== old_p_dest) begin
            errors++;
            $error("[%s] old_p_dest mismatch: expected %0d, got %0d", name, old_p_dest, alu_wb_out.old_p_dest);
        end
        if (alu_wb_out.rob_tag !== rob_tag) begin
            errors++;
            $error("[%s] rob_tag mismatch: expected %0d, got %0d", name, rob_tag, alu_wb_out.rob_tag);
        end
        if (alu_wb_out.reg_we !== reg_we) begin
            errors++;
            $error("[%s] reg_we mismatch: expected %b, got %b", name, reg_we, alu_wb_out.reg_we);
        end
        if (alu_wb_out.pc !== pc_in) begin
            errors++;
            $error("[%s] pc mismatch: expected 0x%08h, got 0x%08h", name, pc_in, alu_wb_out.pc);
        end
        if (alu_wb_out.except !== except_in) begin
            errors++;
            $error("[%s] except mismatch: expected %b, got %b", name, except_in, alu_wb_out.except);
        end

        if (errors == 0 || checks == 1)
            $display("[%0t] %-8s PASS  result=0x%08h p_dest=%0d rob_tag=%0d",
                      $time, name, alu_wb_out.result, alu_wb_out.p_dest, alu_wb_out.rob_tag);

        @(negedge clk);
        regread_in = '0;
    endtask

    // -------------------------------------------------------------------
    // Main directed sequence
    // -------------------------------------------------------------------
    initial begin
        @(posedge rst_n);
        @(negedge clk);

        // --- R-type ops (p_src2_valid=1, operand2 = src2_data) ---
        run_one(ADD,  32'd10,        1'b1, 32'd20,        32'hDEAD, 32'h0,     6'd10, 6'd3,  5'd1, 1'b1, 1'b0, 32'd30,          "ADD");
        run_one(SUB,  32'd5,         1'b1, 32'd20,        32'hDEAD, 32'h0,     6'd11, 6'd4,  5'd2, 1'b1, 1'b0, -32'd15,         "SUB");
        run_one(SUB,  32'd0,         1'b1, 32'd1,         32'hDEAD, 32'h0,     6'd12, 6'd5,  5'd3, 1'b1, 1'b0, 32'hFFFFFFFF,    "SUB_UF");   // underflow wraps
        run_one(SLL,  32'h0000_0001, 1'b1, 32'd31,        32'hDEAD, 32'h0,     6'd13, 6'd6,  5'd4, 1'b1, 1'b0, 32'h8000_0000,   "SLL_31");
        run_one(SLL,  32'h0000_0001, 1'b1, 32'd35,        32'hDEAD, 32'h0,     6'd14, 6'd7,  5'd5, 1'b1, 1'b0, 32'h0000_0008,   "SLL_MASK"); // shamt masked to 3
        run_one(SLT,  -32'd5,        1'b1, 32'd3,         32'hDEAD, 32'h0,     6'd15, 6'd8,  5'd6, 1'b1, 1'b0, 32'd1,           "SLT_NEG");  // -5 < 3 signed -> true
        run_one(SLT,  32'd3,         1'b1, -32'd5,        32'hDEAD, 32'h0,     6'd16, 6'd9,  5'd7, 1'b1, 1'b0, 32'd0,           "SLT_POS");
        run_one(SLTU, 32'hFFFF_FFFF, 1'b1, 32'd1,         32'hDEAD, 32'h0,     6'd17, 6'd10, 5'd8, 1'b1, 1'b0, 32'd0,           "SLTU"); // 0xFFFFFFFF unsigned is huge, not < 1
        run_one(XOR,  32'hF0F0_F0F0, 1'b1, 32'h0F0F_0F0F, 32'hDEAD, 32'h0,     6'd18, 6'd11, 5'd9, 1'b1, 1'b0, 32'hFFFF_FFFF,   "XOR");
        run_one(SRL,  32'h8000_0000, 1'b1, 32'd4,         32'hDEAD, 32'h0,     6'd19, 6'd12, 5'd10,1'b1, 1'b0, 32'h0800_0000,   "SRL");
        run_one(SRA,  32'h8000_0000, 1'b1, 32'd4,         32'hDEAD, 32'h0,     6'd20, 6'd13, 5'd11,1'b1, 1'b0, 32'hF800_0000,   "SRA");   // sign-extends
        run_one(OR,   32'h0F0F_0F0F, 1'b1, 32'hF000_0000, 32'hDEAD, 32'h0,     6'd21, 6'd14, 5'd12,1'b1, 1'b0, 32'hFF0F_0F0F,   "OR");
        run_one(AND,  32'hFF00_FF00, 1'b1, 32'h0F0F_0F0F, 32'hDEAD, 32'h0,     6'd22, 6'd15, 5'd13,1'b1, 1'b0, 32'h0F000F00,    "AND");

        // --- I-type ops (p_src2_valid=0, operand2 = imm_val, NOT src2_data) ---
        run_one(ADD,  32'd100, 1'b0, 32'hBEEF_BEEF /* must be ignored */, 32'd7, 32'h0, 6'd23, 6'd16, 5'd14, 1'b1, 1'b0, 32'd107, "ADDI");
        run_one(SLL,  32'h1,   1'b0, 32'hBEEF_BEEF,                       32'd8, 32'h0, 6'd24, 6'd17, 5'd15, 1'b1, 1'b0, 32'h100, "SLLI");
        run_one(SRA,  32'hFFFF_FFF0 /* -16 */, 1'b0, 32'hBEEF_BEEF,       32'd2, 32'h0, 6'd25, 6'd18, 5'd16, 1'b1, 1'b0, 32'hFFFF_FFFC, "SRAI");

        // --- LUI / AUIPC: ignore both src1/src2, use imm_val / pc+imm_val ---
        run_one(LUI,   32'hBEEF_BEEF, 1'b1, 32'hBEEF_BEEF, 32'h1234_5000, 32'h0,        6'd26, 6'd19, 5'd17, 1'b1, 1'b0, 32'h1234_5000,          "LUI");
        run_one(AUIPC, 32'hBEEF_BEEF, 1'b1, 32'hBEEF_BEEF, 32'h0000_1000, 32'h0000_0100, 6'd27, 6'd20, 5'd18, 1'b1, 1'b0, 32'h0000_1100,          "AUIPC");

        // --- Exception passthrough: except must survive untouched, and
        //     the ALU shouldn't be trusted to gate reg_we itself (Rename
        //     already forces reg_we=0 for exceptions upstream, but confirm
        //     whatever reg_we/except combination arrives is passed through
        //     faithfully rather than being silently altered). ---
        run_one(ADD, 32'd1, 1'b1, 32'd1, 32'hDEAD, 32'h0, 6'd28, 6'd21, 5'd19, 1'b0, 1'b1, 32'd2, "EXCEPT_PASSTHRU");
        // -------------------------------------------------------------
        // Throughput test: 4 back-to-back instructions, 1/cycle throughput.
        // Uses a handshake to align checker with the first issue.
        // -------------------------------------------------------------
        begin
            logic [DATA_WIDTH-1:0] exp_result [0:3];
            logic [TAG_WIDTH-1:0]  exp_pdest  [0:3];
            logic [ROB_PTR-1:0]    exp_robtag [0:3];
            logic                  first_issued;
            int i_issue;
            int i_check;

            exp_result[0] = 32'd50; exp_pdest[0] = 6'd40; exp_robtag[0] = 5'd0; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability." // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[1] = 32'd51; exp_pdest[1] = 6'd41; exp_robtag[1] = 5'd1; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability." // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[2] = 32'd52; exp_pdest[2] = 6'd42; exp_robtag[2] = 5'd2; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability." // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
            exp_result[3] = 32'd53; exp_pdest[3] = 6'd43; exp_robtag[3] = 5'd3; // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability." // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."

            first_issued = 0;

            fork
                // ---- Issuer ----
                begin
                    for (i_issue = 0; i_issue < 4; i_issue++) begin
                        @(negedge clk);
                        regread_in.valid         = 1'b1;
                        regread_in.exec_unit_uop = ADD;
                        regread_in.func_unit_type = FU_ALU;
                        regread_in.instr_class   = INSTR_ALU;
                        regread_in.src1_data     = 32'd50 + i_issue;
                        regread_in.p_src1_valid  = 1'b1;
                        regread_in.p_src2_valid  = 1'b1;
                        regread_in.src2_data     = 32'd0;
                        regread_in.imm_val       = 32'd0;
                        regread_in.pc            = 32'h1000 + 4*i_issue;
                        regread_in.p_dest        = exp_pdest[i_issue];
                        regread_in.old_p_dest    = 6'd0;
                        regread_in.rob_tag       = exp_robtag[i_issue];
                        regread_in.reg_we        = 1'b1;
                        regread_in.except        = 1'b0;
                        regread_in.cause         = EXCEPT_NONE;
                        if (i_issue == 0) first_issued = 1;   // signal that first instruction is on the bus
                    end
                    @(negedge clk);
                    regread_in.valid = 1'b0;   // terminate after last issue
                end

                // ---- Checker ----
                begin
                    wait (first_issued == 1);            // wait for the first issue event
                    // The first instruction is presented at the negative edge.
                    // Its result appears at the second positive edge after that.
                    // So we wait for one positive edge, then the first check samples at the next.
                    @(posedge clk);                      // first positive edge
                    for (i_check = 0; i_check < 4; i_check++) begin
                        @(posedge clk);                  // second, third, fourth, fifth positive edges
                        #1;
                        checks++;
                        if (alu_wb_out.valid !== 1'b1 || alu_wb_out.result !== exp_result[i_check] ||
                            alu_wb_out.p_dest !== exp_pdest[i_check] || alu_wb_out.rob_tag !== exp_robtag[i_check]) begin
                            errors++;
                            $error("[THROUGHPUT %0d] expected result=%0d p_dest=%0d rob_tag=%0d, got valid=%b result=%0d p_dest=%0d rob_tag=%0d",
                                i_check, exp_result[i_check], exp_pdest[i_check], exp_robtag[i_check],
                                alu_wb_out.valid, alu_wb_out.result, alu_wb_out.p_dest, alu_wb_out.rob_tag);
                        end else begin
                            $display("[%0t] THROUGHPUT[%0d] PASS  result=%0d p_dest=%0d rob_tag=%0d (back-to-back, in order)",
                                    $time,i_check, alu_wb_out.result, alu_wb_out.p_dest, alu_wb_out.rob_tag);
                        end
                    end
                end
            join

            @(negedge clk);
            regread_in = '0;
        end

        // -------------------------------------------------------------
        // Flush test: instruction issued, then flush asserted while it's
        // still in flight (in Execute-1). Expect it to NEVER reach
        // Writeback/CDB with valid=1.
        // -------------------------------------------------------------
        begin
            int f;
            logic saw_bad_valid;
            saw_bad_valid = 1'b0;

            @(negedge clk);
            regread_in.valid         = 1'b1;
            regread_in.exec_unit_uop = ADD;
            regread_in.func_unit_type = FU_ALU;
            regread_in.instr_class   = INSTR_ALU;
            regread_in.src1_data     = 32'd999;
            regread_in.p_src1_valid  = 1'b1;
            regread_in.p_src2_valid  = 1'b1;
            regread_in.src2_data     = 32'd1;
            regread_in.p_dest        = 6'd60;
            regread_in.rob_tag       = 5'd30;
            regread_in.reg_we        = 1'b1;

            @(posedge clk);   // now in Execute-1
            #1;
            @(negedge clk);
            regread_in.valid = 1'b0;
            flush = 1'b1;     // flush while the instruction sits in Execute-1

            for (f = 0; f < 3; f++) begin
                @(posedge clk);
                #1;
                checks++;
                if (alu_wb_out.valid === 1'b1 && alu_wb_out.rob_tag === 5'd30) begin
                    saw_bad_valid = 1'b1;
                    errors++;
                    $error("[FLUSH] flushed instruction (rob_tag=30) incorrectly reached Writeback with valid=1");
                end
                @(negedge clk);
                flush = 1'b0;
            end

            if (!saw_bad_valid)
                $display("[%0t] FLUSH    PASS  flushed instruction never reached Writeback with valid=1", $time);
        end

        $display("\n=====================================================");
        if (errors == 0)
            $display("PASS: alu %0d checks, 0 errors.", checks);
        else
            $display("FAIL: alu_2c %0d checks, %0d errors.", checks, errors);
        $display("=====================================================");
        $finish;
    end

endmodule
