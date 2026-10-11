`timescale 1ns/1ps
module ta_array #(parameter N=4) (
    input logic clk, reset, clear, advance,
    input logic signed [7:0] left [0:N-1], top [0:N-1],
    output wire signed [31:0] sums [0:N*N-1]
);
    wire signed [7:0] a [0:N-1][0:N];
    wire signed [7:0] b [0:N][0:N-1];
    genvar r,c;
    generate for (r=0; r<N; r=r+1) begin: rows
        assign a[r][0] = left[r];
        assign b[0][r] = top[r];
        for (c=0; c<N; c=c+1) begin: cols
            ta_pe pe (.clk, .reset, .clear, .advance,
                .a_in(a[r][c]), .b_in(b[r][c]), .a_out(a[r][c+1]),
                .b_out(b[r+1][c]), .sum(sums[r*N+c]));
        end
    end endgenerate
endmodule
