@echo off
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI\"
if not defined VIVADO_BAT set "VIVADO_BAT=E:\Xilinx\Vivado\2024.1\bin\vivado.bat"
if not exist "%VIVADO_BAT%" (
  echo Set VIVADO_BAT to your Vivado 2024.1 vivado.bat path.
  exit /b 2
)
if not exist "%ROOT%vivado_build\" mkdir "%ROOT%vivado_build\"
"%VIVADO_BAT%" -mode batch -source "%ROOT%build\build.tcl" -log "%ROOT%vivado_build\build.log" -journal "%ROOT%vivado_build\build.jou"
if errorlevel 1 exit /b %errorlevel%
echo Bitstream and reports are under board\ and build\reports\
