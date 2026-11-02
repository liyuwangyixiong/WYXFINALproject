# Board bring-up and measurement

Target: PYNQ-Z2, Zynq `xc7z020clg400-1`. The prepared FPGA image is `board/wyxfinalproject.bit` (SHA-256 in `data/bitstream_sha256.txt`). This is the newly integrated `wyx_final_board_top` image, not the older `sensor_screen.bit`. JTAG checks verified room TMP117 freshness and normal Nextion display behavior on 2026-11-02, then simultaneous four-channel liveness on 2026-11-03. A physical four-channel accuracy acceptance run remains pending.

## Connections and prerequisites

- KPT_D01 is the UART heart-rate source. The independent MAX30102 supplies red/IR data for SpO2 over I2C. Probe TMP117 uses address `0x49`; room TMP117 uses `0x48`. Confirm the actual ADDR pin state and shared power/ground before applying power.
- The PL I/O bank pins are defined in `src/constraints/pynqz2.xdc`. The Nextion display uses the TX/RX pair named there. Verify the screen's power and logic levels against its own specifications; the XDC's `LVCMOS33` is the FPGA I/O standard, not a screen supply specification.
- The FPGA clock comes from PS7 FCLK0 at 25 MHz. Boot the PYNQ-Z2 from a known working SD Linux image or initialize the PS by a verified board procedure before expecting PL activity. Merely loading a `.bit` into PL does not prove that PS FCLK0 is running.
- The MAX30102 collects about 100 red/IR pairs per second. The SpO2 estimator waits for a four-second window, then attempts an update each second; poor contact can make the quality gate reject new estimates. A slowly changing displayed percentage alone is not evidence of a slow I2C link. Check the raw sample counter, accepted-result counter, result age and reject bits separately.

## Board procedure

1. With power off, check module power, ground, I2C addresses, UART TX/RX crossing, and the SD boot jumper. Insert a known working PYNQ-Z2 Linux card if using SD boot.
2. Power on, confirm the PS boots and the JTAG/PROG-UART connection appears. Use Vivado Hardware Manager to select the `xc7z020_1` device and program `board/wyxfinalproject.bit`. This step changes the running PL configuration; it does not make the bitstream persistent across power cycles.
3. Observe clock/reset and four channel sample/valid/fault signals with a suitable ILA build, or capture the display/producer output with time stamps. This repository's released bitstream does not contain an ILA. Do not infer success from an LED alone.
4. Measure each channel with the sensor present, then remove one at a time and confirm that its value becomes unavailable without copying the last good number. Exercise bus timeout and recovery separately. Record source firmware hash, wiring, input/reference device and timestamp in a private lab log.
5. Compare output with a reference instrument or controlled test source. Report absolute error, update interval and fault response. Do not publish identifiable health measurements without a separate decision to do so.

The room/display and four-channel liveness checks are recorded in `data/board_validation_20261102.md` and `data/board_validation_20261103.md`. Measurement accuracy and fault-recovery acceptance remain pending. Older captures from a different image cannot be substituted. The script `src/arm_monitor/run_on_pynq.sh` starts the ARM advisory engine on PYNQ Linux, but requires a JSONL producer conforming to `src/arm_monitor/interface.json`. The PL-to-ARM producer is not included in this integration. Without that producer, do not state that ARM is receiving live PL samples.

## Prepare an existing Linux SD card

The SD scripts package and load the exact bitstream above; they do **not** create a bootable Linux image from a blank card. On a Windows development PC, run `python board/prepare_sd_payload.py`. It verifies the bitstream SHA-256 and creates `sd_payload/wyxfinalproject_latest/` with the board loader, ARM monitor files, and a file-hash manifest. Copy that directory to the existing card's boot partition so that the board sees `/boot/wyxfinalproject_latest` after Linux starts. Do not copy private captures or credentials onto the card.

On a powered PYNQ-Z2 booted from that Linux card, run `sudo sh /boot/wyxfinalproject_latest/board/install_sd_latest.sh`. The installer verifies every packaged file, installs the current bitstream under `/opt/wyx-current`, loads it with FCLK0 at 25 MHz, and enables the ARM advisory service. Check `systemctl status wyx-board-loader.service` and `systemctl status wyx-arm-monitor.service` after a reboot, then confirm the loaded bitstream hash in `journalctl -u wyx-board-loader.service`. This is a software boot loader, not a permanent PL flash operation. The ARM service still needs an external JSONL producer; a running service alone is not evidence of live PL-to-ARM data.
