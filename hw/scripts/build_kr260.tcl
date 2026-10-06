# Builds the Kria KR260 PL design and its xmutil firmware file.
#
#   vivado -mode batch -source hw/scripts/build_kr260.tcl
#   vivado -mode batch -source hw/scripts/build_kr260.tcl -tclargs project   ;# create project only
#
# Output: prebuilt/kr260/arc-ref.bit.bin. Commit it; kria/install.sh copies it
# with kria/firmware/arc-ref.dtbo and shell.json into /lib/firmware/xilinx/arc-ref
# on the board, so nobody else needs Vivado.
#
# Needs Vivado 2022.2 or later with the Kria board files (they ship with
# Vivado; if get_board_parts finds nothing, open Vivado's Xilinx Board Store
# and install "Kria KR260 Robotics Starter Kit").
#
# Design: the PS (Ubuntu on the A53s) reaches arc_ref_axi at 0xA000_0000 on
# M_AXI_HPM0_FPD. pl_clk0 is 50 MHz, the clock the RTL is verified at.

set root     [file normalize [file join [file dirname [info script]] .. ..]]
set proj_dir [file join $root build kr260]
set out_dir  [file join $root prebuilt kr260]
set only_project [expr {[lsearch $argv project] >= 0}]
file mkdir $out_dir

set board [lindex [lsort [get_board_parts -quiet "*:kr260_som:*"]] end]
if {$board eq ""} {
    error "Kria KR260 board files not found. Install them from Vivado's Xilinx Board Store (Tools > Vivado Store > Boards)."
}
puts "INFO: using board part $board"
create_project arc_ref_kr260 $proj_dir -part [get_property PART_NAME [get_board_parts $board]] -force
set_property board_part $board [current_project]
set_property board_connections {som240_1_connector xilinx.com:kr260_carrier:som240_1_connector:1.0 som240_2_connector xilinx.com:kr260_carrier:som240_2_connector:1.0} [current_project]

# ------------------------------------------------------------------ sources
set rtl [file join $root hw rtl]
foreach f [glob [file join $rtl *.v]] {
    # The standalone top uses a 7-series MMCM; it isn't part of this design.
    if {[file tail $f] ne "arc_ref_standalone.v"} { add_files $f }
}
add_files [file join $rtl arc_crc.vh]
set_property file_type {Verilog Header} [get_files arc_crc.vh]
set_property include_dirs $rtl [get_filesets sources_1]
add_files -fileset constrs_1 [file join $root hw constraints kr260.xdc]
update_compile_order -fileset sources_1

# ------------------------------------------------------------- block design
create_bd_design arc_bd

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps

# One master port (HPM0_FPD), one 50 MHz fabric clock, one reset.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {50} \
    CONFIG.PSU__NUM_FABRIC_RESETS {1} \
] $ps

set ref [create_bd_cell -type module -reference arc_ref_axi arc_ref_0]
set_property CONFIG.CLK_HZ 50000000 $ref

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps/M_AXI_HPM0_FPD} Slave {/arc_ref_0/s_axi} \
    ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}] \
    [get_bd_intf_pins arc_ref_0/s_axi]

# No buttons or switches on the KR260 carrier: the browser drives everything.
set zero4 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant zero4]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $zero4
connect_bd_net [get_bd_pins zero4/dout] [get_bd_pins arc_ref_0/btn]
connect_bd_net [get_bd_pins zero4/dout] [get_bd_pins arc_ref_0/sw]

# Fan always on (active-low enable).
set zero1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant zero1]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $zero1
create_bd_port -dir O fan_en_b
connect_bd_net [get_bd_pins zero1/dout] [get_bd_ports fan_en_b]

# Wired robot UART on PMOD 1
foreach {name dir} {robot_tx O robot_rx I} {
    create_bd_port -dir $dir $name
    connect_bd_net [get_bd_ports $name] [get_bd_pins arc_ref_0/$name]
}

# Fixed address: kria/arc_refd.py and the device-tree overlay use it.
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]] {
    set_property offset 0xA0000000 $seg
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
    error "Implementation failed; see $proj_dir/arc_ref_kr260.runs/impl_1"
}

open_run impl_1
report_utilization    -file [file join $root build kr260_utilization.txt]
report_timing_summary -file [file join $root build kr260_timing.txt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns ne "" && $wns < 0} {
    error "Timing not met (worst slack $wns ns); see build/kr260_timing.txt"
}

# xmutil/fpga_manager wants the bitstream as a .bin processed by bootgen.
set bit [lindex [glob [file join $proj_dir arc_ref_kr260.runs impl_1 *.bit]] 0]
file copy -force $bit [file join $root build arc_ref_kr260.bit]
set bif [file join $root build arc_ref_kr260.bif]
set fh [open $bif w]
puts $fh "all:\n{\n  \[destination_device = pl\] [file join $root build arc_ref_kr260.bit]\n}"
close $fh
exec bootgen -arch zynqmp -image $bif -process_bitstream bin -w on
file copy -force [file join $root build arc_ref_kr260.bit.bin] [file join $out_dir arc-ref.bit.bin]
puts "INFO: wrote prebuilt/kr260/arc-ref.bit.bin"
