# Builds the standalone bitstream (fabric only, no PS / ARM / SD card).
#
#   vivado -mode batch -source hw/scripts/build_standalone.tcl              ;# Zybo Z7-10
#   vivado -mode batch -source hw/scripts/build_standalone.tcl -tclargs z7-20
#
# Output: prebuilt/arc_ref_zybo_z7_10.bit (or _20), which anyone can load with
# openFPGALoader from macOS, Windows or Linux (load_board.sh / load_board.bat).
# Commit that file so people who clone the repo don't need Vivado.

set root  [file normalize [file join [file dirname [info script]] .. ..]]
set rtl   [file join $root hw rtl]
set board [expr {[lsearch $argv z7-20] >= 0 ? "20" : "10"}]
set part  [expr {$board eq "20" ? "xc7z020clg400-1" : "xc7z010clg400-1"}]
set out   [file join $root build standalone_z7_$board]
file mkdir $out [file join $root prebuilt]

foreach f [glob [file join $rtl *.v]] {
    if {[file tail $f] ne "arc_ref_axi.v"} { read_verilog $f }
}
read_xdc [file join $root hw constraints zybo_z7_10_standalone.xdc]

synth_design -top arc_ref_standalone -part $part -include_dirs $rtl
opt_design
place_design
phys_opt_design
route_design

report_utilization    -file [file join $out utilization.txt]
report_timing_summary -file [file join $out timing.txt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns ne "" && $wns < 0} {
    puts "WARNING: timing not met (worst slack $wns ns); see $out/timing.txt"
}

set bit [file join $root prebuilt arc_ref_zybo_z7_$board.bit]
write_bitstream -force $bit
puts "INFO: wrote $bit"
