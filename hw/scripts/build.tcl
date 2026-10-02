# Builds the Zybo Z7-10 bitstream and exports the hardware platform (.xsa).
#
#   vivado -mode batch -source hw/scripts/build.tcl
#   vivado -mode batch -source hw/scripts/build.tcl -tclargs project   ;# create project only
#
# Outputs:
#   build/vivado/arc_ref.xpr   Vivado project
#   build/arc_ref.xsa          hardware platform with bitstream (for Vitis)
#   build/arc_ref.bit          bitstream
#
# Install the Digilent board files first (see README). Without them the PS is
# configured by hand below and the DDR timing is Vivado's default, which may
# not be reliable on this board.

set root     [file normalize [file join [file dirname [info script]] .. ..]]
set proj_dir [file join $root build vivado]
set part     xc7z010clg400-1
set only_project [expr {[lsearch $argv project] >= 0}]

file mkdir [file join $root build]
create_project arc_ref $proj_dir -part $part -force

set board [lindex [lsort [get_board_parts -quiet *zybo-z7-10*]] end]
if {$board ne ""} {
    puts "INFO: using board part $board"
    set_property board_part $board [current_project]
} else {
    puts "WARNING: Digilent Zybo Z7-10 board files not found; using manual PS settings."
}

# ------------------------------------------------------------------ sources
set rtl [file join $root hw rtl]
add_files [glob [file join $rtl *.v]]
add_files [file join $rtl arc_crc.vh]
set_property file_type {Verilog Header} [get_files arc_crc.vh]
set_property include_dirs $rtl [get_filesets sources_1]
add_files -fileset constrs_1 [file join $root hw constraints zybo_z7_10.xdc]
update_compile_order -fileset sources_1

# ------------------------------------------------------------- block design
create_bd_design arc_bd

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
if {$board ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
} else {
    set_property -dict [list \
        CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
        CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
        CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
        CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
        CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
        CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
    ] $ps
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps
}

# USB-UART (UART1 on MIO 48/49), one AXI master port, 100 MHz fabric clock.
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_UART_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_UART1_BAUD_RATE {115200} \
] $ps

set ref [create_bd_cell -type module -reference arc_ref_axi arc_ref_0]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps7/FCLK_CLK0 (100 MHz)} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps7/M_AXI_GP0} Slave {/arc_ref_0/s_axi} \
    ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins arc_ref_0/s_axi]

foreach {name dir} {btn I sw I led O} {
    create_bd_port -dir $dir -from 3 -to 0 $name
    connect_bd_net [get_bd_ports $name] [get_bd_pins arc_ref_0/$name]
}

# Fixed address so the bridge firmware can hard-code it.
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
    set_property offset 0x43C00000 $seg
    set_property range 64K $seg
}

validate_bd_design
save_bd_design

set wrapper [make_wrapper -files [get_files arc_bd.bd] -top]
add_files -norecurse $wrapper
set_property top arc_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$only_project} {
    puts "INFO: project created at $proj_dir"
    return
}

# -------------------------------------------------------------------- build
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation failed; see $proj_dir/arc_ref.runs/impl_1"
}

open_run impl_1
report_utilization -file [file join $root build utilization.txt]
report_timing_summary -file [file join $root build timing.txt]
write_hw_platform -fixed -include_bit -force -file [file join $root build arc_ref.xsa]
file copy -force [glob [file join $proj_dir arc_ref.runs impl_1 *.bit]] [file join $root build arc_ref.bit]
puts "INFO: wrote build/arc_ref.xsa and build/arc_ref.bit"
