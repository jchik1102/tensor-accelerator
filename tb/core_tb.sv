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
    // Scoreboard: the C++ model of ta_core (cmodel/, compiled into the XSim
    // DPI library) sees every bus access the core accepts and every reset, with
    // the clock edge each happened on, and predicts each response; every RTL
    // response must match it (error flag and read data). The model is
    // cycle-exact for job length, so this also checks the busy window, the
    // CYCLES and LAYER registers and what a reset in the middle of a job keeps.
    // +SCOREBOARD_ONLY turns off the vector file's own read checks, to show
    // the scoreboard catches the RTL mutations by itself.
    import "DPI-C" function chandle ta_model_new(input int array_n);
    import "DPI-C" function void ta_model_reset(input chandle model, input longint cycle);
    import "DPI-C" function void ta_model_access(input chandle model, input longint cycle, input bit write,
        input int unsigned addr, input int unsigned wdata, output bit error, output int unsigned rdata);
    class ta_model_scoreboard extends uvm_scoreboard;
        chandle model;
        typedef struct { longint cycle; bit write; logic [31:0] addr, wdata; bit error; logic [31:0] rdata; } expect_t;
        expect_t pending[$];
        int compared = 0, mismatches = 0, resets = 0;
        function new(string name, int array_n);
            super.new(name, null);
            model = ta_model_new(array_n);
        endfunction
        function void reset(longint cycle);
            ta_model_reset(model, cycle);
            pending.delete();
            resets++;
        endfunction
        function void request(longint cycle, bit write, logic [31:0] addr, logic [31:0] wdata);
            expect_t e;
            bit error;
            int unsigned rdata;
            ta_model_access(model, cycle, write, addr, wdata, error, rdata);
            e.cycle = cycle; e.write = write; e.addr = addr; e.wdata = wdata; e.error = error; e.rdata = rdata;
            pending.push_back(e);
        endfunction
        function void response(bit error, logic [31:0] rdata);
            expect_t e;
            if (pending.size() == 0) begin
                mismatches++;
                $error("MODEL_MISMATCH response with no accepted request");
                return;
            end
            e = pending.pop_front();
            compared++;
            if (error !== e.error || rdata !== e.rdata) begin
                mismatches++;
                if (mismatches <= 20)
                    $error("MODEL_MISMATCH edge=%0d %s addr=%h wdata=%h: RTL error=%b rdata=%h, C++ model error=%b rdata=%h",
                           e.cycle, e.write ? "write" : "read", e.addr, e.wdata, error, rdata, e.error, e.rdata);
            end
        endfunction
    endclass
    ta_model_scoreboard scoreboard;
    longint edge_number = 0;
    bit in_reset = 0;
    bit scoreboard_only = 0;
    // Sampled before the edge's nonblocking updates: a request with valid and
    // ready high is accepted on this edge, and a response high is consumed here.
    always @(posedge clk) begin
        edge_number++;
        if (reset) begin
            if (!in_reset) scoreboard.reset(edge_number);
            in_reset = 1;
        end else begin
            in_reset = 0;
            if (rsp_valid) scoreboard.response(rsp_error, rsp_rdata);
            if (req_valid && req_ready) scoreboard.request(edge_number, req_write, req_addr, req_wdata);
        end
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
        scoreboard=new("scoreboard",ARRAY_N);scoreboard_only=$test$plusargs("SCOREBOARD_ONLY");
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
                    if(value!==b && !scoreboard_only)$fatal(1,"MISMATCH line=%0d addr=%h expected=%h actual=%h",line_number,a,b,value);
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
        if(scoreboard.mismatches!=0 || scoreboard.compared!=transactions)
            $fatal(1,"MODEL_MISMATCH mismatches=%0d compared=%0d transactions=%0d",scoreboard.mismatches,scoreboard.compared,transactions);
        $display("MODEL_SCOREBOARD_PASS compared=%0d resets=%0d array_n=%0d",scoreboard.compared,scoreboard.resets,ARRAY_N);
        $display("CORE_PASS checks=%0d transactions=%0d assertion_hits=%0d coverage=%0.2f gaps=%0d,%0d,%0d,%0d digest=%08h",checks,transactions,assertion_hits,coverage.get_inst_coverage(),gap_hits[0],gap_hits[1],gap_hits[2],gap_hits[3],gap_digest);
        $finish;
    end
    initial begin #200000000; $fatal(1,"WATCHDOG");end
endmodule
