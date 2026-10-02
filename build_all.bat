@echo off
rem Windows: full build (bitstream, bridge app, SD card image).
rem Run from the repo root in a terminal where Vivado/Vitis are on PATH,
rem e.g. after "C:\Xilinx\Vitis\2023.2\settings64.bat".
call vivado -mode batch -nojournal -nolog -source hw\scripts\build.tcl || goto :fail
call xsct sw\scripts\build_sw.tcl || goto :fail
echo.
echo Done. SD card image: build\sd\BOOT.BIN
exit /b 0
:fail
echo Build failed.
exit /b 1
