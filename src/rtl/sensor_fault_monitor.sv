`timescale 1ns/1ps
// ============================================================================
// 【文件作用】监视一颗物理器件的通信、真实更新、冻结证据和可选 PPG 质量。
// 四颗器件各实例化一次；同一器件的三个原因不会被算成三个坏传感器。
// 【故障位图】fault_reason[0]=通信；[1]=无更新/冻结；[2]=质量坏/质量报告超时。
// 【候选】pending_reason 对应待确认原因，不直接开启故障灯或蜂鸣器。
// 【可用】available 是安全使用条件，比“fault_reason==0”更严格。
// 一个坏窗/短冻结证据可先暂停数据，但须达到持续条件才锁存器件故障。
// 【事件要求】comm_event=完成一笔事务的一拍；sample_event=一次转换报告的一拍；
// quality_event=完成一个窗口的一拍；tick_1ms=真实每毫秒一拍，全部在 aclk 域。
// sample_sequence 是真实新转换编号，不可用“读了几次寄存器”来假装新样本。
// ============================================================================
// One instance per PHYSICAL device, not per derived measurement.
// All events/tick are single-cycle strobes in aclk. seq identifies an actual
// new conversion/FIFO pair, never just the number of I2C read attempts.
module sensor_fault_monitor #(
    parameter integer COMM_FAIL_LIMIT = 3,        // 连续多少笔失败事务才确认通信故障，单位：笔
    parameter integer RECOVER_EVENTS = 3,         // 通信/更新故障恢复所需连续成功或真实新转换次数
    parameter integer STALE_MS = 3000,            // 无新转换或冻结证据持续多久确认故障，单位：毫秒
    parameter integer QUALITY_ENABLED = 0,        // PPG质量检查开关：MAX通道为1，温度通道为0
    parameter integer QUALITY_BAD_WINDOWS = 3,    // 连续多少个坏质量窗才确认质量故障，单位：窗
    parameter integer QUALITY_RECOVER_WINDOWS = 3,// 连续多少个好质量窗才清除质量故障，单位：窗
    parameter integer QUALITY_STALE_MS = 5000     // 允许多久没有新质量窗口报告，单位：毫秒
) (
    input wire aclk, aresetn, tick_1ms,
    input wire comm_event, comm_nack, comm_timeout,
    input wire sample_event,
    input wire [31:0] sample_sequence,
    input wire freeze_evidence,
    input wire quality_event, quality_bad,
    // bit 0 communication; bit 1 frozen/missing updates; bit 2 quality.
    output reg [2:0] fault_reason,
    output wire available,
    output wire [2:0] pending_reason
);
    // 【01：计数器】data_age=无真实新转换的时间；freeze_age=冻结证据持续时间；
    // quality_age=无窗口报告的时间。计数器到达门限后饱和，不会溢出回0。
    // comm_bad/good_count 管通信确认/恢复；fresh_good_count 管更新故障恢复；
    // quality_bad/good_count 管坏窗确认/好窗恢复，各类原因独立清除。
    // 【优化：分离门限位宽】通信、更新、冻结、质量各用足够且独立的位宽。
    // 不再因为质量超时较长而扩大温度/更新计时器；门限=1也保留合法1位。
    localparam integer DATA_TIME_W = STALE_MS > 1 ? $clog2(STALE_MS + 1) : 1;                      // 无更新/冻结计时器位宽，至少1位
    localparam integer QUALITY_TIME_W = QUALITY_STALE_MS > 1 ? $clog2(QUALITY_STALE_MS + 1) : 1;   // 质量报告年龄计时器位宽，至少1位
    localparam integer COMM_BAD_W = COMM_FAIL_LIMIT > 1 ? $clog2(COMM_FAIL_LIMIT + 1) : 1;         // 连续失败事务计数器位宽，至少1位
    localparam integer RECOVER_W = RECOVER_EVENTS > 1 ? $clog2(RECOVER_EVENTS + 1) : 1;             // 连续恢复事件计数器位宽，至少1位
    localparam integer QUALITY_BAD_W = QUALITY_BAD_WINDOWS > 1 ? $clog2(QUALITY_BAD_WINDOWS + 1) : 1; // 连续坏窗计数器位宽，至少1位
    localparam integer QUALITY_GOOD_W = QUALITY_RECOVER_WINDOWS > 1 ? $clog2(QUALITY_RECOVER_WINDOWS + 1) : 1; // 连续好窗计数器位宽，至少1位
    reg [DATA_TIME_W-1:0] data_age, freeze_age;
    reg [QUALITY_TIME_W-1:0] quality_age;
    reg [COMM_BAD_W-1:0] comm_bad_count;
    reg [RECOVER_W-1:0] comm_good_count, fresh_good_count;
    reg [QUALITY_BAD_W-1:0] quality_bad_count;
    reg [QUALITY_GOOD_W-1:0] quality_good_count;
    reg seen_sequence, seen_quality, last_quality_bad;
    reg [31:0] last_sequence;
    wire [31:0] sequence_delta = sample_sequence - last_sequence;
    // 【02：序号去重】按32位环形序号判断前进：重复或倒退重放不算新转换。
    // 合法前进差必须小于2**31；自然的 0xffffffff -> 0 回绕仍能被识别。
    // Forward modular progress only: duplicates/backward replay are not new.
    wire fresh_event = sample_event && (!seen_sequence ||
        (sequence_delta != 0 && !sequence_delta[31]));
    wire stale_due = ((!fresh_event && tick_1ms && data_age >= STALE_MS-1) ||
                      (freeze_evidence && tick_1ms && freeze_age >= STALE_MS-1));
    // 【03：来源可用】必须见过真新样本、尚未过期、无冻结证据、无确认故障。
    // PPG 还要有最近的好窗口；温度 QUALITY_ENABLED=0 不受此条件限制。
    assign available = aresetn && seen_sequence && data_age < STALE_MS &&
        !freeze_evidence && (fault_reason == 0) &&
        (!QUALITY_ENABLED || (seen_quality && !last_quality_bad && quality_age < QUALITY_STALE_MS));
    // Diagnostic candidates alone do NOT drive a fault lamp or buzzer.
    assign pending_reason = {QUALITY_ENABLED && quality_bad_count != 0 && !fault_reason[2],
                             freeze_evidence && freeze_age != 0 && !fault_reason[1],
                             comm_bad_count != 0 && !fault_reason[0]};
    // 【04：同步复位/更新计时】真正更新若刚好在超时边界到达，优先清 data_age。
    // 初始尚未有新样本时 available=0；启动后长期无样本也会确认更新故障。
    always @(posedge aclk) begin
        if (!aresetn) begin
            data_age <= 0; freeze_age <= 0; quality_age <= 0;
            comm_bad_count <= 0; comm_good_count <= 0; fresh_good_count <= 0;
            quality_bad_count <= 0; quality_good_count <= 0;
            seen_sequence <= 0; seen_quality <= 0; last_quality_bad <= 0;
            last_sequence <= 0; fault_reason <= 0;
        end else begin
            // A genuine update on the timeout boundary wins over the timer.
            if (fresh_event) begin
                last_sequence <= sample_sequence; seen_sequence <= 1; data_age <= 0;
            end else if (tick_1ms && data_age < STALE_MS)
                data_age <= data_age + 1'b1;
            if (!freeze_evidence) freeze_age <= 0;
            else if (tick_1ms && freeze_age < STALE_MS) freeze_age <= freeze_age + 1'b1;

            if (comm_event) begin
                // 【05：通信故障】只有事务结束才数一次，NACK长高电平不能重复计数。
                // 一笔成功会打断连续失败；已确认故障要连续成功 RECOVER_EVENTS 次恢复。
                if (comm_nack || comm_timeout) begin
                    comm_good_count <= 0;
                    if (comm_bad_count < COMM_FAIL_LIMIT) comm_bad_count <= comm_bad_count + 1'b1;
                    if (comm_bad_count >= COMM_FAIL_LIMIT-1) fault_reason[0] <= 1;
                end else begin
                    comm_bad_count <= 0;
                    if (comm_good_count < RECOVER_EVENTS) comm_good_count <= comm_good_count + 1'b1;
                    if (comm_good_count >= RECOVER_EVENTS-1) fault_reason[0] <= 0;
                end
            end
            if (stale_due) begin
                // 【06：更新/冻结故障】持续无新转换或冻结证据到门限才锁存 bit1。
                // 不比较 sample_data 是否相同；稳定温度本身不是冻结证据。
                fault_reason[1] <= 1; fresh_good_count <= 0;
            end else if (fresh_event && !freeze_evidence) begin
                if (fresh_good_count < RECOVER_EVENTS) fresh_good_count <= fresh_good_count + 1'b1;
                if (fresh_good_count >= RECOVER_EVENTS-1) fault_reason[1] <= 0;
            end else if (freeze_evidence) fresh_good_count <= 0;

            if (QUALITY_ENABLED) begin
                // 【07：PPG质量故障】坏窗/好窗按完整窗口计数，不按 FPGA 时钟计数。
                // 默认三坏窗确认、三好窗恢复；好坏相反会打断各自连续计数。
                if (quality_event) begin
                    quality_age <= 0; seen_quality <= 1; last_quality_bad <= quality_bad;
                    if (quality_bad) begin
                        quality_good_count <= 0;
                        if (quality_bad_count < QUALITY_BAD_WINDOWS) quality_bad_count <= quality_bad_count + 1'b1;
                        if (quality_bad_count >= QUALITY_BAD_WINDOWS-1) fault_reason[2] <= 1;
                    end else begin
                        quality_bad_count <= 0;
                        if (quality_good_count < QUALITY_RECOVER_WINDOWS) quality_good_count <= quality_good_count + 1'b1;
                        if (quality_good_count >= QUALITY_RECOVER_WINDOWS-1) fault_reason[2] <= 0;
                    end
                end else if (tick_1ms && quality_age < QUALITY_STALE_MS) begin
                    // 窗口报告自身消失过久也判质量故障，不能永远沿用最后的好窗。
                    quality_age <= quality_age + 1'b1;
                    if (quality_age >= QUALITY_STALE_MS-1) begin
                        fault_reason[2] <= 1; quality_good_count <= 0;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    // 【08：参数保护】只在仿真检查，禁止0长度计时或0次数确认。
    initial if (COMM_FAIL_LIMIT < 1 || RECOVER_EVENTS < 1 || STALE_MS < 1 ||
                QUALITY_BAD_WINDOWS < 1 || QUALITY_RECOVER_WINDOWS < 1 || QUALITY_STALE_MS < 1)
        $fatal(1, "Invalid sensor fault qualification parameters");
    // synthesis translate_on
endmodule
