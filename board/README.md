# Board bring-up and measurement

Target: PYNQ-Z2, Zynq `xc7z020clg400-1`. The prepared FPGA image is `board/wyxfinalproject.bit` (SHA-256 in `data/bitstream_sha256.txt`). This is the newly integrated `wyx_final_board_top` image. It is not the older `sensor_screen.bit` and has not yet completed a physical four-channel acceptance run.

## Connections and prerequisites

- KPT_D01 is the UART heart-rate source. The independent MAX30102 supplies red/IR data for SpO2 over I2C. Probe TMP117 uses address `0x49`; room TMP117 uses `0x48`. Confirm the actual ADDR pin state and shared power/ground before applying power.
- The PL I/O bank pins are defined in `src/constraints/pynqz2.xdc`. The Nextion display uses the TX/RX pair named there. Verify the screen's power and logic levels against its own specifications; the XDC's `LVCMOS33` is the FPGA I/O standard, not a screen supply specification.
- The FPGA clock comes from PS7 FCLK0 at 25 MHz. Boot the PYNQ-Z2 from a known working SD Linux image or initialize the PS by a verified board procedure before expecting PL activity. Merely loading a `.bit` into PL does not prove that PS FCLK0 is running.

## Board procedure

1. With power off, check module power, ground, I2C addresses, UART TX/RX crossing, and the SD boot jumper. Insert a known working PYNQ-Z2 Linux card if using SD boot.
2. Power on, confirm the PS boots and the JTAG/PROG-UART connection appears. Use Vivado Hardware Manager to select the `xc7z020_1` device and program `board/wyxfinalproject.bit`. This step changes the running PL configuration; it does not make the bitstream persistent across power cycles.
3. Observe clock/reset and four channel sample/valid/fault signals with a suitable ILA build, or capture the display/producer output with time stamps. This repository's released bitstream does not contain an ILA. Do not infer success from an LED alone.
4. Measure each channel with the sensor present, then remove one at a time and confirm that its value becomes unavailable without copying the last good number. Exercise bus timeout and recovery separately. Record source firmware hash, wiring, input/reference device and timestamp in a private lab log.
5. Compare output with a reference instrument or controlled test source. Report absolute error, update interval and fault response. Do not publish identifiable health measurements without a separate decision to do so.

The board-acceptance results for this new image are **pending**. Older captures from a different image cannot be substituted. The script `src/arm_monitor/run_on_pynq.sh` starts the ARM advisory engine on PYNQ Linux, but requires a JSONL producer conforming to `src/arm_monitor/interface.json`. The PL-to-ARM producer is not included in this integration. Without that producer, do not state that ARM is receiving live PL samples.
