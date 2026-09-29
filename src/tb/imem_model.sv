`timescale 1ns/1ps

module imem_model #(
    parameter int DEPTH     = 256,
    parameter     INIT_FILE = ""
) (
    input  logic                     clk,
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [31:0]              rdata
);
 
    logic [31:0] mem [0:DEPTH-1];
 
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end
 
    always_ff @(posedge clk) begin
        rdata <= mem[addr];
    end
 
endmodule