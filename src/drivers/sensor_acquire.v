// 来源：用户NoILA正式包。本次仅另增一拍FIFO溢出通知，保留原采样事务和历史标志语义。
`timescale 1ns/1ps
// B2/B3: MAX30102 100sps SpO2-mode sampling + independent TMP117 x2.
// Uses a SINGLE I2C master: 0x57, 0x48 (room), 0x49 (skin).
// event_payload: PPG={4'h0,RED18,IR18}; TMP117={24'b0,signed_temp16}.
// event_flags[0]=good, [1]=I2C/data error, [2]=MAX FIFO overflow, [3]=reserved.
// All event_* and raw_valid are ONE-cycle strobe, not held data-quality flags.
module sensor_acquire #(
    parameter integer CLK_HZ=125000000, // 输入时钟频率，单位赫兹
    parameter integer I2C_HZ=100000, // I2C总线时钟，单位赫兹
    parameter integer PPG_HZ=100, // MAX红光红外读取调度频率，次每秒
    parameter integer TEMP_HZ=1, // TMP117读取调度频率，次每秒
    parameter integer ENABLE_PART_ID_CHECK=1 // MAX器件身份检查开关，1启用
) (
    input wire clk,
    input wire rst_n,
    inout wire i2c_scl,
    inout wire i2c_sda,
    output reg event_valid,
    output reg [3:0] event_channel,  // 1=RED+IR; 2=room; 3=skin
    output reg [3:0] event_flags,
    output reg [39:0] event_payload,
    output reg ppg_raw_valid,
    output reg [17:0] ppg_red,
    output reg [17:0] ppg_ir,
    output reg room_raw_valid,
    output reg signed [15:0] room_raw,
    output reg body_raw_valid,
    output reg signed [15:0] body_raw,
    output reg room_fault_pulse,
    output reg body_fault_pulse,
    output reg max_fault_pulse,
    output reg max_online,
    output reg fifo_overflow_sticky,
    output reg fifo_overflow_event, // 新发现FIFO计数溢出时仅脉冲一拍，不能用历史sticky位代替
    output reg [2:0] last_i2c_error,
    output wire debug_done,debug_read,debug_error,
    output wire [6:0] debug_addr,
    output wire [7:0] debug_reg,
    output wire [2:0] debug_code,debug_rlen,
    output wire [47:0] debug_response
);
    localparam integer BOOT_CYCLES = (CLK_HZ/10<1) ? 1 : CLK_HZ/10; // 上电等待时长，时钟周期
    localparam integer RESET_CYCLES = (CLK_HZ/100<1) ? 1 : CLK_HZ/100; // MAX软复位等待时长，时钟周期
    localparam integer RETRY_CYCLES = (CLK_HZ<1) ? 1 : CLK_HZ; // MAX重新初始化间隔，时钟周期
    localparam integer PPG_CYCLES = (CLK_HZ/PPG_HZ<1) ? 1 : CLK_HZ/PPG_HZ; // MAX读取调度间隔，时钟周期
    localparam integer TEMP_CYCLES = (CLK_HZ/TEMP_HZ<1) ? 1 : CLK_HZ/TEMP_HZ; // TMP读取调度间隔，时钟周期
    localparam [2:0] S_BOOT=0, S_PICK=1, S_ISSUE=2, // 控制状态或任务编号常量；数值仅用于状态机编码
                     S_WAIT=3, S_RESET_WAIT=4, S_RETRY=5;
    localparam [3:0] J_INIT=0, J_WR=1, J_RD=2, J_OV=3, // 控制状态或任务编号常量；数值仅用于状态机编码
                     J_FIFO=4, J_CLR_OV=5, J_ROOM=6, J_BODY=7;
    reg [2:0] state;
    reg [3:0] job;
    reg [3:0] init_step;
    reg initialized;
    reg [31:0] wait_timer;
    reg [31:0] ppg_timer, temp_timer;
    reg ppg_due, temp_due;
    reg [4:0] fifo_wrptr, fifo_rdptr;
    reg [5:0] drained_count;

    reg cmd_start;
    wire cmd_busy, cmd_done, cmd_error;
    wire [2:0] cmd_error_code;
    wire [47:0] rx_data;
    reg [6:0] cmd_addr;
    reg [7:0] cmd_reg, cmd_wdata;
    reg cmd_read;
    reg [2:0] cmd_rlen;

    i2c_reg_master #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ), // 命名参数/原语连接：时钟与采样频率单位赫兹，INIT为上游XADC寄存器原值
                      .STRETCH_TIMEOUT_CLKS(CLK_HZ/1000)) u_i2c ( // 命名参数/原语连接：时钟与采样频率单位赫兹，INIT为上游XADC寄存器原值
        .clk(clk),.rst_n(rst_n),.scl(i2c_scl),.sda(i2c_sda),
        .cmd_start(cmd_start),.cmd_addr(cmd_addr),.cmd_reg(cmd_reg),
        .cmd_read(cmd_read),.cmd_wdata(cmd_wdata),.cmd_rlen(cmd_rlen),
        .rd_data(rx_data),.busy(cmd_busy),.done(cmd_done),
        .error(cmd_error),.error_code(cmd_error_code)
    );

    // Register setup table for MAX30102 (100 Hz, red+IR, 18-bit ADC).
    // Init sequence: part-id -> reset -> wait -> disable IRQs -> FIFO pointers
    // -> FIFO config -> SpO2 config -> LED currents -> mode=SpO2.
    always @* begin
        cmd_addr = 7'h57;
        cmd_reg = 8'h00;
        cmd_wdata = 8'h00;
        cmd_read = 1'b1;
        cmd_rlen = 3'd1;
        case (job)
            J_INIT: begin
                case (init_step)
                    0: begin cmd_reg=8'hFF; cmd_read=1; cmd_rlen=1; end
                    1: begin cmd_reg=8'h09; cmd_read=0; cmd_wdata=8'h40; end
                    2: begin cmd_reg=8'h02; cmd_read=0; cmd_wdata=8'h00; end
                    3: begin cmd_reg=8'h03; cmd_read=0; cmd_wdata=8'h00; end
                    4: begin cmd_reg=8'h04; cmd_read=0; cmd_wdata=8'h00; end
                    5: begin cmd_reg=8'h05; cmd_read=0; cmd_wdata=8'h00; end
                    6: begin cmd_reg=8'h06; cmd_read=0; cmd_wdata=8'h00; end
                    7: begin cmd_reg=8'h08; cmd_read=0; cmd_wdata=8'h0F; end
                    8: begin cmd_reg=8'h0A; cmd_read=0; cmd_wdata=8'h27; end
                    9: begin cmd_reg=8'h0C; cmd_read=0; cmd_wdata=8'h24; end
                   10: begin cmd_reg=8'h0D; cmd_read=0; cmd_wdata=8'h24; end
                   11: begin cmd_reg=8'h09; cmd_read=0; cmd_wdata=8'h03; end
                   default: begin cmd_reg=8'hFF; cmd_read=1; end
                endcase
            end
            J_WR: begin cmd_reg=8'h04; end
            J_RD: begin cmd_reg=8'h06; end
            J_OV: begin cmd_reg=8'h05; end
            J_FIFO: begin cmd_reg=8'h07; cmd_rlen=6; end
            J_CLR_OV: begin cmd_reg=8'h05;cmd_read=0;cmd_wdata=0;end
            J_ROOM: begin cmd_addr=7'h48;cmd_reg=0;cmd_rlen=2;end
            J_BODY: begin cmd_addr=7'h49;cmd_reg=0;cmd_rlen=2;end
            default: begin end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_BOOT;
            job <= J_INIT;
            init_step <= 0;
            initialized <= 0;
            max_online <= 0;
            fifo_overflow_sticky <= 0;
            fifo_overflow_event <= 0;
            wait_timer <= 0;
            ppg_timer <= 0;
            temp_timer <= 0;
            ppg_due <= 0;
            temp_due <= 0;
            fifo_wrptr <= 0;
            fifo_rdptr <= 0;
            drained_count <= 0;
            cmd_start <= 0;
            fifo_overflow_event <= 0;
            event_valid <= 0;
            event_channel <= 0;
            event_flags <= 0;
            event_payload <= 0;
            ppg_raw_valid <= 0;
            ppg_red <= 0;
            ppg_ir <= 0;
            room_raw_valid <= 0;
            room_raw <= 0;
            body_raw_valid <= 0;
            body_raw <= 0;
            room_fault_pulse <= 0;
            body_fault_pulse <= 0;
            max_fault_pulse <= 0;
            last_i2c_error <= 0;
        end else begin
            cmd_start <= 0;
            fifo_overflow_event <= 0;
            event_valid <= 0;
            ppg_raw_valid <= 0;
            room_raw_valid <= 0;
            body_raw_valid <= 0;
            max_fault_pulse <= 0;
            room_fault_pulse <= 0;
            body_fault_pulse <= 0;
            if (ppg_timer >= PPG_CYCLES-1) begin
                ppg_timer <= 0; ppg_due <= 1;
            end else ppg_timer <= ppg_timer+1'b1;
            if (temp_timer >= TEMP_CYCLES-1) begin
                temp_timer <= 0; temp_due <= 1;
            end else temp_timer <= temp_timer+1'b1;
            case (state)
                S_BOOT: begin
                    if (wait_timer >= BOOT_CYCLES-1) begin
                        wait_timer <= 0;
                        state <= S_PICK;
                    end else wait_timer <= wait_timer+1'b1;
                end
                S_PICK: begin
                    if (!initialized) begin
                        init_step <= 0;
                        job <= J_INIT;
                        state <= S_ISSUE;
                    end else if (ppg_due) begin
                        job <= J_WR;
                        drained_count <= 0;
                        state <= S_ISSUE;
                    end else if (temp_due) begin
                        job <= J_ROOM;
                        state <= S_ISSUE;
                    end
                end
                S_ISSUE: begin
                    if (!cmd_busy) begin
                        cmd_start <= 1;
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (cmd_done) begin
                        if (cmd_error) begin
                            last_i2c_error <= cmd_error_code;
                            event_valid <= 1;
                            event_payload <= 0;
                            event_flags <= 4'b0010;
                            case (job)
                                J_ROOM: begin
                                    event_channel <= 2;
                                    room_fault_pulse <= 1;
                                    job <= J_BODY;
                                    state <= S_ISSUE;
                                end
                                J_BODY: begin
                                    event_channel <= 3;
                                    body_fault_pulse <= 1;
                                    temp_due <= 0;
                                    state <= initialized ? S_PICK : S_RETRY;
                                end
                                default: begin
                                    event_channel <= 1;
                                    max_fault_pulse <= 1;
                                    initialized <= 0;
                                    max_online <= 0;
                                    ppg_due <= 0;
                                    wait_timer <= 0;
                                    state <= S_RETRY;
                                end
                            endcase
                        end else begin
                            case (job)
                                J_INIT: begin
                                    if (init_step == 0 && ENABLE_PART_ID_CHECK &&
                                        rx_data[7:0] != 8'h15) begin
                                        initialized <= 0;
                                        max_online <= 0;
                                        max_fault_pulse <= 1;
                                        last_i2c_error <= 3'd5;
                                        event_valid <= 1;
                                        event_channel <= 1;
                                        event_payload <= {32'd0,rx_data[7:0]};
                                        event_flags <= 4'b0010;
                                        wait_timer <= 0;
                                        state <= S_RETRY;
                                    end else if (init_step == 1) begin
                                        init_step <= 2;
                                        wait_timer <= 0;
                                        state <= S_RESET_WAIT;
                                    end else if (init_step == 11) begin
                                        initialized <= 1;
                                        max_online <= 1;
                                        last_i2c_error <= 0;
                                        ppg_due <= 1;
                                        state <= S_PICK;
                                    end else begin
                                        init_step <= init_step+1'b1;
                                        state <= S_ISSUE;
                                    end
                                end
                                J_WR: begin
                                    fifo_wrptr <= rx_data[4:0];
                                    job <= J_RD;
                                    state <= S_ISSUE;
                                end
                                J_RD: begin
                                    fifo_rdptr <= rx_data[4:0];
                                    job <= J_OV;
                                    state <= S_ISSUE;
                                end
                                J_OV: begin
                                    if (rx_data[7:0] != 0) begin
                                        fifo_overflow_sticky <= 1;
                                        fifo_overflow_event <= 1;
                                        job <= J_CLR_OV;
                                    end else if (fifo_rdptr != fifo_wrptr) begin
                                        job <= J_FIFO;
                                    end else begin
                                        ppg_due <= 0;
                                        // This event loop yields to temperature acquisitions.
                                        job <= J_ROOM;
                                    end
                                    if (rx_data[7:0] == 0 && fifo_rdptr == fifo_wrptr)
                                        state <= S_PICK;
                                    else state <= S_ISSUE;
                                end
                                J_CLR_OV: begin
                                    if (fifo_rdptr != fifo_wrptr) begin
                                        job <= J_FIFO;
                                        state <= S_ISSUE;
                                    end else begin
                                        ppg_due <= 0;
                                        state <= S_PICK;
                                    end
                                end
                                J_FIFO: begin
                                    ppg_red <= rx_data[41:24];
                                    ppg_ir <= rx_data[17:0];
                                    ppg_raw_valid <= 1;
                                    event_valid <= 1;
                                    event_channel <= 1;
                                    event_flags <= {1'b0,fifo_overflow_sticky,1'b0,1'b1};
                                    event_payload <= {4'b0,rx_data[41:24],rx_data[17:0]};
                                    fifo_rdptr <= fifo_rdptr+1'b1;
                                    drained_count <= drained_count+1'b1;
                                    if ((fifo_rdptr+5'd1 != fifo_wrptr) &&
                                         (drained_count < 6'd31)) begin
                                        job <= J_FIFO;
                                        state <= S_ISSUE;
                                    end else begin
                                        ppg_due <= 0;
                                        state <= S_PICK;
                                    end
                                end
                                J_ROOM: begin
                                    event_valid <= 1;
                                    event_channel <= 2;
                                    event_payload <= {24'd0,rx_data[15:0]};
                                    event_flags <= (rx_data[15:0] == 16'h8000)
                                                    ? 4'b0010 : 4'b0001;
                                    if (rx_data[15:0] != 16'h8000) begin
                                        room_raw <= rx_data[15:0];
                                        room_raw_valid <= 1;
                                    end else room_fault_pulse <= 1;
                                    job <= J_BODY;
                                    state <= S_ISSUE;
                                end
                                J_BODY: begin
                                    event_valid <= 1;
                                    event_channel <= 3;
                                    event_payload <= {24'd0,rx_data[15:0]};
                                    event_flags <= (rx_data[15:0] == 16'h8000)
                                                    ? 4'b0010 : 4'b0001;
                                    if (rx_data[15:0] != 16'h8000) begin
                                        body_raw <= rx_data[15:0];
                                        body_raw_valid <= 1;
                                    end else body_fault_pulse <= 1;
                                    temp_due <= 0;
                                    state <= initialized ? S_PICK : S_RETRY;
                                end
                                default: state <= S_PICK;
                            endcase
                        end
                    end
                end
                S_RESET_WAIT: begin
                    if (wait_timer >= RESET_CYCLES-1) begin
                        wait_timer <= 0;
                        job <= J_INIT;
                        state <= S_ISSUE;
                    end else wait_timer <= wait_timer+1'b1;
                end
                S_RETRY: begin
                    // Keep servicing both TMP117 devices while MAX is absent.
                    if (temp_due) begin
                        job <= J_ROOM;
                        state <= S_ISSUE;
                    end else if (wait_timer >= RETRY_CYCLES-1) begin
                        wait_timer <= 0;
                        state <= S_PICK;
                    end else wait_timer <= wait_timer+1'b1;
                end
                default: state <= S_BOOT;
            endcase
        end
    end
// 只读镜像已有事务信号，用于板上诊断；不改变采集状态机。
    assign debug_done=cmd_done;
    assign debug_read=cmd_read;
    assign debug_error=cmd_error;
    assign debug_addr=cmd_addr;
    assign debug_reg=cmd_reg;
    assign debug_code=cmd_error_code;
    assign debug_rlen=cmd_rlen;
    assign debug_response=rx_data;
endmodule
