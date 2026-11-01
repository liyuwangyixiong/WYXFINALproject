`timescale 1ns/1ps
// 【用途】精简C模块：只把心率入口换成KPT_D01的UART，其他三路仍由已调通的上游模块提供。
// 心率：115200/8N1，FF AA + 温度2字节 + 心率2字节 + 血氧2字节 + 3C，默认每秒一帧。
// 仅使用帧内心率并转换为bpm乘100；帧内血氧/温度不接入四路处理，不替代独立传感器。
// 不启用WAVE_ON，不从8位波形重算心率，不套用旧Pulse Sensor的500Hz带通系数。
// 心率继续3点中位数+Q8 EMA；范围/健康判断仍并行看平滑前数值，避免平滑掩盖持续异常。
// 原始PPG质量未提供，因此hr_ppg_quality_known恒0，不把串口格式正确冒充光学质量好。
// 所有事件与其他三路接口均在aclk域；aclk默认25MHz，tick_1ms必须由系统提供真实毫秒脉冲。
// 本顶层为功能模块接口，不是直接烧录的整板顶层；没有I2C、XADC、PS、ILA或屏幕逻辑。
module health_kpt_uart_top #(
    parameter integer CLK_HZ=25000000, // 功能模块处理时钟，赫兹；上游真实时钟必须与此参数一致
    parameter integer UART_BAUD=115200, // KPT_D01默认UART波特率，8数据位、无校验、1停止位
    parameter integer UART_BYTE_GAP_MS=20, // 半帧中字节间隔容错上限，毫秒；工程可配置值，非手册参数
    parameter integer UART_FRAME_STALE_MS=3000, // 连续无完整心率帧的通信超时，毫秒；不由波形或垃圾字节刷新
    parameter integer UART_HR_MAX_BPM=655, // x100后不溢出16位的整数心率编码上限；不是生理正常上限
    // [A] 以下参数是可调整的工程起始设置，不是医学或航天认证阈值。
    // 连续几笔失败事务确认通信故障；连续几笔成功/新转换事件允许恢复。
    parameter integer COMM_FAIL_LIMIT=3,          // 连续失败事务确认门限，默认3笔；NACK/超时均计失败
    parameter integer SENSOR_RECOVER_EVENTS=3,    // 通信或无更新故障恢复所需连续成功事件数，默认3次
    // 真正的新转换停止多久判陈旧/冻结；PPG 窗口报告停止多久判质量超时。
    parameter integer STALE_MS=3000,             // 原始器件无真实更新/冻结证据确认时长，单位：毫秒
    parameter integer QUALITY_STALE_MS=5000,      // PPG质量报告超时门限，单位：毫秒
    // 血氧仍按连续坏/好窗口确认质量故障/恢复；UART心率不伪造PPG窗口。
    parameter integer QUALITY_BAD_WINDOWS=3,     // 确认PPG质量故障所需连续坏窗数，单位：窗
    parameter integer QUALITY_RECOVER_WINDOWS=3, // 清除PPG质量故障所需连续好窗数，单位：窗
    // 一窗含多少个真实新样本；一窗中替换/畸变达到多少次为坏窗。
    // 只有实际有效采样率=100 Hz 时，100 个样本才约等于 1 秒。
    parameter integer PPG_WINDOW_SAMPLES=100,    // 每个PPG质量窗的新样本/完整配对数，不是屏幕刷新次数
    parameter integer PPG_SPIKE_LIMIT=10,        // 一窗内尖峰替换达到多少次判坏窗，单位：次
    parameter integer PPG_DISTORTION_LIMIT=20,   // 一窗内畸变达到多少次判坏窗，单位：次
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
    input wire kpt_uart_rx, // 传感器TX接此UART RX逻辑端口；尚未分配板级管脚
    output wire hr_uart_frame_event, // 完整九字节数值帧，一帧一拍；不含被忽略的血氧/温度结果
    output wire hr_uart_format_error,hr_uart_timeout,hr_uart_encoding_error,hr_uart_overrun,
    output wire hr_uart_link_stale, // 长时间没有完整帧；不能用串口闲置电平证明器件正常
    output wire hr_ppg_quality_known, // 本数值模式没有原始光学质量证据，因此恒0表示未知
    output wire [15:0] hr_uart_raw_bpm, // 帧内原始整数bpm；只有hr_uart_frame_event时是新读数
    // [B] 公共同步时基：aresetn=0 复位；tick_1ms 每真实毫秒只能脉冲一拍。
    // 所有输入应已可靠进入 aclk 域。本模块不处理跨时钟域同步。
    input wire aclk, aresetn, tick_1ms,
    // 四颗器件独立证据；UART心率用完整帧/格式错误/超时形成通信事件。
    // sample_event=一次转换/FIFO 新样本报告；sequence 必须代表真实新转换。
    // freeze_evidence=上游已经形成的冻结证据，不能仅由“数值没变化”产生。
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
    input wire [15:0] spo2_percent_x100,
    input wire signed [15:0] body_raw_q7,room_raw_q7,
    input wire spo2_valid,spo2_new,spo2_good,body_valid,body_new,body_good,room_valid,room_new,room_good,
    output wire spo2_ready,body_ready,room_ready,
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
    wire hr_sensor_comm_event,hr_sensor_nack,hr_sensor_read_timeout;
    wire hr_sensor_sample_event;
    wire [31:0] hr_sensor_sample_sequence;
    wire [15:0] hr_bpm_x100;
    wire hr_valid,hr_new,hr_good,hr_ready;
    wire hr_sensor_freeze_evidence=1'b0; // 相同的整数心率可能是真实稳定值，不作为冻结证据
    wire hr_ppg_event=1'b0,hr_ppg_replaced=1'b0,hr_ppg_distorted=1'b0;
    assign hr_ppg_quality_known=1'b0;
    kpt_d01_uart_hr #(
        .CLK_HZ(CLK_HZ), // UART接收器使用的真实系统时钟，赫兹
        .BAUD(UART_BAUD), // 手册默认115200波特，8N1
        .BYTE_GAP_MS(UART_BYTE_GAP_MS), // 半帧字节间隔容错，毫秒
        .FRAME_STALE_MS(UART_FRAME_STALE_MS), // 完整心率帧超时，毫秒
        .HR_MAX_BPM(UART_HR_MAX_BPM) // x100整数接口的编码上限，非健康阈值
    ) u_hr_uart(
        .aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),.uart_rx(kpt_uart_rx),
        .metric_data(hr_bpm_x100),.metric_valid(hr_valid),.metric_ready(hr_ready),.metric_good(hr_good),
        .comm_event(hr_sensor_comm_event),.comm_error(hr_sensor_nack),.comm_timeout(hr_sensor_read_timeout),
        .sample_event(hr_sensor_sample_event),.sample_sequence(hr_sensor_sample_sequence),
        .frame_event(hr_uart_frame_event),.raw_bpm(hr_uart_raw_bpm),.format_error(hr_uart_format_error),
        .timeout_event(hr_uart_timeout),.encoding_error(hr_uart_encoding_error),
        .overrun_event(hr_uart_overrun),.link_stale(hr_uart_link_stale));
    assign hr_new=1'b1; // pending槽中每条事务都来自不同完整帧；valid&&ready只消费一次
    health_parallel4_top #(
        .COMM_FAIL_LIMIT(COMM_FAIL_LIMIT), // 透传原四路处理参数，默认值与原工程一致
        .SENSOR_RECOVER_EVENTS(SENSOR_RECOVER_EVENTS), // 透传原四路处理参数，默认值与原工程一致
        .STALE_MS(STALE_MS), // 透传原四路处理参数，默认值与原工程一致
        .QUALITY_STALE_MS(QUALITY_STALE_MS), // 透传原四路处理参数，默认值与原工程一致
        .QUALITY_BAD_WINDOWS(QUALITY_BAD_WINDOWS), // 透传原四路处理参数，默认值与原工程一致
        .QUALITY_RECOVER_WINDOWS(QUALITY_RECOVER_WINDOWS), // 透传原四路处理参数，默认值与原工程一致
        .PPG_WINDOW_SAMPLES(PPG_WINDOW_SAMPLES), // 透传原四路处理参数，默认值与原工程一致
        .PPG_SPIKE_LIMIT(PPG_SPIKE_LIMIT), // 透传原四路处理参数，默认值与原工程一致
        .PPG_DISTORTION_LIMIT(PPG_DISTORTION_LIMIT), // 透传原四路处理参数，默认值与原工程一致
        .HR_SOURCE_HAS_PPG(0), // UART只有数值帧，关闭心率原始PPG质量要求；其他三路不受影响
        .RANGE_CONFIRM_MS(RANGE_CONFIRM_MS), // 透传原四路处理参数，默认值与原工程一致
        .RANGE_RECOVER_MS(RANGE_RECOVER_MS), // 透传原四路处理参数，默认值与原工程一致
        .RANGE_CONFIRM_SAMPLES(RANGE_CONFIRM_SAMPLES), // 透传原四路处理参数，默认值与原工程一致
        .RANGE_RECOVER_SAMPLES(RANGE_RECOVER_SAMPLES), // 透传原四路处理参数，默认值与原工程一致
        .FEATURE_FRESH_MS(FEATURE_FRESH_MS), // 透传原四路处理参数，默认值与原工程一致
        .HR_EMA_SHIFT(HR_EMA_SHIFT), // 透传原四路处理参数，默认值与原工程一致
        .SPO2_EMA_SHIFT(SPO2_EMA_SHIFT), // 透传原四路处理参数，默认值与原工程一致
        .UNAVAILABLE_CONFIRM_MS(UNAVAILABLE_CONFIRM_MS), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_CONFIRM_MS(HEALTH_CONFIRM_MS), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_RECOVER_MS(HEALTH_RECOVER_MS), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_CONFIRM_SAMPLES(HEALTH_CONFIRM_SAMPLES), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_RECOVER_SAMPLES(HEALTH_RECOVER_SAMPLES), // 透传原四路处理参数，默认值与原工程一致
        .WEIGHT_HR(WEIGHT_HR), // 透传原四路处理参数，默认值与原工程一致
        .WEIGHT_SPO2(WEIGHT_SPO2), // 透传原四路处理参数，默认值与原工程一致
        .WEIGHT_BODY(WEIGHT_BODY), // 透传原四路处理参数，默认值与原工程一致
        .WEIGHT_ROOM(WEIGHT_ROOM), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_HR_DANGER_LOW(HEALTH_HR_DANGER_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_HR_DANGER_HIGH(HEALTH_HR_DANGER_HIGH), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_HR_NORMAL_LOW(HEALTH_HR_NORMAL_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_HR_NORMAL_HIGH(HEALTH_HR_NORMAL_HIGH), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_SPO2_DANGER_LOW(HEALTH_SPO2_DANGER_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_SPO2_NORMAL_LOW(HEALTH_SPO2_NORMAL_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_BODY_DANGER_LOW(HEALTH_BODY_DANGER_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_BODY_DANGER_HIGH(HEALTH_BODY_DANGER_HIGH), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_BODY_NORMAL_LOW(HEALTH_BODY_NORMAL_LOW), // 透传原四路处理参数，默认值与原工程一致
        .HEALTH_BODY_NORMAL_HIGH(HEALTH_BODY_NORMAL_HIGH) // 透传原四路处理参数，默认值与原工程一致
    ) u_C(
        .aclk(aclk),
        .aresetn(aresetn),
        .tick_1ms(tick_1ms),
        .hr_sensor_comm_event(hr_sensor_comm_event),
        .hr_sensor_nack(hr_sensor_nack),
        .hr_sensor_read_timeout(hr_sensor_read_timeout),
        .hr_sensor_sample_event(hr_sensor_sample_event),
        .hr_sensor_freeze_evidence(hr_sensor_freeze_evidence),
        .hr_sensor_sample_sequence(hr_sensor_sample_sequence),
        .spo2_sensor_comm_event(spo2_sensor_comm_event),
        .spo2_sensor_nack(spo2_sensor_nack),
        .spo2_sensor_read_timeout(spo2_sensor_read_timeout),
        .spo2_sensor_sample_event(spo2_sensor_sample_event),
        .spo2_sensor_freeze_evidence(spo2_sensor_freeze_evidence),
        .spo2_sensor_sample_sequence(spo2_sensor_sample_sequence),
        .tmp_comm_event(tmp_comm_event),
        .tmp_nack(tmp_nack),
        .tmp_read_timeout(tmp_read_timeout),
        .tmp_sample_event(tmp_sample_event),
        .tmp_freeze_evidence(tmp_freeze_evidence),
        .tmp_sample_sequence(tmp_sample_sequence),
        .room_comm_event(room_comm_event),
        .room_nack(room_nack),
        .room_read_timeout(room_read_timeout),
        .room_sample_event(room_sample_event),
        .room_freeze_evidence(room_freeze_evidence),
        .room_sample_sequence(room_sample_sequence),
        .hr_ppg_event(hr_ppg_event),
        .hr_ppg_replaced(hr_ppg_replaced),
        .hr_ppg_distorted(hr_ppg_distorted),
        .spo2_ppg_pair_event(spo2_ppg_pair_event),
        .spo2_ppg_pair_replaced(spo2_ppg_pair_replaced),
        .spo2_ppg_pair_distorted(spo2_ppg_pair_distorted),
        .limits_valid(limits_valid),
        .hr_lower(hr_lower),
        .hr_upper(hr_upper),
        .spo2_lower(spo2_lower),
        .spo2_upper(spo2_upper),
        .body_lower(body_lower),
        .body_upper(body_upper),
        .room_lower(room_lower),
        .room_upper(room_upper),
        .hr_hysteresis(hr_hysteresis),
        .spo2_hysteresis(spo2_hysteresis),
        .body_hysteresis(body_hysteresis),
        .room_hysteresis(room_hysteresis),
        .hr_bpm_x100(hr_bpm_x100),
        .spo2_percent_x100(spo2_percent_x100),
        .body_raw_q7(body_raw_q7),
        .room_raw_q7(room_raw_q7),
        .hr_valid(hr_valid),
        .hr_new(hr_new),
        .hr_good(hr_good),
        .spo2_valid(spo2_valid),
        .spo2_new(spo2_new),
        .spo2_good(spo2_good),
        .body_valid(body_valid),
        .body_new(body_new),
        .body_good(body_good),
        .room_valid(room_valid),
        .room_new(room_new),
        .room_good(room_good),
        .hr_ready(hr_ready),
        .spo2_ready(spo2_ready),
        .body_ready(body_ready),
        .room_ready(room_ready),
        .hr_smooth_bpm_x100(hr_smooth_bpm_x100),
        .spo2_smooth_percent_x100(spo2_smooth_percent_x100),
        .body_smooth_q7(body_smooth_q7),
        .room_smooth_q7(room_smooth_q7),
        .hr_smooth_valid(hr_smooth_valid),
        .spo2_smooth_valid(spo2_smooth_valid),
        .body_smooth_valid(body_smooth_valid),
        .room_smooth_valid(room_smooth_valid),
        .hr_smooth_ready(hr_smooth_ready),
        .spo2_smooth_ready(spo2_smooth_ready),
        .body_smooth_ready(body_smooth_ready),
        .room_smooth_ready(room_smooth_ready),
        .hr_sensor_fault_reason(hr_sensor_fault_reason),
        .spo2_sensor_fault_reason(spo2_sensor_fault_reason),
        .tmp_fault_reason(tmp_fault_reason),
        .room_fault_reason(room_fault_reason),
        .hr_sensor_pending_reason(hr_sensor_pending_reason),
        .spo2_sensor_pending_reason(spo2_sensor_pending_reason),
        .tmp_pending_reason(tmp_pending_reason),
        .room_pending_reason(room_pending_reason),
        .range_alarm(range_alarm),
        .range_candidate(range_candidate),
        .range_config_error(range_config_error),
        .feature_available(feature_available),
        .device_isolated(device_isolated),
        .system_status(system_status),
        .system_error(system_error),
        .buzzer_enable(buzzer_enable),
        .fault_led_rgb(fault_led_rgb),
        .monitor_mode(monitor_mode),
        .degraded(degraded),
        .assessment_valid(assessment_valid),
        .unavailable_confirmed(unavailable_confirmed),
        .health_danger_mask(health_danger_mask),
        .health_warning_mask(health_warning_mask),
        .health_pending_mask(health_pending_mask),
        .danger_active(danger_active),
        .hr_weight_bp(hr_weight_bp),
        .spo2_weight_bp(spo2_weight_bp),
        .body_weight_bp(body_weight_bp),
        .room_weight_bp(room_weight_bp),
        .fusion_score(fusion_score),
        .fusion_valid(fusion_valid)
    );
endmodule
