## Zybo Z7-10 (xc7z010clg400-1). Pins from the Digilent Zybo-Z7 master XDC.
## The clock comes from the PS (FCLK_CLK0, 100 MHz), so no sysclk pin here.
## The USB-UART is on PS MIO 48/49 and is configured in the block design.

## Buttons: BTN0..3 = armor plate 0..3
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## Switches: SW0 = robot the buttons hit (0 red, 1 blue); SW1..3 spare
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]

## LEDs: LD0 combat, LD1 red alive, LD2 blue alive, LD3 control frame received
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Buttons and switches go through a 2-FF synchroniser; LEDs are slow.
set_false_path -from [get_ports {btn[*] sw[*]}]
set_false_path -to   [get_ports {led[*]}]
