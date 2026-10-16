`timescale 1ns/1ps
// ASIC compute tile: the ta_core datapath without its memories or controller.
// It contains the ta_array systolic array and the ta_requant unit, unchanged,
// and reproduces ta_core's output stage: acc <= sums[lane] + bias, then
// requantize acc with (multiplier, shift, relu). The FPGA RAMs (activations,
// weights, parameters, outputs and the per-lane caches) are not part of the
// tile; their data enters and leaves through the ports instead.
//
// Ports are registered once at the tile boundary, so array inputs take effect
// one cycle after they are presented, and acc_out appears the cycle after load.
module ta_asic_tile #(parameter N=8) (
    input  logic clk, reset,
    // array: clear the accumulators, or advance one wave of skewed operands
    input  logic clear, advance,
    input  logic [8*N-1:0] left_in, top_in,
    // output stage
    input  logic load,                       // acc <= sums[lane] + bias
    input  logic [$clog2(N*N)-1:0] lane,
    input  logic [31:0] bias,
    input  logic start,                      // start requantizing acc
    input  logic [30:0] multiplier,
    input  logic [5:0] shift,
    input  logic relu,
    output logic signed [31:0] acc_out,
    output logic done,
    output logic signed [7:0] result
);
    logic clear_q, advance_q, load_q, start_q, relu_q;
    logic [8*N-1:0] left_q, top_q;
    logic [$clog2(N*N)-1:0] lane_q;
    logic [31:0] bias_q;
    logic [30:0] multiplier_q;
    logic [5:0] shift_q;
    always_ff @(posedge clk) begin
        if (reset) begin
            clear_q <= 0; advance_q <= 0; load_q <= 0; start_q <= 0; relu_q <= 0;
            left_q <= 0; top_q <= 0; lane_q <= 0; bias_q <= 0; multiplier_q <= 0; shift_q <= 0;
        end else begin
            clear_q <= clear; advance_q <= advance; load_q <= load; start_q <= start; relu_q <= relu;
            left_q <= left_in; top_q <= top_in; lane_q <= lane; bias_q <= bias;
            multiplier_q <= multiplier; shift_q <= shift;
        end
    end

    wire signed [7:0] left [0:N-1], top [0:N-1];
    wire signed [31:0] sums [0:N*N-1];
    genvar i;
    generate for (i = 0; i < N; i = i + 1) begin : operands
        assign left[i] = left_q[8*i +: 8];
        assign top[i]  = top_q[8*i +: 8];
    end endgenerate

    ta_array #(.N(N)) array_unit (.clk, .reset, .clear(clear_q), .advance(advance_q),
        .left, .top, .sums);

    always_ff @(posedge clk) begin
        if (reset) acc_out <= 0;
        else if (load_q) acc_out <= sums[lane_q] + bias_q;
    end

    ta_requant quant_unit (.clk, .reset, .start(start_q), .value(acc_out),
        .multiplier(multiplier_q), .shift(shift_q), .relu(relu_q), .done, .result);
endmodule
