`timescale 1ns/1ps
import orion_pkg::*;

module store_buffer #(parameter int DEPTH = 8, parameter int SLACK = 2) (
  input logic           clk,
  input logic           rst_n,
  input logic           enq_valid,              // LSU accept cycle, stores only
  input logic [31:0]    enq_addr,
  input logic [31:0]    enq_wdata,
  input logic [3:0]     enq_wstrb,
  input  logic          store_commit,           // from ROB
  input  logic          flush,                  // branch_mispredict | exception_valid
  input  logic          drain_pop,              // memory accepted it
  output logic          can_accept,             // free entries > SLACK
  output logic          drain_valid,            // head entry is committed
  output logic [31:0]   drain_addr, drain_wdata,
  output logic [3:0]    drain_wstrb,
  output logic          empty,                   // rd == wr
  input  logic [31:0]   ld_addr,
  input  logic [3:0]    ld_mask,                // byte lanes the load needs
  output logic          ld_hit,                 // some entry hits the same word
  output logic          ld_fwd_ok,              // youngest hit covers ld_mask
  output logic [31:0]   ld_fwd_data 
);
  localparam int PW = $clog2(DEPTH);
  logic [31:0]    mem_addr [DEPTH];
  logic [31:0]    mem_data [DEPTH];
  logic [3:0]     mem_strb [DEPTH];
  logic [PW:0]    rd, cm, wr;      // one extra wrap bit each
  logic [PW:0]    used;

  assign used        = wr - rd;
  assign empty       = (rd == wr);
  assign drain_valid = (rd != cm);
  assign can_accept  = ((DEPTH - int'(used)) > SLACK);
 
  assign drain_addr  = mem_addr[rd[PW-1:0]];
  assign drain_wdata = mem_data[rd[PW-1:0]];
  assign drain_wstrb = mem_strb[rd[PW-1:0]];
  logic [PW-1:0] lk_idx;
  always_comb begin
    ld_hit      = 1'b0;
    ld_fwd_ok   = 1'b0;
    ld_fwd_data = '0;
    lk_idx      = '0;
    for (int k = 0; k < DEPTH; k++) begin
      lk_idx = rd[PW-1:0] + PW'(k);
      if (k < int'(used) && mem_addr[lk_idx][31:2] == ld_addr[31:2]) begin
        ld_hit      = 1'b1;
        ld_fwd_ok   = ((mem_strb[lk_idx] & ld_mask) == ld_mask);
        ld_fwd_data = mem_data[lk_idx];
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd <= '0;
        cm <= '0;
        wr <= '0;
    end else begin
        // Commit and pop are independent of flush
        cm <= cm + (PW+1)'(store_commit);
        rd <= rd + (PW+1)'(drain_pop);
        // Tail: flush wins and drops speculative entries only
        if (flush) begin
            wr <= cm + (PW+1)'(store_commit);
        end else if (enq_valid) begin
            mem_addr[wr[PW-1:0]] <= enq_addr;
            mem_data[wr[PW-1:0]] <= enq_wdata;
            mem_strb[wr[PW-1:0]] <= enq_wstrb;
            wr <= wr + 1'b1;
        end
    end
  end
 
  // Simulation-only sanity checks
  // always_ff @(posedge clk) begin
  //   if (rst_n) begin
  //     if (enq_valid && !flush && used == (PW+1)'(DEPTH))
  //       $error("[%m] store_buffer overflow: enqueue while full (SLACK too small?)");
  //     if (store_commit && (cm == wr))
  //       $error("[%m] store_commit with no uncommitted entry");
  //     if (drain_pop && !drain_valid)
  //       $error("[%m] drain_pop with no committed entry");
  //   end
  // end
endmodule