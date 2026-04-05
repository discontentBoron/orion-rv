module top_tb;
    import orion_pkg::*;
    initial begin
        $display("--------------------------------------");
        $display("Build System for %s is ACTIVE", PROJECT_NAME);
        $display("--------------------------------------");
        $finish;
    end
endmodule
