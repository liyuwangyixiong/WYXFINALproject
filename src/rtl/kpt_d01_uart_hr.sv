`timescale 1ns/1ps
// 【用途】KPT_D01真实串口 -> 九字节帧 -> 心率乘100 -> 带反压单槽接口。
// 完整新帧增加序号，即便两次心率相同也是真正的新报告；垃圾字节/波形不能刷新帧年龄。
// 编码0或乘100后越出16位时发good=0的无效事务，不限幅、不把坏值当正常心率。
// 通信成功不等于光学测量质量已获验证；当前协议没有接触质量/样本时间戳字段。
module kpt_d01_uart_hr #(
    parameter integer CLK_HZ=25000000, // UART采样时钟频率，赫兹
    parameter integer BAUD=115200, // KPT_D01默认波特率，8N1
    parameter integer BYTE_GAP_MS=20, // 半帧字节间隔容错，毫秒
    parameter integer FRAME_STALE_MS=3000, // 无完整数值帧超时，毫秒；仅完整帧刷新
    parameter integer HR_MAX_BPM=655 // 保证乘100不溢出16位的编码上限，不代表生理正常上限
)(
    input wire aclk,aresetn,tick_1ms,uart_rx,
    output reg [15:0] metric_data,
    output wire metric_valid,
    input wire metric_ready,
    output reg metric_good,
    output reg comm_event,comm_error,comm_timeout,sample_event,
    output reg [31:0] sample_sequence,
    output wire frame_event,
    output wire [15:0] raw_bpm,
    output wire format_error,
    output reg timeout_event,encoding_error,overrun_event,
    output wire link_stale
);
    localparam integer AGE_W=FRAME_STALE_MS>1 ? $clog2(FRAME_STALE_MS+1) : 1; // 完整数值帧年龄计数器位宽
    wire [7:0] byte_data;
    wire byte_valid,uart_error,gap_timeout;
    uart_rx_8n1 #(
        .CLK_HZ(CLK_HZ), // 接收器真实输入时钟，赫兹
        .BAUD(BAUD) // 串口波特率
    ) u_rx(.aclk(aclk),.aresetn(aresetn),.uart_rx(uart_rx),
        .byte_data(byte_data),.byte_valid(byte_valid),.frame_error(uart_error));
    kpt_d01_frame_parser #(
        .BYTE_GAP_MS(BYTE_GAP_MS) // 半帧的字节间隔超时，毫秒
    ) u_parser(.aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),
        .byte_data(byte_data),.byte_valid(byte_valid),.uart_error(uart_error),
        .frame_event(frame_event),.format_error(format_error),.gap_timeout(gap_timeout),.hr_bpm(raw_bpm));
    reg [AGE_W-1:0] frame_age,pending_age;
    reg stale_latched,pending,stage_valid,stage_good;
    reg [15:0] stage_data;
    wire encoding_good=raw_bpm!=0 && raw_bpm<=HR_MAX_BPM;
    wire deadline=tick_1ms && frame_age>=FRAME_STALE_MS-1 && !frame_event;
    wire pending_deadline=tick_1ms && pending && pending_age>=FRAME_STALE_MS-1;
    assign link_stale=aresetn && stale_latched;
    assign metric_valid=aresetn && pending && !stale_latched && !deadline && !pending_deadline;
    always @(posedge aclk) begin
        if(!aresetn) begin
            frame_age<=0;pending_age<=0;stale_latched<=0;pending<=0;stage_valid<=0;stage_good<=0;stage_data<=0;
            metric_data<=0;metric_good<=0;comm_event<=0;comm_error<=0;comm_timeout<=0;
            sample_event<=0;sample_sequence<=0;timeout_event<=0;encoding_error<=0;overrun_event<=0;
        end else begin
            comm_event<=0;comm_error<=0;comm_timeout<=0;sample_event<=0;
            timeout_event<=0;encoding_error<=0;overrun_event<=0;stage_valid<=0;
            if(metric_valid && metric_ready) pending<=0;
            // 缓冲条目的年龄独立于串口链路年龄；新帧不断到达也不能使旧条目返老还童。
            if(pending_deadline) begin pending<=0;overrun_event<=1;end
            else if(pending && tick_1ms) pending_age<=pending_age+1'b1;
            // 先报告器件真实更新，下一拍才发布数值，使C监视器先建立来源可用状态。
            if(stage_valid) begin
                if(!pending || (metric_valid && metric_ready) || pending_deadline) begin
                    metric_data<=stage_data;metric_good<=stage_good;pending<=1;pending_age<=0;
                end else overrun_event<=1; // 下游反压时保持已承诺数据，丢弃新条目并明确报告
            end
            if(frame_event) begin
                frame_age<=0;stale_latched<=0;
                comm_event<=1;sample_event<=1;sample_sequence<=sample_sequence+1'b1;
                stage_valid<=1;stage_good<=encoding_good;
                stage_data<=encoding_good ? raw_bpm*16'd100 : 16'd0;
                encoding_error<=!encoding_good;
            end else begin
                if(tick_1ms) begin
                    if(deadline) begin
                        frame_age<=0;stale_latched<=1;pending<=0;stage_valid<=0;
                        comm_event<=1;comm_timeout<=1;timeout_event<=1;
                    end else frame_age<=frame_age+1'b1;
                end
                if(format_error || gap_timeout) begin
                    comm_event<=1;comm_error<=format_error;comm_timeout<=gap_timeout;
                    timeout_event<=gap_timeout;
                end
            end
        end
    end
    // synthesis translate_off
    initial if(FRAME_STALE_MS<1 || HR_MAX_BPM<1 || HR_MAX_BPM>655)
        $fatal(1,"Invalid UART heart-rate adapter configuration");
    // synthesis translate_on
endmodule
