`timescale 1ns/1ps
// ============================================================================
// 【用途】已计算心率/血氧的数值平滑，不是原始RED/IR滤波或血氧计算。
// 每路独立：最近3个可信新值取中位数，再做 y += (median-y)/2**EMA_SHIFT。
// 默认新值权重1/2，内部保留Q8余数，避免直接整数递推的小变化粘滞。
// 第3个可信新值才产生首个结果，并直接用其中位数初始化，不从零缓慢爬升。
// 仅抑制孤立1点尖峰；连续2点同向异常可能穿过，不能取代原始质量/范围旁路。
// 延迟按“可信指标更新数”计算，不把原始PPG采样率当作指标刷新率。
// 【握手】valid&&ready接收一次；反压期间结果保持。旧值/坏值/编码非法不推进历史。
// 【控制】flush清除两级历史；invalidate_output仅取消待发结果，保留可信历史。
// ============================================================================
module metric_robust_smoother #(
    parameter integer DATA_WIDTH = 16,      // 无符号输入/输出位宽，单位：位
    parameter integer EMA_SHIFT = 1,        // 指数平滑新值权重为1/2的此幂；1表示1/2，越大越慢
    parameter integer MIN_VALUE = 0,        // 允许输入的编码下限，不是生理告警下限
    parameter integer MAX_VALUE = 65535     // 允许输入的编码上限；血氧通道覆盖为10000
) (
    input wire aclk, aresetn, flush, invalidate_output,
    input wire [DATA_WIDTH-1:0] sample_data,
    input wire sample_valid,
    output wire sample_ready,
    input wire sample_new, sample_good,
    output reg [DATA_WIDTH-1:0] smooth_data,
    output wire smooth_valid,
    input wire smooth_ready,
    output wire warming_up,
    output reg rejected,
    output reg [2:0] reject_reason
);
    localparam integer FRACTION_BITS = 8;    // 内部保留8位二进制小数；不改变外部乘100整数单位
    localparam integer STATE_WIDTH = DATA_WIDTH + FRACTION_BITS + 2; // 正数状态与有符号差值的安全运算位宽
    localparam signed [STATE_WIDTH-1:0] STEP_HALF = 2**(EMA_SHIFT-1); // 递推除法的最近舍入半格偏置
    localparam signed [STATE_WIDTH-1:0] OUTPUT_HALF = 2**(FRACTION_BITS-1); // Q8转输出整数的半格舍入偏置
    reg [DATA_WIDTH-1:0] previous_one, previous_two;
    reg [1:0] count;
    reg signed [STATE_WIDTH-1:0] ema_q;
    reg output_pending;
    wire active = aresetn && !flush;
    wire signed [DATA_WIDTH:0] value_ext = $signed({1'b0,sample_data});
    wire in_range = (value_ext >= MIN_VALUE) && (value_ext <= MAX_VALUE);
    wire admissible = sample_new && sample_good && in_range;

    // 【01：中位数】比较3个数而非求平均；单个孤立大/小尖峰不直接拉偏输出。
    wire [DATA_WIDTH-1:0] median_value = (sample_data > previous_one) ?
        ((previous_one > previous_two) ? previous_one :
         ((sample_data > previous_two) ? previous_two : sample_data)) :
        ((sample_data > previous_two) ? sample_data :
         ((previous_one > previous_two) ? previous_two : previous_one));
    wire signed [STATE_WIDTH-1:0] target_q = $signed({2'b00,median_value,{FRACTION_BITS{1'b0}}});
    // 【02：定点EMA】差值先扩宽；正负都最近舍入，恰好半格远离零。
    wire signed [STATE_WIDTH-1:0] delta_q = target_q - ema_q;
    wire signed [STATE_WIDTH-1:0] delta_bias = delta_q[STATE_WIDTH-1] ? STEP_HALF-1'b1 : STEP_HALF;
    wire signed [STATE_WIDTH-1:0] step_q = (delta_q + delta_bias) >>> EMA_SHIFT;
    wire signed [STATE_WIDTH-1:0] next_q = (count < 3) ? target_q : ema_q + step_q;
    wire signed [STATE_WIDTH-1:0] rounded_value = (next_q + OUTPUT_HALF) >>> FRACTION_BITS;

    // 【03：单槽输出】拒绝的事务不占输出槽；暂停时不重复处理同一可信值。
    assign smooth_valid = active && output_pending && !invalidate_output;
    assign sample_ready = active && (!admissible || !output_pending || smooth_ready || invalidate_output);
    assign warming_up = !active || count < 3;
    always @(posedge aclk) begin
        if (!active) begin
            previous_one <= 0; previous_two <= 0; count <= 0;
            ema_q <= 0; smooth_data <= 0; output_pending <= 0;
            rejected <= 0; reject_reason <= 0;
        end else begin
            rejected <= 0; reject_reason <= 0;
            if ((output_pending && smooth_ready) || invalidate_output)
                output_pending <= 0;
            if (sample_valid && sample_ready) begin
                if (!admissible) begin
                    rejected <= 1;
                    reject_reason <= {!in_range,!sample_good,!sample_new};
                end else begin
                    previous_two <= previous_one;
                    previous_one <= sample_data;
                    if (count < 3) count <= count + 1'b1;
                    if (count >= 2) begin
                        ema_q <= next_q;
                        smooth_data <= rounded_value[DATA_WIDTH-1:0];
                        output_pending <= 1;
                    end
                end
            end
        end
    end
    // 参数合法性保护不是自检数据源，不生成综合硬件。
    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 2 || DATA_WIDTH > 24 || EMA_SHIFT < 1 || EMA_SHIFT > 8 ||
            MIN_VALUE < 0 || MIN_VALUE > MAX_VALUE || MAX_VALUE > (2**DATA_WIDTH-1))
            $fatal(1,"Unsupported robust metric smoother configuration");
    end
    // synthesis translate_on
endmodule
