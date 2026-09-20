`timescale 1ns / 1ps
import orion_pkg::*;

module issue_queue (
    input logic clk,
    input logic rst_n,

    input  rename_dispatch_pkt_s               dispatch_in,
    input  logic                 [ROB_PTR-1:0] dispatch_rob_tag,
    input   logic [ROB_PTR-1:0]                 rob_head_tag,
    input   logic                              rob_full,
    output logic                               iq_full,

    input logic [NUM_CDB_PORTS-1:0] cdb_valid,
    input logic [TAG_WIDTH-1:0] cdb_p_dest [NUM_CDB_PORTS],

    input logic branch_mispredict,
    input logic exception_valid,

    input logic div_ready,
    input logic lsu_ready,
    output logic                               issue_valid,
    output rename_dispatch_pkt_s               issue_pkt,
    output logic                 [ROB_PTR-1:0] issue_rob_tag
);

  iq_entry_s                    iq_mem         [IQ_SIZE-1:0];
  logic      [IQ_AGE_WIDTH-1:0] global_counter;
  logic      [     IQ_SIZE-1:0] valid_vec;

  // Same flat hit-vector + reduce shape as rename_unit / register_read.
  function automatic logic cdb_hit(input logic [TAG_WIDTH-1:0] tag);
    logic [NUM_CDB_PORTS-1:0] hits;
    for (int p = 0; p < NUM_CDB_PORTS; p++)
      hits[p] = cdb_valid[p] && (cdb_p_dest[p] == tag);
    cdb_hit = |hits;
  endfunction

  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++) valid_vec[i] = iq_mem[i].valid;
  end
  assign iq_full = &valid_vec;
  logic                       free_slot_valid;
  logic [$clog2(IQ_SIZE)-1:0] free_slot_idx;
  logic [        IQ_SIZE-1:0] ready_vec;
  logic                       any_ready;
  logic [$clog2(IQ_SIZE)-1:0] sel_idx;
  logic lsu_issued_q;
  logic div_issued_q;

  // Binary-tree oldest-ready select: IQ_SIZE-1 comparators total instead of
  // IQ_SIZE*(IQ_SIZE-1) for the old all-pairs matrix. cand[0][*] are the
  // leaves (one per IQ entry); each level pairs its inputs and keeps the
  // older-and-ready one, so cand[NUM_LEVELS][0] is the overall winner.
  localparam int NUM_LEVELS = $clog2(IQ_SIZE);
  typedef struct packed {
    logic                       ready;
    logic [IQ_AGE_WIDTH-1:0]    age;
    logic [$clog2(IQ_SIZE)-1:0] idx;
  } cand_s;
  cand_s cand[NUM_LEVELS+1][IQ_SIZE];

  always_comb begin
    free_slot_valid = 1'b0;
    free_slot_idx   = '0;
    for (int i = IQ_SIZE - 1; i >= 0; i--) begin
      if (!valid_vec[i]) begin
        free_slot_valid = 1'b1;
        free_slot_idx   = i[$clog2(IQ_SIZE)-1:0];
      end
    end
  end
  //////////////////////////////////////////////////////////////////////
  // Load-Store Ordering
  //////////////////////////////////////////////////////////////////////
  typedef struct packed {
    logic                    v;
    logic [IQ_AGE_WIDTH-1:0] age;
  } st_cand_s;
  st_cand_s sc [NUM_LEVELS+1][IQ_SIZE];
  logic [IQ_SIZE-1:0]       load_blocked;
  logic                     have_store;
  logic [IQ_AGE_WIDTH-1:0]  oldest_store_age;
  always_comb begin 
    for (int i = 0; i < IQ_SIZE; i++) begin
      sc[0][i].v   = iq_mem[i].valid && (iq_mem[i].instr_class == INSTR_STORE);
      sc[0][i].age = iq_mem[i].age_tag;
    end
    for (int lvl = 0; lvl < NUM_LEVELS; lvl++) begin
      automatic int n = IQ_SIZE >> lvl;
      for (int k = 0; k < n / 2; k++) begin
        automatic st_cand_s a, b;
        a = sc[lvl][2*k];
        b = sc[lvl][2*k+1];
        if (a.v && b.v) sc[lvl+1][k] = ($signed(b.age - a.age) < 0) ? b : a;
        else if (a.v)   sc[lvl+1][k] = a;
        else            sc[lvl+1][k] = b;
      end
    end
    have_store       = sc[NUM_LEVELS][0].v;
    oldest_store_age = sc[NUM_LEVELS][0].age;
    for (int i = 0; i < IQ_SIZE; i++)
      load_blocked[i] = have_store && (iq_mem[i].instr_class == INSTR_LOAD)
                        && ($signed(iq_mem[i].age_tag - oldest_store_age) > 0);
  end
  //////////////////////////////////////////////////////////////////////
  // Gates issue-select against downstream FU busy state. ALU/BRANCH are
  // fixed-latency and pipelined so they always accept; DIV and LSU are
  // single-outstanding-op FSMs and expose ready/busy.
  function automatic logic fu_available(input func_unit_type_e fu, input exec_unit_opcode_e uop);
    case (fu)
      FU_LSU:    fu_available = lsu_ready && !lsu_issued_q;
      FU_MULDIV: fu_available = uop inside {DIV, DIVU, REM, REMU} ? (div_ready && !div_issued_q) : 1'b1;
      default:   fu_available = 1'b1;  // FU_ALU, FU_BRANCH
    endcase
  endfunction

  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++)
    ready_vec[i] = iq_mem[i].valid & iq_mem[i].p_src1_ready & iq_mem[i].p_src2_ready &
                   fu_available(iq_mem[i].func_unit_type, iq_mem[i].exec_unit_uop) & 
                   ((iq_mem[i].instr_class != INSTR_STORE) | (iq_mem[i].rob_tag == rob_head_tag)) &
                   !load_blocked[i];
  end

  always_comb begin
    // Level 0 = leaves, one per IQ entry.
    for (int i = 0; i < IQ_SIZE; i++) begin
      cand[0][i].ready = ready_vec[i];
      cand[0][i].age   = iq_mem[i].age_tag;
      cand[0][i].idx   = i[$clog2(IQ_SIZE)-1:0];
    end
    // Reduce: each level pairs adjacent candidates from the level below
    // and keeps whichever is ready and older (age_tag compare handles
    // wraparound via the same signed-subtraction trick as before).
    for (int lvl = 0; lvl < NUM_LEVELS; lvl++) begin
      automatic int n = IQ_SIZE >> lvl;
      for (int k = 0; k < n / 2; k++) begin
        automatic cand_s a, b;
        a = cand[lvl][2*k];
        b = cand[lvl][2*k+1];
        if (a.ready && b.ready)
          cand[lvl+1][k] = ($signed(b.age - a.age) < 0) ? b : a;
        else if (a.ready)
          cand[lvl+1][k] = a;
        else if (b.ready)
          cand[lvl+1][k] = b;
        else begin
          cand[lvl+1][k]       = a;
          cand[lvl+1][k].ready = 1'b0;
        end
      end
    end
    any_ready = cand[NUM_LEVELS][0].ready;
    sel_idx   = cand[NUM_LEVELS][0].idx;
  end

  always_comb begin
    issue_valid   = any_ready;
    issue_rob_tag = any_ready ? iq_mem[sel_idx].rob_tag : '0;
    issue_pkt     = '0;
    if (any_ready) begin
      issue_pkt.p_src1         = iq_mem[sel_idx].p_src1;
      issue_pkt.p_src2         = iq_mem[sel_idx].p_src2;
      issue_pkt.p_src1_valid   = iq_mem[sel_idx].p_src1_valid;
      issue_pkt.p_src2_valid   = iq_mem[sel_idx].p_src2_valid;
      issue_pkt.p_dest         = iq_mem[sel_idx].p_dest;
      issue_pkt.old_p_dest     = iq_mem[sel_idx].old_p_dest;
      issue_pkt.reg_we         = iq_mem[sel_idx].reg_we;
      issue_pkt.except         = iq_mem[sel_idx].except;
      issue_pkt.except_cause   = iq_mem[sel_idx].except_cause;
      issue_pkt.instr_class    = iq_mem[sel_idx].instr_class;
      issue_pkt.func_unit_type = iq_mem[sel_idx].func_unit_type;
      issue_pkt.exec_unit_uop  = iq_mem[sel_idx].exec_unit_uop;
      issue_pkt.imm_val        = iq_mem[sel_idx].imm_val;
      issue_pkt.pc             = iq_mem[sel_idx].pc;
      issue_pkt.predicted_pc   = iq_mem[sel_idx].predicted_pc;
      issue_pkt.valid          = 1'b1;
    end
  end



  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      global_counter <= '0;
      lsu_issued_q    <=  1'b0;
      div_issued_q    <=  1'b0;
      for (int i = 0; i < IQ_SIZE; i++) iq_mem[i].valid <= 1'b0;
    end else begin
      lsu_issued_q  <=  issue_valid && issue_pkt.func_unit_type == FU_LSU;
      div_issued_q  <=  issue_valid && issue_pkt.func_unit_type == FU_MULDIV && (issue_pkt.exec_unit_uop inside {DIV, DIVU, REM, REMU});
      if (dispatch_in.valid && !iq_full && !rob_full && !branch_mispredict && !exception_valid) begin
        iq_mem[free_slot_idx].p_src1          <= dispatch_in.p_src1;
        iq_mem[free_slot_idx].p_src2          <= dispatch_in.p_src2;
        iq_mem[free_slot_idx].p_src1_ready <= !dispatch_in.p_src1_valid ||
                                               dispatch_in.p_src1_rdy   || cdb_hit(dispatch_in.p_src1);
        iq_mem[free_slot_idx].p_src2_ready <= !dispatch_in.p_src2_valid ||
                                               dispatch_in.p_src2_rdy   ||  cdb_hit(dispatch_in.p_src2);
        iq_mem[free_slot_idx].p_src1_valid    <= dispatch_in.p_src1_valid;
        iq_mem[free_slot_idx].p_src2_valid    <= dispatch_in.p_src2_valid;
        iq_mem[free_slot_idx].p_dest          <= dispatch_in.p_dest;
        iq_mem[free_slot_idx].old_p_dest      <= dispatch_in.old_p_dest;
        iq_mem[free_slot_idx].rob_tag         <= dispatch_rob_tag;
        iq_mem[free_slot_idx].reg_we          <= dispatch_in.reg_we;
        iq_mem[free_slot_idx].instr_class     <= dispatch_in.instr_class;
        iq_mem[free_slot_idx].func_unit_type  <= dispatch_in.func_unit_type;
        iq_mem[free_slot_idx].exec_unit_uop   <= dispatch_in.exec_unit_uop;
        iq_mem[free_slot_idx].imm_val         <= dispatch_in.imm_val;
        iq_mem[free_slot_idx].pc              <= dispatch_in.pc;
        iq_mem[free_slot_idx].predicted_pc    <= dispatch_in.predicted_pc;
        iq_mem[free_slot_idx].valid           <= 1'b1;
        iq_mem[free_slot_idx].except          <= dispatch_in.except;  // added
        iq_mem[free_slot_idx].except_cause    <= dispatch_in.except_cause;
        iq_mem[free_slot_idx].age_tag         <= global_counter;
        global_counter                        <= global_counter + 1'b1;
      end
      for (int i = 0; i < IQ_SIZE; i++) begin
        if (iq_mem[i].valid) begin
          if (cdb_hit(iq_mem[i].p_src1)) iq_mem[i].p_src1_ready <= 1'b1;
          if (cdb_hit(iq_mem[i].p_src2)) iq_mem[i].p_src2_ready <= 1'b1;
        end
      end
      if (any_ready) iq_mem[sel_idx].valid <= 1'b0;
      if (branch_mispredict || exception_valid) begin
        for (int i = 0; i < IQ_SIZE; i++) iq_mem[i].valid <= 1'b0;
      end
    end
  end
endmodule