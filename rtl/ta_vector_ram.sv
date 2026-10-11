`timescale 1ns/1ps

module ta_vector_ram #(parameter N=4, AW=13) (
    input logic clk,we,
    input logic [AW-1:0] addr,
    input logic [7:0] wdata,
    output wire [8*N-1:0] vector_data,
    output wire [7:0] rdata
);
    localparam LG=$clog2(N);
    wire [7:0] bank_data[0:N-1];
    logic [LG-1:0] rotation;
    always_ff @(posedge clk)rotation<=addr[LG-1:0];
    genvar b;
    generate for(b=0;b<N;b=b+1)begin:banks
        wire [AW-LG-1:0] bank_addr=addr[AW-1:LG]+(b<addr[LG-1:0]);
        ta_ram #(.DEPTH((1<<AW)/N),.ADDR_WIDTH(AW-LG)) ram(
            .clk,.we(we && addr[LG-1:0]==b),.addr(bank_addr),.wdata,.rdata(bank_data[b]));
`ifdef TA_MUTATE_BANK
        wire [LG-1:0] selected=b;
`else
        wire [LG-1:0] selected=rotation+b;
`endif
        assign vector_data[b*8+:8]=bank_data[selected];
    end endgenerate
    assign rdata=vector_data[7:0];
endmodule
