# Nextion interface in this integrated project

The board top is `src/rtl/wyx_final_board_top.sv`. The display logic is in `src/display/nextion_display.sv`, `nextion_link.sv` and `uart_8n1.sv`. The editable screen asset is `src/nextion/health_monitor.hmi`; the supplied compiled asset is `src/nextion/health_monitor.tft`. Confirm the exact screen model before loading the TFT. The `.hmi`/`.tft` files were renamed for repository portability; their internal content was not modified by that rename.

The FPGA sends a four-channel snapshot over 115200 baud, 8N1, with Nextion's `FF FF FF` command terminator. `nextion_tx` goes to the screen RX and `nextion_rx` to screen TX, with a common ground and the correct level/power arrangement verified against hardware. A screen link failure must not stop sensor acquisition or health fusion.

The interface carries heart rate, SpO2, probe temperature, room temperature, a four-state health result, data-availability bits, fault reasons and a trend selection. Invalid measurements are hidden; saved old values are not presented as new readings. The HMI event source text under `src/nextion/hmi_events/` is supporting material. Editing event text alone does not update the compiled TFT; it must be imported and rebuilt with the Nextion editor.

This document describes the code interface. The new integrated bitstream's display behavior still needs physical board verification. The earlier standalone Nextion prototype notes referred to a different top/project and are intentionally not treated as validation of this build.
