`timescale 1ns/1ps
// 接现有核心的最终指标与可信度。四路顺序固定为心率、血氧、体温、室温。
// 快照只在串口空闲边界更换；每条暂存字段成功后才允许屏幕提交。
module nextion_display #(
    parameter integer CLK_HZ=100000000, // 实际aclk频率，赫兹
    parameter integer BAUD=115200, // 屏幕Program.s必须设置相同波特率
    parameter integer REFRESH_MS=1000, // 数值/心跳刷新间隔，毫秒
    parameter integer TREND_MS=1000, // 固定趋势采点间隔，毫秒
    parameter integer RESYNC_MS=1800, // 重同步前静默期，毫秒；大于应答超时
    parameter integer ACK_MS=1500 // 给屏幕绘制命令留出执行时间
)(
    input wire aclk,aresetn,tick_1ms,
    input wire [15:0] hr_smooth_bpm_x100,spo2_smooth_percent_x100,
    input wire signed [15:0] body_smooth_q7,room_smooth_q7,
    input wire hr_smooth_valid,spo2_smooth_valid,body_smooth_valid,room_smooth_valid,
    output wire hr_smooth_ready,spo2_smooth_ready,body_smooth_ready,room_smooth_ready,
    input wire [3:0] feature_available,device_isolated,range_alarm,range_config_error,
    input wire [1:0] system_status,input wire system_error,
    input wire [2:0] hr_sensor_fault_reason,spo2_sensor_fault_reason,tmp_fault_reason,room_fault_reason,
    input wire [2:0] hr_sensor_pending_reason,spo2_sensor_pending_reason,tmp_pending_reason,room_pending_reason,
    input wire nextion_rx,output wire nextion_tx,
    output reg link_online,output reg [31:0] communication_errors
);
    wire [15:0] incoming [0:3];
    assign incoming[0]=hr_smooth_bpm_x100;assign incoming[1]=spo2_smooth_percent_x100;
    assign incoming[2]=body_smooth_q7;assign incoming[3]=room_smooth_q7;
    wire [3:0] v={room_smooth_valid,body_smooth_valid,spo2_smooth_valid,hr_smooth_valid};
    assign {room_smooth_ready,body_smooth_ready,spo2_smooth_ready,hr_smooth_ready}={4{aresetn}};
    wire [3:0] allowed=feature_available & ~device_isolated;
    wire [11:0] faults={room_fault_reason,tmp_fault_reason,spo2_sensor_fault_reason,hr_sensor_fault_reason};
    wire [11:0] pending={room_pending_reason,tmp_pending_reason,spo2_sensor_pending_reason,hr_sensor_pending_reason};
    reg [15:0] latest [0:3];
    reg [3:0] have,window_new,previous_allowed;
    wire [3:0] usable=allowed & have;
    // 不重算健康状态。system_error只用于防御接口不一致的错误低报。
    wire [1:0] status=system_error ? 2'd3 : system_status;
    wire [41:0] safety={status,usable,device_isolated,range_alarm,range_config_error,faults,pending};
    reg [41:0] captured_safety;
    reg [15:0] trend_clock,refresh_clock,recovery_clock;
    reg [7:0] trend_y [0:3];
    reg [3:0] trend_pending,clear_pending;
    reg [31:0] trend_epoch,clear_epoch [0:3];
    reg [31:0] captured_trend_epoch,captured_clear_epoch [0:3];
    reg [31:0] fields [0:18];
    reg [15:0] sequence_id;
    reg [4:0] field_index;
    reg [3:0] phase;
    reg start;
    reg [255:0] command;
    reg [7:0] command_len;
    wire idle,done,failed,screen_reset;
    integer ch,k,pos,digit;
    reg [19:0] decimal_binary;
    reg [23:0] decimal_bcd;
    reg [23:0] decimal_adjusted;
    reg [4:0] decimal_steps;
    reg [16:0] rounded_hr,rounded_spo2;
    reg [6:0] hr_remainder;
    reg [3:0] spo2_remainder;
    reg [4:0] quotient_steps;
    wire [7:0] hr_trial={hr_remainder,rounded_hr[16]};
    wire [4:0] spo2_trial={spo2_remainder,rounded_spo2[16]};
    integer nibble;
    always @* begin
      decimal_adjusted=decimal_bcd;
      for(nibble=0;nibble<6;nibble=nibble+1)
        if(decimal_bcd[nibble*4+:4]>=5)
          decimal_adjusted[nibble*4+:4]=decimal_bcd[nibble*4+:4]+4'd3;
    end
    reg started;
    function automatic [31:0] magnitude_tenths(input [15:0] value);
        integer signed n;
        begin n=$signed(value);if(n<0)n=-n;magnitude_tenths=(n*10+64)/128;end
    endfunction
    function automatic [7:0] scale_y(input integer channel,input [15:0] value);
        integer signed n,lo,hi,level,lower_bound,upper_bound;
        begin
          case(channel)
            0:begin n=value;lo=4000;hi=18000;end
            1:begin n=value;lo=8000;hi=10000;end
            2:begin n=$signed(value);lo=4352;hi=5376;end
            default:begin n=$signed(value);lo=0;hi=6400;end
          endcase
          // 48个固定区间并行比较，等价于原来的四舍五入缩放。
          // 通道在展开循环时为常量，边界全部在综合期求值，无运行时乘除法。
          scale_y=0;
          for(level=1;level<=47;level=level+1) begin
            lower_bound=lo+(level*(hi-lo)-(hi-lo)/2+46)/47;
            upper_bound=lo+((level+1)*(hi-lo)-(hi-lo)/2+46)/47;
            if(n>=lower_bound && (level==47 || n<upper_bound))
              scale_y=scale_y | level;
          end
        end
    endfunction
    nextion_link #(
      .CLK_HZ(CLK_HZ), // 实际时钟，赫兹
      .BAUD(BAUD), // 串口波特率
      .ACK_MS(ACK_MS) // 单命令确认超时，毫秒
    ) u_link(.clk(aclk),.rst_n(aresetn),.tick_1ms(tick_1ms),.command(command),
      .length(command_len),.start(start),.idle(idle),.done(done),.failed(failed),
      .screen_reset(screen_reset),.tx(nextion_tx),.rx(nextion_rx));
    // 固定长度字节数组可综合；ASCII整数格式化只影响显示，不修改核心精度。
    always @* begin
      command=0;command_len=0;pos=0;digit=0;started=0;
      if(phase==1 || phase==2) begin
        // 下方按字节明确写入，避免字符串端序歧义。
        command=0;command[0+:8]="b";command[8+:8]="k";command[16+:8]="c";
        command[24+:8]="m";command[32+:8]="d";command[40+:8]="=";command[48+:8]="3";
        command_len=7;
      end else if(phase==3 || phase==4) begin
        command[0+:8]="p";command[8+:8]="a";command[16+:8]="g";
        command[24+:8]="e";command[32+:8]=" ";command[40+:8]="0";command_len=6;
      end else if(field_index==19) begin
        command[0+:8]="c";command[8+:8]="l";command[16+:8]="i";
        command[24+:8]="c";command[32+:8]="k";command[40+:8]=" ";
        command[48+:8]="m";command[56+:8]="0";command[64+:8]=",";
        command[72+:8]="0";command_len=10;
      end else begin
        command[0+:8]="s";command[8+:8]=8'd48+field_index/10;
        command[16+:8]=8'd48+field_index%10;command[24+:8]="=";pos=4;
        for(k=0;k<6;k=k+1) begin
          digit=decimal_bcd[(5-k)*4+:4];
          if(digit!=0 || started || k==5) begin
            command[pos*8+:8]=8'd48+digit;pos=pos+1;started=1;
          end
        end
        command_len=pos;
      end
    end
    always @(posedge aclk) begin
      if(!aresetn) begin
        have<=0;window_new<=0;previous_allowed<=0;trend_clock<=0;refresh_clock<=0;
        recovery_clock<=0;trend_pending<=0;clear_pending<=15;trend_epoch<=0;
        captured_trend_epoch<=0;captured_safety<=0;sequence_id<=0;
        field_index<=0;phase<=0;start<=0;link_online<=0;communication_errors<=0;
        decimal_binary<=0;decimal_bcd<=0;decimal_steps<=0;
        rounded_hr<=0;rounded_spo2<=0;
        hr_remainder<=0;spo2_remainder<=0;quotient_steps<=0;
        for(ch=0;ch<4;ch=ch+1) begin
          latest[ch]<=0;trend_y[ch]<=0;clear_epoch[ch]<=0;captured_clear_epoch[ch]<=0;
        end
        for(ch=0;ch<19;ch=ch+1) fields[ch]<=0;
      end else begin
        start<=0;previous_allowed<=allowed;
        if(tick_1ms) begin
          if(refresh_clock<REFRESH_MS)refresh_clock<=refresh_clock+1;
          if(trend_clock==TREND_MS-1) begin
            trend_clock<=0;trend_epoch<=trend_epoch+1;
            for(ch=0;ch<4;ch=ch+1) begin
              window_new[ch]<=0;
              if(allowed[ch] && (have[ch] || v[ch]) && (window_new[ch] || v[ch])) begin
                trend_y[ch]<=scale_y(ch,v[ch]?incoming[ch]:latest[ch]);trend_pending[ch]<=1;
                // 上一时间格还未交付：清图再绘，不能把遗漏时间压缩成连续线。
                if(trend_pending[ch]) begin clear_pending[ch]<=1;clear_epoch[ch]<=clear_epoch[ch]+1;end
              end else begin
                trend_pending[ch]<=0;clear_pending[ch]<=1;clear_epoch[ch]<=clear_epoch[ch]+1;
              end
            end
          end else trend_clock<=trend_clock+1;
        end
        for(ch=0;ch<4;ch=ch+1) begin
          if(!allowed[ch]) begin
            have[ch]<=0;window_new[ch]<=0;trend_pending[ch]<=0;clear_pending[ch]<=1;
            if(previous_allowed[ch])clear_epoch[ch]<=clear_epoch[ch]+1;
          end else if(v[ch]) begin
            latest[ch]<=incoming[ch];have[ch]<=1;
            if(!(tick_1ms && trend_clock==TREND_MS-1))window_new[ch]<=1;
          end
        end
        case(phase)
          0: if(tick_1ms) begin
            if(recovery_clock>=RESYNC_MS-1)begin recovery_clock<=0;phase<=1;end
            else recovery_clock<=recovery_clock+1;
          end
          1: if(idle)begin start<=1;phase<=2;end
          2: if(done)phase<=3;
          3: if(idle)begin start<=1;phase<=4;end
          4: if(done)begin phase<=5;clear_pending<=15;end
          5: begin
            captured_safety<=safety;sequence_id<=sequence_id+1;
            captured_trend_epoch<=trend_epoch;
            for(ch=0;ch<4;ch=ch+1)captured_clear_epoch[ch]<=clear_epoch[ch];
            fields[0]<=status;fields[1]<=usable;fields[2]<=device_isolated;
            fields[3]<=range_alarm & usable & ~range_config_error;fields[4]<=range_config_error;
            fields[5]<=faults;fields[6]<=pending;
            rounded_hr<={1'b0,latest[0]}+17'd50;
            rounded_spo2<={1'b0,latest[1]}+17'd5;
            fields[9]<=magnitude_tenths(latest[2]);fields[10]<=magnitude_tenths(latest[3]);
            fields[11]<={28'd0,(latest[3][15] && magnitude_tenths(latest[3])!=0),
                         (latest[2][15] && magnitude_tenths(latest[2])!=0),2'b00};
            fields[12]<=trend_pending & usable;fields[13]<={28'd0,(clear_pending | ~usable)};
            fields[14]<=trend_y[0];fields[15]<=trend_y[1];fields[16]<=trend_y[2];fields[17]<=trend_y[3];
            fields[18]<=sequence_id;
            field_index<=0;phase<=11;refresh_clock<=0;
          end
          11: begin
            hr_remainder<=0;spo2_remainder<=0;quotient_steps<=0;phase<=12;
          end
          // 两路定除数恢复除法，每拍一个二进制位，不占用长组合路径。
          12: begin
            hr_remainder<=hr_trial>=100 ? hr_trial-8'd100 : hr_trial;
            spo2_remainder<=spo2_trial>=10 ? spo2_trial-5'd10 : spo2_trial;
            rounded_hr<={rounded_hr[15:0],(hr_trial>=100)};
            rounded_spo2<={rounded_spo2[15:0],(spo2_trial>=10)};
            if(quotient_steps==16)begin
              fields[7]<={15'd0,rounded_hr[15:0],(hr_trial>=100)};
              fields[8]<={15'd0,rounded_spo2[15:0],(spo2_trial>=10)};
              phase<=6;
            end else quotient_steps<=quotient_steps+1;
          end
          6: if(safety!=captured_safety)phase<=5;
             else if(field_index==19)begin if(idle)begin start<=1;phase<=7;end end
             else begin
               decimal_binary<=fields[field_index][19:0];decimal_bcd<=0;
               decimal_steps<=0;phase<=9;
             end
          // 每拍只做六个小位宽加三运算，避免单拍串联十进制除法。
          9: begin
            decimal_bcd<={decimal_adjusted[22:0],decimal_binary[19]};
            decimal_binary<={decimal_binary[18:0],1'b0};
            if(decimal_steps==19)phase<=10;
            else decimal_steps<=decimal_steps+1;
          end
          10: if(safety!=captured_safety)phase<=5;
              else if(idle)begin start<=1;phase<=7;end
          7: if(done)begin
            if(safety!=captured_safety)phase<=5;
            else if(field_index==19)begin
              link_online<=1;phase<=8;
              if(trend_epoch==captured_trend_epoch && !(tick_1ms && trend_clock==TREND_MS-1))
                trend_pending<=0;
              for(ch=0;ch<4;ch=ch+1)
                if(clear_epoch[ch]==captured_clear_epoch[ch] && allowed[ch] &&
                   !(tick_1ms && trend_clock==TREND_MS-1))clear_pending[ch]<=0;
            end else begin field_index<=field_index+1;phase<=6;end
          end
          8: if(refresh_clock>=REFRESH_MS || safety!=captured_safety)phase<=5;
          default:phase<=0;
        endcase
        if(failed || (screen_reset && phase>=5)) begin
          phase<=0;recovery_clock<=0;link_online<=0;
          if(failed)communication_errors<=communication_errors+1;
          clear_pending<=15;
          for(ch=0;ch<4;ch=ch+1)clear_epoch[ch]<=clear_epoch[ch]+1;
        end
      end
    end
    // synthesis translate_off
    initial if(REFRESH_MS<1 || TREND_MS<1 || RESYNC_MS<=ACK_MS)
      $fatal(1,"Invalid timing configuration");
    // synthesis translate_on
endmodule
