 
module ta_hex_decoder(input wire [7:0] value, output logic [7:0] segments);
    always_comb begin
        case(value)
            0:segments=8'hc0;
            1:segments=8'hf9;
            2:segments=8'ha4;
            3:segments=8'hb0;
            4:segments=8'h99;
            5:segments=8'h92;
            6:segments=8'h82;
            7:segments=8'hf8;
            8:segments=8'h80;
            9:segments=8'h90;
            default:segments=8'hbf;
        endcase
    end
endmodule
