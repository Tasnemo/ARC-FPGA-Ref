# Programs the Zybo over JTAG and starts the bridge (no SD card needed).
#
#   xsct sw/scripts/run_jtag.tcl
#
# Set the Zybo boot jumper (JP5) to JTAG. Close any serial terminal on the
# board's COM port first if you want to watch the "ready" banner in Chrome.

set root [file normalize [file join [file dirname [info script]] .. ..]]
set ws   [file join $root build vitis]
set bit  [file join $root build arc_ref.bit]
set elf  [file join $ws ref_bridge Debug ref_bridge.elf]

proc find_file {dir name} {
    foreach f [glob -nocomplain -directory $dir *] {
        if {[file tail $f] eq $name} { return $f }
        if {[file isdirectory $f]} {
            set r [find_file $f $name]
            if {$r ne ""} { return $r }
        }
    }
    return ""
}

set ps7_init [find_file [file join $ws arc_platform] ps7_init.tcl]
foreach f [list $bit $elf $ps7_init] {
    if {$f eq "" || ![file exists $f]} {
        error "missing build output ($f); run build.tcl and build_sw.tcl first"
    }
}

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000

targets -set -nocase -filter {name =~ "xc7z*"}
fpga -file $bit

targets -set -nocase -filter {name =~ "APU*"}
source $ps7_init
ps7_init
ps7_post_config

targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf
con
puts "INFO: bridge running; open web/index.html in Chrome and press Connect"
