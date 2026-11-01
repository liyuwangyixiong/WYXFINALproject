// 来源：用户NoILA正式包；2026-10-25根据实测SDA卡低加入有限9时钟+STOP恢复。
// 正常读写接口、字节顺序及错误码保持；恢复失败仍报告错误，不制造成功数据。
`timescale 1ns/1ps
// B1: Register-oriented, single-controller I2C master, open-drain SDA/SCL.
// One-byte register write, or register-address write + repeated START + 1..6 byte read.
// rd_data contains sequential received bytes in the LOW bits (read 2 => [15:8], [7:0]).
// cmd_start must pulse for one clk while !busy. done pulses once on completion.
// error_code: 0=OK, 1=NACK, 2=SCL held low (timeout), 3=bus SDA stuck,
//             4=bad read length. Master releases the bus even on timeout.
// Electrical: add external 3.3V pullups; never drive I2C lines high.
module i2c_reg_master #(
    parameter integer CLK_HZ = 125000000, // 输入时钟频率，单位赫兹
    parameter integer I2C_HZ = 100000, // I2C总线时钟，单位赫兹
    parameter integer STRETCH_TIMEOUT_CLKS = 125000 // SCL拉低等待超时，单位时钟周期
) (
    input  wire clk,
    input  wire rst_n,
    inout  wire scl,
    inout  wire sda,
    input  wire cmd_start,
    input  wire [6:0] cmd_addr,
    input  wire [7:0] cmd_reg,
    input  wire cmd_read,
    input  wire [7:0] cmd_wdata,
    input  wire [2:0] cmd_rlen,
    output reg  [47:0] rd_data,
    output reg  busy,
    output reg  done,
    output reg  error,
    output reg  [2:0] error_code
);
    localparam integer DIV_RAW = CLK_HZ/(I2C_HZ*4); // 总线或串口的原始分频周期数
    localparam integer DIVIDER = (DIV_RAW < 2) ? 2 : DIV_RAW; // I2C四相分频，最少两个时钟周期
    localparam integer DIV_WIDTH = $clog2(DIVIDER+1); // I2C分频计数器位宽，位
    localparam integer TO_WIDTH = $clog2(STRETCH_TIMEOUT_CLKS+2); // I2C拉低超时计数器位宽，位

    localparam [3:0] IDLE=0, START=1, SEND=2, GET_ACK=3, // 控制状态或任务编号常量；数值仅用于状态机编码
                     RESTART=4, RECEIVE=5, SEND_ACK=6, STOP=7, // 正常寄存器读写时序状态编码
                     BUS_CLEAR=8, BUS_CLEAR_STOP=9; // SDA卡低时的最多9时钟恢复及STOP状态
    reg [3:0] state;
    reg [1:0] phase;
    reg [DIV_WIDTH-1:0] divider;
    reg [TO_WIDTH-1:0] stretch_counter;
    reg scl_pull_low, sda_pull_low;
    // kind: 0=address+write,1=register,2=data,3=address+read
    reg [1:0] kind;
    reg [7:0] send_byte, recv_byte;
    reg [2:0] bit_index, byte_index;
    reg ack_bad;
    reg [3:0] recovery_pulses;
    reg recovery_used, recovery_sda_free;
    reg [6:0] address_latched;
    reg [7:0] register_latched, data_latched;
    reg read_latched;
    reg [2:0] length_latched;
    wire scl_i = scl;
    wire sda_i = sda;
    assign scl = scl_pull_low ? 1'b0 : 1'bz;
    assign sda = sda_pull_low ? 1'b0 : 1'bz;

    wire needs_scl_high =
        ((state == START) && (phase == 2'd0)) ||
        ((state == RESTART || state == SEND || state == GET_ACK ||
          state == RECEIVE || state == SEND_ACK || state == STOP ||
          state == BUS_CLEAR || state == BUS_CLEAR_STOP) &&
         (phase == 2'd2));

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            phase <= 0;
            divider <= 0;
            stretch_counter <= 0;
            scl_pull_low <= 0;
            sda_pull_low <= 0;
            busy <= 0;
            done <= 0;
            error <= 0;
            error_code <= 0;
            rd_data <= 0;
            kind <= 0;
            send_byte <= 0;
            recv_byte <= 0;
            bit_index <= 0;
            byte_index <= 0;
            ack_bad <= 0;
            recovery_pulses <= 0;
            recovery_used <= 0;
            recovery_sda_free <= 0;
            address_latched <= 0;
            register_latched <= 0;
            data_latched <= 0;
            read_latched <= 0;
            length_latched <= 0;
        end else begin
            done <= 0;
            if (state == IDLE) begin
                scl_pull_low <= 0;
                sda_pull_low <= 0;
                divider <= 0;
                stretch_counter <= 0;
                if (cmd_start) begin
                    if (cmd_read && (cmd_rlen == 0 || cmd_rlen > 6)) begin
                        done <= 1;
                        error <= 1;
                        error_code <= 3'd4;
                        busy <= 0;
                    end else begin
                        busy <= 1;
                        error <= 0;
                        error_code <= 0;
                        rd_data <= 0;
                        address_latched <= cmd_addr;
                        register_latched <= cmd_reg;
                        data_latched <= cmd_wdata;
                        read_latched <= cmd_read;
                        length_latched <= cmd_rlen;
                        byte_index <= 0;
                        recovery_pulses <= 0;
                        recovery_used <= 0;
                        recovery_sda_free <= 0;
                        phase <= 0;
                        state <= START;
                    end
                end
            end else if (needs_scl_high && scl_i !== 1'b1) begin
                // Clock-stretching or stuck-low SCL; timeout releases the bus.
                if (stretch_counter >= STRETCH_TIMEOUT_CLKS) begin
                    state <= IDLE;
                    scl_pull_low <= 0;
                    sda_pull_low <= 0;
                    busy <= 0;
                    done <= 1;
                    error <= 1;
                    error_code <= 3'd2;
                    stretch_counter <= 0;
                end else begin
                    stretch_counter <= stretch_counter + 1'b1;
                end
            end else begin
                stretch_counter <= 0;
                if (divider == DIVIDER-1) begin
                    divider <= 0;
                    case (state)
                        START: begin
                            case (phase)
                                0: begin
                                    // Idle bus must have released SDA.
                                    if (sda_i !== 1'b1) begin
                                        if (!recovery_used) begin
                                            // NXP UM10204 3.1.16：中断的从机可能仍在发送0。
                                            // 只释放SDA并用开漏SCL产生最多9个时钟，绝不推挽拉高。
                                            recovery_used <= 1;
                                            recovery_pulses <= 0;
                                            recovery_sda_free <= 0;
                                            scl_pull_low <= 1;
                                            sda_pull_low <= 0;
                                            state <= BUS_CLEAR;
                                            phase <= 0;
                                        end else begin
                                            error <= 1;
                                            error_code <= 3'd3;
                                            state <= IDLE;
                                            busy <= 0;
                                            done <= 1;
                                        end
                                    end else phase <= 1;
                                end
                                1: begin sda_pull_low <= 1; phase <= 2; end
                                2: begin scl_pull_low <= 1; phase <= 3; end
                                3: begin
                                    send_byte <= {address_latched,1'b0};
                                    kind <= 0;
                                    bit_index <= 7;
                                    phase <= 0;
                                    state <= SEND;
                                end
                            endcase
                        end
                        SEND: begin
                            case (phase)
                                0: begin
                                    scl_pull_low <= 1;
                                    sda_pull_low <= ~send_byte[bit_index];
                                    phase <= 1;
                                end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: phase <= 3;
                                3: begin
                                    scl_pull_low <= 1;
                                    phase <= 0;
                                    if (bit_index == 0) begin
                                        state <= GET_ACK;
                                        ack_bad <= 0;
                                    end else bit_index <= bit_index - 1'b1;
                                end
                            endcase
                        end
                        GET_ACK: begin
                            case (phase)
                                0: begin sda_pull_low <= 0; phase <= 1; end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin
                                    ack_bad <= (sda_i !== 1'b0);
                                    phase <= 3;
                                end
                                3: begin
                                    scl_pull_low <= 1;
                                    phase <= 0;
                                    bit_index <= 7;
                                    if (ack_bad) begin
                                        error <= 1;
                                        error_code <= 3'd1;
                                        state <= STOP;
                                    end else case (kind)
                                        0: begin
                                            kind <= 1;
                                            send_byte <= register_latched;
                                            state <= SEND;
                                        end
                                        1: begin
                                            if (read_latched) begin
                                                state <= RESTART;
                                            end else begin
                                                kind <= 2;
                                                send_byte <= data_latched;
                                                state <= SEND;
                                            end
                                        end
                                        2: state <= STOP;
                                        3: begin
                                            recv_byte <= 0;
                                            state <= RECEIVE;
                                        end
                                    endcase
                                end
                            endcase
                        end
                        RESTART: begin
                            case (phase)
                                0: begin
                                    scl_pull_low <= 1;
                                    sda_pull_low <= 0;
                                    phase <= 1;
                                end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin sda_pull_low <= 1; phase <= 3; end
                                3: begin
                                    scl_pull_low <= 1;
                                    send_byte <= {address_latched,1'b1};
                                    kind <= 3;
                                    bit_index <= 7;
                                    phase <= 0;
                                    state <= SEND;
                                end
                            endcase
                        end
                        RECEIVE: begin
                            case (phase)
                                0: begin
                                    scl_pull_low <= 1;
                                    sda_pull_low <= 0;
                                    phase <= 1;
                                end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin
                                    recv_byte[bit_index] <= sda_i;
                                    phase <= 3;
                                end
                                3: begin
                                    scl_pull_low <= 1;
                                    phase <= 0;
                                    if (bit_index == 0) begin
                                        rd_data <= {rd_data[39:0],recv_byte};
                                        state <= SEND_ACK;
                                    end else bit_index <= bit_index - 1'b1;
                                end
                            endcase
                        end
                        SEND_ACK: begin
                            case (phase)
                                0: begin
                                    // ACK all but final byte; NACK final byte.
                                    sda_pull_low <= (byte_index != length_latched-1'b1);
                                    phase <= 1;
                                end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: phase <= 3;
                                3: begin
                                    scl_pull_low <= 1;
                                    sda_pull_low <= 0;
                                    phase <= 0;
                                    if (byte_index == length_latched-1'b1) begin
                                        state <= STOP;
                                    end else begin
                                        byte_index <= byte_index + 1'b1;
                                        recv_byte <= 0;
                                        bit_index <= 7;
                                        state <= RECEIVE;
                                    end
                                end
                            endcase
                        end
                        BUS_CLEAR: begin
                            case (phase)
                                0: begin scl_pull_low <= 1; sda_pull_low <= 0; phase <= 1; end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin recovery_sda_free <= (sda_i === 1'b1); phase <= 3; end
                                3: begin
                                    scl_pull_low <= 1;
                                    phase <= 0;
                                    if (recovery_sda_free) state <= BUS_CLEAR_STOP;
                                    else if (recovery_pulses == 8) begin
                                        // 9个脉冲后仍卡低，保留真实错误，有限退出而非无限重试。
                                        scl_pull_low <= 0;
                                        sda_pull_low <= 0;
                                        state <= IDLE;
                                        busy <= 0;
                                        done <= 1;
                                        error <= 1;
                                        error_code <= 3'd3;
                                    end else recovery_pulses <= recovery_pulses + 1'b1;
                                end
                            endcase
                        end
                        BUS_CLEAR_STOP: begin
                            case (phase)
                                0: begin scl_pull_low <= 1; sda_pull_low <= 1; phase <= 1; end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin sda_pull_low <= 0; phase <= 3; end
                                3: begin phase <= 0; state <= START; end
                            endcase
                        end
                        STOP: begin
                            case (phase)
                                0: begin
                                    scl_pull_low <= 1;
                                    sda_pull_low <= 1;
                                    phase <= 1;
                                end
                                1: begin scl_pull_low <= 0; phase <= 2; end
                                2: begin sda_pull_low <= 0; phase <= 3; end
                                3: begin
                                    state <= IDLE;
                                    busy <= 0;
                                    done <= 1;
                                    phase <= 0;
                                end
                            endcase
                        end
                        default: state <= IDLE;
                    endcase
                end else divider <= divider + 1'b1;
            end
        end
    end
endmodule
