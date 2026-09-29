`timescale 1ns / 1ps
import orion_pkg::*;

module regread_demux_tb;

  // -----------------------------------------------------------------------
  // DUT signals
  // -----------------------------------------------------------------------
  regread_execute_pkt_s execute_in;
  regread_execute_pkt_s regread_alu_out;
  regread_execute_pkt_s regread_mul_out;
  regread_execute_pkt_s regread_div_out;
  regread_execute_pkt_s regread_branch_out;
  regread_execute_pkt_s regread_lsu_out;

  // -----------------------------------------------------------------------
  // DUT instantiation (purely combinational, no clk/rst)
  // -----------------------------------------------------------------------
  regread_demux dut (
      .execute_in         (execute_in),
      .regread_alu_out    (regread_alu_out),
      .regread_mul_out    (regread_mul_out),
      .regread_div_out    (regread_div_out),
      .regread_branch_out (regread_branch_out),
      .regread_lsu_out    (regread_lsu_out)
  );

  // -----------------------------------------------------------------------
  // Test bookkeeping
  // -----------------------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;

  task automatic check(input string test_name, input logic condition);
    if (condition) begin
      $display("  PASS: %s", test_name);
      pass_count++;
    end else begin
      $display("  FAIL: %s", test_name);
      fail_count++;
    end
  endtask

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------
  task automatic drive(
      input func_unit_type_e   fu_type,
      input exec_unit_opcode_e uop,
      input logic              valid = 1'b1,
      input logic [TAG_WIDTH-1:0] p_dest = 6'd0);
    execute_in                = '0;
    execute_in.valid          = valid;
    execute_in.func_unit_type = fu_type;
    execute_in.exec_unit_uop  = uop;
    execute_in.p_dest         = p_dest;
    #1;  // let the always_comb settle
  endtask

  // All 5 "only the selected port sees valid=1" checks in one place, so
  // each test is a one-liner naming which port should be hot.
  task automatic check_only(input string label, input int hot /* 0=alu 1=mul 2=div 3=branch 4=lsu */);
    check({label, ": alu"},    regread_alu_out.valid    == (hot == 0));
    check({label, ": mul"},    regread_mul_out.valid    == (hot == 1));
    check({label, ": div"},    regread_div_out.valid    == (hot == 2));
    check({label, ": branch"}, regread_branch_out.valid == (hot == 3));
    check({label, ": lsu"},    regread_lsu_out.valid    == (hot == 4));
  endtask

  // -----------------------------------------------------------------------
  // TEST 1: FU_ALU routes to alu only
  // -----------------------------------------------------------------------
  task automatic test_alu();
    $display("\nTEST 1: FU_ALU -> alu port only");
    drive(FU_ALU, ADD, 1'b1, 6'd10);
    check_only("ALU op", 0);
    check("payload (p_dest) passed through to alu port", regread_alu_out.p_dest == 6'd10);
  endtask

  // -----------------------------------------------------------------------
  // TEST 2: FU_BRANCH routes to branch only
  // -----------------------------------------------------------------------
  task automatic test_branch();
    $display("\nTEST 2: FU_BRANCH -> branch port only");
    drive(FU_BRANCH, BEQ, 1'b1, 6'd11);
    check_only("Branch op", 3);
  endtask

  // -----------------------------------------------------------------------
  // TEST 3: FU_LSU routes to lsu only (load and store opcodes both)
  // -----------------------------------------------------------------------
  task automatic test_lsu();
    $display("\nTEST 3: FU_LSU -> lsu port only");
    drive(FU_LSU, LW, 1'b1, 6'd12);
    check_only("Load op", 4);
    drive(FU_LSU, SW, 1'b1, 6'd13);
    check_only("Store op", 4);
  endtask

  // -----------------------------------------------------------------------
  // TEST 4: FU_MULDIV + MUL-family opcode routes to mul only
  // -----------------------------------------------------------------------
  task automatic test_mul_family();
    $display("\nTEST 4: FU_MULDIV + {MUL,MULH,MULHSU,MULHU} -> mul port only");
    drive(FU_MULDIV, MUL,    1'b1, 6'd20); check_only("MUL",    1); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, MULH,   1'b1, 6'd21); check_only("MULH",   1); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, MULHSU, 1'b1, 6'd22); check_only("MULHSU", 1); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, MULHU,  1'b1, 6'd23); check_only("MULHU",  1); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
  endtask

  // -----------------------------------------------------------------------
  // TEST 5: FU_MULDIV + DIV-family opcode routes to div only
  // -----------------------------------------------------------------------
  task automatic test_div_family();
    $display("\nTEST 5: FU_MULDIV + {DIV,DIVU,REM,REMU} -> div port only");
    drive(FU_MULDIV, DIV,  1'b1, 6'd30); check_only("DIV",  2); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, DIVU, 1'b1, 6'd31); check_only("DIVU", 2); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, REM,  1'b1, 6'd32); check_only("REM",  2); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
    drive(FU_MULDIV, REMU, 1'b1, 6'd33); check_only("REMU", 2); // @suppress "Multiple statements on this line. Split the statements over multiple lines to improve readability."
  endtask

  // -----------------------------------------------------------------------
  // TEST 6: execute_in.valid=0 -> nothing hot, regardless of fu type/uop
  // -----------------------------------------------------------------------
  task automatic test_input_invalid();
    $display("\nTEST 6: execute_in.valid=0 -> all 5 ports invalid");
    drive(FU_ALU, ADD, 1'b0, 6'd40);
    check_only("Invalid input, FU_ALU", -1);
    drive(FU_MULDIV, DIV, 1'b0, 6'd41);
    check_only("Invalid input, FU_MULDIV/DIV", -1);
  endtask

  // -----------------------------------------------------------------------
  // TEST 7: payload fields are passed through unchanged on the hot port
  // (spot-check a few fields beyond p_dest, since the demux uses a
  // struct-wide assign-then-override-valid pattern)
  // -----------------------------------------------------------------------
  task automatic test_payload_passthrough();
    $display("\nTEST 7: full payload passthrough on selected port");
    execute_in                = '0;
    execute_in.valid          = 1'b1;
    execute_in.func_unit_type = FU_LSU;
    execute_in.exec_unit_uop  = LW;
    execute_in.p_dest         = 6'd50;
    execute_in.p_src1         = 6'd5;
    execute_in.p_src2         = 6'd6;
    execute_in.src1_data      = 32'hDEAD_0000;
    execute_in.src2_data      = 32'hBEEF_0000;
    execute_in.rob_tag        = 5'd9;
    execute_in.imm_val        = 32'h4;
    #1;
    check("lsu port sees p_src1",    regread_lsu_out.p_src1    == 6'd5);
    check("lsu port sees p_src2",    regread_lsu_out.p_src2    == 6'd6);
    check("lsu port sees src1_data", regread_lsu_out.src1_data == 32'hDEAD_0000);
    check("lsu port sees src2_data", regread_lsu_out.src2_data == 32'hBEEF_0000);
    check("lsu port sees rob_tag",   regread_lsu_out.rob_tag   == 5'd9);
    check("lsu port sees imm_val",   regread_lsu_out.imm_val   == 32'h4);
    // Non-selected ports still see the same field values, just gated
    // invalid -- confirm that's actually true (assign-then-override, not
    // a zeroed struct) since something downstream keying off a stray
    // field on an invalid port would otherwise be a latent bug.
    check("alu port (not hot) still carries the same rob_tag",
          regread_alu_out.rob_tag == 5'd9 && regread_alu_out.valid == 1'b0);
  endtask

  // -----------------------------------------------------------------------
  // Main
  // -----------------------------------------------------------------------
  initial begin
    $dumpfile("regread_demux_tb.vcd");
    $dumpvars(0, regread_demux_tb);

    test_alu();
    test_branch();
    test_lsu();
    test_mul_family();
    test_div_family();
    test_input_invalid();
    test_payload_passthrough();

    $display("\n========================================");
    $display("  PASSED: %0d / %0d", pass_count, pass_count + fail_count);
    $display("  FAILED: %0d / %0d", fail_count, pass_count + fail_count);
    $display("========================================\n");

    $finish;
  end

endmodule