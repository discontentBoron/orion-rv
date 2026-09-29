`timescale 1ns / 1ps
import orion_pkg::*;
//TODO: Fix to support updated modules. Lot of changes in module to fix
// =============================================================================
// fdr_rob_top.sv — Orion integration slice: Fetch -> Decode -> Rename -> ROB
//
// Purpose: joint test of the one real coupling point among these four blocks
// before wiring the full 8-stage core — rename_stall backpressure into fetch,
// and the real rob_full / commit_* handshake between rename_unit and
// reorder_buffer. No IQ, no register_read, no execute units exist yet.
//
// Since there is no IQ and no execute backend, this wrapper exposes a fake
// CDB interface (cdb_*) driven directly by the testbench, standing in for
// "some execute unit finished." This is the ONLY hand-driven stimulus needed
// downstream of dispatch — commit_valid/commit_rd/commit_pd/commit_old_pd
// into rename_unit are REAL reorder_buffer outputs in this wrapper, not
// stubbed, unlike the earlier two-stage-only version of this test.
//
// iq_full is tied low everywhere (no IQ exists yet) — both reorder_buffer's
// dispatch-gating iq_full input and rename_unit's own iq_full input.
//
// Not yet simulated. Instance names below (u_fetch, u_decode, u_rename,
// u_rob) are chosen deliberately so the testbench can reach internal
// signals not exposed as ports (e.g. u_fetch.imem[], u_rename.free_list_head,
// u_rename.free_list_tail, u_rename.free_list_empty) via hierarchical
// reference — the same convention fetch_unit.sv's own header comment
// documents for imem preload.
// =============================================================================

module fdr_rob_top #(
    parameter int IMEM_DEPTH = 256
) (
    input  logic clk,
    input  logic rst_n,

    // ---- Fake CDB stimulus (testbench-driven "execute unit completed") ----
    input  logic [NUM_CDB_PORTS-1:0]   cdb_valid,
    input  logic [ROB_PTR-1:0]         cdb_rob_tag   [NUM_CDB_PORTS],
    input  logic [TAG_WIDTH-1:0]       cdb_p_dest    [NUM_CDB_PORTS],
    input  logic [NUM_CDB_PORTS-1:0]   cdb_mispredict,
    input  logic [DATA_WIDTH-1:0]      cdb_target_pc [NUM_CDB_PORTS],
    input  logic [NUM_CDB_PORTS-1:0]   cdb_exception,
    input  except_cause_e              cdb_cause     [NUM_CDB_PORTS],

    // ---- Observability (also reachable hierarchically if more is needed) ----
    output logic [DATA_WIDTH-1:0]   fetch_pc,
    output logic [DATA_WIDTH-1:0]   fetch_instr,
    output logic                    fetch_valid,

    output rename_dispatch_pkt_s    rename_dispatch_out,
    output logic                    rename_stall,

    output logic [ROB_PTR-1:0]      rob_tag_out,
    output logic                    rob_full,

    output logic                    commit_valid,
    output logic [REG_ADDR_WIDTH-1:0] commit_rd,
    output logic [TAG_WIDTH-1:0]    commit_pd,
    output logic [TAG_WIDTH-1:0]    commit_old_pd,

    output logic                    branch_mispredict,
    output logic                    exception_valid
);

    logic iq_full_tie;
    assign iq_full_tie = 1'b0;
    logic redirect_valid_i;
    logic [DATA_WIDTH-1:0] redirect_pc_i;
    assign redirect_valid_i = branch_mispredict | exception_valid;

    decode_rename_pkt_s decode_out_i;

    // Unused reorder_buffer outputs in this slice, still wired so the
    // instance is complete and nothing is left dangling.
    logic store_commit_i;
    except_cause_e exception_cause_i;
    logic [DATA_WIDTH-1:0] exception_pc_i;

    // Early (combinational) commit path, one cycle ahead of commit_valid,
    // used only for the rename unit's free-list reclaim so it releases the
    // physical register the same cycle rob_full clears.
    logic                    commit_fire_i;
    logic [REG_ADDR_WIDTH-1:0] commit_rd_e_i;
    logic [TAG_WIDTH-1:0]    commit_pd_e_i;
    logic [TAG_WIDTH-1:0]    commit_old_pd_e_i;

    fetch_unit #(
        .IMEM_DEPTH(IMEM_DEPTH),
        .IMEM_INIT_FILE("")
    ) u_fetch (
        .clk            (clk),
        .rst_n          (rst_n),
        .stall          (rename_stall),
        .redirect_valid (redirect_valid_i),
        .redirect_pc    (redirect_pc_i),
        .fetch_pc       (fetch_pc),
        .fetch_instr    (fetch_instr),
        .fetch_valid    (fetch_valid)
    );

    decode_unit u_decode (
        .fetch_pc     (fetch_pc),
        .fetch_instr  (fetch_instr),
        .fetch_valid  (fetch_valid),
        .decode_out   (decode_out_i)
    );

    rename_unit u_rename (
        .clk                  (clk),
        .rst_n                (rst_n),
        .decode_rename_in     (decode_out_i),
        .branch_mispredict    (branch_mispredict),
        .exception_valid      (exception_valid),
        .cdb_valid            (cdb_valid),
        .rob_full             (rob_full),
        .iq_full              (iq_full_tie),
        .cdb_p_dest           (cdb_p_dest),
        .commit_fire          (commit_fire_i),
        .commit_rd            (commit_rd_e_i),
        .commit_pd            (commit_pd_e_i),
        .commit_old_pd        (commit_old_pd_e_i),
        .rename_stall         (rename_stall),
        .rename_dispatch_out  (rename_dispatch_out)
    );

    reorder_buffer u_rob (
        .clk                (clk),
        .rst_n              (rst_n),
        .dispatch_in        (rename_dispatch_out),
        .iq_full            (iq_full_tie),
        .rob_tag_out        (rob_tag_out),
        .rob_full           (rob_full),
        .cdb_valid          (cdb_valid),
        .cdb_rob_tag        (cdb_rob_tag),
        .cdb_mispredict     (cdb_mispredict),
        .cdb_target_pc      (cdb_target_pc),
        .cdb_exception      (cdb_exception),
        .cdb_cause          (cdb_cause),
        .commit_valid       (commit_valid),
        .commit_rd          (commit_rd),
        .commit_pd          (commit_pd),
        .commit_old_pd      (commit_old_pd),
        .commit_fire        (commit_fire_i),
        .commit_rd_e        (commit_rd_e_i),
        .commit_pd_e        (commit_pd_e_i),
        .commit_old_pd_e    (commit_old_pd_e_i),
        .store_commit       (store_commit_i),
        .branch_mispredict  (branch_mispredict),
        .exception_valid    (exception_valid),
        .redirect_pc        (redirect_pc_i),
        .exception_cause    (exception_cause_i),
        .exception_pc       (exception_pc_i)
    );

endmodule