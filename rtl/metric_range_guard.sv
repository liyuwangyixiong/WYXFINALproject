`timescale 1ns/1ps
// ============================================================================
// 【文件作用】一个最终数值通道的新鲜度与持续越界监测器；顶层实例化四次。
// 有可信数据持续超出项目配置范围 => range_alarm；不是“该传感器必然坏了”。
// 确认和恢复都要求“连续可信新样本数 + 持续时间”，避免单点跳变误报。
// 【编码】SIGNED_INPUT 控制温度符号；CODE_MIN/CODE_MAX 是合法编码，不是告警限值。
// 【范围】lower_limit/upper_limit 是项目配置；hysteresis 是恢复区内缩量。
// 【时基】tick_1ms 是每真实毫秒一拍；sample_event 是已接收的数值事务。
// 【输出】candidate=正在积累越界证据；config_error=范围未配好或不合法；
// fresh=最近有可信数值且最新事务可信；history_expired=曾收到值但已长期未更新。
// 缺样不能凭“时间过去了”自行确认/清除告警；必须再收到可信新数值。
// ============================================================================
// Trustworthy physiological excursions are ALARMS, not sensor failures.
// Require BOTH consecutive new measurements AND elapsed confirmation time.
// A missing/invalid measurement cannot create or clear a physiological alarm.
module metric_range_guard #(
    parameter integer SIGNED_INPUT = 0,    // 输入编码解释：1为有符号温度，0为无符号心率/血氧
    parameter integer CODE_MIN = 0,        // 输入合法编码下限，不是运行时告警下限
    parameter integer CODE_MAX = 65535,    // 输入合法编码上限，不是运行时告警上限
    parameter integer CONFIRM_SAMPLES = 3,// 确认持续越界所需连续可信新结果数，单位：个
    parameter integer RECOVER_SAMPLES = 3,// 清除越界告警所需连续恢复区新结果数，单位：个
    parameter integer CONFIRM_MS = 3000,   // 确认越界还必须满足的持续时间，单位：毫秒
    parameter integer RECOVER_MS = 2000,   // 清除越界还必须满足的恢复持续时间，单位：毫秒
    parameter integer FRESH_MS = 5000      // 最终数值允许的最大更新年龄，单位：毫秒
) (
    input wire aclk, aresetn, tick_1ms,
    input wire sample_event, sample_new, sample_good,
    input wire [15:0] sample_data,
    input wire limits_valid,
    input wire signed [31:0] lower_limit, upper_limit,
    input wire [15:0] hysteresis,
    output reg range_alarm,
    output wire candidate,
    output wire config_error,
    output wire fresh,
    output wire history_expired
);
    // 【01：状态量】age=距离上次可信新值的毫秒数；bad/good_time=确认/恢复计时。
    // bad/good_samples=连续越界/恢复区样本数；bad/good_run=该段过程是否已开始。
    // seen=至少有过一次可信新值；latest_good=最近一次接收事务是否可信。
    // previous_* 用来检测配置变化，避免把旧阈值积累的证据套到新阈值上。
    // 【优化：各自定宽】每个饱和计数器只覆盖自身门限，不被其它门限撑宽。
    // 至少保留1位；门限、饱和行为、确认及恢复条件均不改变。
    localparam integer AGE_W = FRESH_MS > 1 ? $clog2(FRESH_MS + 1) : 1;              // 数值年龄计数器位宽，至少1位
    localparam integer BAD_TIME_W = CONFIRM_MS > 1 ? $clog2(CONFIRM_MS + 1) : 1;     // 越界持续时间计数器位宽
    localparam integer GOOD_TIME_W = RECOVER_MS > 1 ? $clog2(RECOVER_MS + 1) : 1;     // 恢复持续时间计数器位宽
    localparam integer BAD_COUNT_W = $clog2(CONFIRM_SAMPLES + 1);                   // 连续越界新结果计数器位宽
    localparam integer GOOD_COUNT_W = $clog2(RECOVER_SAMPLES + 1);                  // 连续恢复区新结果计数器位宽
    reg [AGE_W-1:0] age;
    reg [BAD_TIME_W-1:0] bad_time;
    reg [GOOD_TIME_W-1:0] good_time;
    reg [BAD_COUNT_W-1:0] bad_samples;
    reg [GOOD_COUNT_W-1:0] good_samples;
    reg seen, latest_good, bad_run, good_run;
    reg previous_valid;
    reg signed [31:0] previous_low, previous_high;
    reg [15:0] previous_hysteresis;
    wire signed [31:0] value = SIGNED_INPUT ? $signed(sample_data) : $signed({1'b0, sample_data});
    // 【02：可信事件】必须是已接收、新、可信、合法编码四个条件同时成立。
    wire code_good = value >= CODE_MIN && value <= CODE_MAX;
    wire trustworthy = sample_event && sample_new && sample_good && code_good;
    wire signed [31:0] hyst = $signed({1'b0, hysteresis});
    // 【03：配置校验】不能上下限颠倒、越出编码域、或让恢复区被滞回挤没。
    assign config_error = !limits_valid || lower_limit > upper_limit ||
        lower_limit < CODE_MIN || upper_limit > CODE_MAX ||
        ((hyst <<< 1) > (upper_limit - lower_limit));
    wire outside = value < lower_limit || value > upper_limit;
    // 原告警区间为 [lower,upper]，恢复需要进入 [lower+hyst,upper-hyst]。
    // 留在边界附近不会马上恢复，防止告警在阈值附近反复跳变。
    wire inside_recovery = value >= lower_limit + hyst && value <= upper_limit - hyst;
    wire config_changed = previous_valid != limits_valid || previous_low != lower_limit ||
                          previous_high != upper_limit || previous_hysteresis != hysteresis;
    assign fresh = aresetn && seen && latest_good && age < FRESH_MS;
    assign history_expired = seen && age >= FRESH_MS;
    assign candidate = bad_run && !range_alarm && !config_error;
    // 【04：同步计时】每次可信新值将 age 清0；只有毫秒脉冲才让计时器加1。
    always @(posedge aclk) begin
        if (!aresetn) begin
            age <= 0; bad_time <= 0; good_time <= 0;
            bad_samples <= 0; good_samples <= 0; seen <= 0; latest_good <= 0;
            bad_run <= 0; good_run <= 0; range_alarm <= 0;
            previous_valid <= 0; previous_low <= 0; previous_high <= 0; previous_hysteresis <= 0;
        end else begin
            previous_valid <= limits_valid; previous_low <= lower_limit;
            previous_high <= upper_limit; previous_hysteresis <= hysteresis;
            if (trustworthy) begin age <= 0; seen <= 1; end
            else if (tick_1ms && age < FRESH_MS) age <= age + 1'b1;
            if (sample_event) latest_good <= sample_new && sample_good && code_good;
            if (tick_1ms && bad_run && bad_time < CONFIRM_MS) bad_time <= bad_time + 1'b1;
            if (tick_1ms && good_run && good_time < RECOVER_MS) good_time <= good_time + 1'b1;
            if (config_error || config_changed) begin
                // 阈值改变/失效时取消旧判据及其告警；顶层用 config_error 报 Warning。
                bad_samples <= 0; good_samples <= 0; bad_time <= 0; good_time <= 0;
                bad_run <= 0; good_run <= 0; range_alarm <= 0;
            end else if (trustworthy) begin
                if (outside) begin
                    // 【05：确认越界】本次越界中断恢复计数；不连续或不新鲜则重起。
                    // 确认条件在可信事务到来时检查，并同时核对样本数与经过时间。
                    good_samples <= 0; good_time <= 0; good_run <= 0;
                    if (!bad_run || !fresh) begin bad_samples <= 1; bad_time <= 0; end
                    else if (bad_samples < CONFIRM_SAMPLES) bad_samples <= bad_samples + 1'b1;
                    bad_run <= 1;
                    if (bad_run && fresh && bad_samples >= CONFIRM_SAMPLES-1 &&
                        (bad_time >= CONFIRM_MS || (tick_1ms && bad_time >= CONFIRM_MS-1)))
                        range_alarm <= 1;
                end else begin
                    // 【06：确认恢复】任意回到正常区间的值会打断越界候选。
                    // 但已确认告警必须连续处于更窄的恢复区并满足次数+时间才清除。
                    bad_samples <= 0; bad_time <= 0; bad_run <= 0;
                    if (inside_recovery) begin
                        if (!good_run || !fresh) begin good_samples <= 1; good_time <= 0; end
                        else if (good_samples < RECOVER_SAMPLES) good_samples <= good_samples + 1'b1;
                        good_run <= 1;
                        if (good_run && fresh && good_samples >= RECOVER_SAMPLES-1 &&
                            (good_time >= RECOVER_MS || (tick_1ms && good_time >= RECOVER_MS-1)))
                            range_alarm <= 0;
                    end else begin good_samples <= 0; good_time <= 0; good_run <= 0; end
                end
            end else if (history_expired) begin
                // 【07：长期缺样】取消候选计数，不能拿旧值继续积累证据。
                // 已有 range_alarm 不在这里伪造恢复；顶层用可用标志取消风险参与。
                bad_samples <= 0; good_samples <= 0; bad_time <= 0; good_time <= 0;
                bad_run <= 0; good_run <= 0;
            end
        end
    end
    // synthesis translate_off
    // 【08：仅仿真检查】工程参数必须为合法正数，不是可综合的判断电路。
    initial if (CONFIRM_SAMPLES < 2 || RECOVER_SAMPLES < 2 || CONFIRM_MS < 1 || RECOVER_MS < 1 || FRESH_MS < 1)
        $fatal(1, "Invalid range qualification parameters");
    // synthesis translate_on
endmodule
