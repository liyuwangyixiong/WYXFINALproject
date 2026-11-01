`timescale 1ns/1ps
// 参考用户preprocessing.py的Butterworth因果带通思路；这是PPG专用0.5~8Hz定点实现。
// 原例360Hz/0.5~50Hz用于ECG，不能直接复制其系数。此处两色同系数、独立历史、同拍更新。
// 原始值另路完整保留供DC与质量判断；输出AC绝不直接冒充SpO2或身体状态。
module wyx_ppg_bandpass_pair #(
    parameter integer SAMPLE_HZ=100, // 原始样本频率，赫兹；仅支持MAX的100Hz及Pulse的500Hz两组已验证系数
    parameter integer WARMUP_SECONDS=2 // 清空/断流后滤波器预热时长，秒；预热期间不发布有效滤波样本
)(
    input wire clk,rst_n,sample_valid,
    input wire [17:0] raw_a,raw_b,
    output reg filtered_valid,settled,arithmetic_fault,
    output reg [17:0] raw_a_aligned,raw_b_aligned,
    output reg signed [23:0] ac_a,ac_b
);
    localparam integer WARMUP_SAMPLES=SAMPLE_HZ*WARMUP_SECONDS; // 必须收到的真实新样本数；25MHz空时钟不推进滤波
    localparam signed [31:0] B0=(SAMPLE_HZ==100)?32'sd207875994:32'sd48355969; // 带通分子b0，Q30；b1为0，b2等于负b0
    localparam signed [31:0] A1=(SAMPLE_HZ==100)?-32'sd1717818069:-32'sd2050123574; // 分母a1，Q30；方程中减a1乘前次输出
    localparam signed [31:0] A2=(SAMPLE_HZ==100)?32'sd657989836:32'sd977029885; // 分母a2，Q30；两组量化后极点均在单位圆内
    localparam signed [67:0] HALF_COEFF=68'sd536870912; // Q30系数乘积转回Q8状态的最近舍入半格
    localparam signed [67:0] Q8_MAX=68'sd2147483647; // 内部有符号Q8状态的正限幅，触发时明确报告算术异常
    localparam signed [67:0] Q8_MIN=-68'sd2147483648; // 内部有符号Q8状态的负限幅，避免回绕伪造正常波形
    reg initialized;
    reg [17:0] base_a,base_b;
    reg [15:0] warm_count;
    reg signed [31:0] x_a1,x_a2,x_b1,x_b2,y_a1,y_a2,y_b1,y_b2;
    wire signed [31:0] in_a_q8=($signed({1'b0,raw_a})-$signed({1'b0,base_a}))<<<8;
    wire signed [31:0] in_b_q8=($signed({1'b0,raw_b})-$signed({1'b0,base_b}))<<<8;
    wire signed [63:0] pa0=$signed(in_a_q8-x_a2)*B0;
    wire signed [63:0] pa1=$signed(y_a1)*A1;
    wire signed [63:0] pa2=$signed(y_a2)*A2;
    wire signed [63:0] pb0=$signed(in_b_q8-x_b2)*B0;
    wire signed [63:0] pb1=$signed(y_b1)*A1;
    wire signed [63:0] pb2=$signed(y_b2)*A2;
    wire signed [67:0] sum_a={{4{pa0[63]}},pa0}-{{4{pa1[63]}},pa1}-{{4{pa2[63]}},pa2};
    wire signed [67:0] sum_b={{4{pb0[63]}},pb0}-{{4{pb1[63]}},pb1}-{{4{pb2[63]}},pb2};
    wire signed [67:0] next_a=(sum_a+(sum_a<0?HALF_COEFF-1:HALF_COEFF))>>>30;
    wire signed [67:0] next_b=(sum_b+(sum_b<0?HALF_COEFF-1:HALF_COEFF))>>>30;
    wire overflow_a=next_a>Q8_MAX || next_a<Q8_MIN;
    wire overflow_b=next_b>Q8_MAX || next_b<Q8_MIN;
    wire signed [31:0] clipped_a=overflow_a?(next_a<0?32'sh80000000:32'sh7fffffff):next_a[31:0];
    wire signed [31:0] clipped_b=overflow_b?(next_b<0?32'sh80000000:32'sh7fffffff):next_b[31:0];
    wire signed [32:0] out_a=($signed({clipped_a[31],clipped_a})+(clipped_a<0?33'sd127:33'sd128))>>>8;
    wire signed [32:0] out_b=($signed({clipped_b[31],clipped_b})+(clipped_b<0?33'sd127:33'sd128))>>>8;
    always @(posedge clk) begin
        filtered_valid<=0;arithmetic_fault<=0;
        if(!rst_n) begin
            initialized<=0;base_a<=0;base_b<=0;warm_count<=0;settled<=0;
            x_a1<=0;x_a2<=0;x_b1<=0;x_b2<=0;y_a1<=0;y_a2<=0;y_b1<=0;y_b2<=0;
            raw_a_aligned<=0;raw_b_aligned<=0;ac_a<=0;ac_b<=0;
        end else if(sample_valid) begin
            raw_a_aligned<=raw_a;raw_b_aligned<=raw_b;
            if(!initialized) begin
                // 以首个实测值设置静态偏置，等价于常值稳态初值，避免从零启动的巨大DC阶跃。
                initialized<=1;base_a<=raw_a;base_b<=raw_b;warm_count<=1;
            end else begin
                x_a2<=x_a1;x_a1<=in_a_q8;x_b2<=x_b1;x_b1<=in_b_q8;
                y_a2<=y_a1;y_a1<=clipped_a;y_b2<=y_b1;y_b1<=clipped_b;
                ac_a<=out_a[23:0];ac_b<=out_b[23:0];
                arithmetic_fault<=overflow_a || overflow_b;
                if(warm_count<WARMUP_SAMPLES) warm_count<=warm_count+1'b1;
                if(warm_count>=WARMUP_SAMPLES-1 && !overflow_a && !overflow_b) begin filtered_valid<=1;settled<=1;end
                if(overflow_a || overflow_b) begin settled<=0;warm_count<=0;end
            end
        end
    end
    // synthesis translate_off
    initial if((SAMPLE_HZ!=100 && SAMPLE_HZ!=500) || WARMUP_SECONDS<1 || WARMUP_SAMPLES>65535)
        $fatal(1,"PPG filter requires verified 100/500Hz configuration and bounded warmup");
    // synthesis translate_on
endmodule
