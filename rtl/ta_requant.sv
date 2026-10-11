`timescale 1ns/1ps
module ta_requant (
    input logic clk, reset, start,
    input logic signed [31:0] value,
    input logic [30:0] multiplier,
    input logic [5:0] shift,
    input logic relu,
    output logic done,
    output logic signed [7:0] result
);
    logic [2:0] phase;
    logic signed [63:0] product;
    logic [5:0] saved_shift;
    logic negative, increment;
    logic [63:0] magnitude, quotient, remainder, half, rounded;
    always_comb begin
        remainder = magnitude & ((64'd1 << saved_shift) - 1);
        half = saved_shift == 0 ? 0 : (64'd1 << (saved_shift - 1));
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            phase <= 0; done <= 0; result <= 0; product <= 0; saved_shift <= 0;
            magnitude<=0;quotient<=0;rounded<=0;negative<=0;increment<=0;
        end else begin
            done <= 0;
            case (phase)
                0: if (start) begin
                    product <= (relu && value[31]) ? 64'sd0 : value * $signed({1'b0,multiplier});
                    saved_shift <= shift; phase <= 1;
                end
                1: begin
                    magnitude <= product[63] ? (~$unsigned(product) + 64'd1) : $unsigned(product);
                    negative<=product[63];phase<=2;
                end
                2: begin
                    quotient<=magnitude>>saved_shift;
                    increment<=saved_shift!=0 && (remainder>half || (remainder==half && magnitude[saved_shift]));
`ifdef TA_MUTATE_ROUND
                    increment<=saved_shift!=0 && remainder>=half;
`endif
                    phase<=3;
                end
                3: begin rounded<=quotient+{63'd0,increment};phase<=4;end
                4: begin
                    if(!negative && rounded>127)result<=8'sd127;
                    else if(negative && rounded>128)result<=8'sh80;
                    else if(negative)result<=-rounded[7:0];
                    else result<=rounded[7:0];
                    done <= 1; phase <= 0;
                end
                default: phase <= 0;
            endcase
        end
    end
endmodule
