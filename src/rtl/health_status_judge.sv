`timescale 1ns/1ps
// ============================================================================
// 【用途】可信最终指标的持续分级与辅助融合；不是原始PPG算法或医疗诊断。
// 【位序】[3:0]={室温,人体温度,血氧,心率}；feature_event只在接收可信新指标时脉冲。
// 原始可信指标并行分级，显示曲线仍走原平滑器，避免滤波掩盖持续异常。
// HR/SpO2/人体温度/室温基础权重20/40/30/10；失效后归一化，不补造缺失测量。
// 权重及Normal=0/Warning=50/Danger=100分数是项目演示规则，不是风险概率。
// 任一可信人体Danger不能被平均抵消；室温最多计50，只形成环境Warning。
// 温度Q7演示阈值须按安装位置标定，不能把TMP117皮温当成已验证核心体温。
// 组合不足只在本模块标“无法判断”，System Error由顶层确认持续不可用后决定。
// ============================================================================
module health_status_judge #(
    parameter [15:0] HR_DANGER_LOW=16'd5000,       // 心率危险下界，单位bpm乘100；严格小于时危险，演示值
    parameter [15:0] HR_DANGER_HIGH=16'd12000,     // 心率危险上界，单位bpm乘100；严格大于时危险，演示值
    parameter [15:0] HR_NORMAL_LOW=16'd6000,       // 心率正常闭区间下界，单位bpm乘100；待实测校准
    parameter [15:0] HR_NORMAL_HIGH=16'd10000,     // 心率正常闭区间上界，单位bpm乘100；不区分运动状态
    parameter [15:0] SPO2_DANGER_LOW=16'd9000,     // 血氧危险下界，单位百分数乘100；严格小于时危险
    parameter [15:0] SPO2_NORMAL_LOW=16'd9500,     // 血氧正常闭区间下界，单位百分数乘100；合法上限10000
    parameter signed [15:0] BODY_DANGER_LOW=16'sd4480,  // 人体测温危险下界，摄氏度乘128；沿用35摄氏度演示值
    parameter signed [15:0] BODY_DANGER_HIGH=16'sd4992, // 人体测温危险上界，摄氏度乘128；沿用39摄氏度演示值
    parameter signed [15:0] BODY_NORMAL_LOW=16'sd4647, // 人体测温正常最小Q7码；沿用36.3摄氏度演示值，不是皮温标准
    parameter signed [15:0] BODY_NORMAL_HIGH=16'sd4761, // 人体测温正常最大Q7码；沿用37.2摄氏度演示值，须校准
    parameter integer CONFIRM_MS=3000,            // 健康等级升高所需连续确认时长，毫秒；还需满足新指标数
    parameter integer RECOVER_MS=2000,            // 健康等级降低所需连续恢复时长，毫秒；缺样不能伪造恢复
    parameter integer CONFIRM_SAMPLES=3,          // 健康异常确认所需连续可信新指标数，个
    parameter integer RECOVER_SAMPLES=3,          // 健康恢复确认所需连续可信新指标数，个
    parameter integer WEIGHT_HR=20,               // 心率基础权重，相对百分比；四项合计必须100
    parameter integer WEIGHT_SPO2=40,             // 血氧基础权重，相对百分比；不是医学风险概率
    parameter integer WEIGHT_BODY=30,             // 人体测温基础权重，相对百分比；按测温位置校准
    parameter integer WEIGHT_ROOM=10              // 室温基础权重，相对百分比；仅作辅助环境背景
) (
    input wire aclk, aresetn, tick_1ms,
    input wire [15:0] hr_bpm_x100, spo2_percent_x100,
    input wire signed [15:0] body_raw_q7,
    input wire [3:0] feature_valid,
    input wire [2:0] feature_event,
    input wire environment_warning,
    input wire [2:0] range_danger,
    output reg [1:0] health_status,
    output wire [3:0] evaluated_valid,
    output wire [2:0] danger_mask, warning_mask, pending_mask,
    output reg [1:0] monitor_mode,
    output wire degraded, assessment_valid,
    output reg [13:0] hr_weight_bp, spo2_weight_bp, body_weight_bp, room_weight_bp,
    output reg [6:0] fusion_score,
    output wire fusion_valid
);
    localparam [1:0] NORMAL=2'd0;        // 已监测范围内未发现配置的异常
    localparam [1:0] WARNING=2'd1;       // 持续确认的项目预警
    localparam [1:0] DANGER=2'd2;        // 持续确认的可信人体危险
    localparam [1:0] UNASSESSABLE=2'd3;  // 内部无法判断，不直接代表物理器件损坏
    localparam [1:0] MODE_WAIT=2'd0;     // 模式0：组合不足或等待数据
    localparam [1:0] MODE_FULL=2'd1;     // 模式1：四路完整监测
    localparam [1:0] MODE_THREE=2'd2;    // 模式2：任意三路降级监测
    localparam [1:0] MODE_CORE=2'd3;     // 模式3：仅血氧和人体温度有限监测
    localparam integer FULL_W=WEIGHT_HR+WEIGHT_SPO2+WEIGHT_BODY+WEIGHT_ROOM; // 四路权重分母
    localparam integer NO_HR_W=WEIGHT_SPO2+WEIGHT_BODY+WEIGHT_ROOM; // 无心率的归一化分母
    localparam integer NO_SPO2_W=WEIGHT_HR+WEIGHT_BODY+WEIGHT_ROOM; // 无血氧的归一化分母
    localparam integer NO_BODY_W=WEIGHT_HR+WEIGHT_SPO2+WEIGHT_ROOM; // 无人体测温的归一化分母
    localparam integer NO_ROOM_W=WEIGHT_HR+WEIGHT_SPO2+WEIGHT_BODY; // 无室温的归一化分母
    localparam integer CORE_W=WEIGHT_SPO2+WEIGHT_BODY; // 温度与氧合双路模式的归一化分母
    wire [1:0] raw_level [0:2], qualified_level [0:2];
    wire [2:0] assessed;
    assign raw_level[0]=(hr_bpm_x100<HR_DANGER_LOW || hr_bpm_x100>HR_DANGER_HIGH) ? DANGER :
        (hr_bpm_x100<HR_NORMAL_LOW || hr_bpm_x100>HR_NORMAL_HIGH) ? WARNING : NORMAL;
    assign raw_level[1]=spo2_percent_x100>16'd10000 ? UNASSESSABLE :
        spo2_percent_x100<SPO2_DANGER_LOW ? DANGER : spo2_percent_x100<SPO2_NORMAL_LOW ? WARNING : NORMAL;
    assign raw_level[2]=(body_raw_q7<BODY_DANGER_LOW || body_raw_q7>BODY_DANGER_HIGH) ? DANGER :
        (body_raw_q7<BODY_NORMAL_LOW || body_raw_q7>BODY_NORMAL_HIGH) ? WARNING : NORMAL;
    genvar lane;
    generate for (lane=0;lane<3;lane=lane+1) begin : g_health_lane
        health_level_qualifier #(
            .CONFIRM_MS(CONFIRM_MS),             // 本路等级升高所需真实毫秒数
            .RECOVER_MS(RECOVER_MS),             // 本路等级降低所需真实毫秒数
            .CONFIRM_SAMPLES(CONFIRM_SAMPLES),   // 本路异常确认所需可信新指标数
            .RECOVER_SAMPLES(RECOVER_SAMPLES)    // 本路恢复确认所需可信新指标数
        ) u_qualify (
            .aclk(aclk),.aresetn(aresetn),.tick_1ms(tick_1ms),
            .available(feature_valid[lane]),.sample_event(feature_event[lane]),
            .raw_level(raw_level[lane]),.qualified_level(qualified_level[lane]),
            .assessed(assessed[lane]),.pending(pending_mask[lane]));
        // 组合不足时也保留单路可信危险位，不能由System Error屏蔽。
        assign danger_mask[lane]=feature_valid[lane] && (range_danger[lane] ||
            (assessed[lane] && qualified_level[lane]==DANGER));
        assign warning_mask[lane]=feature_valid[lane] && !range_danger[lane] &&
            assessed[lane] && qualified_level[lane]==WARNING;
    end endgenerate
    wire [13:0] weighted_risk=
        (danger_mask[0] ? 100 : warning_mask[0] ? 50 : 0)*WEIGHT_HR +
        (danger_mask[1] ? 100 : warning_mask[1] ? 50 : 0)*WEIGHT_SPO2 +
        (danger_mask[2] ? 100 : warning_mask[2] ? 50 : 0)*WEIGHT_BODY +
        ((feature_valid[3] && environment_warning) ? 50 : 0)*WEIGHT_ROOM;
    // bp为百分之一百分点，10000代表100%；各项独立四舍五入可能相差1bp。
    // 六种允许组合各用常量分母，综合后不需要通用可变除法器。
    always @* begin
        monitor_mode=MODE_WAIT;
        hr_weight_bp=0; spo2_weight_bp=0; body_weight_bp=0; room_weight_bp=0; fusion_score=0;
        case (feature_valid)
            4'b1111: begin
                monitor_mode=MODE_FULL;
                hr_weight_bp=(10000*WEIGHT_HR+FULL_W/2)/FULL_W;
                spo2_weight_bp=(10000*WEIGHT_SPO2+FULL_W/2)/FULL_W;
                body_weight_bp=(10000*WEIGHT_BODY+FULL_W/2)/FULL_W;
                room_weight_bp=(10000*WEIGHT_ROOM+FULL_W/2)/FULL_W;
                fusion_score=(weighted_risk+FULL_W/2)/FULL_W;
            end
            4'b1110: begin
                monitor_mode=MODE_THREE;
                spo2_weight_bp=(10000*WEIGHT_SPO2+NO_HR_W/2)/NO_HR_W;
                body_weight_bp=(10000*WEIGHT_BODY+NO_HR_W/2)/NO_HR_W;
                room_weight_bp=(10000*WEIGHT_ROOM+NO_HR_W/2)/NO_HR_W;
                fusion_score=(weighted_risk+NO_HR_W/2)/NO_HR_W;
            end
            4'b1101: begin
                monitor_mode=MODE_THREE;
                hr_weight_bp=(10000*WEIGHT_HR+NO_SPO2_W/2)/NO_SPO2_W;
                body_weight_bp=(10000*WEIGHT_BODY+NO_SPO2_W/2)/NO_SPO2_W;
                room_weight_bp=(10000*WEIGHT_ROOM+NO_SPO2_W/2)/NO_SPO2_W;
                fusion_score=(weighted_risk+NO_SPO2_W/2)/NO_SPO2_W;
            end
            4'b1011: begin
                monitor_mode=MODE_THREE;
                hr_weight_bp=(10000*WEIGHT_HR+NO_BODY_W/2)/NO_BODY_W;
                spo2_weight_bp=(10000*WEIGHT_SPO2+NO_BODY_W/2)/NO_BODY_W;
                room_weight_bp=(10000*WEIGHT_ROOM+NO_BODY_W/2)/NO_BODY_W;
                fusion_score=(weighted_risk+NO_BODY_W/2)/NO_BODY_W;
            end
            4'b0111: begin
                monitor_mode=MODE_THREE;
                hr_weight_bp=(10000*WEIGHT_HR+NO_ROOM_W/2)/NO_ROOM_W;
                spo2_weight_bp=(10000*WEIGHT_SPO2+NO_ROOM_W/2)/NO_ROOM_W;
                body_weight_bp=(10000*WEIGHT_BODY+NO_ROOM_W/2)/NO_ROOM_W;
                fusion_score=(weighted_risk+NO_ROOM_W/2)/NO_ROOM_W;
            end
            4'b0110: begin
                monitor_mode=MODE_CORE;
                spo2_weight_bp=(10000*WEIGHT_SPO2+CORE_W/2)/CORE_W;
                body_weight_bp=(10000*WEIGHT_BODY+CORE_W/2)/CORE_W;
                fusion_score=(weighted_risk+CORE_W/2)/CORE_W;
            end
            default: begin end
        endcase
        health_status=NORMAL;
        if (monitor_mode==MODE_WAIT || ((assessed & feature_valid[2:0])!=feature_valid[2:0]))
            health_status=UNASSESSABLE;
        else if (|danger_mask) health_status=DANGER;
        else if ((|warning_mask) || (feature_valid[3] && environment_warning)) health_status=WARNING;
        if (health_status==UNASSESSABLE) fusion_score=0;
    end
    // 当前掩码直接组合判断；确认状态在各路寄存，不再使用旧拍组合。
    assign evaluated_valid=feature_valid;
    assign assessment_valid=aresetn && health_status!=UNASSESSABLE;
    assign fusion_valid=assessment_valid;
    assign degraded=aresetn && (monitor_mode==MODE_THREE || monitor_mode==MODE_CORE);
    // synthesis translate_off
    initial begin
        if (HR_DANGER_LOW>HR_NORMAL_LOW || HR_NORMAL_LOW>HR_NORMAL_HIGH || HR_NORMAL_HIGH>HR_DANGER_HIGH ||
            SPO2_DANGER_LOW>SPO2_NORMAL_LOW || SPO2_NORMAL_LOW>10000 ||
            BODY_DANGER_LOW>BODY_NORMAL_LOW || BODY_NORMAL_LOW>BODY_NORMAL_HIGH || BODY_NORMAL_HIGH>BODY_DANGER_HIGH ||
            WEIGHT_HR<1 || WEIGHT_SPO2<1 || WEIGHT_BODY<1 || WEIGHT_ROOM<1 || FULL_W!=100)
            $fatal(1,"Invalid health thresholds or project fusion weights");
    end
    // synthesis translate_on
endmodule

// 同文件复用的单路分级器；没有测试刺激、文件输入或伪数据。
module health_level_qualifier #(
    parameter integer CONFIRM_MS=3000,       // 等级上升的最短连续时长，毫秒
    parameter integer RECOVER_MS=2000,       // 等级下降的最短连续时长，毫秒
    parameter integer CONFIRM_SAMPLES=3,     // 等级上升所需连续可信新指标数，个
    parameter integer RECOVER_SAMPLES=3      // 等级下降所需连续可信新指标数，个
) (
    input wire aclk, aresetn, tick_1ms, available, sample_event,
    input wire [1:0] raw_level,
    output reg [1:0] qualified_level,
    output reg assessed,
    output wire pending
);
    localparam integer MAX_MS=CONFIRM_MS>RECOVER_MS ? CONFIRM_MS : RECOVER_MS; // 计时饱和上限，毫秒
    localparam integer TIME_W=MAX_MS>1 ? $clog2(MAX_MS+1) : 1; // 计时器位宽，最少一位
    localparam integer MAX_COUNT=CONFIRM_SAMPLES>RECOVER_SAMPLES ? CONFIRM_SAMPLES : RECOVER_SAMPLES; // 样本计数饱和上限
    localparam integer COUNT_W=MAX_COUNT>1 ? $clog2(MAX_COUNT+1) : 1; // 新指标计数器位宽，最少一位
    reg active;
    reg [1:0] candidate_level;
    reg [TIME_W-1:0] elapsed_ms;
    reg [COUNT_W-1:0] sample_count;
    wire rising_level=raw_level>qualified_level;
    wire compatible=active && ((rising_level && candidate_level>qualified_level) ||
        (!rising_level && raw_level<qualified_level && candidate_level<qualified_level));
    // Warning/Danger交替时至少确认Warning；恢复时取较高等级，不能过早清Normal。
    wire [1:0] candidate_next=!compatible ? raw_level : rising_level ?
        (raw_level<candidate_level ? raw_level : candidate_level) :
        (raw_level>candidate_level ? raw_level : candidate_level);
    wire time_met=rising_level ? (elapsed_ms>=CONFIRM_MS || (tick_1ms && elapsed_ms>=CONFIRM_MS-1)) :
        (elapsed_ms>=RECOVER_MS || (tick_1ms && elapsed_ms>=RECOVER_MS-1));
    wire count_met=rising_level ? sample_count>=CONFIRM_SAMPLES-1 : sample_count>=RECOVER_SAMPLES-1;
    assign pending=available && active;
    always @(posedge aclk) begin
        if (!aresetn || !available) begin
            qualified_level<=0; assessed<=0; active<=0;
            candidate_level<=0; elapsed_ms<=0; sample_count<=0;
        end else begin
            if (active && tick_1ms && elapsed_ms<MAX_MS) elapsed_ms<=elapsed_ms+1'b1;
            if (sample_event) begin
                if (raw_level==2'd3) begin
                    // 非法有效编码不是生理Danger，等待真正合格的新指标。
                    qualified_level<=0; assessed<=0; active<=0; elapsed_ms<=0; sample_count<=0;
                end else if (raw_level==qualified_level) begin
                    assessed<=1; active<=0; elapsed_ms<=0; sample_count<=0;
                end else if (!compatible) begin
                    active<=1; candidate_level<=raw_level; sample_count<=1; elapsed_ms<=0;
                end else begin
                    candidate_level<=candidate_next;
                    if (sample_count<MAX_COUNT) sample_count<=sample_count+1'b1;
                    if (time_met && count_met) begin
                        qualified_level<=candidate_next; assessed<=1;
                        active<=0; elapsed_ms<=0; sample_count<=0;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    initial if (CONFIRM_MS<1 || RECOVER_MS<1 || CONFIRM_SAMPLES<2 || RECOVER_SAMPLES<2)
        $fatal(1,"Invalid health persistence configuration");
    // synthesis translate_on
endmodule
