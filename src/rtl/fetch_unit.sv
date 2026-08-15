// =============================================================================
// fetch_unit.sv — Orion OOO RISC-V Processor
// Fetch Stage (Stage 1 of 8)
//
// Responsibilities:
//   1. Sequential PC generation (PC + 4), word-addressed instruction memory
//   2. Redirect on branch misprediction (from ROB / branch FU)
//   3. Stall on rename_stall (backpressure from the rename free-list)
//
// Scope note (explicitly limited for now):
//   - No branch predictor. Every instruction is fetched fall-through
//     (predicted_pc = pc + 4) and corrected via redirect on misprediction.
//     This is fine for straight-line test programs; anything with taken
//     branches will show every branch as a "mispredict" by construction,
//     which is expected, not a bug, until a predictor is added.
//   - No I-cache / memory interface. imem is a flat array loaded via
//     $readmemh, sized for early bring-up only.
//   - No fetch-side stall for rob_full / iq_full — only rename_stall is
//     wired in. If ROB/IQ back up independently of the free list, this
//     stage will currently keep fetching past that. Flagged, not fixed,
//     since dispatch-level backpressure doesn't exist yet either.
// =============================================================================

import orion_pkg::*;

module fetch_unit #(
    parameter int IMEM_DEPTH      = 256,          // words
    parameter      IMEM_INIT_FILE = ""             // optional $readmemh file
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Backpressure from rename (free list empty)
    input  logic                    stall,

    // Redirect from ROB commit-time misprediction / exception resolution
    input  logic                    redirect_valid,
    input  logic [DATA_WIDTH-1:0]   redirect_pc,

    // To Decode
    output logic [DATA_WIDTH-1:0]   fetch_pc,
    output logic [DATA_WIDTH-1:0]   fetch_instr,
    output logic                    fetch_valid
);

    // Word-addressable instruction memory. Hierarchical access (imem) is
    // intentionally left non-local so a testbench can preload it directly
    // via `dut.imem[i] = ...` without needing a hex file for quick bring-up.
    logic [DATA_WIDTH-1:0] imem [0:IMEM_DEPTH-1];

    initial begin
        if (IMEM_INIT_FILE != "")
            $readmemh(IMEM_INIT_FILE, imem);
    end

    logic [DATA_WIDTH-1:0] pc_q;
    logic [DATA_WIDTH-1:0] pc_next;
    logic [DATA_WIDTH-1:0] word_addr;

    assign word_addr = pc_q[$clog2(IMEM_DEPTH)+1:2]; // word index, drop byte offset bits

    always_comb begin
        if (redirect_valid)
            pc_next = redirect_pc;
        else if (stall)
            pc_next = pc_q;
        else
            pc_next = pc_q + 32'd4;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q        <= '0;
            fetch_pc    <= '0;
            fetch_instr <= '0;
            fetch_valid <= 1'b0;
        end else begin
            pc_q <= pc_next;
            `ifdef DEBUG 
                if (stall) begin
                    $display("FETCH: stall=1 at time %t, pc_q=%h, pc_next=%h", $time, pc_q, pc_next);
                end else begin
                    $display("FETCH: stall=0 at time %t, pc_q=%h, pc_next=%h", $time, pc_q, pc_next);
                end
            `endif
            
            if (redirect_valid) begin
                // Bubble the cycle a redirect lands; the instruction fetched
                // this cycle was on the wrong path and shouldn't be decoded.
                fetch_valid <= 1'b0;
                fetch_pc    <= '0;
                fetch_instr <= '0;
            end else if (stall) begin
                // Hold current outputs steady (do not re-fetch / do not clear)
                fetch_valid <= fetch_valid;
                fetch_pc    <= fetch_pc;
                fetch_instr <= fetch_instr;
            end else begin
                fetch_valid <= 1'b1;
                fetch_pc    <= pc_q;
                fetch_instr <= imem[word_addr];
            end
        end
    end

endmodule
