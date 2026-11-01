`timescale 1ns/1ps
// 片内EMIO快照桥：请求位翻转时锁存整组数据，翻页不重新采样。
// ARM须核对版本、请求确认及页号回显；不能把轮询次数当传感器样本数。
module wyx_snapshot_bridge #(
    parameter integer PAGE_COUNT=32, // 快照32位页数，1到32页；页号使用低5位
    parameter [7:0] VERSION=8'd3 // 接口契约版本，必须与ARM读取程序一致
)(
    input wire clk,rst_n,
    input wire [63:0] ps_request,
    input wire [PAGE_COUNT*32-1:0] live_words,
    output wire [63:0] ps_response
);
    (* ASYNC_REG="TRUE" *) reg [5:0] request_meta=0,request_sync=0;
    reg acknowledged=0;
    reg [PAGE_COUNT*32-1:0] snapshot;
    wire [4:0] page=request_sync[4:0];
    wire [31:0] payload=page<PAGE_COUNT ? snapshot[page*32+:32] : 32'd0;
    assign ps_response={16'h5759,VERSION,2'd0,acknowledged,page,payload};
    always @(posedge clk) begin
        if(!rst_n) begin
            request_meta<=0;request_sync<=0;acknowledged<=0;snapshot<=0;
        end else begin
            request_meta<=ps_request[5:0];request_sync<=request_meta;
            if(request_sync[5]!=acknowledged) begin
                snapshot<=live_words;
                acknowledged<=request_sync[5];
            end
        end
    end
endmodule
