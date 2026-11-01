`timescale 1ns/1ps
// ============================================================================
// 【文件作用】C 模块总入口：四路最终数值的平滑、可信度门控、故障隔离和状态汇总。
// 【四路映射】0=独立心率器件；1=MAX30102血氧指标；2=TMP117体表温度；3=TMP117室温。
// 【不是驱动】这里没有 I2C 引脚，也不从 PPG 计算心率/血氧；上游先算好数值。
// 【单位】心率/血氧为无符号整数 x100；两路温度为有符号 Q7（计数/128=摄氏度）。
// 【并行】generate 展开为四套独立电路，不是将四种不同单位的数据混在一起平均。
// 【默认平滑】心率/血氧=3点中位数+Q8指数平滑；两路温度仍为4点平均；缺样不预测。
// 【本次更新】2026-10-22加入归一化权重、健康持续确认、长期不可用确认及并行危险告警。
// 降级Normal只表示剩余可监测范围未发现异常，必须同时显示degraded和故障/缺失通道。
// 【状态编码】0 Normal；1 Warning；2 Danger；3 System Error。
// 【边界】buzzer_enable / fault_led_rgb 只是逻辑输出，尚未分配板上引脚。
// 完整接口、参数、模块关系及阅读顺序见工程根目录的 CODE_GUIDE.txt。
// ============================================================================
// Four independent data lanes and FOUR physical devices. The board wrapper uses
// a separate HR device, one MAX30102, and two TMP117s. No automatic feature substitution.
// Upstream owns I2C, accepted raw-sample quality evidence and feature extraction.
module health_parallel4_top #(
    // [A] 以下参数是可调整的工程起始设置，不是医学或航天认证阈值。
    // 连续几笔失败事务确认通信故障；连续几笔成功/新转换事件允许恢复。
    parameter integer COMM_FAIL_LIMIT=3,          // 连续失败事务确认门限，默认3笔；NACK/超时均计失败
    parameter integer SENSOR_RECOVER_EVENTS=3,    // 通信或无更新故障恢复所需连续成功事件数，默认3次
    // 真正的新转换停止多久判陈旧/冻结；PPG 窗口报告停止多久判质量超时。
    parameter integer STALE_MS=3000,             // 原始器件无真实更新/冻结证据确认时长，单位：毫秒
    parameter integer QUALITY_STALE_MS=5000,      // PPG质量报告超时门限，单位：毫秒
    // 连续几个坏/好窗口确认质量故障/恢复，Pulse Sensor与MAX各自计数。
    parameter integer QUALITY_BAD_WINDOWS=3,     // 确认PPG质量故障所需连续坏窗数，单位：窗
    parameter integer QUALITY_RECOVER_WINDOWS=3, // 清除PPG质量故障所需连续好窗数，单位：窗
    // 一窗含多少个真实新样本；一窗中替换/畸变达到多少次为坏窗。
    // 只有实际有效采样率=100 Hz 时，100 个样本才约等于 1 秒。
    parameter integer PPG_WINDOW_SAMPLES=100,    // 每个PPG质量窗的新样本/完整配对数，不是屏幕刷新次数
    parameter integer PPG_SPIKE_LIMIT=10,        // 一窗内尖峰替换达到多少次判坏窗，单位：次
    parameter integer PPG_DISTORTION_LIMIT=20,   // 一窗内畸变达到多少次判坏窗，单位：次
    parameter integer HR_SOURCE_HAS_PPG=1, // 心率来源是否提供原始PPG质量证据；1保留旧链，UART数值模式覆盖为0
    parameter integer HR_WINDOW_SAMPLES=PPG_WINDOW_SAMPLES, // 心率质量窗样本数；板级500Hz时覆盖为500，即一秒
    parameter integer HR_SPIKE_LIMIT=PPG_SPIKE_LIMIT, // 心率质量窗尖峰次数；板级未做波形替换时输入固定0
    parameter integer HR_DISTORTION_LIMIT=PPG_DISTORTION_LIMIT, // 心率质量窗坏样本门限；板级500Hz时覆盖为100，即20%
    // 越界确认/恢复必须同时满足“持续时间”和“可信新数值个数”。
    parameter integer RANGE_CONFIRM_MS=3000,    // 持续越界告警的时间门限，单位：毫秒；还需满足次数
    parameter integer RANGE_RECOVER_MS=2000,    // 越界恢复的时间门限，单位：毫秒；还需满足次数
    parameter integer RANGE_CONFIRM_SAMPLES=3,  // 确认越界所需连续可信新数值数，单位：个
    parameter integer RANGE_RECOVER_SAMPLES=3,  // 清除越界所需连续恢复区新数值数，单位：个
    // 这是最终心率/血氧/温度特征值的新鲜度，不是原始 FIFO 样本年龄。
    parameter integer FEATURE_FRESH_MS=5000,    // 最终心率/血氧/温度数值允许的最大更新年龄，单位：毫秒
    parameter integer HR_EMA_SHIFT=1,          // 心率中位数后指数平滑的新值权重为1/2的此幂；1表示1/2
    parameter integer SPO2_EMA_SHIFT=1,         // 血氧中位数后指数平滑的新值权重为1/2的此幂；按可信指标更新
    parameter integer UNAVAILABLE_CONFIRM_MS=5000, // 最终指标持续不可用确认时长，毫秒；不是一次valid空洞
    parameter integer HEALTH_CONFIRM_MS=3000,      // 人体等级升高的持续确认时长，毫秒；同时要求新指标数
    parameter integer HEALTH_RECOVER_MS=2000,      // 人体等级降低的持续恢复时长，毫秒；不能靠旧值恢复
    parameter integer HEALTH_CONFIRM_SAMPLES=3,    // 人体等级升高所需连续可信新指标数，个
    parameter integer HEALTH_RECOVER_SAMPLES=3,    // 人体等级降低所需连续可信新指标数，个
    parameter integer WEIGHT_HR=20,                // 心率基础权重20%，四项合计100；不是医学风险概率
    parameter integer WEIGHT_SPO2=40,              // 血氧基础权重40%，失效后只在可信剩余项间归一化
    parameter integer WEIGHT_BODY=30,              // 人体测温基础权重30%，安装位置必须标明并校准
    parameter integer WEIGHT_ROOM=10,              // 室温辅助权重10%，不能单独触发人体Danger
    parameter [15:0] HEALTH_HR_DANGER_LOW=16'd5000,   // 心率危险下界，bpm乘100；沿用项目演示值
    parameter [15:0] HEALTH_HR_DANGER_HIGH=16'd12000, // 心率危险上界，bpm乘100；严格大于时为危险候选
    parameter [15:0] HEALTH_HR_NORMAL_LOW=16'd6000,   // 心率正常闭区间下界，bpm乘100；待实测调整
    parameter [15:0] HEALTH_HR_NORMAL_HIGH=16'd10000, // 心率正常闭区间上界，bpm乘100；不是固定医学标准
    parameter [15:0] HEALTH_SPO2_DANGER_LOW=16'd9000, // 血氧危险下界，百分数乘100；严格小于时为危险候选
    parameter [15:0] HEALTH_SPO2_NORMAL_LOW=16'd9500, // 血氧正常闭区间下界，百分数乘100；合法上限10000
    parameter signed [15:0] HEALTH_BODY_DANGER_LOW=16'sd4480,  // 人体测温危险下界，摄氏度乘128；35摄氏度演示值
    parameter signed [15:0] HEALTH_BODY_DANGER_HIGH=16'sd4992, // 人体测温危险上界，摄氏度乘128；39摄氏度演示值
    parameter signed [15:0] HEALTH_BODY_NORMAL_LOW=16'sd4647,  // 人体测温正常最小Q7码；36.3摄氏度演示值，不是皮温标准
    parameter signed [15:0] HEALTH_BODY_NORMAL_HIGH=16'sd4761  // 人体测温正常最大Q7码；37.2摄氏度演示值，须按测温位置标定
) (
    // [B] 公共同步时基：aresetn=0 复位；tick_1ms 每真实毫秒只能脉冲一拍。
    // 所有输入应已可靠进入 aclk 域。本模块不处理跨时钟域同步。
    input wire aclk, aresetn, tick_1ms,
    // 四颗器件独立证据；UART心率用完整帧/格式错误/超时形成通信事件。
    // sample_event=一次转换/FIFO 新样本报告；sequence 必须代表真实新转换。
    // freeze_evidence=上游已经形成的冻结证据，不能仅由“数值没变化”产生。
    input wire hr_sensor_comm_event,hr_sensor_nack,hr_sensor_read_timeout,
    input wire hr_sensor_sample_event,hr_sensor_freeze_evidence,
    input wire [31:0] hr_sensor_sample_sequence,
    input wire spo2_sensor_comm_event,spo2_sensor_nack,spo2_sensor_read_timeout,
    input wire spo2_sensor_sample_event,spo2_sensor_freeze_evidence,
    input wire [31:0] spo2_sensor_sample_sequence,
    // tmp_* 固定指体温模块；room_* 指另一颗室温模块，二者不能共用序号。
    // tmp_* continues to mean the body TMP117, never either MAX30102.
    input wire tmp_comm_event,tmp_nack,tmp_read_timeout,tmp_sample_event,tmp_freeze_evidence,
    input wire [31:0] tmp_sample_sequence,
    input wire room_comm_event,room_nack,room_read_timeout,room_sample_event,room_freeze_evidence,
    input wire [31:0] room_sample_sequence,
    // [C] PPG 质量输入只报告“这个新样本是否被替换/畸变”，不传原始波形。
    // 有原始PPG证据的HR来源才计波形；UART数值模式关闭该HR质量窗要求，SpO2保持原配对证据。
    // replaced/distorted 的具体判据在上游；此处只做窗口统计和持续确认。
    // One event per distinct HR waveform sample; SpO2 uses a same-device
    // RED/IR pair. Count replacements once per event, not a held window flag.
    input wire hr_ppg_event,hr_ppg_replaced,hr_ppg_distorted,
    input wire spo2_ppg_pair_event,spo2_ppg_pair_replaced,spo2_ppg_pair_distorted,
    // [D] 告警范围来自配置端。limits_valid[ch]=1 才表示该路配置有效。
    // 上/下限和 hysteresis 都用该路的整数单位，不是直接写小数摄氏度。
    // 无配置或配置错误只能报 Warning，不能据此确认生理告警或器件坏了。
    // bits 0 HR, 1 SpO2, 2 body, 3 room; limits keep each input's units.
    input wire [3:0] limits_valid,
    input wire signed [31:0]
        hr_lower,      // 心率告警下限，输入单位：bpm乘100；不是器件故障门限
        hr_upper,      // 心率告警上限，输入单位：bpm乘100
        spo2_lower,    // 血氧告警下限，输入单位：百分数乘100
        spo2_upper,    // 血氧告警上限，输入单位：百分数乘100
        body_lower,    // 体温告警下限，输入单位：摄氏度乘128，支持负温度
        body_upper,    // 体温告警上限，输入单位：摄氏度乘128
        room_lower,    // 室温告警下限，输入单位：摄氏度乘128，支持负温度
        room_upper,    // 室温告警上限，输入单位：摄氏度乘128
    input wire [15:0]
        hr_hysteresis,   // 心率恢复滞回量，单位：bpm乘100；不允许负值
        spo2_hysteresis, // 血氧恢复滞回量，单位：百分数乘100
        body_hysteresis, // 体温恢复滞回量，单位：摄氏度乘128
        room_hysteresis, // 室温恢复滞回量，单位：摄氏度乘128
    // [E] 最终数值入口：有效事务只有在 valid && ready 的时钟沿被接收。
    // new=新结果；good=可信结果。valid=1 而 ready=0 时上游必须保持所有字段。
    input wire [15:0] hr_bpm_x100,spo2_percent_x100,
    input wire signed [15:0] body_raw_q7,room_raw_q7,
    input wire hr_valid,hr_new,hr_good,spo2_valid,spo2_new,spo2_good,body_valid,body_new,body_good,room_valid,room_new,room_good,
    output wire hr_ready,spo2_ready,body_ready,room_ready,
    // [F] 四路独立输出。下游只在 smooth_valid && smooth_ready 时消费一次。
    // smooth_valid=0 时端口可能仍保留旧比特，禁止把旧比特当实时正常读数。
    output wire [15:0] hr_smooth_bpm_x100,spo2_smooth_percent_x100,
    output wire signed [15:0] body_smooth_q7,room_smooth_q7,
    output wire hr_smooth_valid,spo2_smooth_valid,body_smooth_valid,room_smooth_valid,
    input wire hr_smooth_ready,spo2_smooth_ready,body_smooth_ready,room_smooth_ready,
    // [G] 每颗器件的原因均为位图：bit0=通信；bit1=陈旧/冻结；bit2=PPG质量。
    // pending_reason 仅为待确认原因；不会直接点故障灯或开启蜂鸣器。
    // range_alarm=可信值持续越界；feature_available=当前可以信任该路特征。
    // device_isolated=该器件已有确认故障，和“暂时不可用”不是一回事。
    output wire [2:0] hr_sensor_fault_reason,spo2_sensor_fault_reason,tmp_fault_reason,room_fault_reason,
    output wire [2:0] hr_sensor_pending_reason,spo2_sensor_pending_reason,tmp_pending_reason,room_pending_reason,
    output wire [3:0] range_alarm,range_candidate,range_config_error,feature_available,
    // bit 0 independent HR, bit 1 MAX30102 SpO2, bit 2 body, bit 3 room.
    output wire [3:0] device_isolated,
    output wire [1:0] system_status,
    output wire system_error,buzzer_enable,
    output wire [2:0] fault_led_rgb,
    // [H] 新增显示/告警侧输出，不改变原有采样、握手和整数单位。
    output wire [1:0] monitor_mode,        // 0等待/组合不足，1四路，2三路降级，3血氧+人体温度
    output wire degraded,                 // 允许的降级模式标志；Normal必须结合此位解释
    output wire assessment_valid,         // 当前允许组合已经获得可信判断；预热/配置错误时为0
    output wire [3:0] unavailable_confirmed, // 最终指标长期不可用位图；不等于物理器件永久损坏
    output wire [2:0] health_danger_mask,health_warning_mask,health_pending_mask, // bit0心率、bit1血氧、bit2人体温度
    output wire danger_active,            // 独立可信危险告警；即使主状态System Error也不屏蔽
    output wire [13:0] hr_weight_bp,spo2_weight_bp,body_weight_bp,room_weight_bp, // 10000=100%，除100显示百分比
    output wire [6:0] fusion_score,        // 0..100辅助综合风险分数，不是概率，不覆盖单项危险
    output wire fusion_valid              // 分数有效标志；无效时分数置0，但0绝不能解释为正常
);
    // 【01：整理接口】将分散的四套端口排成统一数组，供下面的 generate 使用。
    // 拼接最右边是 bit0；数组顺序始终是心率、血氧、体温、室温。
    wire [3:0] comm_event={room_comm_event,tmp_comm_event,spo2_sensor_comm_event,hr_sensor_comm_event};
    wire [3:0] comm_nack={room_nack,tmp_nack,spo2_sensor_nack,hr_sensor_nack};
    wire [3:0] comm_timeout={room_read_timeout,tmp_read_timeout,spo2_sensor_read_timeout,hr_sensor_read_timeout};
    wire [3:0] sample_event={room_sample_event,tmp_sample_event,spo2_sensor_sample_event,hr_sensor_sample_event};
    wire [3:0] freeze_evidence={room_freeze_evidence,tmp_freeze_evidence,spo2_sensor_freeze_evidence,hr_sensor_freeze_evidence};
    wire [31:0] sequence_id [0:3];
    wire [2:0] fault_reason [0:3],pending_reason [0:3];
    wire [3:0] source_available,quality_event,quality_bad;
    assign sequence_id[0]=hr_sensor_sample_sequence;
    assign sequence_id[1]=spo2_sensor_sample_sequence;
    assign sequence_id[2]=tmp_sample_sequence;
    assign sequence_id[3]=room_sample_sequence;
    // 【02：独立质量窗口】两个实例各自保存样本数、替换数、畸变数。
    // 一个 MAX 的正常窗口不能替另一个 MAX 清除故障；温度不走 PPG 质量。
    ppg_quality_windows #(
        .WINDOW_SAMPLES(HR_WINDOW_SAMPLES),       // 心率通道每个质量窗的真实新样本数
        .SPIKE_LIMIT(HR_SPIKE_LIMIT),             // 心率通道每窗尖峰替换坏窗门限
        .DISTORTION_LIMIT(HR_DISTORTION_LIMIT)    // 心率通道每窗波形畸变坏窗门限
    ) u_hr_quality (
        .aclk(aclk),.aresetn(aresetn),.sample_event(hr_ppg_event),
        .spike_replaced(hr_ppg_replaced),.distorted(hr_ppg_distorted),
        .window_event(quality_event[0]),.window_bad(quality_bad[0]));
    ppg_quality_windows #(
        .WINDOW_SAMPLES(PPG_WINDOW_SAMPLES),       // 血氧通道每窗的同器件红光/红外配对数
        .SPIKE_LIMIT(PPG_SPIKE_LIMIT),             // 血氧通道每窗尖峰替换坏窗门限
        .DISTORTION_LIMIT(PPG_DISTORTION_LIMIT)    // 血氧通道每窗波形畸变坏窗门限
    ) u_spo2_quality (
        .aclk(aclk),.aresetn(aresetn),.sample_event(spo2_ppg_pair_event),
        .spike_replaced(spo2_ppg_pair_replaced),.distorted(spo2_ppg_pair_distorted),
        .window_event(quality_event[1]),.window_bad(quality_bad[1]));
    assign quality_event[3:2]=2'b00;
    assign quality_bad[3:2]=2'b00;

    // 【03：四路数据及控制数组】fresh=新鲜；expired=历史已过期；warming=预热。
    // core_valid/core_ready 为平均器握手；blocking 表示本路不能继续使用历史。
    wire [3:0] fresh,expired,warming,core_valid,core_ready,blocking,in_ready;
    wire [15:0] input_data [0:3],output_data [0:3];
    wire [3:0] in_valid={room_valid,body_valid,spo2_valid,hr_valid};
    wire [3:0] in_new={room_new,body_new,spo2_new,hr_new};
    wire [3:0] in_good={room_good,body_good,spo2_good,hr_good};
    wire [3:0] out_ready={room_smooth_ready,body_smooth_ready,spo2_smooth_ready,hr_smooth_ready};
    wire signed [31:0] lows [0:3],highs [0:3];
    wire [15:0] hyst [0:3];
    assign input_data[0]=hr_bpm_x100; assign input_data[1]=spo2_percent_x100;
    assign input_data[2]=body_raw_q7; assign input_data[3]=room_raw_q7;
    assign lows[0]=hr_lower; assign lows[1]=spo2_lower; assign lows[2]=body_lower; assign lows[3]=room_lower;
    assign highs[0]=hr_upper; assign highs[1]=spo2_upper; assign highs[2]=body_upper; assign highs[3]=room_upper;
    assign hyst[0]=hr_hysteresis; assign hyst[1]=spo2_hysteresis; assign hyst[2]=body_hysteresis; assign hyst[3]=room_hysteresis;
    genvar ch;
    // 【04：复制四套处理链】generate 是 elaboration 时的硬件展开，不是运行循环。
    // 每路都有器件监视、原始指标范围监视和平滑器；状态/计数器/历史完全独立。
    generate for(ch=0;ch<4;ch=ch+1) begin : g_device
        // 温度编码域为 -55~150 摄氏度（Q7）；SpO2 编码域为 0~100%。
        // 心率编码域为 16 位无符号。以上是输入编码保护，不是“正常健康范围”。
        localparam integer LOW_CODE=ch>=2 ? -7040 : 0; // 编码下限：温度-55摄氏度乘128，其余为0
        localparam integer HIGH_CODE=ch>=2 ? 19200 : (ch==1 ? 10000 : 65535); // 编码上限：温度150摄氏度、血氧100%、心率16位无符号上限
        localparam integer UNAVAILABLE_W=UNAVAILABLE_CONFIRM_MS>1 ? $clog2(UNAVAILABLE_CONFIRM_MS+1) : 1; // 本路最终指标不可用计时位宽，至少一位
        reg [UNAVAILABLE_W-1:0] unavailable_age;
        sensor_fault_monitor #(
            .COMM_FAIL_LIMIT(COMM_FAIL_LIMIT),                 // 该物理器件的连续失败事务确认次数
            .RECOVER_EVENTS(SENSOR_RECOVER_EVENTS),             // 该物理器件的连续恢复事件门限
            .STALE_MS(STALE_MS),                                // 无更新或冻结证据确认时间，毫秒
            .QUALITY_ENABLED(ch==0 ? HR_SOURCE_HAS_PPG : ch==1), // 仅心率按来源选择PPG质量；血氧保持开启，温度保持关闭
            .QUALITY_BAD_WINDOWS(QUALITY_BAD_WINDOWS),           // 连续坏窗确认门限，窗
            .QUALITY_RECOVER_WINDOWS(QUALITY_RECOVER_WINDOWS),   // 连续好窗恢复门限，窗
            .QUALITY_STALE_MS(QUALITY_STALE_MS)                  // 质量报告超时门限，毫秒
        ) u_sensor (
            .aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),
            .comm_event(comm_event[ch]),.comm_nack(comm_nack[ch]),.comm_timeout(comm_timeout[ch]),
            .sample_event(sample_event[ch]),.sample_sequence(sequence_id[ch]),.freeze_evidence(freeze_evidence[ch]),
            .quality_event(quality_event[ch]),.quality_bad(quality_bad[ch]),.fault_reason(fault_reason[ch]),
            .available(source_available[ch]),.pending_reason(pending_reason[ch]));
        // 来源不可信或最终数值长时间过期时，清空本路平均历史并作废输出。
        // 即便尚未达到确认故障次数，也可以先安全暂停该路；不等于已判损坏。
        assign blocking[ch]=!source_available[ch] || expired[ch];
        // 不可用期间仍接收并丢弃输入事务，避免旧事务堵住上游、妨碍恢复。
        // Drain unusable tokens so a stalled display cannot prevent recovery.
        assign in_ready[ch]=aresetn && (blocking[ch] || core_ready[ch]);
        // 先看可信原始数值的越界与新鲜度，再平滑；避免平均曲线掩盖持续越界。
        metric_range_guard #(
            .SIGNED_INPUT(ch>=2),                     // 两路温度按有符号解释，心率/血氧为无符号
            .CODE_MIN(LOW_CODE),                      // 本通道输入的合法编码下限
            .CODE_MAX(HIGH_CODE),                     // 本通道输入的合法编码上限
            .CONFIRM_SAMPLES(RANGE_CONFIRM_SAMPLES),  // 越界确认所需连续可信新数值数
            .RECOVER_SAMPLES(RANGE_RECOVER_SAMPLES),  // 越界恢复所需连续恢复区新数值数
            .CONFIRM_MS(RANGE_CONFIRM_MS),            // 越界确认持续时间，毫秒
            .RECOVER_MS(RANGE_RECOVER_MS),            // 越界恢复持续时间，毫秒
            .FRESH_MS(FEATURE_FRESH_MS)               // 最终数值的新鲜度超时，毫秒
        ) u_range (
            .aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),
            .sample_event(in_valid[ch] && in_ready[ch]),.sample_new(in_new[ch]),
            .sample_good(in_good[ch] && source_available[ch]),.sample_data(input_data[ch]),
            .limits_valid(limits_valid[ch]),.lower_limit(lows[ch]),.upper_limit(highs[ch]),.hysteresis(hyst[ch]),
            .range_alarm(range_alarm[ch]),.candidate(range_candidate[ch]),.config_error(range_config_error[ch]),
            .fresh(fresh[ch]),.history_expired(expired[ch]));
        // 心率/血氧抑制孤立尖峰并平滑；温度继续沿用4点平均，不跨路共用历史。
        if (ch < 2) begin : g_robust
            metric_robust_smoother #(
                .EMA_SHIFT(ch==0 ? HR_EMA_SHIFT : SPO2_EMA_SHIFT), // 按本路可信指标更新计算的新值权重
                .MIN_VALUE(LOW_CODE),   // 心率/血氧允许进入历史的编码下限
                .MAX_VALUE(HIGH_CODE)   // 心率/血氧允许进入历史的编码上限
            ) u_smoother (
                .aclk(aclk),.aresetn(aresetn),.flush(blocking[ch]),.invalidate_output(!fresh[ch]),
                .sample_data(input_data[ch]),.sample_valid(in_valid[ch] && !blocking[ch]),.sample_ready(core_ready[ch]),
                .sample_new(in_new[ch]),.sample_good(in_good[ch]),.smooth_data(output_data[ch]),
                .smooth_valid(core_valid[ch]),.smooth_ready(out_ready[ch]),.warming_up(warming[ch]),.rejected(),.reject_reason());
        end else begin : g_temperature
        metric_moving_average #(
            .SIGNED_INPUT(ch>=2),  // 温度采用有符号平均，心率/血氧采用无符号输入
            .MIN_VALUE(LOW_CODE),  // 仅允许合法编码进入平滑历史：下限
            .MAX_VALUE(HIGH_CODE)  // 仅允许合法编码进入平滑历史：上限；窗口沿用默认4点
        ) u_average (
            .aclk(aclk),.aresetn(aresetn),.flush(blocking[ch]),.invalidate_output(!fresh[ch]),
            .sample_data(input_data[ch]),.sample_valid(in_valid[ch] && !blocking[ch]),.sample_ready(core_ready[ch]),
            .sample_new(in_new[ch]),.sample_good(in_good[ch]),.smooth_data(output_data[ch]),
            .smooth_valid(core_valid[ch]),.smooth_ready(out_ready[ch]),.warming_up(warming[ch]),.rejected(),.reject_reason());
        end
        assign feature_available[ch]=source_available[ch] && fresh[ch] && !warming[ch];
        // 算法停产出或编码持续无效也会导致最终指标不可用，不能永远只有Warning。
        // 一次质量波动仅暂停使用；持续到此门限后才进入组合不足判断。
        always @(posedge aclk) begin
            if (!aresetn || feature_available[ch]) unavailable_age<=0;
            else if (tick_1ms && unavailable_age<UNAVAILABLE_CONFIRM_MS)
                unavailable_age<=unavailable_age+1'b1;
        end
        assign unavailable_confirmed[ch]=aresetn && unavailable_age>=UNAVAILABLE_CONFIRM_MS;
        // 一颗器件无论有几个故障原因，只占 device_isolated 的一个 bit。
        assign device_isolated[ch]=|fault_reason[ch];
    end endgenerate
    // 【05：还原外部输出】把数组各路结果和原因接回有明确含义的端口。
    assign {room_ready,body_ready,spo2_ready,hr_ready}=in_ready;
    assign hr_smooth_bpm_x100=output_data[0]; assign spo2_smooth_percent_x100=output_data[1];
    assign body_smooth_q7=output_data[2]; assign room_smooth_q7=output_data[3];
    assign {room_smooth_valid,body_smooth_valid,spo2_smooth_valid,hr_smooth_valid}=core_valid & feature_available;
    assign hr_sensor_fault_reason=fault_reason[0]; assign spo2_sensor_fault_reason=fault_reason[1];
    assign tmp_fault_reason=fault_reason[2]; assign room_fault_reason=fault_reason[3];
    assign hr_sensor_pending_reason=pending_reason[0]; assign spo2_sensor_pending_reason=pending_reason[1];
    assign tmp_pending_reason=pending_reason[2]; assign room_pending_reason=pending_reason[3];
    // 【06：确认不可用组合】物理确认故障和最终指标持续不可用合并，同一器件仅占一位。
    // 位序仍为{室温,人体温度,血氧,心率}；1001表示坏心率+室温，允许剩余0110有限监测。
    // 其余五种双故障、任意三/四路不可用才报错；单路/短毛刺不触发System Error。
    wire [3:0] confirmed_unusable=device_isolated | unavailable_confirmed;
    assign system_error=aresetn && (
        (confirmed_unusable[1] && (confirmed_unusable[0] || confirmed_unusable[2] || confirmed_unusable[3])) ||
        (confirmed_unusable[2] && (confirmed_unusable[0] || confirmed_unusable[3])));
    // 【07：并行人体判断】只在接受可信新指标时积累证据，不用显示消费脉冲充当新测量。
    // 读平滑前指标以保留持续异常；显示输出仍复用原心率/血氧中位数EMA及温度平均。
    wire [2:0] health_event=(in_valid & in_ready & in_new & in_good & source_available & ~blocking);
    wire [2:0] range_danger=range_alarm[2:0] & feature_available[2:0] & ~range_config_error[2:0];
    wire room_warning=range_alarm[3] && feature_available[3] && !range_config_error[3];
    wire [1:0] health_level;
    wire health_assessment_valid,health_fusion_valid;
    wire [6:0] health_fusion_score;
    health_status_judge #(
        .HR_DANGER_LOW(HEALTH_HR_DANGER_LOW),       // 心率危险下界，bpm乘100
        .HR_DANGER_HIGH(HEALTH_HR_DANGER_HIGH),     // 心率危险上界，bpm乘100
        .HR_NORMAL_LOW(HEALTH_HR_NORMAL_LOW),       // 心率正常下界，bpm乘100
        .HR_NORMAL_HIGH(HEALTH_HR_NORMAL_HIGH),     // 心率正常上界，bpm乘100
        .SPO2_DANGER_LOW(HEALTH_SPO2_DANGER_LOW),   // 血氧危险下界，百分数乘100
        .SPO2_NORMAL_LOW(HEALTH_SPO2_NORMAL_LOW),   // 血氧正常下界，百分数乘100
        .BODY_DANGER_LOW(HEALTH_BODY_DANGER_LOW),   // 人体测温危险下界，摄氏度乘128
        .BODY_DANGER_HIGH(HEALTH_BODY_DANGER_HIGH), // 人体测温危险上界，摄氏度乘128
        .BODY_NORMAL_LOW(HEALTH_BODY_NORMAL_LOW),   // 人体测温正常下界，摄氏度乘128
        .BODY_NORMAL_HIGH(HEALTH_BODY_NORMAL_HIGH), // 人体测温正常上界，摄氏度乘128
        .CONFIRM_MS(HEALTH_CONFIRM_MS),             // 健康等级升高的持续确认毫秒数
        .RECOVER_MS(HEALTH_RECOVER_MS),             // 健康等级降低的持续恢复毫秒数
        .CONFIRM_SAMPLES(HEALTH_CONFIRM_SAMPLES),   // 健康异常确认所需可信新指标数
        .RECOVER_SAMPLES(HEALTH_RECOVER_SAMPLES),   // 健康恢复确认所需可信新指标数
        .WEIGHT_HR(WEIGHT_HR),                     // 心率基础权重，默认20%
        .WEIGHT_SPO2(WEIGHT_SPO2),                 // 血氧基础权重，默认40%
        .WEIGHT_BODY(WEIGHT_BODY),                 // 人体测温基础权重，默认30%
        .WEIGHT_ROOM(WEIGHT_ROOM)                  // 室温辅助权重，默认10%
    ) u_health (
        .aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),
        .hr_bpm_x100(hr_bpm_x100),.spo2_percent_x100(spo2_percent_x100),
        .body_raw_q7(body_raw_q7),.feature_valid(feature_available),.feature_event(health_event),
        .environment_warning(room_warning),.range_danger(range_danger),
        .health_status(health_level),.evaluated_valid(),
        .danger_mask(health_danger_mask),.warning_mask(health_warning_mask),.pending_mask(health_pending_mask),
        .monitor_mode(monitor_mode),.degraded(degraded),.assessment_valid(health_assessment_valid),
        .hr_weight_bp(hr_weight_bp),.spo2_weight_bp(spo2_weight_bp),
        .body_weight_bp(body_weight_bp),.room_weight_bp(room_weight_bp),
        .fusion_score(health_fusion_score),.fusion_valid(health_fusion_valid));
    // 【08：四态与独立告警】主状态System Error优先，但危险位和蜂鸣器独立保留。
    // 降级时允许“当前监测范围Normal + degraded=1”，绝不解释成缺失指标正常。
    // 室温范围越界仅为环境Warning，不再由旧范围旁路直接升级人体Danger。
    assign danger_active=aresetn && (|health_danger_mask);
    assign assessment_valid=health_assessment_valid && !(|(range_config_error & feature_available)) && !system_error;
    assign fusion_valid=health_fusion_valid && assessment_valid;
    assign fusion_score=fusion_valid ? health_fusion_score : 7'd0;
    assign system_status=!aresetn ? 2'd1 : system_error ? 2'd3 : danger_active ? 2'd2 :
        (!assessment_valid || health_level==2'd1 || room_warning) ? 2'd1 : 2'd0;
    assign buzzer_enable=aresetn && (system_error || danger_active);
    wire [2:0] reasons=fault_reason[0] | fault_reason[1] | fault_reason[2] | fault_reason[3];
    // 【09：故障灯逻辑】按 [R,G,B] 排列：100 红=通信/系统错误；110 黄=冻结；
    // 001 蓝=PPG质量；000 熄灭。它显示确认的器件故障，不直接显示生理 Danger。
    // 灯的实际引脚、极性、驱动与蜂鸣器电路均不属于本文件。
    assign fault_led_rgb=!aresetn ? 3'b000 : (system_error || reasons[0]) ? 3'b100 :
        reasons[1] ? 3'b110 : reasons[2] ? 3'b001 : 3'b000;
    // 参数保护不是自检或伪数据源，不改变板上数据；只在非法配置时提示。
    // synthesis translate_off
    initial if (UNAVAILABLE_CONFIRM_MS<1)
        $fatal(1,"Invalid final-feature unavailability timeout");
    // synthesis translate_on
endmodule
