`timescale 1ns/1ps
 
module ta_avalon_adapter #(parameter ARRAY_N=4) (
    input logic clk, reset,
    input logic [31:0] address,writedata,
    input logic [3:0] byteenable,
    input logic read,write,
    output wire waitrequest,
    output wire [31:0] readdata,
    output wire readdatavalid,
    output logic [7:0] display_value
);
    logic waiting, saved_read;
    wire ready,valid,error;
    wire [31:0] data;
    logic local_valid;
    logic [31:0] local_data;
    wire local_access=byteenable==4'hf && !(read && write) &&
        (address==32'h20 || (address==32'h24 && read && !write));
    wire accept=(read || write) && !waitrequest;
    assign waitrequest=waiting || !ready || reset;
    assign readdata=local_valid ? local_data : data;
    assign readdatavalid=(valid || local_valid) && saved_read;
    ta_core #(.ARRAY_N(ARRAY_N)) core(.clk,.reset,.req_valid((read || write) && !waiting && !local_access),
        .req_write(write),.req_addr(byteenable==4'hf && !(read && write) ? address : 32'hffffffff),
        .req_wdata(writedata),.req_ready(ready),.rsp_valid(valid),.rsp_error(error),.rsp_rdata(data));
    always_ff @(posedge clk) begin
        if(reset)begin waiting<=0;saved_read<=0;local_valid<=0;local_data<=0;display_value<=255;end
        else begin
            local_valid<=0;
            if(accept)begin waiting<=1;saved_read<=read;end
            if(valid || local_valid)waiting<=0;
            if(accept && local_access)begin
                local_valid<=1;
                local_data<=address==32'h24 ? 32'h48455831 : {24'b0,display_value};
                if(write)display_value<=writedata<=9 ? writedata[7:0] : 8'hff;
            end
            if(accept && write && !read && byteenable==15 && address==8 && writedata==4)
                display_value<=255;
        end
    end
endmodule
