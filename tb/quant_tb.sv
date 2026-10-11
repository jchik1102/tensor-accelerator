`timescale 1ns/1ps
module quant_tb;
    bit clk=0;
    always #10 clk=~clk;
    logic reset=1,start=0,relu;
    logic signed[31:0] value;
    logic[30:0] multiplier;
    logic[5:0] shift;
    wire done;
    wire signed[7:0] result;
    ta_requant dut(.*);
    integer fd,rc,count=0;
    logic[31:0] v,m,s,r,e;
    initial begin
        fd=$fopen("../vectors/quant.txt","r");if(!fd)$fatal(1,"No quant vectors");
        repeat(3)@(negedge clk);reset=0;
        while(!$feof(fd))begin
            rc=$fscanf(fd,"%h %h %h %h %h\n",v,m,s,r,e);if(rc!=5)$fatal(1,"Malformed quant vector");
            @(negedge clk);value=v;multiplier=m[30:0];shift=s[5:0];relu=r[0];start=1;
            @(negedge clk);start=0;
            do @(negedge clk);while(!done);
            if(result!==e[7:0])$fatal(1,"QUANT_MISMATCH value=%h mult=%h shift=%0d relu=%0d expected=%h actual=%h",v,m,s,r,e[7:0],result);
            count++;
        end
        $display("QUANT_PASS cases=%0d",count);$finish;
    end
endmodule
