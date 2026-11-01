`timescale 1ns/1ps
// ============================================================================
// 【文件作用】一个数值通道的滑动平均器；当前顶层用于体温、室温两条独立曲线。
// 最近 N=2**WINDOW_LOG2 个“成功接收、可信、真正新”的值求平均，单位不改变。
// 默认 N=4。不是原始 PPG 去噪算法，不是血氧估算，不预测丢失数据。
// 【参数】DATA_WIDTH=数据位宽；SIGNED_INPUT=温度时取1、心率/血氧取0；
// WINDOW_LOG2=窗口长度的log2；MIN_VALUE/MAX_VALUE=允许输入的编码边界。
// 【入口】sample_valid && sample_ready 接收一笔；new/good 必须与数值一起保持。
// 【出口】smooth_valid && smooth_ready 消费一笔；暂停接收时输出保持不变。
// 【控制】flush 清除历史；invalidate_output 只作废待发结果，不抹掉好的历史。
// 【诊断】warming_up=历史未满；rejected=本拍拒绝事务；原因 bit0旧/bit1坏/bit2编码越界。
// ============================================================================
// Average the last 2**WINDOW_LOG2 accepted, good, NEW feature values.
// Units are unchanged. Round to nearest, ties away from zero.
// No output is produced until a full window exists. No interpolation or
// prediction is performed during gaps. One registered ready/valid output.
module metric_moving_average #(
    parameter integer DATA_WIDTH = 16,    // 输入和输出数值位宽，单位：位
    parameter integer SIGNED_INPUT = 0,   // 有符号开关：1用于温度，0用于心率和血氧
    parameter integer WINDOW_LOG2 = 2,    // 平滑窗长度的以2为底对数；2表示最近4个可信新值
    parameter integer MIN_VALUE = 0,      // 允许输入的编码下限，不是生理告警下限
    parameter integer MAX_VALUE = 65535   // 允许输入的编码上限，不是生理告警上限
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire                  flush,
    // Cancel an unsafe pending output WITHOUT clearing sample history.
    input  wire                  invalidate_output,
    input  wire [DATA_WIDTH-1:0] sample_data,
    input  wire                  sample_valid,
    output wire                  sample_ready,
    input  wire                  sample_new,
    input  wire                  sample_good,
    output reg  [DATA_WIDTH-1:0] smooth_data,
    output wire                  smooth_valid,
    input  wire                  smooth_ready,
    output wire                  warming_up,
    output reg                   rejected,
    // bit 0: old transaction; bit 1: upstream bad; bit 2: range invalid.
    output reg [2:0]             reject_reason
);
    localparam integer WINDOW = 2**WINDOW_LOG2; // 实际平滑窗长度，单位：个可信新数值
    // 【01：历史存储】history 是环形缓存；write_index 指向下一项被覆盖的旧值。
    // count 是预热计数，满窗后不再增加；sum_q 是当前缓存总和，非平均值。
    // Extra bits also cover the intermediate add before subtraction.
    localparam integer ACC_WIDTH = DATA_WIDTH + WINDOW_LOG2 + 2; // 累加及中间运算位宽，含防溢出余量
    localparam signed [ACC_WIDTH-1:0] HALF = 2**(WINDOW_LOG2-1);  // 最近舍入的半窗偏置，正负半格均远离零
    reg signed [DATA_WIDTH:0] history [0:WINDOW-1];
    reg [WINDOW_LOG2-1:0] write_index;
    reg [WINDOW_LOG2:0] count;
    reg signed [ACC_WIDTH-1:0] sum_q;
    reg output_pending;
    // 【02：数值判定】温度做符号扩展；无符号数补0，避免高位为1被当负数。
    wire active = aresetn && !flush;
    wire signed [DATA_WIDTH:0] value_ext =
        SIGNED_INPUT ? $signed({sample_data[DATA_WIDTH-1], sample_data}) :
                       $signed({1'b0, sample_data});
    wire in_range = (value_ext >= MIN_VALUE) && (value_ext <= MAX_VALUE);
    wire admissible = sample_new && sample_good && in_range;
    // 【03：滑动求和】新总和=旧总和+本次新值-当前要覆盖的旧值。
    // 不必每次重新把四项相加；除以2的幂使用算术右移，减少硬件代价。
    wire signed [ACC_WIDTH-1:0] next_sum =
        sum_q + value_ext - history[write_index];
    // 【优化：等价舍入】正数加 HALF，负数加 HALF-1，再统一算术右移。
    // 仍是“四舍五入，恰好半格时远离零”，负温度也与原算法逐位一致。
    // 避免原负数分支的“取负→加偏置→移位→再取负”组合运算链。
    wire signed [ACC_WIDTH-1:0] rounding_bias =
        next_sum[ACC_WIDTH-1] ? (HALF - 1'b1) : HALF;
    wire signed [ACC_WIDTH-1:0] rounded_average =
        (next_sum + rounding_bias) >>> WINDOW_LOG2;

    // 【04：握手控制】尚无结果、下游本拍接走结果或旧结果被作废时可接收新值。
    // 明确拒绝的事务不占平均器输出缓存，即使下游暂停也可以被接收后丢弃。
    assign smooth_valid = active && output_pending && !invalidate_output;
    // Rejected tokens can be consumed even while a prior result is stalled.
    assign sample_ready = active &&
        (!admissible || !output_pending || smooth_ready || invalidate_output);
    assign warming_up = !active || (count < WINDOW);

    integer k;
    // 【05：同步状态更新】aresetn=0 或 flush=1 都清历史，恢复后重新收集满窗。
    always @(posedge aclk) begin
        if (!active) begin
            write_index <= 0;
            count <= 0;
            sum_q <= 0;
            smooth_data <= 0;
            output_pending <= 0;
            rejected <= 0;
            reject_reason <= 0;
            for (k = 0; k < WINDOW; k = k + 1)
                history[k] <= 0;
        end else begin
            // rejected/reject_reason 是本拍诊断，不是长期锁存的器件故障。
            rejected <= 0;
            reject_reason <= 0;
            if ((output_pending && smooth_ready) || invalidate_output)
                output_pending <= 0;
            if (sample_valid && sample_ready) begin
                if (!admissible) begin
                    rejected <= 1;
                    reject_reason <= {!in_range, !sample_good, !sample_new};
                end else begin
                    // 只有 admissible 的新值才进入环形历史并推进窗口。
                    history[write_index] <= value_ext;
                    write_index <= write_index + 1'b1;
                    sum_q <= next_sum;
                    if (count < WINDOW)
                        count <= count + 1'b1;
                    if (count >= WINDOW-1) begin
                        // 第 N 个有效新值到来时产生首个结果；之前不能输出零填充平均。
                        smooth_data <= rounded_average[DATA_WIDTH-1:0];
                        output_pending <= 1;
                    end
                end
            end
        end
    end

    // Supported configuration guard for simulation. Ranges are data-domain
    // 【06：仿真参数保护】非法位宽/窗口会直接结束测试；该检查不生成综合硬件。
    // bounds, NOT clinical alarm thresholds or a diagnosis.
    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 2 || DATA_WIDTH > 24 ||
            WINDOW_LOG2 < 1 || WINDOW_LOG2 > 8 || MIN_VALUE > MAX_VALUE)
            $fatal(1, "Unsupported moving-average configuration");
    end
    // synthesis translate_on
endmodule
