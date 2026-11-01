`timescale 1ns/1ps
// 【协议】FF AA T_H T_L HR_H HR_L SPO2_H SPO2_L 3C，共9字节、大端整数心率。
// 3C是固定帧尾，不是校验和；手册未给本数值帧CRC，不添加虚构的校验规则。
// 帧中温度与血氧只跳过，不输出到另三路；AA 55波形和ASCII应答不作为心率新值。
// 连续FF、错误帧尾、半帧超时和UART停止位错误均有明确恢复路径。
module kpt_d01_frame_parser #(
    parameter integer BYTE_GAP_MS=20 // 半帧内允许的最大字节间隔，毫秒；工程容错值，可调整
)(
    input wire aclk,aresetn,tick_1ms,
    input wire [7:0] byte_data,
    input wire byte_valid,uart_error,
    output reg frame_event,format_error,gap_timeout,
    output reg [15:0] hr_bpm
);
    localparam integer AGE_W=BYTE_GAP_MS>1 ? $clog2(BYTE_GAP_MS+1) : 1; // 半帧计时器位宽
    reg [3:0] index;
    reg [AGE_W-1:0] gap_age;
    reg [7:0] hr_hi,hr_lo;
    always @(posedge aclk) begin
        if(!aresetn) begin
            index<=0;gap_age<=0;hr_hi<=0;hr_lo<=0;hr_bpm<=0;
            frame_event<=0;format_error<=0;gap_timeout<=0;
        end else begin
            frame_event<=0;format_error<=0;gap_timeout<=0;
            if(uart_error) begin index<=0;gap_age<=0;format_error<=1;end
            else if(byte_valid) begin
                gap_age<=0;
                case(index)
                    0: if(byte_data==8'hff) index<=1;
                    1: if(byte_data==8'haa) index<=2;else if(byte_data!=8'hff) index<=0;
                    2,3,6,7: index<=index+1'b1;
                    4: begin hr_hi<=byte_data;index<=5;end
                    5: begin hr_lo<=byte_data;index<=6;end
                    8: begin
                        if(byte_data==8'h3c) begin hr_bpm<={hr_hi,hr_lo};frame_event<=1;end
                        else format_error<=1;
                        index<=byte_data==8'hff ? 1 : 0;
                    end
                    default: index<=0;
                endcase
            end else if(index!=0 && tick_1ms) begin
                if(gap_age>=BYTE_GAP_MS-1) begin index<=0;gap_age<=0;gap_timeout<=1;end
                else gap_age<=gap_age+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if(BYTE_GAP_MS<1) $fatal(1,"BYTE_GAP_MS must be positive");
    // synthesis translate_on
endmodule
