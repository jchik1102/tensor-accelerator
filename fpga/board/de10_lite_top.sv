module de10_lite_top #(parameter ARRAY_N=4, CORE_MHZ=50)(input wire MAX10_CLK1_50, input wire KEY0,
    output wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5);
    wire [7:0] display_value;
    ta_hex_decoder display_decoder(.value(display_value),.segments(HEX0));
    assign HEX1=8'hff, HEX2=8'hff, HEX3=8'hff, HEX4=8'hff, HEX5=8'hff;
    wire core_clk,clock_locked;
    generate if(CORE_MHZ==50)begin:direct_clock
        assign core_clk=MAX10_CLK1_50;
        assign clock_locked=1'b1;
    end else begin:generated_clock
        wire [4:0] clocks;
        altpll #(.inclk0_input_frequency(20000),.clk0_multiply_by(CORE_MHZ),
            .clk0_divide_by(50),.operation_mode("NORMAL"),.compensate_clock("CLK0"),
            .intended_device_family("MAX 10"),.width_clock(5)) pll(
            .inclk({1'b0,MAX10_CLK1_50}),.areset(!KEY0),.clk(clocks),.locked(clock_locked));
        assign core_clk=clocks[0];
    end endgenerate
     
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [2:0] key_sync=3'b111;
    wire clock_reset=!KEY0 || !clock_locked;
    always @(posedge core_clk or posedge clock_reset)
        if(clock_reset)key_sync<=3'b111;else key_sync<={key_sync[1:0],1'b0};
    wire master_reset;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [2:0] core_sync=3'b111;
    wire reset_request=key_sync[2] || master_reset;
    always @(posedge core_clk or posedge reset_request)
        if(reset_request)core_sync<=3'b111;else core_sync<={core_sync[1:0],1'b0};
    wire [31:0] address,writedata,readdata;
    wire [3:0] byteenable;
    wire read,write,waitrequest,readdatavalid;
    ta_jtag bridge(.clk_clk(core_clk),.reset_reset(key_sync[2]),
        .master_reset_reset(master_reset),.master_address(address),.master_writedata(writedata),
        .master_byteenable(byteenable),.master_read(read),.master_write(write),
        .master_waitrequest(waitrequest),.master_readdata(readdata),.master_readdatavalid(readdatavalid));
    ta_avalon_adapter #(.ARRAY_N(ARRAY_N)) adapter(.clk(core_clk),.reset(core_sync[2]),.*);
endmodule
