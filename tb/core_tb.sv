`timescale 1ns/1ps
module core_tb;
`ifdef TA_ARRAY_8
    localparam ARRAY_N=8;
`else
    localparam ARRAY_N=4;
`endif
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    bit clk=0;
    always #10 clk=~clk;
    logic reset=1,req_valid=0,req_write=0;
    logic [31:0] req_addr=0,req_wdata=0;
    wire req_ready,rsp_valid,rsp_error;
    wire [31:0] rsp_rdata;
    ta_core #(.ARRAY_N(ARRAY_N)) dut(.*);
    class gap_item extends uvm_sequence_item;
        function new(string name="gap"); super.new(name); endfunction
        rand int gap;
        constraint legal { gap inside {[0:3]}; }
    endclass
    gap_item item;
    int gap_hits[4];
    logic [31:0] gap_digest=32'h811c9dc5;
    int checks=0, transactions=0, line_number=0, assertion_hits=0;
    int cm,ck,cn,cr;
    covergroup functional;
        m: coverpoint cm {bins below={[1:3]};bins full={4};bins above={[5:32]};}
        n: coverpoint cn {bins below={[1:3]};bins full={4};bins above={[5:128]};}
        k: coverpoint ck {bins short_k={[1:3]};bins four={4};bins longer={[5:1023]};bins maximum={1024};}
        relu: coverpoint cr {bins off={0};bins on={1};}
        row_tail: coverpoint (cm%ARRAY_N) {bins tail[]={[0:ARRAY_N-1]};}
        col_tail: coverpoint (cn%ARRAY_N) {bins tail[]={[0:ARRAY_N-1]};}
    endgroup
    functional coverage;
     
    property response_bounded;
        @(posedge clk) disable iff(reset) req_valid && req_ready |-> ##2 rsp_valid;
    endproperty
    assert property(response_bounded) assertion_hits++; else $fatal(1,"BUS_RESPONSE_ASSERTION");
    always @(posedge clk) if(!reset) begin
        assert (!(dut.a_we && dut.busy) || dut.state==dut.STORE) else $fatal(1,"OWNERSHIP_ASSERTION");
        assert (!dut.d_we || dut.output_valid) else $fatal(1,"BOUNDARY_ASSERTION");
        assert (!(dut.load_a_q && dut.stream_q) && !(dut.load_b_q && dut.stream_q)) else $fatal(1,"CACHE_OWNERSHIP_ASSERTION");
    end
    task automatic transact(input bit wr,input logic[31:0] address,data,input bit expected_error,output logic[31:0] value);
        assert(item.randomize()) else $fatal(1,"RANDOMIZE_FAILED");
        assert(item.gap>=0 && item.gap<=3) else $fatal(1,"RANDOM_ILLEGAL");
        gap_hits[item.gap]++;
        gap_digest=(gap_digest ^ item.gap)*32'h01000193;
        repeat(item.gap) @(negedge clk);
        @(negedge clk);req_valid=1;req_write=wr;req_addr=address;req_wdata=data;
        do @(posedge clk); while(!req_ready);
        @(negedge clk);req_valid=0;
        do @(negedge clk); while(!rsp_valid);
        if(rsp_error!==expected_error) $fatal(1,"BUS_ERROR line=%0d address=%h expected=%b actual=%b",line_number,address,expected_error,rsp_error);
        value=rsp_rdata;transactions++;
    endtask
    integer fd,rc,polls;
    string path,op;
    logic [31:0] a,b,c,d,value;
    initial begin
        item=new("gap");coverage=new;
        if(!$value$plusargs("VECTORS=%s",path)) path="../vectors/core.txt";
        fd=$fopen(path,"r");if(!fd)$fatal(1,"No vectors %s",path);
        repeat(4)@(negedge clk);reset=0;
        while(!$feof(fd)) begin
            rc=$fscanf(fd,"%s %h %h %h %h\n",op,a,b,c,d);
            if(rc!=5)$fatal(1,"Malformed vector line %0d",line_number+1);
            line_number++;
            case(op)
                "Z":begin @(negedge clk);reset=1;repeat(3)@(negedge clk);reset=0;end
                "D":repeat(a)@(negedge clk);
                "C":begin cm=a;ck=b;cn=c;cr=d;coverage.sample();end
                "W":transact(1,a,b,c[0],value);
                "R":begin
                    transact(0,a,0,c[0],value);
                    if(value!==b)$fatal(1,"MISMATCH line=%0d addr=%h expected=%h actual=%h",line_number,a,b,value);
                    checks++;
                end
                "P":begin
                    polls=0;
                    do begin
                        repeat(50)@(negedge clk);transact(0,a,0,0,value);polls++;
                        if(polls>30000)$fatal(1,"COMPUTE_TIMEOUT line=%0d status=%h",line_number,value);
                    end while(value[0]);
                    if(value!==b)$fatal(1,"STATUS_MISMATCH line=%0d expected=%h actual=%h",line_number,b,value);
                    checks++;
                end
                "T":begin transact(0,20,0,0,value);$display("COMPUTE_CYCLES %0d",value);end
                "O":begin transact(0,a,0,0,value);$display("READBACK %08h %08h",a,value);end
                "H":begin
                    polls=0;
                    while(dut.state!=a)begin @(negedge clk);polls++;if(polls>100000)$fatal(1,"STATE_TIMEOUT");end
                    reset=1;repeat(3)@(negedge clk);reset=0;
                end
                default:$fatal(1,"Unknown command %s",op);
            endcase
        end
        repeat(4)@(negedge clk);
        foreach(gap_hits[i]) if(gap_hits[i]==0)$fatal(1,"NO_GAP_VARIATION");
        $display("CORE_PASS checks=%0d transactions=%0d assertion_hits=%0d coverage=%0.2f gaps=%0d,%0d,%0d,%0d digest=%08h",checks,transactions,assertion_hits,coverage.get_inst_coverage(),gap_hits[0],gap_hits[1],gap_hits[2],gap_hits[3],gap_digest);
        $finish;
    end
    initial begin #200000000; $fatal(1,"WATCHDOG");end
endmodule
