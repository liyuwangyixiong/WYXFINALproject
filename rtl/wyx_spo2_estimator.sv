`timescale 1ns/1ps
// MAX30102双波长实验估算器：4秒滑窗、去直流/线性趋势、RMS比值及质量门控。
// 数学方法参考 Robert Fraczkiewicz/MAX30102_by_RF 及用户包内Maxim参考代码。
// 独立定点RTL实现；拟合系数未经本模块光学结构标定，不能声称医疗准确度。
// 原始数据不会被改写；只有通过质量检查的新结果才送到既有C平滑接口。
module wyx_spo2_estimator #(
    parameter integer GAP_LIMIT_MS=100, // 连续无原始样本的失效时长，毫秒；恢复后重新收集完整窗口
    parameter integer MIN_DC_COUNTS=1000, // 最低平均光强，ADC计数；用于无接触候选门控，需实物标定
    parameter integer MIN_PERFUSION_BP=5, // 最低RMS交流/直流比，万分比；5表示0.05%
    parameter integer MAX_PERFUSION_BP=1000, // 最高RMS交流/直流比，万分比；1000表示10%
    parameter integer MIN_CORRELATION_BP=8000, // 红光/红外最低正相关系数，万分比；8000表示0.80
    parameter integer MIN_PERIODICITY_BP=4500 // IR首选周期峰相对零延迟能量门限，万分比；4500表示0.45
)(
    input wire clk,rst_n,tick_1ms,
    input wire sample_valid,stream_online,stream_overflow,
    input wire [17:0] red_raw,ir_raw,
    input wire signed [23:0] red_ac_filtered,ir_ac_filtered, // 与raw对齐的PPG带通交流量，原始DC独立保留
    output reg estimate_valid,estimate_good,
    output reg [15:0] spo2_x100,
    output reg result_event,
    output reg [7:0] reject_reason,
    output reg [31:0] ratio_q16,
    output reg [15:0] correlation_bp,period_samples
);
    localparam integer WINDOW_SAMPLES=400; // 固定100Hz下的4秒分析窗，修改采样率必须重新验证整个估算器
    localparam integer HOP_SAMPLES=100; // 满窗后每100个新样本计算一次，即约每秒更新
    localparam integer SQRT_WINDOW=20; // 400个样本数的整数平方根，用于RMS/直流比的单位换算
    localparam integer TIME_SUM_SQUARE=21333200; // sum((2*i-399)^2)，用于中心化线性回归斜率
    localparam integer MIN_LAG=25; // 周期搜索最短间隔，100Hz下相当于240bpm；仅作信号质量检查
    localparam integer MAX_LAG=166; // 周期搜索最长间隔，100Hz下约36bpm；不替代独立心率模块
    localparam [4:0] IDLE=0,COPY=1,MEAN=2,DETREND=3,ROOT_R_START=4,ROOT_R_WAIT=5, // 分析状态编码：快照、回归和能量
        ROOT_I_START=6,ROOT_I_WAIT=7,CORR_START=8,CORR_WAIT=9,PI_R_START=10,PI_R_WAIT=11, // 分析状态编码：平方根和质量比值
        PI_I_START=12,PI_I_WAIT=13,RATIO_START=14,RATIO_WAIT=15,AUTO_INIT=16,AUTO_MAC=17, // 分析状态编码：比值和周期搜索
        AUTO_CHECK=18,POLY_PREP=19,POLY_CALC=20,POLY_DIV_START=21,POLY_DIV_WAIT=22,FINISH=23,AUTO_READ=24; // 分析状态编码：拟合及结果发布

    reg [83:0] ring_mem[0:WINDOW_SAMPLES-1];
    reg [83:0] frame_mem[0:WINDOW_SAMPLES-1];
    reg [20:0] ir_ac_mem[0:WINDOW_SAMPLES-1]; // 交流量按21位二补码原样存储；读出后显式恢复符号
    reg signed [20:0] auto_left,auto_right; // 先寄存带符号读数，避免综合时数组选择隐式零扩展

    reg [8:0] wr_ptr,fill_count,snapshot_start,copy_ptr,index;
    reg [6:0] hop_count;
    reg [15:0] gap_ms;
    reg pending,snapshot_torn,rail_seen;
    reg [4:0] state;
    reg [63:0] sum_red,sum_ir;
    reg signed [63:0] mean_red_q8,mean_ir_q8;
    reg signed [63:0] sum_red_ac,sum_ir_ac;
    reg signed [47:0] dot_red,dot_ir;
    reg signed [31:0] slope_red_q8,slope_ir_q8;
    reg [31:0] dc_red,dc_ir;
    reg [63:0] energy_red,energy_ir;
    reg signed [63:0] covariance;
    reg [31:0] root_red,root_ir;
    reg [63:0] pi_red,pi_ir,ratio_full,corr_full;
    reg [8:0] lag;
    reg signed [63:0] auto_sum,auto_prev,auto_prev2,best_auto;
    reg [15:0] best_lag;
    reg [63:0] ratio_square_q16,linear_term;
    reg signed [63:0] polynomial_q16;
    reg [63:0] candidate_spo2;
    wire [83:0] copy_word=ring_mem[copy_ptr];
    wire signed [10:0] centered_time=$signed({1'b0,index,1'b0})-11'sd399;
    wire signed [23:0] copy_red=$signed(copy_word[47:24]);
    wire signed [23:0] copy_ir=$signed(copy_word[23:0]);
    wire signed [63:0] frame_red=$signed(frame_mem[index][47:24]);
    wire signed [63:0] frame_ir=$signed(frame_mem[index][23:0]);
    wire signed [63:0] detrend_red_q8=(frame_red<<<8)-$signed(mean_red_q8)-slope_red_q8*centered_time;
    wire signed [63:0] detrend_ir_q8=(frame_ir<<<8)-$signed(mean_ir_q8)-slope_ir_q8*centered_time;
    wire signed [20:0] ac_red=detrend_red_q8>>>8;
    wire signed [20:0] ac_ir=detrend_ir_q8>>>8;
    wire signed [63:0] square_red=$signed(ac_red)*$signed(ac_red);
    wire signed [63:0] square_ir=$signed(ac_ir)*$signed(ac_ir);
    wire signed [63:0] cross_product=$signed(ac_red)*$signed(ac_ir);
    wire signed [41:0] auto_product_narrow=auto_left*auto_right;
    wire signed [63:0] auto_product={{22{auto_product_narrow[41]}},auto_product_narrow};
    wire gap_expired=tick_1ms && gap_ms>=GAP_LIMIT_MS-1 && !sample_valid;
    wire abort_stream=!stream_online || stream_overflow || gap_expired;
    reg div_start,root_start;
    reg [63:0] numerator,denominator,root_operand;
    wire div_done,root_done;
    wire [63:0] quotient;
    wire [31:0] root_value;
    wyx_spo2_u64_div u_div(.clk(clk),.rst_n(rst_n && !abort_stream),.start(div_start),
        .numerator(numerator),.denominator(denominator),.done(div_done),.quotient(quotient));
    wyx_spo2_u64_sqrt u_root(.clk(clk),.rst_n(rst_n && !abort_stream),.start(root_start),
        .operand(root_operand),.done(root_done),.root(root_value));

    always @(posedge clk) begin
        estimate_valid<=0;result_event<=0;div_start<=0;root_start<=0;
        if(!rst_n) begin
            wr_ptr<=0;fill_count<=0;hop_count<=0;gap_ms<=0;pending<=0;state<=IDLE;
            estimate_good<=0;spo2_x100<=0;reject_reason<=8'h80;ratio_q16<=0;correlation_bp<=0;period_samples<=0;
            snapshot_start<=0;copy_ptr<=0;index<=0;snapshot_torn<=0;rail_seen<=0;
            sum_red<=0;sum_ir<=0;sum_red_ac<=0;sum_ir_ac<=0;dot_red<=0;dot_ir<=0;mean_red_q8<=0;mean_ir_q8<=0;
            slope_red_q8<=0;slope_ir_q8<=0;dc_red<=0;dc_ir<=0;energy_red<=0;energy_ir<=0;covariance<=0;
            root_red<=0;root_ir<=0;pi_red<=0;pi_ir<=0;ratio_full<=0;corr_full<=0;
            auto_left<=0;auto_right<=0;lag<=MIN_LAG;auto_sum<=0;auto_prev<=0;auto_prev2<=0;best_auto<=0;best_lag<=0;
            ratio_square_q16<=0;linear_term<=0;polynomial_q16<=0;candidate_spo2<=0;
            numerator<=0;denominator<=1;root_operand<=0;
        end else if(abort_stream) begin
            wr_ptr<=0;fill_count<=0;hop_count<=0;pending<=0;state<=IDLE;gap_ms<=0;
            estimate_good<=0;reject_reason<=8'h80;
        end else begin
            if(sample_valid) begin
                gap_ms<=0;
                ring_mem[wr_ptr]<={red_raw,ir_raw,red_ac_filtered,ir_ac_filtered};
                wr_ptr<=(wr_ptr==WINDOW_SAMPLES-1)?0:wr_ptr+1'b1;
                if(fill_count<WINDOW_SAMPLES) begin
                    fill_count<=fill_count+1'b1;
                    if(fill_count==WINDOW_SAMPLES-1) begin
                        pending<=1; snapshot_start<=(wr_ptr==WINDOW_SAMPLES-1)?0:wr_ptr+1'b1;hop_count<=0;
                    end
                end else if(hop_count==HOP_SAMPLES-1) begin
                    hop_count<=0;
                    if(state==IDLE && !pending) begin
                        pending<=1;snapshot_start<=(wr_ptr==WINDOW_SAMPLES-1)?0:wr_ptr+1'b1;
                    end
                end else hop_count<=hop_count+1'b1;
                if(state==COPY) snapshot_torn<=1; // 快照时恰有写入则丢弃本次计算，不影响持续采集
            end else if(tick_1ms && gap_ms<65535) gap_ms<=gap_ms+1'b1;

            case(state)
                IDLE: if(pending) begin
                    pending<=0;copy_ptr<=snapshot_start;index<=0;snapshot_torn<=0;rail_seen<=0;
                    sum_red<=0;sum_ir<=0;sum_red_ac<=0;sum_ir_ac<=0;dot_red<=0;dot_ir<=0;state<=COPY;
                end
                COPY: begin // 复制当前400个真实样本，原始红光/红外保留DC，滤波交流量用于能量统计
                    frame_mem[index]<=copy_word;
                    sum_red<=sum_red+copy_word[83:66];sum_ir<=sum_ir+copy_word[65:48];
                    sum_red_ac<=sum_red_ac+copy_red;sum_ir_ac<=sum_ir_ac+copy_ir;
                    dot_red<=dot_red+copy_red*centered_time;dot_ir<=dot_ir+copy_ir*centered_time;
                    if(copy_word[83:66]==0 || copy_word[83:66]==18'h3ffff || copy_word[65:48]==0 || copy_word[65:48]==18'h3ffff) rail_seen<=1;
                    copy_ptr<=(copy_ptr==WINDOW_SAMPLES-1)?0:copy_ptr+1'b1;
                    if(index==WINDOW_SAMPLES-1) begin index<=0;state<=MEAN;end
                    else index<=index+1'b1;
                end
                MEAN: begin // 分别求原始DC均值及滤波AC均值、线性趋势；两者不混用
                    mean_red_q8<=(sum_red_ac<<<8)/WINDOW_SAMPLES;mean_ir_q8<=(sum_ir_ac<<<8)/WINDOW_SAMPLES;
                    dc_red<=sum_red/WINDOW_SAMPLES;dc_ir<=sum_ir/WINDOW_SAMPLES;
                    slope_red_q8<=(dot_red<<<8)/TIME_SUM_SQUARE;slope_ir_q8<=(dot_ir<<<8)/TIME_SUM_SQUARE;
                    energy_red<=0;energy_ir<=0;covariance<=0;state<=DETREND;
                end
                DETREND: begin // 滤波AC去均值和慢线性漂移后，累计平方能量、协方差与IR窗口
                    ir_ac_mem[index]<=ac_ir;
                    energy_red<=energy_red+square_red;energy_ir<=energy_ir+square_ir;covariance<=covariance+cross_product;
                    if(index==WINDOW_SAMPLES-1) begin index<=0;state<=ROOT_R_START;end
                    else index<=index+1'b1;
                end
                ROOT_R_START: begin root_operand<=energy_red;root_start<=1;state<=ROOT_R_WAIT;end
                ROOT_R_WAIT: if(root_done) begin root_red<=root_value;state<=ROOT_I_START;end
                ROOT_I_START: begin root_operand<=energy_ir;root_start<=1;state<=ROOT_I_WAIT;end
                ROOT_I_WAIT: if(root_done) begin root_ir<=root_value;state<=CORR_START;end
                CORR_START: begin // 红光红外相关性门控；协方差除以两路能量平方根的乘积
                    numerator<=(covariance>0)?$unsigned(covariance)*64'd10000:0;
                    denominator<={32'd0,root_red}*root_ir;div_start<=1;state<=CORR_WAIT;
                end
                CORR_WAIT: if(div_done) begin corr_full<=quotient;state<=PI_R_START;end
                PI_R_START: begin numerator<={32'd0,root_red}*64'd10000;denominator<={32'd0,dc_red}*SQRT_WINDOW;div_start<=1;state<=PI_R_WAIT;end
                PI_R_WAIT: if(div_done) begin pi_red<=quotient;state<=PI_I_START;end
                PI_I_START: begin numerator<={32'd0,root_ir}*64'd10000;denominator<={32'd0,dc_ir}*SQRT_WINDOW;div_start<=1;state<=PI_I_WAIT;end
                PI_I_WAIT: if(div_done) begin pi_ir<=quotient;state<=RATIO_START;end
                RATIO_START: begin // R等于红光RMS乘红外DC，再除以红外RMS乘红光DC；Q16编码
                    numerator<=({32'd0,root_red}*dc_ir)<<16;denominator<={32'd0,root_ir}*dc_red;
                    div_start<=1;state<=RATIO_WAIT;
                end
                RATIO_WAIT: if(div_done) begin ratio_full<=quotient;state<=AUTO_INIT;end
                AUTO_INIT: begin lag<=MIN_LAG;index<=0;auto_sum<=0;auto_prev<=0;auto_prev2<=0;best_auto<=0;best_lag<=0;state<=AUTO_READ;end
                AUTO_READ: begin // 按21位二补码读取并寄存两路带符号交流量，避免数组读数被综合成无符号量
                    auto_left<=$signed(ir_ac_mem[index]);
                    auto_right<=$signed(ir_ac_mem[index+lag]);
                    state<=AUTO_MAC;
                end
                AUTO_MAC: begin // 逐延迟累加红外自相关，验证是否存在可信脉搏周期
                    auto_sum<=auto_sum+auto_product;
                    if(index==WINDOW_SAMPLES-lag-1) begin index<=0;state<=AUTO_CHECK;end
                    else begin index<=index+1'b1;state<=AUTO_READ;end
                end
                AUTO_CHECK: begin // 只保留局部周期峰，避免零延迟附近的高相似度冒充心跳
                    if(lag>=MIN_LAG+2 && auto_prev>=auto_prev2 && auto_prev>auto_sum && auto_prev>best_auto) begin best_auto<=auto_prev;best_lag<=lag-1'b1;end
                    auto_prev2<=auto_prev;auto_prev<=auto_sum;auto_sum<=0;
                    if(lag==MAX_LAG) state<=POLY_PREP;
                    else begin lag<=lag+1'b1;state<=AUTO_READ;end
                end
                POLY_PREP: begin // 准备R平方与一次项；工程拟合曲线仍须按光路实物标定
                    ratio_square_q16<=(ratio_full*ratio_full+64'd32768)>>16;
                    linear_term<=64'd30354*ratio_full;state<=POLY_CALC;
                end
                POLY_CALC: begin // 拟合SpO2=-45.060R平方+30.354R+94.845，保留Q16和千分数精度
                    polynomial_q16<=64'sd6215761920+$signed(linear_term)-$signed(64'd45060*ratio_square_q16);
                    state<=POLY_DIV_START;
                end
                POLY_DIV_START: begin // 将拟合中间量换算成百分数乘100整数接口
                    numerator<=(polynomial_q16>0)?$unsigned(polynomial_q16)+64'd327680:0;
                    denominator<=64'd655360;div_start<=1;state<=POLY_DIV_WAIT;
                end
                POLY_DIV_WAIT: if(div_done) begin candidate_spo2<=quotient;state<=FINISH;end
                FINISH: begin // 先发布质量诊断；只有通过所有门控的新结果才置estimate_valid，不填常数
                    result_event<=1;estimate_good<=0;
                    correlation_bp<=(corr_full>10000)?16'd10000:corr_full[15:0];
                    ratio_q16<=(ratio_full>32'hffffffff)?32'hffffffff:ratio_full[31:0];period_samples<=best_lag;
                    reject_reason<={snapshot_torn,(ratio_full<=1310 || ratio_full>=120586 || candidate_spo2>10000 || polynomial_q16<=0),
                        (best_auto<=0 || $unsigned(best_auto)*64'd10000<energy_ir*MIN_PERIODICITY_BP),
                        (corr_full<MIN_CORRELATION_BP || covariance<=0),
                        (pi_red<MIN_PERFUSION_BP || pi_ir<MIN_PERFUSION_BP || pi_red>MAX_PERFUSION_BP || pi_ir>MAX_PERFUSION_BP),
                        rail_seen,(dc_red<MIN_DC_COUNTS || dc_ir<MIN_DC_COUNTS),1'b0};
                    if(!snapshot_torn && !rail_seen && dc_red>=MIN_DC_COUNTS && dc_ir>=MIN_DC_COUNTS &&
                        pi_red>=MIN_PERFUSION_BP && pi_ir>=MIN_PERFUSION_BP && pi_red<=MAX_PERFUSION_BP && pi_ir<=MAX_PERFUSION_BP &&
                        corr_full>=MIN_CORRELATION_BP && covariance>0 && best_auto>0 && $unsigned(best_auto)*64'd10000>=energy_ir*MIN_PERIODICITY_BP &&
                        ratio_full>1310 && ratio_full<120586 && candidate_spo2<=10000 && polynomial_q16>0) begin
                        spo2_x100<=candidate_spo2[15:0];estimate_valid<=1;estimate_good<=1;
                    end
                    state<=IDLE;
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule

// 固定64位无符号迭代除法；零分母输出全1哨兵，由估算器质量门控拒绝。
module wyx_spo2_u64_div(input wire clk,rst_n,start,input wire [63:0] numerator,denominator,
    output reg done,output reg [63:0] quotient);
    reg busy;
    reg [6:0] count;
    reg [63:0] divisor,dividend,q;
    reg [64:0] remainder;
    wire [64:0] shifted={remainder[63:0],dividend[63]};
    wire ge=shifted>={1'b0,divisor};
    always @(posedge clk) begin
        done<=0;
        if(!rst_n) begin busy<=0;count<=0;quotient<=0;divisor<=0;dividend<=0;q<=0;remainder<=0;end
        else if(start && !busy) begin
            if(denominator==0) begin quotient<=64'hffffffffffffffff;done<=1;end
            else begin busy<=1;count<=0;divisor<=denominator;dividend<=numerator;q<=0;remainder<=0;end
        end else if(busy) begin
            remainder<=ge?shifted-{1'b0,divisor}:shifted;
            dividend<=dividend<<1;q<={q[62:0],ge};
            if(count==63) begin quotient<={q[62:0],ge};done<=1;busy<=0;end
            else count<=count+1'b1;
        end
    end
endmodule

// 每拍处理两位被开方数，32拍完成整数平方根，避免长组合开方链。
module wyx_spo2_u64_sqrt(input wire clk,rst_n,start,input wire [63:0] operand,
    output reg done,output reg [31:0] root);
    reg busy;
    reg [5:0] count;
    reg [63:0] source,remainder;
    reg [31:0] q;
    wire [63:0] shifted=(remainder<<2)|{62'd0,source[63:62]};
    wire [63:0] trial=({32'd0,q}<<2)|64'd1;
    wire ge=shifted>=trial;
    always @(posedge clk) begin
        done<=0;
        if(!rst_n) begin busy<=0;count<=0;source<=0;remainder<=0;q<=0;root<=0;end
        else if(start && !busy) begin busy<=1;count<=0;source<=operand;remainder<=0;q<=0;end
        else if(busy) begin
            remainder<=ge?shifted-trial:shifted;source<=source<<2;q<={q[30:0],ge};
            if(count==31) begin root<={q[30:0],ge};done<=1;busy<=0;end
            else count<=count+1'b1;
        end
    end
endmodule
