`timescale 1ns/1ps

import orion_pkg::*;
module icache(
    input  logic     clk,
    input  logic     rst_n,
    input  logic     invalidate,

    //core side interface
    input  logic [ADDR_WIDTH-1:0]   req_addr,
    output logic                    resp_valid,
    output logic [DATA_WIDTH-1:0]   resp_data,

    // Backing-store side (read only)
    output logic                    mem_req_valid,
    input  logic                    mem_req_ready,
    output logic [ADDR_WIDTH-1:0]   mem_req_addr,
    input  logic                    mem_resp_valid,
    input  logic [31:0]             mem_resp_data,
    input  logic                    mem_resp_last
);
    localparam int SETS         = 128;
    localparam int LINE_WORDS   = 8;
    localparam int IDX_W        = $clog2(SETS);         // 7
    localparam int WORD_W       = $clog2(LINE_WORDS);   // 3
    localparam int OFF_W        = WORD_W + 2;           // 5
    localparam int TAG_W        = ADDR_WIDTH - IDX_W - OFF_W;  // 20
    
    typedef enum logic [1:0] { S_IDLE, S_REFILL_REQ, S_REFILL_DATA } state_e;
    state_e state;
 
    //lookup state regs
    logic [ADDR_WIDTH-1:0] addr_q;      // address whose read is in flight
    logic                  lookup_q;
    logic [IDX_W-1:0]  idx_q;
    logic [TAG_W-1:0]  tag_q;
    assign idx_q = addr_q[OFF_W +: IDX_W];
    assign tag_q = addr_q[ADDR_WIDTH-1 -: TAG_W];
    
    logic [SETS-1:0] valid;
    logic                       data_en, data_we;
    logic [IDX_W+WORD_W-1:0]    data_addr;
    logic [31:0]                data_din, data_dout;

    logic               tag_en, tag_we;
    logic [IDX_W-1:0]   tag_addr;
    logic [TAG_W-1:0]   tag_din, tag_dout;

    sram_1rw #(
        .MACRO_ID(0),
        .WIDTH(32),
        .DEPTH(SETS*LINE_WORDS),
        .WMASK_W(1)
    ) 
    u_data (
        .clk(clk),
        .en(data_en),
        .we(data_we),
        .wmask(1'b1),
        .addr(data_addr),
        .din(data_din),
        .dout(data_dout)
    );
 
    sram_1rw #(
        .MACRO_ID(1),
        .WIDTH(TAG_W),
        .DEPTH(SETS),
        .WMASK_W(1)
    )
    u_tag (
        .clk(clk),
        .en(tag_en),
        .we(tag_we),
        .wmask(1'b1),
        .addr(tag_addr),
        .din(tag_din),
        .dout(tag_dout)
    );
    logic hit, miss_now;
    assign hit      = lookup_q & valid[idx_q] & (tag_dout == tag_q);
    assign miss_now = lookup_q & ~hit;
    
    assign resp_valid   = hit;
    assign resp_data    = hit ? data_dout : 32'h0;

    logic [ADDR_WIDTH-1:0] miss_addr;
    logic [WORD_W-1:0]     beat_q;
    logic [IDX_W-1:0]      miss_idx;
    logic [TAG_W-1:0]      miss_tag;
    assign miss_idx = miss_addr[OFF_W +: IDX_W];
    assign miss_tag = miss_addr[ADDR_WIDTH-1 -: TAG_W];
    
    assign mem_req_valid = (state == S_REFILL_REQ);
    assign mem_req_addr  = {miss_addr[ADDR_WIDTH-1:OFF_W], {OFF_W{1'b0}}};

    logic rd_issue;
    assign rd_issue = (state == S_IDLE) & ~miss_now;
 
    logic beat_wr;
    assign beat_wr = (state == S_REFILL_DATA) & mem_resp_valid;

    always_comb begin
        data_en   = rd_issue | beat_wr;
        data_we   = beat_wr;
        data_addr = beat_wr ? {miss_idx, beat_q} : req_addr[2 +: IDX_W+WORD_W];  // addr[11:2]
        data_din  = mem_resp_data;
        
        tag_en    = rd_issue | (beat_wr & mem_resp_last);
        tag_we    = beat_wr & mem_resp_last;
        tag_addr  = tag_we ? miss_idx : req_addr[OFF_W +: IDX_W];
        tag_din   = miss_tag;
    end

    //Cache FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            lookup_q  <= 1'b0;
            addr_q    <= '0;
            miss_addr <= '0;
            beat_q    <= '0;
            valid     <= '0;
        end else begin
            lookup_q <= rd_issue;
        if (rd_issue) addr_q <= req_addr;
        if (invalidate) valid <= '0;
        unique case (state)
            S_IDLE: begin
            if (miss_now) begin
                    miss_addr        <= addr_q;
                    valid[idx_q]     <= 1'b0;        // victim line is about to be overwritten
                    state            <= S_REFILL_REQ;
                end
            end
 
            S_REFILL_REQ: begin
                beat_q <= '0;
                if (mem_req_ready) state <= S_REFILL_DATA;
            end
 
            S_REFILL_DATA: begin
                if (mem_resp_valid) begin
                    beat_q <= beat_q + 1'b1;
                    if (mem_resp_last) begin
                        valid[miss_idx] <= 1'b1;
                        state           <= S_IDLE;
                    end
                end
            end
 
        default: state <= S_IDLE;
      endcase
    end
  end


endmodule
