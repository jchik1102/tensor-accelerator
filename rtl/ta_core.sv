`timescale 1ns/1ps

module ta_core #(parameter ARRAY_N=4) (
    input logic clk, reset,
    input logic req_valid, req_write,
    input logic [31:0] req_addr, req_wdata,
    output wire req_ready,
    output logic rsp_valid, rsp_error,
    output logic [31:0] rsp_rdata
);
    localparam LG=$clog2(ARRAY_N), CW=10-LG;
    typedef enum logic [4:0] {IDLE,DESC,CHECK_DESC,TILE_CLEAR,
        LOAD_A,DRAIN_A,LOAD_B,DRAIN_B,STREAM,
        STREAM_DRAIN,MAC_DRAIN,P_BIAS,CAP_BIAS,
        P_MULT,CAP_MULT,Q_START,Q_WAIT,STORE,
        NEXT_OUTPUT,NEXT_TILE,NEXT_LAYER,P_SHIFT,CAP_SHIFT} state_t;
    state_t state;
    wire busy=state!=IDLE;
    logic done,error_sticky;
    logic [31:0] error_code,cycles,layer_count;
    logic [2:0] layer;
    logic [31:0] desc[0:63];
    logic [31:0] m,k,n,src,dst,wb,pb,flags;
    logic [5:0] row_base;
    logic [7:0] col_base;
    logic [10:0] wave,load_pos;
    logic [LG-1:0] load_lane,load_lane_q;
    logic [CW-1:0] load_word_q;
    logic load_a_q,load_b_q,stream_q;
    logic [12:0] tile_a_start;
    logic [15:0] tile_b_start,load_row_start;
    logic [12:0] tile_out_row,out_row_addr;
    logic [2*LG-1:0] output_lane;
    wire [5:0] out_row=row_base+output_lane[2*LG-1:LG];
    wire [7:0] out_col=col_base+output_lane[LG-1:0];
    wire output_valid=out_row<m && out_col<n;
    wire [12:0] output_address=out_row_addr+out_col;
    wire signed [7:0] left[0:ARRAY_N-1],top[0:ARRAY_N-1];
    wire signed [31:0] sums[0:ARRAY_N*ARRAY_N-1];
    wire clear_array=state==TILE_CLEAR;
    wire soft_reset=req_valid && req_ready && req_write && req_addr==8 && req_wdata==4;
    wire local_reset=reset || soft_reset;
    logic signed [31:0] bias,acc;
    logic [31:0] mult,shift_value;
    wire q_done;
    wire signed [7:0] q_result;
    ta_array #(.N(ARRAY_N)) array_unit(.clk,.reset(local_reset),.clear(clear_array),
        .advance(stream_q),.left,.top,.sums);
    ta_requant quant_unit(.clk,.reset(local_reset),.start(state==Q_START),.value(acc),
        .multiplier(mult[30:0]),.shift(shift_value[5:0]),.relu(flags[0]),.done(q_done),.result(q_result));

    logic [12:0] a_addr;
    logic [15:0] w_addr;
    logic [11:0] p_addr,d_addr;
    logic a_we,w_we,p_we,d_we;
    logic [7:0] a_wdata,w_wdata;
    logic [31:0] p_wdata,d_wdata;
    wire [7:0] a_rdata,w_rdata;
    wire [8*ARRAY_N-1:0] a_vector,w_vector;
    wire [31:0] p_rdata,d_rdata;
    ta_vector_ram #(.N(ARRAY_N),.AW(13)) a_ram(.clk,.we(a_we),.addr(a_addr),.wdata(a_wdata),.rdata(a_rdata),.vector_data(a_vector));
    ta_vector_ram #(.N(ARRAY_N),.AW(16)) w_ram(.clk,.we(w_we),.addr(w_addr),.wdata(w_wdata),.rdata(w_rdata),.vector_data(w_vector));
    ta_ram #(.WIDTH(32),.DEPTH(3072),.ADDR_WIDTH(12)) p_ram(.clk,.we(p_we),.addr(p_addr),.wdata(p_wdata),.rdata(p_rdata));
    ta_ram #(.WIDTH(32),.DEPTH(4096),.ADDR_WIDTH(12)) d_ram(.clk,.we(d_we),.addr(d_addr),.wdata(d_wdata),.rdata(d_rdata));

    genvar lane;
    generate for(lane=0;lane<ARRAY_N;lane=lane+1)begin:cache_lanes
        wire [10:0] skew=wave-lane;
        wire [8*ARRAY_N-1:0] a_word,b_word;
        logic [LG-1:0] byte_q;
        logic a_valid_q,b_valid_q;
        wire cache_a_write=load_a_q && load_lane_q==lane && !local_reset;
        wire cache_b_write=load_b_q && load_lane_q==lane && !local_reset;
        ta_ram #(.WIDTH(8*ARRAY_N),.DEPTH(1024/ARRAY_N),.ADDR_WIDTH(CW)) a_cache(
            .clk,.we(cache_a_write),.addr(cache_a_write?load_word_q:skew[9:LG]),.wdata(a_vector),.rdata(a_word));
        ta_ram #(.WIDTH(8*ARRAY_N),.DEPTH(1024/ARRAY_N),.ADDR_WIDTH(CW)) b_cache(
            .clk,.we(cache_b_write),.addr(cache_b_write?load_word_q:skew[9:LG]),.wdata(w_vector),.rdata(b_word));
        always_ff @(posedge clk)begin
            byte_q<=skew[LG-1:0];
            a_valid_q<=state==STREAM && wave>=lane && wave<k+lane && row_base+lane<m;
            b_valid_q<=state==STREAM && wave>=lane && wave<k+lane && col_base+lane<n;
        end
        assign left[lane]=a_valid_q?a_word[8*byte_q+:8]:8'd0;
        assign top[lane]=b_valid_q?b_word[8*byte_q+:8]:8'd0;
    end endgenerate
    always_ff @(posedge clk)begin
        if(local_reset)begin load_a_q<=0;load_b_q<=0;stream_q<=0;load_lane_q<=0;load_word_q<=0;end
        else begin
            load_a_q<=state==LOAD_A;load_b_q<=state==LOAD_B;stream_q<=state==STREAM;
            load_lane_q<=load_lane;load_word_q<=load_pos[9:LG];
        end
    end

    logic pending,pending_error;
    logic [2:0] read_kind;
    logic [31:0] register_read;
    assign req_ready=!pending && !reset;
    wire accept=req_valid && req_ready;
    wire aligned=req_addr[1:0]==0;
    wire sel_a=req_addr>='h10000 && req_addr<'h18000;
    wire sel_w=req_addr>='h20000 && req_addr<'h60000;
    wire sel_p=req_addr>='h1000 && req_addr<'h4000;
    wire sel_d=req_addr>='h60000 && req_addr<'h64000;
    wire sel_desc=req_addr>='h100 && req_addr<'h200;
    wire [11:0] channel_word=(pb[9:0]+out_col)*3;
    always_comb begin
        a_addr=0;w_addr=0;p_addr=0;d_addr=0;
        a_we=0;w_we=0;p_we=0;d_we=0;
        a_wdata=req_wdata[7:0];w_wdata=req_wdata[7:0];p_wdata=req_wdata;d_wdata=acc;
        if(!busy && accept && aligned)begin
            if(sel_a)begin a_addr=(req_addr-'h10000)>>2;a_we=req_write;end
            if(sel_w)begin w_addr=(req_addr-'h20000)>>2;w_we=req_write;end
            if(sel_p)begin p_addr=(req_addr-'h1000)>>2;p_we=req_write;end
            if(sel_d)d_addr=(req_addr-'h60000)>>2;
        end
        if(state==LOAD_A)a_addr=load_row_start[12:0]+load_pos;
        if(state==LOAD_B)w_addr=load_row_start+load_pos;
        if(state==P_BIAS || state==CAP_BIAS)p_addr=channel_word;
        if(state==P_MULT || state==CAP_MULT)p_addr=channel_word+1;
        if(state==P_SHIFT || state==CAP_SHIFT)p_addr=channel_word+2;
        if(state==STORE && output_valid)begin
            a_addr=output_address;a_we=1;a_wdata=q_result;
            d_addr=output_address-dst[12:0];d_we=1;
        end
        if(local_reset)begin a_we=0;w_we=0;p_we=0;d_we=0;end
    end

    integer i;
    always_ff @(posedge clk)begin
        if(reset)begin
            state<=IDLE;done<=0;error_sticky<=0;error_code<=0;cycles<=0;layer_count<=0;layer<=0;
            pending<=0;pending_error<=0;rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;read_kind<=0;register_read<=0;
            m<=0;k<=0;n<=0;src<=0;dst<=0;wb<=0;pb<=0;flags<=0;
            row_base<=0;col_base<=0;wave<=0;load_pos<=0;load_lane<=0;output_lane<=0;
            tile_a_start<=0;tile_b_start<=0;load_row_start<=0;tile_out_row<=0;out_row_addr<=0;
            bias<=0;acc<=0;mult<=0;shift_value<=0;
            for(i=0;i<64;i=i+1)desc[i]<=0;
        end else begin
            rsp_valid<=0;
            if(busy)cycles<=cycles+1;
            if(pending)begin
                pending<=0;rsp_valid<=1;rsp_error<=pending_error;
                case(read_kind)
                    1:rsp_rdata<={{24{a_rdata[7]}},a_rdata};
                    2:rsp_rdata<={{24{w_rdata[7]}},w_rdata};
                    3:rsp_rdata<=p_rdata;
                    4:rsp_rdata<=d_rdata;
                    default:rsp_rdata<=register_read;
                endcase
            end
            case(state)
                IDLE:;
                DESC:begin
                    m<=desc[{layer,3'b000}];k<=desc[{layer,3'b000}+1];n<=desc[{layer,3'b000}+2];
                    src<=desc[{layer,3'b000}+3];dst<=desc[{layer,3'b000}+4];wb<=desc[{layer,3'b000}+5];
                    pb<=desc[{layer,3'b000}+6];flags<=desc[{layer,3'b000}+7];state<=CHECK_DESC;
                end
                CHECK_DESC:begin
                    if(m<1 || m>32 || k<1 || k>1024 || n<1 || n>128 || flags>1 ||
                       src>8191 || dst>8191 || wb>65535 || pb>1023 ||
                       src+m[5:0]*k[10:0]>8192 || dst+m[5:0]*n[7:0]>8192 ||
                       wb+n[7:0]*k[10:0]>65536 || pb+n>1024 ||
                       !(src+m[5:0]*k[10:0]<=dst || dst+m[5:0]*n[7:0]<=src))begin
                        state<=IDLE;error_sticky<=1;error_code<=3;
                    end else begin
                        row_base<=0;col_base<=0;tile_a_start<=src[12:0];tile_b_start<=wb[15:0];
                        tile_out_row<=dst[12:0];state<=TILE_CLEAR;
                    end
                end
                TILE_CLEAR:begin
                    load_lane<=0;load_pos<=0;load_row_start<={3'd0,tile_a_start};state<=LOAD_A;
                end
                LOAD_A:begin
                    if(load_pos+ARRAY_N>=k)begin
                        load_pos<=0;load_lane<=load_lane+1'b1;load_row_start<=load_row_start+k[10:0];
                        if(load_lane==ARRAY_N-1 || row_base+load_lane+1>=m)state<=DRAIN_A;
                    end else load_pos<=load_pos+ARRAY_N;
                end
                DRAIN_A:begin load_lane<=0;load_pos<=0;load_row_start<=tile_b_start;state<=LOAD_B;end
                LOAD_B:begin
                    if(load_pos+ARRAY_N>=k)begin
                        load_pos<=0;load_lane<=load_lane+1'b1;load_row_start<=load_row_start+k[10:0];
                        if(load_lane==ARRAY_N-1 || col_base+load_lane+1>=n)state<=DRAIN_B;
                    end else load_pos<=load_pos+ARRAY_N;
                end
                DRAIN_B:begin wave<=0;state<=STREAM;end
                STREAM:begin
                    if(wave==k+2*ARRAY_N-3)state<=STREAM_DRAIN;
                    else wave<=wave+1'b1;
                end
                STREAM_DRAIN:state<=MAC_DRAIN;
                MAC_DRAIN:begin output_lane<=0;out_row_addr<=tile_out_row;state<=P_BIAS;end
                P_BIAS:if(output_valid)state<=CAP_BIAS;else state<=NEXT_OUTPUT;
                CAP_BIAS:begin bias<=p_rdata;state<=P_MULT;end
                P_MULT:state<=CAP_MULT;
                CAP_MULT:begin mult<=p_rdata;state<=P_SHIFT;end
                P_SHIFT:state<=CAP_SHIFT;
                CAP_SHIFT:begin
                    shift_value<=p_rdata;
                    if(mult==0 || mult[31] || p_rdata>62 ||
                       $signed(bias)>$signed(32'h7fffffff-k[10:0]*16384) ||
                       $signed(bias)<-$signed(32'h7fffffff-k[10:0]*16384))begin
                        state<=IDLE;error_sticky<=1;error_code<=4;
                    end else begin acc<=sums[output_lane]+bias;state<=Q_START;end
                end
                Q_START:state<=Q_WAIT;
                Q_WAIT:if(q_done)state<=STORE;
                STORE:state<=NEXT_OUTPUT;
                NEXT_OUTPUT:begin
                    if(output_lane==ARRAY_N*ARRAY_N-1)state<=NEXT_TILE;
                    else begin
                        output_lane<=output_lane+1'b1;
                        if(output_lane[LG-1:0]==ARRAY_N-1)out_row_addr<=out_row_addr+n[7:0];
                        state<=P_BIAS;
                    end
                end
                NEXT_TILE:begin
                    if(col_base+ARRAY_N<n)begin
                        col_base<=col_base+ARRAY_N;tile_b_start<=tile_b_start+(k[10:0]<<LG);state<=TILE_CLEAR;
                    end else if(row_base+ARRAY_N<m)begin
                        row_base<=row_base+ARRAY_N;col_base<=0;tile_b_start<=wb[15:0];
                        tile_a_start<=tile_a_start+(k[10:0]<<LG);tile_out_row<=tile_out_row+(n[7:0]<<LG);state<=TILE_CLEAR;
                    end else state<=NEXT_LAYER;
                end
                NEXT_LAYER:begin
                    if({29'd0,layer}+1<layer_count)begin layer<=layer+1'b1;state<=DESC;end
                    else begin state<=IDLE;done<=1;end
                end
                default:begin state<=IDLE;error_sticky<=1;error_code<=3;end
            endcase
            if(accept)begin
                pending<=1;pending_error<=0;read_kind<=0;register_read<=0;
                if(!aligned)begin pending_error<=1;error_sticky<=1;error_code<=1;end
                else if(req_write && req_addr==8 && req_wdata==4)begin
                    state<=IDLE;done<=0;error_sticky<=0;error_code<=0;cycles<=0;layer_count<=0;layer<=0;
                    for(i=0;i<64;i=i+1)desc[i]<=0;
                end else if(busy && (req_write || sel_a || sel_w || sel_p || sel_d || sel_desc))begin
                    pending_error<=1;error_sticky<=1;error_code<=2;
                end else if(sel_desc)begin
                    if(req_write)desc[req_addr[7:2]]<=req_wdata;else register_read<=desc[req_addr[7:2]];
                end else if(sel_a)begin if(!req_write)read_kind<=1;end
                else if(sel_w)begin if(!req_write)read_kind<=2;end
                else if(sel_p)begin if(!req_write)read_kind<=3;end
                else if(sel_d && !req_write)read_kind<=4;
                else if(req_write)begin
                    case(req_addr)
                        8:begin
                            if(req_wdata==2)begin done<=0;error_sticky<=0;error_code<=0;end
                            else if(req_wdata==1 && !done && !error_sticky && layer_count>=1 && layer_count<=8)begin
                                cycles<=0;layer<=0;state<=DESC;
                            end else begin pending_error<=1;error_sticky<=1;error_code<=3;end
                        end
                        12:layer_count<=req_wdata;
                        default:begin pending_error<=1;error_sticky<=1;error_code<=1;end
                    endcase
                end else begin
                    case(req_addr)
                        0:register_read<=32'h54413031;
                        4:register_read<={29'd0,error_sticky,done,busy};
                        12:register_read<=layer_count;
                        16:register_read<=error_code;
                        20:register_read<=cycles;
                        24:register_read<={29'd0,layer};
                        default:begin pending_error<=1;error_sticky<=1;error_code<=1;end
                    endcase
                end
            end
        end
    end
endmodule
