# Third-party and supplied-material notices

## New board integration

The complete project under this repository was assembled from the existing project RTL, the supplied four-sensor acquisition sources, the supplied Nextion screen project, and the PS7 configuration. The new top module is `wyx_final_board_top`. The supplied older `sensor_screen.bit` has top module `health_screen_board_top`; its matching complete source was not found. The new bitstream must not be represented as a reproduction of that older binary.

## MAX30102 processing references

The fixed-point PPG filtering and SpO₂ estimator are included as project RTL. Related method/reference materials include the MAX30102 datasheet and the project's existing reference annotations. A method reference does not imply authorship or validation of upstream reference code.

- MAX30102 datasheet: https://www.analog.com/media/en/technical-documentation/data-sheets/max30102.pdf

## Supplied sources and vendor outputs

The acquisition modules and Nextion assets came from materials supplied for this project. Their original ownership and any applicable terms remain with their authors. The root MIT license applies only to original project contributions and does not relicense third-party sources, Nextion firmware assets, or AMD/Xilinx-generated IP output.

AMD, Xilinx, PYNQ, and Nextion are names of their respective owners and do not imply endorsement. This repository does not contain Vivado or a PYNQ Linux disk image.
