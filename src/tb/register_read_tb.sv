`timescale 1ns / 1ps
import orion_pkg::*;
//TODO: Fix to support updated modules. Lot of changes in module to fix
module register_read_tb;

  localparam int CLK_PERIOD        = 10;
  localparam int NUM_RANDOM_CYCLES = 2000;

  logic clk;
  logic rst_n;

  rename_dispatch_pkt_s dispatch_in;
  logic                 flush;
  logic [ROB_PTR-1:0]   dispatch_rob_tag;

  logic [TAG_WIDTH-1:0]     cdb_tag   [NUM_CDB_PORTS];
  logic [DATA_WIDTH-1:0]    cdb_data  [NUM_CDB_PORTS];
  logic [NUM_CDB_PORTS-1:0] cdb_valid;

  logic [NUM_CDB_PORTS-1:0] wb_en;
  logic [TAG_WIDTH-1:0]     wb_tag  [NUM_CDB_PORTS];
  logic [DATA_WIDTH-1:0]    wb_data [NUM_CDB_PORTS];

  regread_execute_pkt_s execute_out;

  int unsigned error_count = 0;
  int unsigned check_count = 0;

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  register_read dut (
      .clk               (clk),
      .rst_n             (rst_n),
      .dispatch_in       (dispatch_in),
      .flush             (flush),
      .dispatch_rob_tag  (dispatch_rob_tag),
      .cdb_tag           (cdb_tag),
      .cdb_data          (cdb_data),
      .cdb_valid         (cdb_valid),
      .wb_en             (wb_en),
      .wb_tag            (wb_tag),
      .wb_data           (wb_data),
      .execute_out       (execute_out)
  );

  // ------------------------------------------------------------------
  // Clock
  // ------------------------------------------------------------------
  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ------------------------------------------------------------------
  // Golden reference model
  // ------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] shadow_prf [0:PHY_REGS-1];

  function automatic logic [DATA_WIDTH-1:0] golden_read(
      input logic [TAG_WIDTH-1:0] tag,
      input logic                 tag_valid
  );
      logic [DATA_WIDTH-1:0] result;
      result = '0;
      if (tag_valid && tag != '0) begin
          result = shadow_prf[tag];
          for (int p = 0; p < NUM_CDB_PORTS; p++) begin
              if (cdb_valid[p] && cdb_tag[p] == tag)
                  result = cdb_data[p]; // CDB forward wins over PRF
          end
      end
      return result;
  endfunction

  typedef struct packed {
      logic [DATA_WIDTH-1:0] src1_data;
      logic [DATA_WIDTH-1:0] src2_data;
      logic                  valid;
      logic [ROB_PTR-1:0]    rob_tag;
  } expected_s;

  // ------------------------------------------------------------------
  // Stimulus helpers
  // ------------------------------------------------------------------
  task automatic clear_inputs();
      dispatch_in      = '0;
      flush            = 1'b0;
      dispatch_rob_tag = '0;
      cdb_valid        = '0;
      wb_en            = '0;
      for (int p = 0; p < NUM_CDB_PORTS; p++) begin
          cdb_tag[p]  = '0;
          cdb_data[p] = '0;
          wb_tag[p]   = '0;
          wb_data[p]  = '0;
      end
  endtask

  task automatic do_reset();
      rst_n = 0;
      clear_inputs();
      repeat (3) @(posedge clk);
      // Release reset at the negedge, not the instant the previous
      // @(posedge clk) returns -- releasing exactly on a posedge races
      // the DUT's own posedge-triggered always_ff for that same edge.
      @(negedge clk);
      rst_n = 1;
      for (int i = 0; i < PHY_REGS; i++) shadow_prf[i] = '0;
  endtask

  // Dump every signal that could have contributed to this cycle's result.
  // dispatch_in/cdb_*/wb_* are still holding the values that were live
  // during the cycle just checked (the next drive_cycle() hasn't
  // overwritten them yet), so this is an exact snapshot of the stimulus
  // that produced the mismatch.
  task automatic dump_state();
      $display("    dispatch_in: valid=%0b p_src1=%0h(v=%0b) p_src2=%0h(v=%0b)",
                dispatch_in.valid, dispatch_in.p_src1, dispatch_in.p_src1_valid,
                dispatch_in.p_src2, dispatch_in.p_src2_valid);
      $display("    flush=%0b dispatch_rob_tag=%0h", flush, dispatch_rob_tag);
      for (int p = 0; p < NUM_CDB_PORTS; p++)
          $display("    cdb[%0d]: valid=%0b tag=%0h data=%0h", p, cdb_valid[p], cdb_tag[p], cdb_data[p]);
      for (int p = 0; p < NUM_CDB_PORTS; p++)
          $display("    wb[%0d]:  en=%0b   tag=%0h data=%0h", p, wb_en[p], wb_tag[p], wb_data[p]);
      $display("    shadow_prf[p_src1]=%0h  shadow_prf[p_src2]=%0h",
                shadow_prf[dispatch_in.p_src1], shadow_prf[dispatch_in.p_src2]);
      $display("    DUT internals: hit1=%0b hit2=%0b prf_src1_raw=%0h prf_src2_raw=%0h",
                dut.hit1, dut.hit2, dut.prf_src1_raw, dut.prf_src2_raw);
      $display("    DUT prf[p_src1]=%0h  DUT prf[p_src2]=%0h",
                dut.prf[dispatch_in.p_src1], dut.prf[dispatch_in.p_src2]);
  endtask

  task automatic check_output(input expected_s e);
      bit mismatch;
      mismatch = 1'b0;
      check_count++;
      if (execute_out.src1_data !== e.src1_data) begin
          $error("[%0t] src1_data mismatch: DUT=%0h exp=%0h", $time, execute_out.src1_data, e.src1_data);
          error_count++;
          mismatch = 1'b1;
      end
      if (execute_out.src2_data !== e.src2_data) begin
          $error("[%0t] src2_data mismatch: DUT=%0h exp=%0h", $time, execute_out.src2_data, e.src2_data);
          error_count++;
          mismatch = 1'b1;
      end
      if (execute_out.valid !== e.valid) begin
          $error("[%0t] valid mismatch: DUT=%0b exp=%0b", $time, execute_out.valid, e.valid);
          error_count++;
          mismatch = 1'b1;
      end
      if (execute_out.rob_tag !== e.rob_tag) begin
          $error("[%0t] rob_tag mismatch: DUT=%0h exp=%0h", $time, execute_out.rob_tag, e.rob_tag);
          error_count++;
          mismatch = 1'b1;
      end
      if (mismatch) dump_state();
  endtask

  // Drive one cycle's stimulus, cross the edge that registers it into
  // execute_out, then check synchronously in the same procedural flow.
  //
  // IMPORTANT: a bare `#0` after `@(posedge clk)` is NOT sufficient to
  // observe the DUT's NBA-driven update for that same edge. A process
  // resuming from @(posedge clk) is in the Active region; `#0` merely
  // reschedules it into the Inactive region of the *same* time step,
  // which is serviced *before* the NBA region where `execute_out <= ...`
  // actually commits. Sampling after only `#0` therefore reads the
  // stale, pre-edge value every cycle -- checks end up comparing the
  // *previous* cycle's DUT output against the *current* cycle's golden
  // expectation. A nonzero delay (short relative to the clock period)
  // pushes past the NBA region before sampling, so execute_out is
  // guaranteed current.
  //
  // Callers set dispatch_in/cdb_*/wb_* fields, then call this task, right
  // after the *previous* drive_cycle() returned -- i.e. at the exact
  // simulation instant of the previous posedge. Sampling the golden model
  // (or letting the DUT sample stimulus) at that same instant races the
  // DUT's own posedge-triggered always_ff for that edge. Settling at the
  // negedge first removes the race: stimulus is guaranteed stable for a
  // full half-cycle before the next posedge, with no shared time step
  // against any posedge-sensitive process.
  task automatic drive_cycle();
      expected_s e;
      @(negedge clk);
      e.src1_data = golden_read(dispatch_in.p_src1, dispatch_in.p_src1_valid);
      e.src2_data = golden_read(dispatch_in.p_src2, dispatch_in.p_src2_valid);
      e.valid     = dispatch_in.valid & ~flush;
      e.rob_tag   = dispatch_rob_tag;

      // Mirror the write port's spec directly (tag 0 never updated,
      // one port per tag per cycle by construction of the stimulus).
      for (int r = 1; r < PHY_REGS; r++) begin
          for (int p = 0; p < NUM_CDB_PORTS; p++) begin
              if (wb_en[p] && wb_tag[p] == r[TAG_WIDTH-1:0])
                  shadow_prf[r] = wb_data[p];
          end
      end

      @(posedge clk);
      #1;
      check_output(e);
  endtask

  // ------------------------------------------------------------------
  // Directed tests
  // ------------------------------------------------------------------
  task automatic directed_tests();
      $display("---- directed tests ----");

      // T1: plain PRF read, no forwarding, no prior write -> expect 0
      clear_inputs();
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src1       = 6'd5;
      dispatch_in.p_src1_valid = 1'b1;
      dispatch_in.p_src2       = 6'd9;
      dispatch_in.p_src2_valid = 1'b1;
      dispatch_rob_tag         = 5'd1;
      drive_cycle();

      // T2: x0 always reads zero even if "written"
      clear_inputs();
      wb_en[0]    = 1'b1;
      wb_tag[0]   = 6'd0;
      wb_data[0]  = 32'hDEAD_BEEF; // must be dropped by DUT
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src1       = 6'd0;
      dispatch_in.p_src1_valid = 1'b1;
      dispatch_rob_tag         = 5'd2;
      drive_cycle();

      // T3: normal write then read (no forwarding), one cycle apart
      clear_inputs();
      wb_en[1]   = 1'b1;
      wb_tag[1]  = 6'd12;
      wb_data[1] = 32'hCAFE_F00D;
      drive_cycle();

      clear_inputs();
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src1       = 6'd12;
      dispatch_in.p_src1_valid = 1'b1;
      dispatch_rob_tag         = 5'd3;
      drive_cycle(); // should read back CAFEF00D

      // T4: CDB forwarding takes priority over (stale) PRF content
      clear_inputs();
      wb_en[0]   = 1'b1;
      wb_tag[0]  = 6'd20;
      wb_data[0] = 32'h1111_1111;
      drive_cycle();

      clear_inputs();
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src1       = 6'd20;
      dispatch_in.p_src1_valid = 1'b1;
      dispatch_rob_tag         = 5'd4;
      cdb_valid[2]  = 1'b1;
      cdb_tag[2]    = 6'd20;
      cdb_data[2]   = 32'h2222_2222; // should win over PRF's 0x11111111
      drive_cycle();

      // T5: unused operand (p_srcX_valid=0) forces zero even if tag hits CDB
      clear_inputs();
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src2       = 6'd20;
      dispatch_in.p_src2_valid = 1'b0;
      cdb_valid[3]  = 1'b1;
      cdb_tag[3]    = 6'd20;
      cdb_data[3]   = 32'h3333_3333;
      dispatch_rob_tag = 5'd5;
      drive_cycle();

      // T6: flush forces valid low; data fields still register cleanly
      clear_inputs();
      dispatch_in.valid        = 1'b1;
      dispatch_in.p_src1       = 6'd12;
      dispatch_in.p_src1_valid = 1'b1;
      flush                    = 1'b1;
      dispatch_rob_tag         = 5'd6;
      drive_cycle();

      // T7: each of the 5 CDB ports individually forwards correctly
      for (int p = 0; p < NUM_CDB_PORTS; p++) begin
          clear_inputs();
          dispatch_in.valid        = 1'b1;
          dispatch_in.p_src1       = 6'(30 + p);
          dispatch_in.p_src1_valid = 1'b1;
          cdb_valid[p] = 1'b1;
          cdb_tag[p]   = 6'(30 + p);
          cdb_data[p]  = 32'hA000_0000 + p;
          dispatch_rob_tag = 5'(p);
          drive_cycle();
      end

      repeat (2) @(posedge clk); // drain outstanding checks

      $display("---- directed tests done ----");
  endtask

  // ------------------------------------------------------------------
  // Randomized tests
  // ------------------------------------------------------------------
  task automatic randomized_tests(int num_cycles);
      $display("---- randomized tests (%0d cycles) ----", num_cycles);
      for (int c = 0; c < num_cycles; c++) begin
          clear_inputs();

          dispatch_in.valid        = $urandom_range(0, 9) != 0; // mostly valid
          dispatch_in.p_src1       = $urandom_range(0, PHY_REGS-1);
          dispatch_in.p_src2       = $urandom_range(0, PHY_REGS-1);
          dispatch_in.p_src1_valid = $urandom_range(0, 9) != 0;
          dispatch_in.p_src2_valid = $urandom_range(0, 9) != 0;
          dispatch_rob_tag         = $urandom_range(0, (1<<ROB_PTR)-1);
          flush                    = $urandom_range(0, 19) == 0; // occasional flush

          // Random, collision-free CDB activity: at most one port
          // targets any given tag this cycle (architectural invariant).
          begin
              logic [TAG_WIDTH-1:0] used_tags[$];
              logic [TAG_WIDTH-1:0] t;
              logic clash;
              used_tags.delete();
              for (int p = 0; p < NUM_CDB_PORTS; p++) begin
                  if ($urandom_range(0, 2) == 0) begin
                      do begin
                          t = $urandom_range(1, PHY_REGS-1); // never target x0
                          clash = 1'b0;
                          foreach (used_tags[i]) if (used_tags[i] == t) clash = 1'b1;
                      end while (clash);
                      used_tags.push_back(t);
                      cdb_valid[p] = 1'b1;
                      cdb_tag[p]   = t;
                      cdb_data[p]  = $urandom();
                  end
              end
          end

          // Random, collision-free writeback activity, same invariant.
          begin
              logic [TAG_WIDTH-1:0] used_tags[$];
              logic [TAG_WIDTH-1:0] t;
              logic clash;
              used_tags.delete();
              for (int p = 0; p < NUM_CDB_PORTS; p++) begin
                  if ($urandom_range(0, 2) == 0) begin
                      do begin
                          t = $urandom_range(0, PHY_REGS-1); // tag 0 allowed: must be dropped
                          clash = 1'b0;
                          foreach (used_tags[i]) if (used_tags[i] == t) clash = 1'b1;
                      end while (clash);
                      used_tags.push_back(t);
                      wb_en[p]   = 1'b1;
                      wb_tag[p]  = t;
                      wb_data[p] = $urandom();
                  end
              end
          end

          drive_cycle();
      end
      repeat (2) @(posedge clk);
      $display("---- randomized tests done ----");
  endtask

  // ------------------------------------------------------------------
  // Main
  // ------------------------------------------------------------------
  initial begin
      do_reset();
      @(posedge clk);
      directed_tests();
      randomized_tests(NUM_RANDOM_CYCLES);

      if (error_count == 0)
          $display("\nPASS: %0d checks, 0 mismatches", check_count);
      else
          $display("\nFAIL: %0d checks, %0d mismatches", check_count, error_count);

      $finish;
  end

  // Safety timeout
  initial begin
      #(CLK_PERIOD * (NUM_RANDOM_CYCLES + 200));
      $display("\nTIMEOUT: simulation did not finish in time");
      $finish;
  end

endmodule