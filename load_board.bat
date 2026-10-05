@echo off
rem Loads the referee onto a Zybo Z7 over its USB cable (Windows).
rem Needs openFPGALoader from MSYS2: pacman -S mingw-w64-ucrt-x86_64-openFPGALoader
rem and C:\msys64\ucrt64\bin on PATH. Set jumper JP5 to JTAG.
rem   load_board.bat        Zybo Z7-10
rem   load_board.bat 20     Zybo Z7-20
setlocal
cd /d "%~dp0"
set SIZE=%1
if "%SIZE%"=="" set SIZE=10
set BIT=prebuilt\arc_ref_zybo_z7_%SIZE%.bit
where openFPGALoader >nul 2>nul || (echo openFPGALoader not found. See README "Windows" & exit /b 1)
if not exist "%BIT%" (echo %BIT% is missing. Build it once with Vivado and commit it. & exit /b 1)
openFPGALoader -b zybo_z7_%SIZE% "%BIT%" || (echo Load failed. If no cable was found, see README: Zadig step. & exit /b 1)
echo Loaded. Open web\arc-ref-console.html in Chrome and click Connect board.
