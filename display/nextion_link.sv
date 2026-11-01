`timescale 1ns/1ps
// 每条命令等待屏幕执行确认；不会向监测链反压。超时交由上层重建页面。
module nextion_link #(
    parameter integer CLK_HZ=100000000, // UART输入时钟，赫兹
    parameter integer BAUD=115200, // UART波特率，8N1
    parameter integer ACK_MS=150, // 命令执行应答超时，毫秒
    parameter integer MAX_BYTES=32 // 单条ASCII命令最大长度，不含三个FF
)(input wire clk,rst_n,tick_1ms,
 input wire [MAX_BYTES*8-1:0] command,input wire [7:0] length,input wire start,
 output wire idle,output reg done,failed,screen_reset,
 output wire tx,input wire rx);
    wire ready,rv,re;
    wire [7:0] rd;
    reg [MAX_BYTES*8-1:0] saved;
    reg [7:0] count,size;
    reg [1:0] state;
    reg [15:0] age;
    reg ack_seen,bad_seen;
    reg [7:0] packet_type,packet_pos;
    reg [1:0] ff_count;
    wire sending=state==1;
    wire [7:0] td=(count<size) ? saved[count*8+:8] : 8'hff;
    assign idle=state==0;
    uart_8n1 #(
      .CLK_HZ(CLK_HZ), // 实际处理时钟，赫兹
      .BAUD(BAUD) // 串口速率，波特
    ) u_uart(.clk(clk),.rst_n(rst_n),.tx_data(td),.tx_valid(sending),
      .tx_ready(ready),.tx(tx),.rx(rx),.rx_data(rd),.rx_valid(rv),.rx_error(re));
    always @(posedge clk) begin
      if(!rst_n) begin
        saved<=0;count<=0;size<=0;state<=0;age<=0;done<=0;failed<=0;
        ack_seen<=0;bad_seen<=0;screen_reset<=0;
        packet_type<=0;packet_pos<=0;ff_count<=0;
      end else begin
        done<=0;failed<=0;screen_reset<=0;
        if(re) begin packet_pos<=0;ff_count<=0;if(state!=0) bad_seen<=1;end
        if(rv) begin
          if(packet_pos==0) begin packet_type<=rd;packet_pos<=1;ff_count<=0;end
          else if(rd==8'hff) begin
            if(ff_count==2) begin
              packet_pos<=0;ff_count<=0;
              if(packet_type==8'h01 && packet_pos==3 && state!=0) ack_seen<=1;
              else if(packet_type==8'h88 || (packet_type==8'h66 && packet_pos==4)) screen_reset<=1;
              else if(packet_pos==3 && packet_type!=8'h01 && state!=0) bad_seen<=1;
            end else begin ff_count<=ff_count+1;packet_pos<=packet_pos+1;end
          end else begin
            ff_count<=0;
            if(packet_pos<15) packet_pos<=packet_pos+1;
            else packet_pos<=0; // 有界解析，噪声不能无限增长
          end
        end
        case(state)
          0: if(start) begin
            saved<=command;size<=length;count<=0;age<=0;
            ack_seen<=0;bad_seen<=0;
            if(length==0 || length>MAX_BYTES) failed<=1;else state<=1;
          end
          1: if(ready) begin
            if(count==size+2) begin state<=2;age<=0;end
            else count<=count+1;
          end
          2: begin
            if(bad_seen) begin failed<=1;state<=0;end
            else if(ack_seen && ready) begin done<=1;state<=0;end
            else if(tick_1ms) begin
              if(age>=ACK_MS-1) begin failed<=1;state<=0;packet_pos<=0;ff_count<=0;end
              else age<=age+1;
            end
          end
        endcase
      end
    end
endmodule
