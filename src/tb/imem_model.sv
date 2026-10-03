`timescale 1ns/1ps
module imem_model #(
  parameter int DEPTH = 256,                 // words, power of two
  parameter int AW    = 32
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          req_valid,
  output logic          req_ready,
  input  logic [AW-1:0] req_addr,
  output logic          resp_valid,
  output logic [31:0]   resp_data,
  output logic          resp_last
);
  localparam int IW = $clog2(DEPTH);

  logic [31:0] mem [0:DEPTH-1];
  int lat_min = 1; 
  int lat_max = 1;
  int gap_pct = 0;

  typedef enum logic [1:0] { S_IDLE, S_WAIT, S_BEATS } st_e;
  st_e         st;
  logic [AW-1:0] base;
  int          wait_cnt, beat;

  assign req_ready = (st == S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= S_IDLE;
      resp_valid <= 1'b0;
      resp_last  <= 1'b0;
      resp_data  <= '0;
      base       <= '0;
      wait_cnt   <= 0;
      beat       <= 0;
    end else begin
      resp_valid <= 1'b0;
      resp_last  <= 1'b0;
      case (st)
        S_IDLE: if (req_valid) begin
          base     <= {req_addr[AW-1:5], 5'b0};
          wait_cnt <= $urandom_range(lat_max, lat_min);
          beat     <= 0;
          st       <= S_WAIT;
        end
        S_WAIT: begin
          if (wait_cnt <= 1) st <= S_BEATS;
          else               wait_cnt <= wait_cnt - 1;
        end
        S_BEATS: begin
          if (!($urandom_range(99, 0) < gap_pct)) begin
            resp_valid <= 1'b1;
            resp_data  <= mem[(base[IW+1:2] + beat[IW-1:0]) & (DEPTH-1)];
            resp_last  <= (beat == 7);
            beat       <= beat + 1;
            if (beat == 7) st <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule