`timescale 1ns/1ps
// SD Linux四路板级入口；原健康滤波、分级与容错RTL逐字保留。
// UART心率、独立MAX30102血氧、0x49体温及0x48室温均启用；失败时不生成替代值。
module wyx_final_board_top #(
    parameter integer CLK_HZ=25000000, // PS的FCLK0真实频率，赫兹
    parameter integer HR_RANGE_LOW=6000, // 心率范围下界，bpm乘100，沿用项目配置
    parameter integer HR_RANGE_HIGH=10000, // 心率范围上界，bpm乘100
    parameter integer SPO2_RANGE_LOW=9500, // 血氧范围下界，百分数乘100
    parameter integer SPO2_RANGE_HIGH=10000, // 血氧合法上界，百分数乘100
    parameter integer BODY_RANGE_LOW=4647, // 探头温度范围下界，摄氏度乘128
    parameter integer BODY_RANGE_HIGH=4761, // 探头温度范围上界，摄氏度乘128
    parameter integer ROOM_RANGE_LOW=2304, // 室温范围下界，摄氏度乘128
    parameter integer ROOM_RANGE_HIGH=3584, // 室温范围上界，摄氏度乘128
    parameter integer HR_RANGE_HYSTERESIS=100, // 心率恢复内缩量，bpm乘100
    parameter integer SPO2_RANGE_HYSTERESIS=0, // 血氧恢复内缩量；0避免100%合法上界无法恢复，仍保留连续次数和时间确认
    parameter integer BODY_RANGE_HYSTERESIS=13, // 探头温度恢复内缩量，摄氏度乘128
    parameter integer ROOM_RANGE_HYSTERESIS=64 // 室温恢复内缩量，摄氏度乘128
)(inout wire [53:0] FIXED_IO_mio,
  inout wire FIXED_IO_ps_clk,FIXED_IO_ps_porb,FIXED_IO_ps_srstb,
  input wire btn_reset,kpt_uart_rxd,
  inout wire i2c_scl,i2c_sda,
  input wire nextion_rx,output wire nextion_tx,
  output wire [3:0] led,output wire led4_r,led4_g,led4_b,buzzer_out);
wire core_clk,compute_clk,clock_ready;
wire [63:0] ps_in,ps_out;
wyx_ps_clock_wrapper u_ps_clock(.FCLK_CLK0_0(core_clk),.FCLK_CLK1_0(compute_clk),.FCLK_RESET0_N_0(clock_ready),
  .FIXED_IO_mio(FIXED_IO_mio),.FIXED_IO_ps_clk(FIXED_IO_ps_clk),
  .FIXED_IO_ps_porb(FIXED_IO_ps_porb),.FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
  .live_input(ps_in),.live_output(ps_out));
(* ASYNC_REG="TRUE" *) reg [1:0] reset_sync=2'b11;
reg [7:0] reset_hold=8'hff;
always @(posedge core_clk) begin
  reset_sync<={reset_sync[0],btn_reset};
  if(!clock_ready || reset_sync[1]) reset_hold<=8'hff;
  else reset_hold<={reset_hold[6:0],1'b0};
end
wire rst_n=clock_ready && !(|reset_hold);
wire max_online;
(* ASYNC_REG="TRUE" *) reg [2:0] compute_reset_sync;
always @(posedge compute_clk or negedge rst_n) begin
  if(!rst_n) compute_reset_sync<=0;
  else compute_reset_sync<={compute_reset_sync[1:0],1'b1};
end
wire compute_rst_n=compute_reset_sync[2];
(* ASYNC_REG="TRUE" *) reg [1:0] max_online_sync;
always @(posedge compute_clk or negedge compute_rst_n) begin
  if(!compute_rst_n) max_online_sync<=0;
  else max_online_sync<={max_online_sync[0],max_online};
end
wire max_online_fast=max_online_sync[1];
localparam integer COMPUTE_MS_DIV=100000; // FCLK1=100MHz，每真实毫秒一拍
reg [16:0] compute_ms_count;
reg compute_tick_1ms;
always @(posedge compute_clk or negedge compute_rst_n) begin
  if(!compute_rst_n) begin compute_ms_count<=0;compute_tick_1ms<=0;end
  else begin
    compute_tick_1ms<=0;
    if(compute_ms_count==COMPUTE_MS_DIV-1) begin compute_ms_count<=0;compute_tick_1ms<=1;end
    else compute_ms_count<=compute_ms_count+1'b1;
  end
end
localparam integer MS_DIV=CLK_HZ/1000; // 一毫秒的时钟周期数
reg [$clog2(MS_DIV)-1:0] divider;
reg tick_1ms;
(* MARK_DEBUG="TRUE" *) reg [31:0] live_time_ms;
always @(posedge core_clk) begin
  if(!rst_n) begin divider<=0;tick_1ms<=0;live_time_ms<=0;end
  else begin
    tick_1ms<=0;
    if(divider==MS_DIV-1) begin divider<=0;tick_1ms<=1;live_time_ms<=live_time_ms+1'b1;end
    else divider<=divider+1'b1;
  end
end
wire body_valid,body_fault,room_valid,room_fault,ppg_raw_valid,max_fault,fifo_overflow;
wire [17:0] ppg_red,ppg_ir;
wire signed [15:0] raw_room;
wire signed [15:0] raw_body;
wire [2:0] diag_i2c_error;
sensor_acquire #(.CLK_HZ(CLK_HZ),.I2C_HZ(100000),.PPG_HZ(100),.TEMP_HZ(1),.ENABLE_PART_ID_CHECK(1))
 u_acquire(.clk(core_clk),.rst_n(rst_n),.i2c_scl(i2c_scl),.i2c_sda(i2c_sda),
 .body_raw_valid(body_valid),.body_raw(raw_body),.body_fault_pulse(body_fault),.last_i2c_error(diag_i2c_error),
 .room_raw_valid(room_valid),.room_raw(raw_room),.room_fault_pulse(room_fault),
 .ppg_raw_valid(ppg_raw_valid),.ppg_red(ppg_red),.ppg_ir(ppg_ir),
 .max_fault_pulse(max_fault),.max_online(max_online),.fifo_overflow_event(fifo_overflow));
wire filtered_ppg_valid,filter_settled,filter_fault;
wire [17:0] red_aligned,ir_aligned;
wire signed [23:0] red_ac,ir_ac;
wire spo2_est_valid,spo2_est_good,spo2_result;
wire [15:0] spo2_est;
wire [7:0] spo2_reject;
wire [35:0] ppg_fast_data;
wire ppg_fast_valid,ppg_mailbox_overflow;
wire ppg_path_overflow=fifo_overflow || ppg_mailbox_overflow;
wire compute_overflow_event;
wire [0:0] compute_overflow_data;
wire fast_filter_valid,fast_filter_settled,fast_filter_fault;
wire fast_est_valid,fast_est_good,fast_result_event;
wire [15:0] fast_spo2_est;
wire [7:0] fast_spo2_reject;
wire [24:0] result_slow_data;
wire result_slow_valid;
wire [0:0] filter_fault_slow_data;
(* ASYNC_REG="TRUE" *) reg [1:0] filter_settled_sync;
always @(posedge core_clk or negedge rst_n) begin
  if(!rst_n) filter_settled_sync<=0;
  else filter_settled_sync<={filter_settled_sync[0],fast_filter_settled};
end
assign filter_settled=filter_settled_sync[1];
assign spo2_result=result_slow_valid;
assign spo2_est_good=result_slow_data[24];
assign spo2_est_valid=result_slow_valid && result_slow_data[24];
assign spo2_est=result_slow_data[23:8];
assign spo2_reject=result_slow_data[7:0];
wyx_cdc_mailbox #(.WIDTH(36)) u_ppg_to_compute(
 .sclk(core_clk),.srst_n(rst_n),.s_valid(ppg_raw_valid),.s_data({ppg_red,ppg_ir}),
 .s_overflow(ppg_mailbox_overflow),.dclk(compute_clk),.drst_n(compute_rst_n),
 .d_valid(ppg_fast_valid),.d_data(ppg_fast_data));
wyx_cdc_mailbox #(.WIDTH(1)) u_overflow_to_compute(
 .sclk(core_clk),.srst_n(rst_n),.s_valid(ppg_path_overflow),.s_data(1'b1),
 .s_overflow(),.dclk(compute_clk),.drst_n(compute_rst_n),
 .d_valid(compute_overflow_event),.d_data(compute_overflow_data));
wyx_cdc_mailbox #(.WIDTH(1)) u_fault_to_peripheral(
 .sclk(compute_clk),.srst_n(compute_rst_n),.s_valid(fast_filter_fault),.s_data(1'b1),
 .s_overflow(),.dclk(core_clk),.drst_n(rst_n),
 .d_valid(filter_fault),.d_data(filter_fault_slow_data));
wyx_cdc_mailbox #(.WIDTH(25)) u_result_to_peripheral(
 .sclk(compute_clk),.srst_n(compute_rst_n),.s_valid(fast_result_event),
 .s_data({fast_est_good,fast_spo2_est,fast_spo2_reject}),.s_overflow(),
 .dclk(core_clk),.drst_n(rst_n),.d_valid(result_slow_valid),.d_data(result_slow_data));
reg [31:0] ppg_samples,spo2_samples,room_samples,spo2_errors,room_errors,spo2_age,room_age;
reg [15:0] spo2_filtered,spo2_pending_data;
reg signed [15:0] room_filtered,room_pending_data;
reg spo2_pending,room_pending;
wire spo2_filter_valid,room_filter_valid,spo2_ready,room_ready;
wire [15:0] spo2_filter_wire;
wire signed [15:0] room_filter_wire;
wire [2:0] spo2_reason,room_reason;
wire hr_display_ready,spo2_display_ready,body_display_ready,room_display_ready;
wyx_ppg_bandpass_pair_200 #(.SAMPLE_HZ(100)) u_max_filter(
 .clk(compute_clk),.rst_n(compute_rst_n && max_online_fast && !compute_overflow_event),.sample_valid(ppg_fast_valid),
 .raw_a(ppg_fast_data[35:18]),.raw_b(ppg_fast_data[17:0]),.filtered_valid(fast_filter_valid),.settled(fast_filter_settled),
 .arithmetic_fault(fast_filter_fault),.raw_a_aligned(red_aligned),.raw_b_aligned(ir_aligned),.ac_a(red_ac),.ac_b(ir_ac));
wyx_spo2_estimator_200 u_max_estimator(.clk(compute_clk),.rst_n(compute_rst_n),.tick_1ms(compute_tick_1ms),
 .sample_valid(fast_filter_valid),.stream_online(max_online_fast && fast_filter_settled && !fast_filter_fault),
 .stream_overflow(compute_overflow_event),.red_raw(red_aligned),.ir_raw(ir_aligned),
 .red_ac_filtered(red_ac),.ir_ac_filtered(ir_ac),.estimate_valid(fast_est_valid),.estimate_good(fast_est_good),
 .spo2_x100(fast_spo2_est),.result_event(fast_result_event),.reject_reason(fast_spo2_reject));
always @(posedge core_clk) begin
 if(!rst_n) begin
   ppg_samples<=0;spo2_samples<=0;room_samples<=0;spo2_errors<=0;room_errors<=0;
   spo2_age<=32'hffffffff;room_age<=32'hffffffff;spo2_filtered<=0;room_filtered<=0;
   spo2_pending<=0;room_pending<=0;spo2_pending_data<=0;room_pending_data<=0;
 end else begin
   if(tick_1ms) begin
     if(spo2_age!=32'hffffffff) spo2_age<=spo2_age+1'b1;
     if(room_age!=32'hffffffff) room_age<=room_age+1'b1;
   end
   if(ppg_raw_valid) ppg_samples<=ppg_samples+1'b1;
   if(max_fault) spo2_errors<=spo2_errors+1'b1;
   if(room_fault) room_errors<=room_errors+1'b1;
   if(spo2_filter_valid && spo2_display_ready) begin spo2_filtered<=spo2_filter_wire;spo2_samples<=spo2_samples+1'b1;spo2_age<=0;end
   if(room_filter_valid && room_display_ready) begin room_filtered<=room_filter_wire;room_samples<=room_samples+1'b1;room_age<=0;end
   if(spo2_pending && spo2_ready) spo2_pending<=0;
   if(room_pending && room_ready) room_pending<=0;
   if(spo2_est_valid && spo2_est_good) begin spo2_pending_data<=spo2_est;spo2_pending<=1;end
   // 不在ready=0期间取消已提交事务；坏窗口不会生成新的可信血氧值。
   if(room_valid) begin room_pending_data<=raw_room;room_pending<=1;end
 end
end
wire hr_frame,hr_format,hr_timeout,hr_encoding,hr_overrun;
wire [15:0] raw_hr_bpm,hr_filter_wire;
wire signed [15:0] body_filter_wire;
wire hr_filter_valid,body_filter_valid,body_ready;
wire [3:0] available,isolated,range_alarm;
wire [1:0] fpga_state;
wire assessment_valid,danger_active,fusion_valid;
wire [2:0] hr_reason,body_reason;
reg [31:0] hr_frames,body_samples,hr_errors,body_errors,hr_age,body_age;
reg [31:0] hr_results,body_results,room_raw_samples;
reg [2:0] max_last_error,body_last_error,room_last_error;
wire [3:0] range_config_error;
wire system_error,health_buzzer;
wire [2:0] fault_rgb,hr_pending_reason,spo2_pending_reason,body_pending_reason,room_pending_reason;
wire display_online;
wire [31:0] display_errors;
wire [1:0] monitor_mode;
wire [6:0] fusion_score;
reg [15:0] hr_filtered;
reg signed [15:0] body_filtered,body_pending_data;
reg body_pending;
always @(posedge core_clk) begin
  if(!rst_n) begin
    hr_frames<=0;body_samples<=0;hr_errors<=0;body_errors<=0;hr_age<=32'hffffffff;body_age<=32'hffffffff;
    hr_filtered<=0;body_filtered<=0;body_pending<=0;body_pending_data<=0;
    hr_results<=0;body_results<=0;room_raw_samples<=0;
    max_last_error<=0;body_last_error<=0;room_last_error<=0;
  end else begin
    if(tick_1ms) begin
      if(hr_age!=32'hffffffff) hr_age<=hr_age+1'b1;
      if(body_age!=32'hffffffff) body_age<=body_age+1'b1;
    end
    if(hr_frame) hr_frames<=hr_frames+1'b1;
    if(body_valid) body_samples<=body_samples+1'b1;
    if(room_valid) room_raw_samples<=room_raw_samples+1'b1;
    if(hr_format || hr_timeout || hr_encoding || hr_overrun) hr_errors<=hr_errors+1'b1;
    if(body_fault) body_errors<=body_errors+1'b1;
    if(hr_filter_valid && hr_display_ready) begin hr_filtered<=hr_filter_wire;hr_results<=hr_results+1'b1;hr_age<=0;end
    if(body_filter_valid && body_display_ready) begin body_filtered<=body_filter_wire;body_results<=body_results+1'b1;body_age<=0;end
    if(max_fault) max_last_error<=diag_i2c_error;
    if(body_fault) body_last_error<=diag_i2c_error;
    if(room_fault) room_last_error<=diag_i2c_error;
    if(body_pending && body_ready) body_pending<=0;
    if(body_valid) begin body_pending_data<=raw_body;body_pending<=1;end
  end
end
health_kpt_uart_top #(.CLK_HZ(CLK_HZ)) u_health(
    .kpt_uart_rx(kpt_uart_rxd),
    .aclk(core_clk),
    .aresetn(rst_n),
    .tick_1ms(tick_1ms),
    .spo2_sensor_comm_event(ppg_raw_valid || max_fault),
    .spo2_sensor_nack(max_fault && diag_i2c_error==1),
    .spo2_sensor_read_timeout(max_fault && diag_i2c_error!=1),
    .spo2_sensor_sample_event(ppg_raw_valid),
    .spo2_sensor_freeze_evidence('0),
    .spo2_sensor_sample_sequence(ppg_samples),
    .tmp_comm_event(body_valid || body_fault),
    .tmp_nack(body_fault && diag_i2c_error==1),
    .tmp_read_timeout(body_fault && diag_i2c_error!=1),
    .tmp_sample_event(body_valid),
    .tmp_freeze_evidence('0),
    .tmp_sample_sequence(body_samples),
    .room_comm_event(room_valid || room_fault),
    .room_nack(room_fault && diag_i2c_error==1),
    .room_read_timeout(room_fault && diag_i2c_error!=1),
    .room_sample_event(room_valid),
    .room_freeze_evidence('0),
    .room_sample_sequence(room_raw_samples),
    .spo2_ppg_pair_event(ppg_raw_valid),
    .spo2_ppg_pair_replaced('0),
    .spo2_ppg_pair_distorted(ppg_red==0 || ppg_ir==0 || ppg_red==18'h3ffff || ppg_ir==18'h3ffff),
    .limits_valid(4'b1111),
    .hr_lower(HR_RANGE_LOW),
    .hr_upper(HR_RANGE_HIGH),
    .spo2_lower(SPO2_RANGE_LOW),
    .spo2_upper(SPO2_RANGE_HIGH),
    .body_lower(BODY_RANGE_LOW),
    .body_upper(BODY_RANGE_HIGH),
    .room_lower(ROOM_RANGE_LOW),
    .room_upper(ROOM_RANGE_HIGH),
    .hr_hysteresis(HR_RANGE_HYSTERESIS[15:0]),
    .spo2_hysteresis(SPO2_RANGE_HYSTERESIS[15:0]),
    .body_hysteresis(BODY_RANGE_HYSTERESIS[15:0]),
    .room_hysteresis(ROOM_RANGE_HYSTERESIS[15:0]),
    .spo2_percent_x100(spo2_pending_data),
    .body_raw_q7(body_pending_data),
    .room_raw_q7(room_pending_data),
    .spo2_valid(spo2_pending),
    .spo2_new(1'b1),
    .spo2_good(1'b1),
    .body_valid(body_pending),
    .body_new(1'b1),
    .body_good(1'b1),
    .room_valid(room_pending),
    .room_new(1'b1),
    .room_good(1'b1),
    .hr_smooth_ready(hr_display_ready),
    .spo2_smooth_ready(spo2_display_ready),
    .body_smooth_ready(body_display_ready),
    .room_smooth_ready(room_display_ready),
    .hr_uart_frame_event(hr_frame),
    .hr_uart_raw_bpm(raw_hr_bpm),
    .hr_uart_format_error(hr_format),
    .hr_uart_timeout(hr_timeout),
    .hr_uart_encoding_error(hr_encoding),
    .hr_uart_overrun(hr_overrun),
    .body_ready(body_ready),.spo2_ready(spo2_ready),.room_ready(room_ready),
    .hr_smooth_bpm_x100(hr_filter_wire),
    .body_smooth_q7(body_filter_wire),.spo2_smooth_percent_x100(spo2_filter_wire),.room_smooth_q7(room_filter_wire),
    .hr_smooth_valid(hr_filter_valid),
    .body_smooth_valid(body_filter_valid),.spo2_smooth_valid(spo2_filter_valid),.room_smooth_valid(room_filter_valid),
    .feature_available(available),
    .device_isolated(isolated),
    .system_status(fpga_state),
    .assessment_valid(assessment_valid),
    .danger_active(danger_active),
    .fusion_valid(fusion_valid),
    .hr_sensor_fault_reason(hr_reason),
    .tmp_fault_reason(body_reason),.spo2_sensor_fault_reason(spo2_reason),.room_fault_reason(room_reason),
    .range_alarm(range_alarm),.range_config_error(range_config_error),
    .system_error(system_error),.buzzer_enable(health_buzzer),.fault_led_rgb(fault_rgb),
    .hr_sensor_pending_reason(hr_pending_reason),.spo2_sensor_pending_reason(spo2_pending_reason),
    .tmp_pending_reason(body_pending_reason),.room_pending_reason(room_pending_reason),
    .monitor_mode(monitor_mode),.fusion_score(fusion_score)
);


// 显示始终消费四路最终新值；串口屏掉线不会阻塞滤波与健康判断。
nextion_display #(.CLK_HZ(CLK_HZ)) u_display(
 .aclk(core_clk),.aresetn(rst_n),.tick_1ms(tick_1ms),
 .hr_smooth_bpm_x100(hr_filter_wire),.spo2_smooth_percent_x100(spo2_filter_wire),
 .body_smooth_q7(body_filter_wire),.room_smooth_q7(room_filter_wire),
 .hr_smooth_valid(hr_filter_valid),.spo2_smooth_valid(spo2_filter_valid),
 .body_smooth_valid(body_filter_valid),.room_smooth_valid(room_filter_valid),
 .hr_smooth_ready(hr_display_ready),.spo2_smooth_ready(spo2_display_ready),
 .body_smooth_ready(body_display_ready),.room_smooth_ready(room_display_ready),
 .feature_available(available),.device_isolated(isolated),.range_alarm(range_alarm),
 .range_config_error(range_config_error),.system_status(fpga_state),.system_error(system_error),
 .hr_sensor_fault_reason(hr_reason),.spo2_sensor_fault_reason(spo2_reason),
 .tmp_fault_reason(body_reason),.room_fault_reason(room_reason),
 .hr_sensor_pending_reason(hr_pending_reason),.spo2_sensor_pending_reason(spo2_pending_reason),
 .tmp_pending_reason(body_pending_reason),.room_pending_reason(room_pending_reason),
 .nextion_rx(nextion_rx),.nextion_tx(nextion_tx),
 .link_online(display_online),.communication_errors(display_errors));

// ARM片内接口V3：32个32位页，整组一次锁存；不占用屏幕或KPT串口。
wire [31:0] flags={6'd0,range_alarm,body_reason,hr_reason,rst_n,body_age<5000,
  (raw_hr_bpm!=0 && raw_hr_bpm<=655 && hr_age<3000),fusion_valid,danger_active,
  assessment_valid,fpga_state,isolated,available};
wire [31:0] words [0:31];
wire [1023:0] live_words;
assign words[0]=live_time_ms;
assign words[1]={raw_body,raw_hr_bpm};
assign words[2]={body_filtered,hr_filtered};
assign words[3]=hr_results; assign words[4]=body_results; assign words[5]=flags;
assign words[6]=hr_age; assign words[7]=body_age;
assign words[8]=hr_errors; assign words[9]=body_errors;
assign words[10]=32'h57595831; assign words[11]=32'd3;
assign words[12]={room_filtered,spo2_filtered};
assign words[13]=spo2_samples; assign words[14]=room_samples;
assign words[15]=spo2_age; assign words[16]=room_age;
assign words[17]=spo2_errors; assign words[18]=room_errors;
assign words[19]={18'd0,spo2_reject,room_reason,spo2_reason};
assign words[20]={raw_room,raw_body};
assign words[21]=hr_frames; assign words[22]=body_samples;
assign words[23]=room_raw_samples; assign words[24]=ppg_samples;
assign words[25]={14'd0,ppg_red}; assign words[26]={14'd0,ppg_ir};
assign words[27]=display_errors;
assign words[28]={10'd0,range_config_error,monitor_mode,7'd0,fifo_overflow,
  filter_fault,filter_settled,max_online,display_online};
assign words[29]={20'd0,room_pending_reason,body_pending_reason,spo2_pending_reason,hr_pending_reason};
assign words[30]={20'd0,room_reason,body_reason,spo2_reason,hr_reason};
assign words[31]={16'd0,room_last_error,body_last_error,max_last_error,fusion_score};
genvar p;
generate for(p=0;p<32;p=p+1) begin: g_snapshot
 assign live_words[p*32+:32]=words[p];
end endgenerate
wyx_snapshot_bridge u_snapshot(.clk(core_clk),.rst_n(rst_n),.ps_request(ps_out),
 .live_words(live_words),.ps_response(ps_in));
assign led={system_error,max_online,display_online,live_time_ms[9]};
assign {led4_r,led4_g,led4_b}=fault_rgb;
assign buzzer_out=health_buzzer;
endmodule
