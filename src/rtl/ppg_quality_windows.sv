`timescale 1ns/1ps
// ============================================================================
// 【文件作用】将一个 MAX 的逐样本质量标志统计成“不重叠的质量窗口”。
// 顶层有两个实例：心率新样本一套、血氧完整 RED/IR 对一套，不能共用统计状态。
// 【不是检测器】此处不计算尖峰/畸变，也不替换数值；上游提供 replaced/distorted。
// WINDOW_SAMPLES=一窗新样本数；SPIKE_LIMIT/DISTORTION_LIMIT=坏窗计数门限。
// 默认100个样本一窗，替换>=10次或畸变>=20次就报告坏窗。
// window_event=窗结束后一拍有效脉冲；window_bad 仅在该事件中有“新报告”意义。
// 一坏窗不直接确认器件损坏，后面的 sensor_fault_monitor 再做连续窗口确认。
// ============================================================================
// NON-overlapping windows of distinct processed RED/IR pairs.
// replaced means this ONE pair was replaced, not the old 33-tap OR flag.
// distorted is a per-pair quality indication supplied by the waveform stage.
module ppg_quality_windows #(
    parameter integer WINDOW_SAMPLES = 100, // 一个质量窗中的真实新样本或完整红光/红外配对数
    parameter integer SPIKE_LIMIT = 10,     // 一窗内尖峰替换次数达到此值，即判该窗质量差
    parameter integer DISTORTION_LIMIT = 20 // 一窗内畸变次数达到此值，即判该窗质量差
) (
    input wire aclk, aresetn,
    input wire sample_event, spike_replaced, distorted,
    output reg window_event,
    output reg window_bad
);
    localparam integer CW = $clog2(WINDOW_SAMPLES + 1); // 窗内样本、替换和畸变计数器位宽
    // 【01：三个计数器】samples 只数真实 sample_event；其余两项数该窗异常次数。
    // 没有新样本时全部保持，绝不把 FPGA 的每个时钟周期当一次传感器采样。
    reg [CW-1:0] samples, spikes, distortions;
    always @(posedge aclk) begin
        if (!aresetn) begin
            samples <= 0; spikes <= 0; distortions <= 0;
            window_event <= 0; window_bad <= 0;
        end else begin
            window_event <= 0;
            if (sample_event) begin
                if (samples == WINDOW_SAMPLES-1) begin
                    // 【02：窗口结束】门限判断必须包含本次最后一个样本的异常标志。
                    // 用完即清三个计数器，下一次新样本属于下一窗，没有窗口重叠。
                    window_event <= 1;
                    window_bad <= ((spikes + {1'b0, spike_replaced}) >= SPIKE_LIMIT) ||
                                  ((distortions + {1'b0, distorted}) >= DISTORTION_LIMIT);
                    samples <= 0; spikes <= 0; distortions <= 0;
                end else begin
                    // 【03：窗口中途】只累计，不提前生成窗口结果。
                    samples <= samples + 1'b1;
                    spikes <= spikes + spike_replaced;
                    distortions <= distortions + distorted;
                end
            end
        end
    end
    // synthesis translate_off
    // 【04：仿真配置校验】窗口至少2点，异常门限必须处于1..窗口长度。
    initial if (WINDOW_SAMPLES < 2 || SPIKE_LIMIT < 1 ||
                DISTORTION_LIMIT < 1 || SPIKE_LIMIT > WINDOW_SAMPLES ||
                DISTORTION_LIMIT > WINDOW_SAMPLES)
        $fatal(1, "Invalid quality window configuration");
    // synthesis translate_on
endmodule
