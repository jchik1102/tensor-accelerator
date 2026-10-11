`timescale 1ns/1ps
module ta_pe (
    input logic clk, reset, clear, advance,
    input logic signed [7:0] a_in, b_in,
    output logic signed [7:0] a_out, b_out,
    output logic signed [31:0] sum
);
    logic signed [15:0] product;
    logic product_valid;
    always_ff @(posedge clk) begin
        if (reset || clear) begin
            a_out <= 0; b_out <= 0; sum <= 0; product<=0;product_valid<=0;
        end else begin
            product_valid<=advance;
            if(advance)begin
                a_out <= a_in; b_out <= b_in;
                product<=a_in*b_in;
            end
            if(product_valid)begin
`ifdef TA_MUTATE_PE
            sum <= sum + $signed({1'b0, product[14:0]});
`else
            sum <= sum + {{16{product[15]}}, product};
`endif
            end
        end
    end
endmodule
