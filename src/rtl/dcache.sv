`timescale 1ns/1ps
import orion_pkg::*;

module dcache(
    input   logic                   clk,
    input   logic                   rst_n,

    input   logic                   req_valid,
    input   logic                   req_we,
    input   logic [ADDR_WIDTH-1:0]  req_addr,
    input   logic [DATA_WIDTH-1:0]  req_wdata,
    input   logic [3:0]             req_wstrb,
    output  logic                   req_ready,
    output  logic                   resp_valid,
    output  logic [DATA_WIDTH-1:0]  resp_rdata,
    
    output  logic                   mem_req_valid,
    input   logic                   mem_req_ready,
    output  logic                   mem_req_we,
    output  logic [ADDR_WIDTH-1:0]  mem_req_addr,
    output  logic [DATA_WIDTH-1:0]  mem_req_wdata,
    output  logic [3:0]             mem_req_wstrb,
    input   logic                   mem_resp_valid,
    input   logic [DATA_WIDTH-1:0]  mem_resp_data,
    input   logic                   mem_resp_last
    );
    localparam int WAYS         = 2;
    localparam int SETS         = 64;
    localparam int LINE_WORDS   = 8;
    localparam int IDX_W        = $clog2(SETS);                 // 6
    localparam int WORD_W       = $clog2(LINE_WORDS);           // 3
    localparam int OFF_W        = WORD_W + 2;                   // 5
    localparam int TAG_W        = ADDR_WIDTH - IDX_W - OFF_W;   // 21
    localparam int DADDR_W      = IDX_W + WORD_W;

    typedef enum logic [2:0] {
        S_IDLE,          // accepting requests
        S_LOOKUP,        // load: compare, respond or miss
        S_REFILL_REQ,    // present line request to backing store
        S_REFILL_DATA,   // receive 8 beats
        S_RELOOK,        // re-read the line just filled
        S_ST_CMP,        // store: compare tags, register hit/way
        S_ST_WR,         // store: write-through + (hit) data macro write
        S_ST_DONE        // store: pulse req_ready
    } state_e;
    state_e state;
    
    logic [ADDR_WIDTH-1:0] addr_q;
    logic [DATA_WIDTH-1:0] wdata_q;
    logic [3:0]            wstrb_q;

    logic [IDX_W-1:0]  idx_q;
    logic [TAG_W-1:0]  tag_q;
    logic [WORD_W-1:0] word_q;
    assign idx_q    = addr_q[OFF_W +: IDX_W];
    assign tag_q    = addr_q[ADDR_WIDTH-1 -: TAG_W];
    assign word_q   = addr_q[2 +: WORD_W];

    logic [WAYS-1:0][SETS-1:0]  valid;
    logic [SETS-1:0]            lru;          // lru[set] = way to evict next
    logic                       miss_way_q;   // victim way of the refill in flight
    logic [WORD_W-1:0]          beat_q;
    logic                       st_hit_q, st_way_q, st_first_q;
    logic                       resp_valid_q;
    logic [DATA_WIDTH-1:0]      resp_rdata_q;

    logic [WAYS-1:0]            d_en, d_we, t_en, t_we;
    logic [3:0]                 d_wmask_c;
    logic [DADDR_W-1:0]         d_addr_c;
    logic [31:0]                d_din_c;
    logic [IDX_W-1:0]           t_addr_c;
    logic [TAG_W-1:0]           t_din_c;
    logic [WAYS-1:0][31:0]      d_dout;
    logic [WAYS-1:0][TAG_W-1:0] t_dout;

    for (genvar w = 0; w < WAYS; w++) begin : g_way
        sram_1rw #(.MACRO_ID(2), .WIDTH(32),    .DEPTH(SETS*LINE_WORDS), .WMASK_W(4)) u_data (
            .clk(clk), .en(d_en[w]), .we(d_we[w]), .wmask(d_wmask_c),
            .addr(d_addr_c), .din(d_din_c), .dout(d_dout[w])
        );

        sram_1rw #(.MACRO_ID(3), .WIDTH(TAG_W), .DEPTH(SETS),            .WMASK_W(1)) u_tag (
            .clk(clk), .en(t_en[w]), .we(t_we[w]), .wmask(1'b1),
            .addr(t_addr_c), .din(t_din_c), .dout(t_dout[w])
        );
    end
    logic [WAYS-1:0]    hit_w;
    logic               hit, hit_way;
    logic [31:0]        sel_data;

    always_comb begin
      for (int w = 0; w < WAYS; w++)
        hit_w[w] = valid[w][idx_q] & (t_dout[w] == tag_q);
    end
    assign hit      = |hit_w;
    assign hit_way  = hit_w[1];
    assign sel_data = hit_w[1] ? d_dout[1] : d_dout[0];

    logic victim_way;
    assign victim_way = !valid[0][idx_q] ? 1'b0 : !valid[1][idx_q] ? 1'b1 : lru[idx_q];
    
    logic accept, accept_ld, accept_st;
    assign accept       = (state == S_IDLE) & req_valid;
    assign accept_ld    = accept & ~req_we;
    assign accept_st    = accept &  req_we;

    // Loads: ready = idle (accepted). Stores: ready = completion pulse.
    assign req_ready    = req_we ? (state == S_ST_DONE) : (state == S_IDLE);
    assign resp_valid   = resp_valid_q;
    assign resp_rdata   = resp_rdata_q;

    logic rd_ld, rd_tag, refill_wr, last_wr, st_dw;
    assign rd_ld        = accept_ld | (state == S_RELOOK);   // data + tags, both ways
    assign rd_tag       = rd_ld | accept_st;                 // stores need tags only
    assign refill_wr    = (state == S_REFILL_DATA) & mem_resp_valid;
    assign last_wr      = refill_wr & mem_resp_last;
    assign st_dw        = (state == S_ST_WR) & st_first_q & st_hit_q;

    always_comb begin
        for (int w = 0; w < WAYS; w++) begin
            d_we[w] = (refill_wr & (miss_way_q == w)) | (st_dw & (st_way_q == w));
            d_en[w] = rd_ld | d_we[w];
            t_we[w] = last_wr & (miss_way_q == w);
            t_en[w] = rd_tag | t_we[w];
        end

        // read address comes from the live request in IDLE, the captured one after
        case (state)
            S_REFILL_DATA: d_addr_c = {idx_q, beat_q};
            S_ST_WR:       d_addr_c = {idx_q, word_q};
            S_IDLE:        d_addr_c = req_addr[2 +: DADDR_W];
            default:       d_addr_c = {idx_q, word_q};
        endcase
        t_addr_c    = (state == S_IDLE) ? req_addr[OFF_W +: IDX_W] : idx_q;
        d_wmask_c   = (state == S_ST_WR) ? wstrb_q : 4'hF;
        d_din_c     = (state == S_ST_WR) ? wdata_q : mem_resp_data;
        t_din_c     = tag_q;
    end

    assign mem_req_valid    = (state == S_REFILL_REQ) | (state == S_ST_WR);
    assign mem_req_we       = (state == S_ST_WR);
    assign mem_req_addr     = (state == S_ST_WR) ? {addr_q[ADDR_WIDTH-1:2], 2'b00}: {addr_q[ADDR_WIDTH-1:OFF_W], {OFF_W{1'b0}}};
    assign mem_req_wdata    = wdata_q;
    assign mem_req_wstrb    = wstrb_q;

    //FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            addr_q          <= '0;
            wdata_q         <= '0;
            wstrb_q         <= '0;
            valid           <= '0;
            lru             <= '0;
            miss_way_q      <= 1'b0;
            beat_q          <= '0;
            st_hit_q        <= 1'b0;
            st_way_q        <= 1'b0;
            st_first_q      <= 1'b0;
            resp_valid_q    <= 1'b0;
            resp_rdata_q    <= '0;
        end else begin
            resp_valid_q    <= 1'b0;                       // one-cycle pulse

            unique case (state)
                S_IDLE: if (accept) begin
                    addr_q  <= req_addr;
                    wdata_q <= req_wdata;
                    wstrb_q <= req_wstrb;
                    state   <= req_we ? S_ST_CMP : S_LOOKUP;
                end

                S_LOOKUP: begin
                    if (hit) begin
                        resp_valid_q <= 1'b1;
                        resp_rdata_q <= sel_data;
                        lru[idx_q]   <= ~hit_way;             // other way becomes LRU
                        state        <= S_IDLE;
                    end else begin
                        miss_way_q                <= victim_way;
                        valid[victim_way][idx_q]  <= 1'b0;    // victim is about to be overwritten
                        state                     <= S_REFILL_REQ;
                    end
                end

                S_REFILL_REQ: begin
                    beat_q <= '0;
                    if (mem_req_ready) state <= S_REFILL_DATA;
                end

                S_REFILL_DATA: if (mem_resp_valid) begin
                    beat_q <= beat_q + 1'b1;
                    if (mem_resp_last) begin
                        valid[miss_way_q][idx_q] <= 1'b1;
                        state                    <= S_RELOOK;
                    end
                end

                S_RELOOK: state <= S_LOOKUP;               // read issued this cycle

                S_ST_CMP: begin
                    st_hit_q   <= hit;
                    st_way_q   <= hit_way;
                    st_first_q <= 1'b1;
                    if (hit) lru[idx_q] <= ~hit_way;
                    state      <= S_ST_WR;
                end

                S_ST_WR: begin
                    st_first_q <= 1'b0;                      // data macro write is first cycle only
                    if (mem_req_ready) state <= S_ST_DONE;
                end

                S_ST_DONE: state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

