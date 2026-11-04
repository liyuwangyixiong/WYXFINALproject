`timescale 1ns/1ps
// 单槽双时钟握手邮箱。发送端保持数据直到接收端确认；适用于本工程低速事件。
module wyx_cdc_mailbox #(
    parameter integer WIDTH=1
)(
    input wire sclk,srst_n,s_valid,
    input wire [WIDTH-1:0] s_data,
    output reg s_overflow,
    input wire dclk,drst_n,
    output reg d_valid,
    output reg [WIDTH-1:0] d_data
);
    reg [WIDTH-1:0] s_hold;
    reg s_toggle,d_ack;
    (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync,req_meta,req_sync;
    wire s_ready=(s_toggle==ack_sync);
    always @(posedge sclk or negedge srst_n) begin
        if(!srst_n) begin
            s_hold<=0;s_toggle<=0;ack_meta<=0;ack_sync<=0;s_overflow<=0;
        end else begin
            ack_meta<=d_ack;ack_sync<=ack_meta;s_overflow<=0;
            if(s_valid) begin
                if(s_ready) begin s_hold<=s_data;s_toggle<=~s_toggle;end
                else s_overflow<=1;
            end
        end
    end
    always @(posedge dclk or negedge drst_n) begin
        if(!drst_n) begin
            req_meta<=0;req_sync<=0;d_ack<=0;d_valid<=0;d_data<=0;
        end else begin
            req_meta<=s_toggle;req_sync<=req_meta;d_valid<=0;
            if(req_sync!=d_ack) begin
                d_data<=s_hold;d_ack<=req_sync;d_valid<=1;
            end
        end
    end
endmodule
