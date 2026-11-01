# PYNQ-Z2，沿用已提供运行包的连接。FCLK0=25MHz，由PS7产生，不使用H16。
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn_reset]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports i2c_sda]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports kpt_uart_rxd]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports nextion_rx]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports nextion_tx]
set_property PULLTYPE PULLUP [get_ports {i2c_scl i2c_sda kpt_uart_rxd nextion_rx}]
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports led4_r]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports led4_g]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports led4_b]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports buzzer_out]
# UART和按钮为异步输入，仅排除其到第一级同步寄存器的路径。
set_false_path -from [get_ports btn_reset] -to [get_cells -hier -filter {NAME =~ *reset_sync_reg[0]}]
set_false_path -from [get_ports kpt_uart_rxd] -to [get_cells -hier -filter {NAME =~ *rx_sync_reg[0]}]
set_false_path -from [get_ports nextion_rx] -to [get_cells -hier -filter {NAME =~ *rx_meta_reg}]
# I2C和UART为自定时外设接口；未用虚构同步外部时钟设置IO延迟。
# 报告中的内部时序通过不等于外部电气时序或实板测量已通过。
