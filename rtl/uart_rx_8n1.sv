`timescale 1ns/1ps
// 【用途】异步串口RX，空闲高、低起始位、低位先传、8数据位、1高停止位。
// 两级同步后在位中心采样；假起始脉冲丢弃，停止位低只报告一次并等待线路恢复高。
module uart_rx_8n1 #(
    parameter integer CLK_HZ=25000000, // 输入时钟频率，赫兹
    parameter integer BAUD=115200 // UART波特率；这里固定使用8N1帧格式
)(
    input wire aclk,aresetn,uart_rx,
    output reg [7:0] byte_data,
    output reg byte_valid,frame_error
);
    localparam integer BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD; // 每位时钟数四舍五入；25MHz时为217
    localparam integer HALF_CYCLES=BIT_CYCLES/2; // 起始位中点的等待时钟数
    localparam integer COUNT_W=BIT_CYCLES>1 ? $clog2(BIT_CYCLES) : 1; // 位时间计数器位宽，至少1位
    localparam [2:0] IDLE=0,START=1,DATA=2,STOP=3,WAIT_HIGH=4; // 串口接收状态编码
    (* ASYNC_REG="TRUE" *) reg [1:0] rx_sync=2'b11;
    reg [2:0] state;
    reg [COUNT_W-1:0] count;
    reg [2:0] bit_index;
    reg [7:0] shift_data;
    always @(posedge aclk) begin
        if(!aresetn) begin
            rx_sync<=2'b11;state<=IDLE;count<=0;bit_index<=0;
            shift_data<=0;byte_data<=0;byte_valid<=0;frame_error<=0;
        end else begin
            rx_sync<={rx_sync[0],uart_rx};byte_valid<=0;frame_error<=0;
            case(state)
                IDLE: if(!rx_sync[1]) begin count<=HALF_CYCLES-1;state<=START;end
                START: if(count!=0) count<=count-1'b1;
                    else if(rx_sync[1]) state<=IDLE;
                    else begin count<=BIT_CYCLES-1;bit_index<=0;state<=DATA;end
                DATA: if(count!=0) count<=count-1'b1;
                    else begin
                        shift_data[bit_index]<=rx_sync[1];count<=BIT_CYCLES-1;
                        if(bit_index==7) state<=STOP;else bit_index<=bit_index+1'b1;
                    end
                STOP: if(count!=0) count<=count-1'b1;
                    else if(rx_sync[1]) begin byte_data<=shift_data;byte_valid<=1;state<=IDLE;end
                    else begin frame_error<=1;state<=WAIT_HIGH;end
                WAIT_HIGH: if(rx_sync[1]) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(BAUD<1 || BIT_CYCLES<8) $fatal(1,"UART clock must provide at least eight clocks per bit");
    // synthesis translate_on
endmodule
