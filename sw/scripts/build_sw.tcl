# Builds the bare-metal bridge app from build/arc_ref.xsa (Vitis classic / xsct).
#
#   xsct sw/scripts/build_sw.tcl
#
# Outputs:
#   build/vitis/ref_bridge/Debug/ref_bridge.elf   app, for JTAG (run_jtag.tcl)
#   build/sd/BOOT.BIN                             SD card image (FSBL + bitstream + app)
# Vitis 2024.1 and later dropped the classic flow; there, create a platform
# from build/arc_ref.xsa and an "Empty Application (C)" in the GUI and add
# sw/ref_bridge/main.c.

set root [file normalize [file join [file dirname [info script]] .. ..]]
set xsa  [file join $root build arc_ref.xsa]
set ws   [file join $root build vitis]

if {![file exists $xsa]} {
    error "missing $xsa; run hw/scripts/build.tcl in Vivado first"
}

file delete -force $ws
setws $ws

platform create -name arc_platform -hw $xsa -proc ps7_cortexa9_0 -os standalone -out $ws
platform write
platform generate

app create -name ref_bridge -platform arc_platform -template {Empty Application(C)}
importsources -name ref_bridge -path [file join $root sw ref_bridge]
app build -name ref_bridge

set elf [file join $ws ref_bridge Debug ref_bridge.elf]
puts "INFO: built $elf"

# ---------------------------------------------------------------- SD card
# The platform builds an FSBL as its boot component; find it.
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
set fsbl [find_file [file join $ws arc_platform] fsbl.elf]
if {$fsbl eq ""} {
    puts "WARNING: no fsbl.elf in the platform; skipping BOOT.BIN (JTAG still works)"
    return
}
set sd [file join $root build sd]
file mkdir $sd
set bif [file join $sd boot.bif]
set fh [open $bif w]
puts $fh "the_ROM_image:\n\{\n  \[bootloader\] $fsbl\n  [file join $root build arc_ref.bit]\n  $elf\n\}"
close $fh
exec bootgen -arch zynq -image $bif -o [file join $sd BOOT.BIN] -w on
puts "INFO: wrote [file join $sd BOOT.BIN]; copy it to a FAT32 SD card and set JP5 to SD"
