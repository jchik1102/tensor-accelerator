`timescale 1ns/1ps
module ta_ram #(parameter WIDTH=8, DEPTH=8192, ADDR_WIDTH=13) (
    input logic clk, we,
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [WIDTH-1:0] wdata,
    output logic [WIDTH-1:0] rdata
);
    (* ramstyle = "M9K" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
    end
endmodule
