`timescale 1ns/1ps
// 200 MHz 实验滤波器：一次100 Hz样本的运算分布到多个时钟周期。
// 与原实现相同的定点系数、舍入和限幅；输出有效位随结果一起延迟。
module wyx_ppg_bandpass_pair_200 #(
    parameter integer SAMPLE_HZ=100,
    parameter integer WARMUP_SECONDS=2
)(
    input wire clk,rst_n,sample_valid,
    input wire [17:0] raw_a,raw_b,
    output reg filtered_valid,settled,arithmetic_fault,
    output reg [17:0] raw_a_aligned,raw_b_aligned,
    output reg signed [23:0] ac_a,ac_b
);
    localparam integer WARMUP_SAMPLES=SAMPLE_HZ*WARMUP_SECONDS;
    localparam signed [31:0] B0=(SAMPLE_HZ==100)?32'sd207875994:32'sd48355969;
    localparam signed [31:0] A1=(SAMPLE_HZ==100)?-32'sd1717818069:-32'sd2050123574;
    localparam signed [31:0] A2=(SAMPLE_HZ==100)?32'sd657989836:32'sd977029885;
    localparam signed [67:0] HALF_COEFF=68'sd536870912;
    localparam signed [67:0] Q8_MAX=68'sd2147483647;
    localparam signed [67:0] Q8_MIN=-68'sd2147483648;

    reg initialized,overlap_seen;
    reg [17:0] base_a,base_b,held_raw_a,held_raw_b;
    reg [15:0] warm_count;
    reg signed [31:0] x_a1,x_a2,x_b1,x_b2,y_a1,y_a2,y_b1,y_b2;
    reg signed [31:0] in_a_reg,in_b_reg,dx_a,dx_b;
    wire signed [63:0] pa0,pa1,pa2,pb0,pb1,pb2;
    reg signed [67:0] sum_a0,sum_b0,sum_a,sum_b,rounded_a,rounded_b;
    reg signed [31:0] clipped_a,clipped_b;
    reg overflow_a,overflow_b;
    reg [3:0] stage;

    wyx_mul_s32_const_pipeline #(.C(B0)) mul_pa0(.clk(clk),.x(dx_a),.p(pa0));
    wyx_mul_s32_const_pipeline #(.C(A1)) mul_pa1(.clk(clk),.x(y_a1),.p(pa1));
    wyx_mul_s32_const_pipeline #(.C(A2)) mul_pa2(.clk(clk),.x(y_a2),.p(pa2));
    wyx_mul_s32_const_pipeline #(.C(B0)) mul_pb0(.clk(clk),.x(dx_b),.p(pb0));
    wyx_mul_s32_const_pipeline #(.C(A1)) mul_pb1(.clk(clk),.x(y_b1),.p(pb1));
    wyx_mul_s32_const_pipeline #(.C(A2)) mul_pb2(.clk(clk),.x(y_b2),.p(pb2));

    wire signed [31:0] in_a_q8=($signed({1'b0,raw_a})-$signed({1'b0,base_a}))<<<8;
    wire signed [31:0] in_b_q8=($signed({1'b0,raw_b})-$signed({1'b0,base_b}))<<<8;
    wire signed [67:0] pa0_ext={{4{pa0[63]}},pa0};
    wire signed [67:0] pa1_ext={{4{pa1[63]}},pa1};
    wire signed [67:0] pa2_ext={{4{pa2[63]}},pa2};
    wire signed [67:0] pb0_ext={{4{pb0[63]}},pb0};
    wire signed [67:0] pb1_ext={{4{pb1[63]}},pb1};
    wire signed [67:0] pb2_ext={{4{pb2[63]}},pb2};
    wire ov_a=rounded_a>Q8_MAX || rounded_a<Q8_MIN;
    wire ov_b=rounded_b>Q8_MAX || rounded_b<Q8_MIN;
    wire signed [32:0] out_a=($signed({clipped_a[31],clipped_a})+(clipped_a<0?33'sd127:33'sd128))>>>8;
    wire signed [32:0] out_b=($signed({clipped_b[31],clipped_b})+(clipped_b<0?33'sd127:33'sd128))>>>8;

    always @(posedge clk) begin
        filtered_valid<=0;
        arithmetic_fault<=0;
        if (!rst_n) begin
            initialized<=0;overlap_seen<=0;stage<=0;
            base_a<=0;base_b<=0;held_raw_a<=0;held_raw_b<=0;warm_count<=0;settled<=0;
            x_a1<=0;x_a2<=0;x_b1<=0;x_b2<=0;y_a1<=0;y_a2<=0;y_b1<=0;y_b2<=0;
            in_a_reg<=0;in_b_reg<=0;dx_a<=0;dx_b<=0;
            sum_a0<=0;sum_b0<=0;sum_a<=0;sum_b<=0;rounded_a<=0;rounded_b<=0;
            clipped_a<=0;clipped_b<=0;overflow_a<=0;overflow_b<=0;
            raw_a_aligned<=0;raw_b_aligned<=0;ac_a<=0;ac_b<=0;
        end else begin
            if (sample_valid && stage!=0) overlap_seen<=1;
            case (stage)
                0: if (sample_valid) begin
                    if (!initialized) begin
                        initialized<=1;base_a<=raw_a;base_b<=raw_b;warm_count<=1;
                        raw_a_aligned<=raw_a;raw_b_aligned<=raw_b;
                    end else begin
                        held_raw_a<=raw_a;held_raw_b<=raw_b;
                        in_a_reg<=in_a_q8;in_b_reg<=in_b_q8;
                        overlap_seen<=0;stage<=1;
                    end
                end
                1: begin
                    dx_a<=in_a_reg-x_a2;dx_b<=in_b_reg-x_b2;
                    stage<=2;
                end
                2,3,4,5: stage<=stage+1'b1;
                6: begin
                    sum_a0<=pa0_ext-pa1_ext;sum_b0<=pb0_ext-pb1_ext;
                    stage<=7;
                end
                7: begin
                    sum_a<=sum_a0-pa2_ext;sum_b<=sum_b0-pb2_ext;
                    stage<=8;
                end
                8: begin
                    rounded_a<=(sum_a+(sum_a<0?HALF_COEFF-1:HALF_COEFF))>>>30;
                    rounded_b<=(sum_b+(sum_b<0?HALF_COEFF-1:HALF_COEFF))>>>30;
                    stage<=9;
                end
                9: begin
                    overflow_a<=ov_a;overflow_b<=ov_b;
                    clipped_a<=ov_a?(rounded_a<0?32'sh80000000:32'sh7fffffff):rounded_a[31:0];
                    clipped_b<=ov_b?(rounded_b<0?32'sh80000000:32'sh7fffffff):rounded_b[31:0];
                    stage<=10;
                end
                10: begin
                    stage<=0;
                    if (overlap_seen || sample_valid) begin
                        initialized<=0;settled<=0;warm_count<=0;
                        arithmetic_fault<=1;
                    end else begin
                        raw_a_aligned<=held_raw_a;raw_b_aligned<=held_raw_b;
                        x_a2<=x_a1;x_a1<=in_a_reg;x_b2<=x_b1;x_b1<=in_b_reg;
                        y_a2<=y_a1;y_a1<=clipped_a;y_b2<=y_b1;y_b1<=clipped_b;
                        ac_a<=out_a[23:0];ac_b<=out_b[23:0];
                        arithmetic_fault<=overflow_a || overflow_b;
                        if (warm_count<WARMUP_SAMPLES) warm_count<=warm_count+1'b1;
                        if (warm_count>=WARMUP_SAMPLES-1 && !overflow_a && !overflow_b) begin
                            filtered_valid<=1;settled<=1;
                        end
                        if (overflow_a || overflow_b) begin settled<=0;warm_count<=0;end
                    end
                end
            endcase
        end
    end
    // synthesis translate_off
    initial if((SAMPLE_HZ!=100 && SAMPLE_HZ!=500) || WARMUP_SECONDS<1 || WARMUP_SAMPLES>65535)
        $fatal(1,"PPG filter requires verified 100/500Hz configuration and bounded warmup");
    // synthesis translate_on
endmodule

// 单个16x16乘法适配DSP48E1；分级相加避免32x32乘法的DSP级联跨越一拍。
module wyx_mul_s32_const_pipeline #(
    parameter signed [31:0] C=32'sd0
)(input wire clk,input wire signed [31:0] x,output reg signed [63:0] p);
    localparam [15:0] CL=C[15:0];
    localparam signed [15:0] CH=C[31:16];
    wire [15:0] xl=x[15:0];
    wire signed [15:0] xh=x[31:16];
    reg [31:0] p00;
    reg signed [32:0] p01,p10;
    reg signed [31:0] p11;
    reg signed [33:0] mid;
    reg signed [63:0] lowplus;
    always @(posedge clk) begin
        p00<=xl*CL;
        p01<=$signed({1'b0,xl})*CH;
        p10<=xh*$signed({1'b0,CL});
        p11<=xh*CH;
        mid<=$signed(p01)+$signed(p10);
        lowplus<=$signed({32'b0,p00})+($signed({{30{mid[33]}},mid})<<<16);
        p<=lowplus+($signed({{32{p11[31]}},p11})<<<32);
    end
endmodule
