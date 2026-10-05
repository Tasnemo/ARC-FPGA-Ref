# Prebuilt bitstreams

`load_board.sh` / `load_board.bat` load the files here onto a Zybo Z7 with
openFPGALoader, so people who clone the repo don't need Vivado.

| File | Board |
|---|---|
| `arc_ref_zybo_z7_10.bit` | Zybo Z7-10 |
| `arc_ref_zybo_z7_20.bit` | Zybo Z7-20 (optional) |

They are produced on a PC with Vivado by
`vivado -mode batch -source hw/scripts/build_standalone.tcl` (add
`-tclargs z7-20` for the Z7-20). Rebuild and commit after any change under
`hw/rtl/`. Changes to the web console never need a rebuild.
