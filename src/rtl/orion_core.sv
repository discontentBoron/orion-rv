`timescale 1ns/1ps
import orion_pkg::*;

module orion_core #(
    parameter int IMEM_DEPTH = 256
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // Instruction memory interface
    output logic                            imem_req_valid,
    input  logic                            imem_req_ready,
    output logic [DATA_WIDTH-1:0]           imem_req_addr,
    input  logic                            imem_resp_valid,
    input  logic [DATA_WIDTH-1:0]           imem_resp_data,
    input  logic                            imem_resp_last,


    // Data memory interface (D-cache backing store), one in-order channel:
    //   refill: dmem_req_we=0, 32 B-aligned address, then 8 in-order 32-bit beats
    //           on dmem_resp_* with dmem_resp_last on the 8th. Beats must arrive
    //           AFTER the request handshake cycle; the cache never back-pressures.
    //   write : dmem_req_we=1, word address + wdata/wstrb (write-through).
    //           Completion is the dmem_req_ready handshake; no response beat.
    output logic                            dmem_req_valid,
    input  logic                            dmem_req_ready,
    output logic                            dmem_req_we,
    output logic [DATA_WIDTH-1:0]           dmem_req_addr,
    output logic [DATA_WIDTH-1:0]           dmem_req_wdata,
    output logic [3:0]                      dmem_req_wstrb,
    input  logic                            dmem_resp_valid,
    input  logic [DATA_WIDTH-1:0]           dmem_resp_data,
    input  logic                            dmem_resp_last
);
    // Former top-level outputs, now internal-only signals
    logic [DATA_WIDTH-1:0]  fetch_pc;
    logic [DATA_WIDTH-1:0]  fetch_instr;
    logic                   fetch_valid;
    logic [DATA_WIDTH-1:0]  ic_req_addr;      // fetch -> icache (pc_next)
    logic                   ic_resp_valid;    // icache -> fetch (hit for pc_q)
    logic [DATA_WIDTH-1:0]  ic_resp_data;

    logic                   rename_stall;
    logic                   rob_full;
    logic                   iq_full;
    logic                   issue_valid;
    logic                   branch_mispredict;
    logic [DATA_WIDTH-1:0]  redirect_pc;
    logic                   exception_valid;

    decode_rename_pkt_s     decode_out;
    rename_dispatch_pkt_s   rename_dispatch_out;
    rename_dispatch_pkt_s   issue_pkt;
    regread_execute_pkt_s   execute_out;

    regread_execute_pkt_s   regread_alu_in;
    regread_execute_pkt_s   regread_mul_in;
    regread_execute_pkt_s   regread_div_in;
    regread_execute_pkt_s   regread_branch_in;
    regread_execute_pkt_s   regread_lsu_in;

    logic [ROB_PTR-1:0] rob_tag_out;
    logic [ROB_PTR-1:0] issue_rob_tag;

    logic                       commit_fire_i;
    logic [REG_ADDR_WIDTH-1:0]  commit_rd_e_i;
    logic [TAG_WIDTH-1:0]       commit_pd_e_i;
    logic [TAG_WIDTH-1:0]       commit_old_pd_e_i;
    logic [ROB_PTR-1:0]         rob_head_tag;
    execute_wb_pkt_s    alu_wb;
    execute_wb_pkt_s    mul_wb;
    execute_wb_pkt_s    div_wb;
    execute_wb_pkt_s    lsu_wb;
    branch_wb_pkt_s     branch_wb;

    logic   div_ready;
    logic   lsu_ready;
    logic                   sb_store_commit;
    logic                   sb_can_accept;
    logic                   sb_empty;
    logic                   sb_enq_valid;
    logic [DATA_WIDTH-1:0]  sb_enq_addr, sb_enq_wdata;
    logic [3:0]             sb_enq_wstrb;
    logic [DATA_WIDTH-1:0]  sb_ld_addr, sb_ld_fwd_data;
    logic [3:0]             sb_ld_mask;
    logic                   sb_ld_hit, sb_ld_fwd_ok;
    logic                   sb_drain_valid, sb_drain_pop;
    logic [DATA_WIDTH-1:0]  sb_drain_addr, sb_drain_wdata;
    logic [3:0]             sb_drain_wstrb;

    // LSU (load) side of the memory port, before arbitration
    logic                       lsu_req_valid, lsu_req_ready;
    logic                   dc_req_valid, dc_req_we, dc_req_ready;
    logic [DATA_WIDTH-1:0]  dc_req_addr, dc_req_wdata;
    logic [3:0]             dc_req_wstrb;
    logic                   dc_resp_valid;
    logic [DATA_WIDTH-1:0]  dc_resp_rdata;
    logic [DATA_WIDTH-1:0]      lsu_req_addr;
    logic [DATA_WIDTH-1:0]    fetch_predicted_pc;
    logic [NUM_CDB_PORTS-1:0] cdb_valid_i;
    logic [NUM_CDB_PORTS-1:0] cdb_mispredict_i;
    logic [NUM_CDB_PORTS-1:0] cdb_exception_i;
    logic [NUM_CDB_PORTS-1:0] cdb_reg_we_i;
    logic [TAG_WIDTH-1:0]     cdb_p_dest_i [NUM_CDB_PORTS];
    logic [ROB_PTR-1:0]       cdb_rob_tag_i [NUM_CDB_PORTS];
    logic [TAG_WIDTH-1:0]     cdb_tag_i    [NUM_CDB_PORTS];
    logic [DATA_WIDTH-1:0]    cdb_data_i   [NUM_CDB_PORTS];
    logic [DATA_WIDTH-1:0]    cdb_target_pc_i [NUM_CDB_PORTS];
    except_cause_e            cdb_cause_i [NUM_CDB_PORTS];
    logic [NUM_CDB_PORTS-1:0] wb_en_i;
    logic [TAG_WIDTH-1:0]     wb_tag_i [NUM_CDB_PORTS];
    logic [DATA_WIDTH-1:0]    wb_data_i [NUM_CDB_PORTS];

    // ALU CDB port
    assign cdb_valid_i      [CDB_PORT_ALU]  =   alu_wb.valid;
    assign cdb_p_dest_i     [CDB_PORT_ALU]  =   alu_wb.p_dest;
    assign cdb_rob_tag_i    [CDB_PORT_ALU]  =   alu_wb.rob_tag;
    assign cdb_tag_i        [CDB_PORT_ALU]  =   alu_wb.p_dest;
    assign cdb_data_i       [CDB_PORT_ALU]  =   alu_wb.result;
    assign cdb_reg_we_i     [CDB_PORT_ALU]  =   alu_wb.reg_we;
    assign cdb_exception_i  [CDB_PORT_ALU]  =   alu_wb.except;
    assign cdb_cause_i      [CDB_PORT_ALU]  =   alu_wb.except_cause;
    assign cdb_mispredict_i [CDB_PORT_ALU]  =   1'b0;
    assign cdb_target_pc_i  [CDB_PORT_ALU]  =   '0;

    // MUL CDB port
    assign cdb_valid_i      [CDB_PORT_MUL]  =   mul_wb.valid;
    assign cdb_p_dest_i     [CDB_PORT_MUL]  =   mul_wb.p_dest;
    assign cdb_rob_tag_i    [CDB_PORT_MUL]  =   mul_wb.rob_tag;
    assign cdb_tag_i        [CDB_PORT_MUL]  =   mul_wb.p_dest;
    assign cdb_data_i       [CDB_PORT_MUL]  =   mul_wb.result;
    assign cdb_reg_we_i     [CDB_PORT_MUL]  =   mul_wb.reg_we;
    assign cdb_exception_i  [CDB_PORT_MUL]  =   mul_wb.except;
    assign cdb_cause_i      [CDB_PORT_MUL]  =   mul_wb.except_cause;
    assign cdb_mispredict_i [CDB_PORT_MUL]  =   1'b0;
    assign cdb_target_pc_i  [CDB_PORT_MUL]  =   '0;

    // DIV CDB port
    assign cdb_valid_i      [CDB_PORT_DIV]  =   div_wb.valid;
    assign cdb_p_dest_i     [CDB_PORT_DIV]  =   div_wb.p_dest;
    assign cdb_rob_tag_i    [CDB_PORT_DIV]  =   div_wb.rob_tag;
    assign cdb_tag_i        [CDB_PORT_DIV]  =   div_wb.p_dest;
    assign cdb_data_i       [CDB_PORT_DIV]  =   div_wb.result;
    assign cdb_reg_we_i     [CDB_PORT_DIV]  =   div_wb.reg_we;
    assign cdb_exception_i  [CDB_PORT_DIV]  =   div_wb.except;
    assign cdb_cause_i      [CDB_PORT_DIV]  =   div_wb.except_cause;
    assign cdb_mispredict_i [CDB_PORT_DIV]  =   1'b0;
    assign cdb_target_pc_i  [CDB_PORT_DIV]  =   '0;

    // BRANCH CDB port — the only source of a real mispredict/target signal.
    assign cdb_valid_i      [CDB_PORT_BRANCH]   =   branch_wb.valid;
    assign cdb_p_dest_i     [CDB_PORT_BRANCH]   =   branch_wb.p_dest;
    assign cdb_rob_tag_i    [CDB_PORT_BRANCH]   =   branch_wb.rob_tag;
    assign cdb_tag_i        [CDB_PORT_BRANCH]   =   branch_wb.p_dest;
    assign cdb_data_i       [CDB_PORT_BRANCH]   =   branch_wb.result;
    assign cdb_reg_we_i     [CDB_PORT_BRANCH]   =   branch_wb.reg_we;
    assign cdb_exception_i  [CDB_PORT_BRANCH]   =   branch_wb.except;
    assign cdb_cause_i      [CDB_PORT_BRANCH]   =   branch_wb.except_cause;
    assign cdb_mispredict_i [CDB_PORT_BRANCH]   =   branch_wb.mispredict;
    assign cdb_target_pc_i  [CDB_PORT_BRANCH]   =   branch_wb.target_pc;

    // LSU CDB port
    assign cdb_valid_i      [CDB_PORT_LSU]      =   lsu_wb.valid;
    assign cdb_p_dest_i     [CDB_PORT_LSU]      =   lsu_wb.p_dest;
    assign cdb_rob_tag_i    [CDB_PORT_LSU]      =   lsu_wb.rob_tag;
    assign cdb_tag_i        [CDB_PORT_LSU]      =   lsu_wb.p_dest;
    assign cdb_data_i       [CDB_PORT_LSU]      =   lsu_wb.result;
    assign cdb_reg_we_i     [CDB_PORT_LSU]      =   lsu_wb.reg_we;
    assign cdb_exception_i  [CDB_PORT_LSU]      =   lsu_wb.except;
    assign cdb_cause_i      [CDB_PORT_LSU]      =   lsu_wb.except_cause;
    assign cdb_mispredict_i [CDB_PORT_LSU]      =   1'b0;
    assign cdb_target_pc_i  [CDB_PORT_LSU]      =   '0;

    always_comb begin
        for (int p = 0; p < NUM_CDB_PORTS; p++) begin
            wb_en_i[p]  = cdb_valid_i[p] && cdb_reg_we_i[p] && !cdb_exception_i[p];
            wb_tag_i[p] = cdb_p_dest_i[p];
            wb_data_i[p] = cdb_data_i[p];
        end
    end

    // Fetch / Decode
    logic redirect_valid_i;
    assign redirect_valid_i = branch_mispredict | exception_valid;

    fetch_unit u_fetch (
        .clk                (clk),
        .rst_n              (rst_n),
        .stall              (rename_stall),
        .redirect_valid     (redirect_valid_i),
        .redirect_pc        (redirect_pc),
        .fetch_pc           (fetch_pc),
        .imem_addr          (ic_req_addr),
        .imem_valid         (ic_resp_valid),
        .imem_rdata         (ic_resp_data),
        .fetch_predicted_pc (fetch_predicted_pc),
        .fetch_instr        (fetch_instr),
        .fetch_valid        (fetch_valid),
        .bp_update_valid    (branch_wb.valid && !branch_wb.except),
        .bp_update_pc       (branch_wb.pc),
        .bp_update_taken    (branch_wb.taken),
        .bp_update_target   (branch_wb.target_pc)
    );
    icache u_icache (
        .clk                (clk),
        .rst_n              (rst_n),
        .invalidate         (1'b0),             // no FENCE.I support yet
        .req_addr           (ic_req_addr),
        .resp_valid         (ic_resp_valid),
        .resp_data          (ic_resp_data),
        .mem_req_valid      (imem_req_valid),
        .mem_req_ready      (imem_req_ready),
        .mem_req_addr       (imem_req_addr),
        .mem_resp_valid     (imem_resp_valid),
        .mem_resp_data      (imem_resp_data),
        .mem_resp_last      (imem_resp_last)
    );

    decode_unit u_decode (
        .clk                (clk),
        .rst_n              (rst_n),
        .stall              (rename_stall),
        .flush              (redirect_valid_i),
        .fetch_pc           (fetch_pc),
        .fetch_instr        (fetch_instr),
        .fetch_valid        (fetch_valid),
        .fetch_predicted_pc (fetch_predicted_pc),
        .decode_out         (decode_out)
    );

    
    // Rename / Dispatch into both ROB and IQ
    rename_unit u_rename (
        .clk                  (clk),
        .rst_n                (rst_n),
        .decode_rename_in     (decode_out),
        .branch_mispredict    (branch_mispredict),
        .exception_valid      (exception_valid),
        .cdb_valid            (cdb_valid_i),
        .rob_full             (rob_full),
        .iq_full              (iq_full),
        .cdb_p_dest           (cdb_p_dest_i),
        .commit_fire          (commit_fire_i),
        .commit_rd            (commit_rd_e_i),
        .commit_pd            (commit_pd_e_i),
        .commit_old_pd        (commit_old_pd_e_i),
        .rename_stall         (rename_stall),
        .rename_dispatch_out  (rename_dispatch_out)
    );

    // ROB allocation and IQ insertion are the same architectural dispatch
    // event. Both consume the same renamed packet and ROB tag.
    reorder_buffer u_rob (
        .clk                (clk),
        .rst_n              (rst_n),
        .dispatch_in        (rename_dispatch_out),
        .iq_full            (iq_full),
        .rob_tag_out        (rob_tag_out),
        .rob_head_tag       (rob_head_tag),
        .rob_full           (rob_full),
        .cdb_valid          (cdb_valid_i),
        .cdb_rob_tag        (cdb_rob_tag_i),
        .cdb_mispredict     (cdb_mispredict_i),
        .cdb_target_pc      (cdb_target_pc_i),
        .cdb_exception      (cdb_exception_i),
        .cdb_cause          (cdb_cause_i),
        .commit_valid       (),
        .commit_rd          (),
        .commit_pd          (),
        .commit_old_pd      (),
        .commit_fire        (commit_fire_i),
        .commit_rd_e        (commit_rd_e_i),
        .commit_pd_e        (commit_pd_e_i),
        .commit_old_pd_e    (commit_old_pd_e_i),
        .store_commit       (sb_store_commit),
        .branch_mispredict  (branch_mispredict),
        .exception_valid    (exception_valid),
        .redirect_pc        (redirect_pc),
        .exception_cause    (),
        .exception_pc       ()
    );

    // Issue Queue
    issue_queue u_issue (
        .clk                (clk),
        .rst_n              (rst_n),
        .dispatch_in        (rename_dispatch_out),
        .dispatch_rob_tag   (rob_tag_out),
        .rob_full           (rob_full),
        .iq_full            (iq_full),
        .cdb_valid          (cdb_valid_i),
        .cdb_p_dest         (cdb_p_dest_i),
        .branch_mispredict  (branch_mispredict),
        .exception_valid    (exception_valid),
        .div_ready          (div_ready),
        .lsu_ready          (lsu_ready),
        .sb_can_accept      (sb_can_accept),
        .issue_valid        (issue_valid),
        .issue_pkt          (issue_pkt),
        .issue_rob_tag      (issue_rob_tag)
    );

    // Register Read / operand bypass
    register_read u_regread (
        .clk             (clk),
        .rst_n           (rst_n),
        .dispatch_in     (issue_pkt),
        .flush           (redirect_valid_i),
        .dispatch_rob_tag(issue_rob_tag),
        .cdb_tag         (cdb_p_dest_i),
        .cdb_valid       (cdb_valid_i),
        .wb_en           (wb_en_i),
        .wb_tag          (wb_tag_i),
        .wb_data         (wb_data_i),
        .execute_out     (execute_out)
    );

    regread_demux u_regread_demux (
        .execute_in       (execute_out),
        .regread_alu_out  (regread_alu_in),
        .regread_mul_out  (regread_mul_in),
        .regread_div_out  (regread_div_in),
        .regread_branch_out(regread_branch_in),
        .regread_lsu_out  (regread_lsu_in)
    );

    // Execute
    alu u_alu (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (redirect_valid_i),
        .regread_in (regread_alu_in),
        .alu_wb_out (alu_wb)
    );

    mul u_mul (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (redirect_valid_i),
        .regread_in (regread_mul_in),
        .mul_wb_out (mul_wb)
    );

    div u_div (
        .clk        (clk),
        .rst_n      (rst_n),
        .flush      (redirect_valid_i),
        .regread_in (regread_div_in),
        .div_wb_out (div_wb),
        .div_ready  (div_ready)
    );

    branch u_branch (
        .clk           (clk),
        .rst_n         (rst_n),
        .flush         (redirect_valid_i),
        .regread_in    (regread_branch_in),
        .branch_wb_out (branch_wb)
    );

   lsu u_lsu (
        .clk            (clk),
        .rst_n          (rst_n),
        .flush          (redirect_valid_i),
        .regread_in     (regread_lsu_in),
        .lsu_ready      (lsu_ready),
        .lsu_wb_out     (lsu_wb),
        .sb_enq_valid   (sb_enq_valid),
        .sb_enq_addr    (sb_enq_addr),
        .sb_enq_wdata   (sb_enq_wdata),
        .sb_enq_wstrb   (sb_enq_wstrb),
        .sb_ld_addr     (sb_ld_addr),
        .sb_ld_mask     (sb_ld_mask),
        .sb_ld_hit      (sb_ld_hit),
        .sb_ld_fwd_ok   (sb_ld_fwd_ok),
        .sb_ld_fwd_data (sb_ld_fwd_data),
        .mem_req_valid  (lsu_req_valid),
        .mem_req_addr   (lsu_req_addr),
        .mem_req_ready  (lsu_req_ready),
        .mem_resp_valid (dc_resp_valid),
        .mem_resp_rdata (dc_resp_rdata)
    );
    store_buffer #(.DEPTH(8), .SLACK(2)) u_sb (
        .clk          (clk),
        .rst_n        (rst_n),
        .enq_valid    (sb_enq_valid),
        .enq_addr     (sb_enq_addr),
        .enq_wdata    (sb_enq_wdata),
        .enq_wstrb    (sb_enq_wstrb),
        .store_commit (sb_store_commit),
        .flush        (redirect_valid_i),
        .drain_pop    (sb_drain_pop),
        .can_accept   (sb_can_accept),
        .drain_valid  (sb_drain_valid),
        .drain_addr   (sb_drain_addr),
        .drain_wdata  (sb_drain_wdata),
        .drain_wstrb  (sb_drain_wstrb),
        .empty        (sb_empty),
        .ld_addr      (sb_ld_addr),
        .ld_mask      (sb_ld_mask),
        .ld_hit       (sb_ld_hit),
        .ld_fwd_ok    (sb_ld_fwd_ok),
        .ld_fwd_data  (sb_ld_fwd_data)
    );
    logic sb_lock_q, sel_sb;
    assign sel_sb        = sb_drain_valid & (sb_lock_q | ~lsu_req_valid);

    assign dc_req_valid = sel_sb | lsu_req_valid;
    assign dc_req_we    = sel_sb;
    assign dc_req_addr  = sel_sb ? sb_drain_addr  : lsu_req_addr;
    assign dc_req_wdata = sb_drain_wdata;                         // don't-care for reads
    assign dc_req_wstrb = sel_sb ? sb_drain_wstrb : 4'b0000;
    assign lsu_req_ready = dc_req_ready & ~sel_sb;
    assign sb_drain_pop  = dc_req_ready &  sel_sb;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sb_lock_q <= 1'b0;
        else        sb_lock_q <= sel_sb & ~dc_req_ready;
    end

    dcache u_dcache (
        .clk            (clk),
        .rst_n          (rst_n),
        // core side
        .req_valid      (dc_req_valid),
        .req_we         (dc_req_we),
        .req_addr       (dc_req_addr),
        .req_wdata      (dc_req_wdata),
        .req_wstrb      (dc_req_wstrb),
        .req_ready      (dc_req_ready),
        .resp_valid     (dc_resp_valid),
        .resp_rdata     (dc_resp_rdata),
        // backing store
        .mem_req_valid  (dmem_req_valid),
        .mem_req_ready  (dmem_req_ready),
        .mem_req_we     (dmem_req_we),
        .mem_req_addr   (dmem_req_addr),
        .mem_req_wdata  (dmem_req_wdata),
        .mem_req_wstrb  (dmem_req_wstrb),
        .mem_resp_valid (dmem_resp_valid),
        .mem_resp_data  (dmem_resp_data),
        .mem_resp_last  (dmem_resp_last)
    );
endmodule

