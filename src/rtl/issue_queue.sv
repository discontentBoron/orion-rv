`timescale 1ns / 1ps
import orion_pkg::*;

module issue_queue (
    input logic clk,
    input logic rst_n,

    input  rename_dispatch_pkt_s               dispatch_in,
    input   logic                 [ROB_PTR-1:0] dispatch_rob_tag,
    input   logic                              rob_full,
    output  logic                               iq_full,

    input logic [NUM_CDB_PORTS-1:0] cdb_valid,
    input logic [TAG_WIDTH-1:0] cdb_p_dest [NUM_CDB_PORTS],

    input logic branch_mispredict,
    input logic exception_valid,

    input logic div_ready,
    input logic lsu_ready,
    input logic sb_can_accept,
    output logic                               issue_valid,
    output rename_dispatch_pkt_s               issue_pkt,
    output logic                 [ROB_PTR-1:0] issue_rob_tag
);

  iq_entry_s                    iq_mem         [IQ_SIZE-1:0];
  logic      [     IQ_SIZE-1:0] valid_vec;
  logic issue_valid_c;
  rename_dispatch_pkt_s issue_pkt_c;
  logic [ROB_PTR-1:0] issue_rob_tag_c;

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
  logic [1:0] lsu_issued_q;
  logic [1:0] div_issued_q;

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

  logic older[IQ_SIZE][IQ_SIZE];

  logic dispatch_fire;
  assign dispatch_fire = dispatch_in.valid && !iq_full && !rob_full &&
                          !branch_mispredict && !exception_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < IQ_SIZE; i++)
        for (int j = 0; j < IQ_SIZE; j++) older[i][j] <= 1'b0;
    end else if (dispatch_fire) begin
      for (int k = 0; k < IQ_SIZE; k++) begin
        if (k != free_slot_idx) begin
          older[free_slot_idx][k] <= 1'b0;  // new entry is younger than k
          older[k][free_slot_idx] <= 1'b1;  // k is older than the new entry
        end
      end
    end
  end

  //////////////////////////////////////////////////////////////////////
  // Load-Store Ordering
  //////////////////////////////////////////////////////////////////////
  logic [IQ_SIZE-1:0] is_store, is_load;
  logic [IQ_SIZE-1:0] older_store_pending;  // per-entry: an older store is still in the IQ
  logic [IQ_SIZE-1:0] older_load_pending;   // per-entry: an older load  is still in the IQ
  logic [IQ_SIZE-1:0] load_blocked;
  logic [IQ_SIZE-1:0] store_ok;

  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++) begin
      is_store[i] = valid_vec[i] && (iq_mem[i].instr_class == INSTR_STORE);
      is_load[i]  = valid_vec[i] && (iq_mem[i].instr_class == INSTR_LOAD);
    end
    for (int i = 0; i < IQ_SIZE; i++) begin
      automatic logic osp, olp;
      osp = 1'b0;
      olp = 1'b0;
      for (int j = 0; j < IQ_SIZE; j++) begin
        if (is_store[j] && older[j][i]) osp = 1'b1;
        if (is_load[j]  && older[j][i]) olp = 1'b1;
      end
      older_store_pending[i] = osp;
      older_load_pending[i]  = olp;
    end

    for (int i = 0; i < IQ_SIZE; i++) begin
      // A store blocks a younger load only while it's still pending.
      load_blocked[i] = is_load[i] && older_store_pending[i];
      // A store may issue once it is the oldest store in the IQ
      // (no older store pending) and no older load is still waiting.
      store_ok[i]     = sb_can_accept && is_store[i] &&
                         !older_store_pending[i] && !older_load_pending[i];
    end
  end
  //////////////////////////////////////////////////////////////////////
  // Gates issue-select against downstream FU busy state. ALU/BRANCH are
  // fixed-latency and pipelined so they always accept; DIV and LSU are
  // single-outstanding-op FSMs and expose ready/busy.
  function automatic logic fu_available(input func_unit_type_e fu, input exec_unit_opcode_e uop);
    case (fu)
      FU_LSU:    fu_available = lsu_ready && !lsu_issued_q[0] && !lsu_issued_q[1];
      FU_MULDIV: fu_available = uop inside {DIV, DIVU, REM, REMU} ? (div_ready && !div_issued_q[0] && !div_issued_q[1]) : 1'b1;
      default:   fu_available = 1'b1;  // FU_ALU, FU_BRANCH
    endcase
  endfunction

  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++)
    ready_vec[i] = iq_mem[i].valid & iq_mem[i].p_src1_ready & iq_mem[i].p_src2_ready &
                   fu_available(iq_mem[i].func_unit_type, iq_mem[i].exec_unit_uop) &
                   ((iq_mem[i].instr_class != INSTR_STORE) | store_ok[i]) &
                   !load_blocked[i];
  end
  logic [IQ_SIZE-1:0] is_selected;
  always_comb begin
    for (int i = 0; i < IQ_SIZE; i++) begin
      automatic logic older_ready_pending;
      older_ready_pending = 1'b0;
      for (int j = 0; j < IQ_SIZE; j++)
        if (ready_vec[j] && older[j][i]) older_ready_pending = 1'b1;
      is_selected[i] = ready_vec[i] && !older_ready_pending;
    end

    any_ready = |is_selected;
    sel_idx   = '0;
    for (int i = IQ_SIZE - 1; i >= 0; i--)
      if (is_selected[i]) sel_idx = i[$clog2(IQ_SIZE)-1:0];
  end

  always_comb begin
    issue_valid_c   = any_ready;
    issue_rob_tag_c = any_ready ? iq_mem[sel_idx].rob_tag : '0;
    issue_pkt_c     = '0;
    if (any_ready) begin
      issue_pkt_c.p_src1         = iq_mem[sel_idx].p_src1;
      issue_pkt_c.p_src2         = iq_mem[sel_idx].p_src2;
      issue_pkt_c.p_src1_valid   = iq_mem[sel_idx].p_src1_valid;
      issue_pkt_c.p_src2_valid   = iq_mem[sel_idx].p_src2_valid;
      issue_pkt_c.p_dest         = iq_mem[sel_idx].p_dest;
      issue_pkt_c.old_p_dest     = iq_mem[sel_idx].old_p_dest;
      issue_pkt_c.reg_we         = iq_mem[sel_idx].reg_we;
      issue_pkt_c.except         = iq_mem[sel_idx].except;
      issue_pkt_c.except_cause   = iq_mem[sel_idx].except_cause;
      issue_pkt_c.instr_class    = iq_mem[sel_idx].instr_class;
      issue_pkt_c.func_unit_type = iq_mem[sel_idx].func_unit_type;
      issue_pkt_c.exec_unit_uop  = iq_mem[sel_idx].exec_unit_uop;
      issue_pkt_c.imm_val        = iq_mem[sel_idx].imm_val;
      issue_pkt_c.pc             = iq_mem[sel_idx].pc;
      issue_pkt_c.predicted_pc   = iq_mem[sel_idx].predicted_pc;
      issue_pkt_c.valid          = 1'b1;
    end
  end



  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lsu_issued_q    <=  1'b0;
      div_issued_q    <=  1'b0;
      for (int i = 0; i < IQ_SIZE; i++) iq_mem[i].valid <= 1'b0;
    end else begin
      lsu_issued_q[0] <= issue_valid_c && (issue_pkt_c.func_unit_type == FU_LSU);
      lsu_issued_q[1] <= lsu_issued_q[0];

      div_issued_q[0] <= issue_valid_c && (issue_pkt_c.func_unit_type == FU_MULDIV) && (issue_pkt_c.exec_unit_uop inside {DIV, DIVU, REM, REMU});
      div_issued_q[1] <= div_issued_q[0];

      if (dispatch_fire) begin
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

  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      issue_pkt     <= 'b0;
      issue_valid   <=  1'b0;
      issue_rob_tag <=  'b0;
    end else if(branch_mispredict || exception_valid) begin
      issue_pkt     <= 'b0;
      issue_valid   <=  1'b0;
      issue_rob_tag <=  'b0;
    end else begin
      issue_pkt     <=  issue_pkt_c;
      issue_valid   <=  issue_valid_c;
      issue_rob_tag <=  issue_rob_tag_c;
    end
  end
endmodule