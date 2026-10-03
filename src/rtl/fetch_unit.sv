import orion_pkg::*;

module fetch_unit #(
    parameter int   BTB_ENTRIES     = 16,
    parameter int   PHT_ENTRIES     = 64
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Backpressure from rename (free list empty)
    input  logic                    stall,

    // Redirect from ROB commit-time misprediction / exception resolution
    input  logic                    redirect_valid,
    input  logic [DATA_WIDTH-1:0]   redirect_pc,
    // I-cache interface
    input  logic [DATA_WIDTH-1:0]   imem_rdata,
    input  logic                    imem_valid,
    output logic [DATA_WIDTH-1:0]  imem_addr,
    // Branch Predictor state update signals from branch unit 
    input  logic                    bp_update_valid,
    input  logic [DATA_WIDTH-1:0]   bp_update_pc,
    input  logic                    bp_update_taken,
    input  logic [DATA_WIDTH-1:0]   bp_update_target,
    // To Decode
    output logic [DATA_WIDTH-1:0]   fetch_pc,
    output logic [DATA_WIDTH-1:0]   fetch_instr,
    output logic                    fetch_valid,
    output logic [DATA_WIDTH-1:0]   fetch_predicted_pc
);

    // Word-addressable instruction memory. Hierarchical access (imem) is
    // intentionally left non-local so a testbench can preload it directly
    // via `dut.imem[i] = ...` without needing a hex file for quick bring-up.
    logic [DATA_WIDTH-1:0] pc_q;
    logic [DATA_WIDTH-1:0] pc_next;
    assign imem_addr    = pc_next;
    localparam int BTB_IDX_W = $clog2(BTB_ENTRIES);
    localparam int BTB_TAG_W = DATA_WIDTH - 2 - BTB_IDX_W;
    localparam int PHT_IDX_W = $clog2(PHT_ENTRIES);

    logic                   btb_valid   [BTB_ENTRIES];
    logic [BTB_TAG_W-1:0]   btb_tag     [BTB_ENTRIES];
    logic [DATA_WIDTH-1:0]  btb_target  [BTB_ENTRIES];
    logic [1:0]             pht         [PHT_ENTRIES];

    logic [BTB_IDX_W-1:0]   btb_rd_idx;
    logic [BTB_TAG_W-1:0]   btb_rd_tag;
    logic [PHT_IDX_W-1:0]   pht_rd_idx;
    logic                   btb_hit;
    logic                   pred_taken;
    logic [DATA_WIDTH-1:0]  pred_pc;
    assign btb_rd_idx = pc_q[2 +: BTB_IDX_W];
    assign btb_rd_tag = pc_q[DATA_WIDTH-1 -: BTB_TAG_W];
    assign pht_rd_idx = pc_q[2 +: PHT_IDX_W];

    always_comb begin
        btb_hit    = btb_valid[btb_rd_idx] && (btb_tag[btb_rd_idx] == btb_rd_tag);
        pred_taken = btb_hit && pht[pht_rd_idx][1];
        pred_pc    = pred_taken ? btb_target[btb_rd_idx] : (pc_q + 32'd4);
    end

    logic [BTB_IDX_W-1:0]   btb_wr_idx;
    logic [BTB_TAG_W-1:0]   btb_wr_tag;
    logic [PHT_IDX_W-1:0]   pht_wr_idx;

    assign btb_wr_idx = bp_update_pc[2 +: BTB_IDX_W];
    assign btb_wr_tag = bp_update_pc[DATA_WIDTH-1 -: BTB_TAG_W];
    assign pht_wr_idx = bp_update_pc[2 +: PHT_IDX_W];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < BTB_ENTRIES; i++) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= '0;
                btb_target[i] <= '0;
            end
            for (int i = 0; i < PHT_ENTRIES; i++)
                pht[i] <= 2'b01;                       // weakly not-taken
        end else if (bp_update_valid) begin
            if (bp_update_taken) begin
                btb_valid [btb_wr_idx] <= 1'b1;
                btb_tag   [btb_wr_idx] <= btb_wr_tag;
                btb_target[btb_wr_idx] <= bp_update_target;
                if (pht[pht_wr_idx] != 2'b11)
                    pht[pht_wr_idx] <= pht[pht_wr_idx] + 2'd1;
            end else begin
                if (pht[pht_wr_idx] != 2'b00)
                    pht[pht_wr_idx] <= pht[pht_wr_idx] - 2'd1;
            end
        end
    end

    always_comb begin
        if(!rst_n) begin
            pc_next = '0;
        end else if (redirect_valid)
            pc_next = redirect_pc;
        else if (stall || !imem_valid)
            pc_next = pc_q;
        else
            pc_next = pred_pc;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q        <= '0;
            fetch_pc    <= '0;
            fetch_instr <= '0;
            fetch_valid <= 1'b0;
            fetch_predicted_pc <= '0;
        end else begin
            pc_q <= pc_next;
            // `ifdef DEBUG 
            //     if (stall) begin
            //         $display("FETCH: stall=1 at time %t, pc_q=%h, pc_next=%h", $time, pc_q, pc_next);
            //     end else begin
            //         $display("FETCH: stall=0 at time %t, pc_q=%h, pc_next=%h", $time, pc_q, pc_next);
            //     end
            // `endif
            
            if (redirect_valid) begin
                // Bubble the cycle a redirect lands; the instruction fetched
                // this cycle was on the wrong path and shouldn't be decoded.
                fetch_valid         <= 1'b0;
                fetch_pc            <= '0;
                fetch_instr         <= '0;
                fetch_predicted_pc  <= '0;
            end else if (stall) begin
                // Hold current outputs steady (do not re-fetch / do not clear)
                fetch_valid         <= fetch_valid;
                fetch_pc            <= fetch_pc;
                fetch_instr         <= fetch_instr;
                fetch_predicted_pc  <= fetch_predicted_pc;
            end else if(!imem_valid) begin 
                fetch_valid         <= 1'b0;
                fetch_pc            <= '0;
                fetch_instr         <= '0;
                fetch_predicted_pc  <= '0;
            end else begin
                fetch_valid         <= 1'b1;
                fetch_pc            <= pc_q;
                fetch_instr         <= imem_rdata;
                fetch_predicted_pc  <= pred_pc;
            end
        end
    end

endmodule
