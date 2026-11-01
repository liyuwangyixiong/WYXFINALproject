`timescale 1ns/1ps
// 单时钟域、8N1全双工UART；ready仅表示可接收一个字节。
module uart_8n1 #(
    parameter integer CLK_HZ=100000000, // 输入时钟频率，赫兹；必须与实际时钟一致
    parameter integer BAUD=115200 // 串口波特率，双方使用同一值
)(input wire clk,rst_n, input wire [7:0] tx_data,input wire tx_valid,
  output wire tx_ready,output reg tx, input wire rx,
  output reg [7:0] rx_data,output reg rx_valid,rx_error);
    localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD; // 四舍五入后的每位时钟数
    reg [31:0] tx_count,rx_count;
    reg [3:0] tx_bit,rx_bit;
    reg [9:0] tx_shift;
    reg [7:0] rx_shift;
    reg tx_busy;
    reg [1:0] rx_state;
    (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
    assign tx_ready=rst_n && !tx_busy;
    always @(posedge clk) begin
        if(!rst_n) begin
            tx<=1;tx_busy<=0;tx_count<=0;tx_bit<=0;tx_shift<=10'h3ff;
            rx_meta<=1;rx_sync<=1;rx_state<=0;rx_count<=0;rx_bit<=0;
            rx_shift<=0;rx_data<=0;rx_valid<=0;rx_error<=0;
        end else begin
            rx_meta<=rx;rx_sync<=rx_meta;rx_valid<=0;rx_error<=0;
            if(!tx_busy) begin
                if(tx_valid) begin
                    tx_shift<={1'b1,tx_data,1'b0};tx<=0;tx_busy<=1;
                    tx_count<=DIV-1;tx_bit<=0;
                end
            end else if(tx_count!=0) tx_count<=tx_count-1;
            else if(tx_bit==9) begin tx<=1;tx_busy<=0;end
            else begin
                tx_shift<={1'b1,tx_shift[9:1]};tx<=tx_shift[1];
                tx_count<=DIV-1;tx_bit<=tx_bit+1;
            end
            case(rx_state)
              0: if(!rx_sync) begin rx_count<=DIV/2-1;rx_state<=1;end
              1: if(rx_count!=0) rx_count<=rx_count-1;
                 else if(rx_sync) rx_state<=0;
                 else begin rx_count<=DIV-1;rx_bit<=0;rx_state<=2;end
              2: if(rx_count!=0) rx_count<=rx_count-1;
                 else begin
                     rx_shift[rx_bit]<=rx_sync;rx_count<=DIV-1;
                     if(rx_bit==7) rx_state<=3;else rx_bit<=rx_bit+1;
                 end
              3: if(rx_count!=0) rx_count<=rx_count-1;
                 else begin
                     rx_state<=0;
                     if(rx_sync) begin rx_data<=rx_shift;rx_valid<=1;end
                     else rx_error<=1;
                 end
            endcase
        end
    end
    // synthesis translate_off
    initial if(DIV<8) $fatal(1,"UART needs at least 8 clocks per bit");
    // synthesis translate_on
endmodule
