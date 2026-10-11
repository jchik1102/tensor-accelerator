`timescale 1ns/1ps
module adapter_tb;
    bit clk=0;always #10 clk=~clk;
    logic reset=1,read=0,write=0;
    logic[31:0] address=0,writedata=0;
    logic[3:0] byteenable=15;
    wire waitrequest,readdatavalid;
    wire[31:0] readdata;
    wire[7:0] display_value,segments;
    ta_hex_decoder decoder(.value(display_value),.segments);
`ifdef TA_ARRAY_8
    ta_avalon_adapter #(.ARRAY_N(8)) dut(.*);
`else
    ta_avalon_adapter #(.ARRAY_N(4)) dut(.*);
`endif
    int checks=0;
    logic [7:0] patterns[10]='{'hc0,'hf9,'ha4,'hb0,'h99,'h92,'h82,'hf8,'h80,'h90};
    task automatic check_hex(input logic[7:0] expected);
        #1;
        if(segments!==expected)$fatal(1,"HEX_MISMATCH expected=%h actual=%h",expected,segments);
        checks++;
    endtask
    task automatic wr(input logic[31:0] addr,data,input logic[3:0] enables=15);
        @(negedge clk);address=addr;writedata=data;byteenable=enables;write=1;
        do @(posedge clk);while(waitrequest);
        @(negedge clk);write=0;
    endtask
    task automatic rd(input logic[31:0] addr,expected);
        @(negedge clk);address=addr;byteenable=15;read=1;
        do @(posedge clk);while(waitrequest);
        @(negedge clk);read=0;
        while(!readdatavalid)@(negedge clk);
        if(readdata!==expected)$fatal(1,"ADAPTER_MISMATCH addr=%h expected=%h actual=%h",addr,expected,readdata);
        checks++;
    endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;
        rd(0,32'h54413031);rd(4,0);
        rd('h24,'h48455831);rd('h20,255);check_hex('hbf);
        for(int digit=0;digit<10;digit++)begin
            wr('h20,digit);rd('h20,digit);check_hex(patterns[digit]);
            repeat(5)@(negedge clk);check_hex(patterns[digit]);
        end
        wr(8,2);rd('h20,9);check_hex('h90);
        wr('h20,10);rd('h20,255);check_hex('hbf);
        wr('h20,32'h100);rd('h20,255);
        wr('h20,7);wr('h20,2,1);rd('h20,7);rd(16,1);wr(8,2);
        wr('h24,0);rd('h24,'h48455831);rd(16,1);wr(8,2);
        wr(8,4);rd('h20,255);check_hex('hbf);
        wr('h20,8);@(negedge clk);reset=1;repeat(3)@(negedge clk);reset=0;
        rd('h20,255);check_hex('hbf);
        wr('h10000,32'hfffffffd);rd('h10000,32'hfffffffd);
        wr('h10000,4,1);rd(16,1);wr(8,2);rd('h10000,32'hfffffffd);
        wr('h20000,1);wr('h1000,0);wr('h1004,1);wr('h1008,1);
        wr('h100,1);wr('h104,1);wr('h108,1);wr('h10c,0);wr('h110,4096);wr('h114,0);wr('h118,0);wr('h11c,0);
        wr(12,1);wr(8,1);repeat(300)@(negedge clk);rd(4,2);rd('h14000,32'hfffffffe);rd('h60000,32'hfffffffd);
        wr(8,4);rd(4,0);rd(12,0);
        $display("ADAPTER_PASS checks=%0d",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"ADAPTER_TIMEOUT");end
endmodule
