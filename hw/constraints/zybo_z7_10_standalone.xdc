## Zybo Z7 standalone build (fabric only, loaded with openFPGALoader).
## Pins from Digilent's Zybo-Z7-Master.xdc.

## 125 MHz fabric clock from the Ethernet PHY
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Buttons: BTN0..3 = armor plate 0..3
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## Switches: SW0 team, SW2:1 robot the buttons hit, SW3 swap PC TX/RX on JE
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## LEDs: LD0 battle, LD1/LD2 red/blue alive, LD3 control frame received
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## PC link: USB-UART Pmod on JE (JE2, JE3). Pull-ups keep an unplugged RX idle.
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 PULLUP true } [get_ports { pc_a }]
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 PULLUP true } [get_ports { pc_b }]

## Robot link on JD: JD1 TX to the robot, JD2 RX from the robot
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { robot_tx }]
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 PULLUP true } [get_ports { robot_rx }]

## Slow, synchronised I/O
set_false_path -from [get_ports {btn[*] sw[*] pc_a pc_b robot_rx}]
set_false_path -to   [get_ports {led[*] pc_a pc_b robot_tx}]
