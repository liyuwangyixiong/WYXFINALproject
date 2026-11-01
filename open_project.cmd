@echo off
setlocal
set "ROOT=%~dp0"
if not defined VIVADO_BAT set "VIVADO_BAT=E:\Xilinx\Vivado\2024.1\bin\vivado.bat"
if not exist "%VIVADO_BAT%" (
  echo Set VIVADO_BAT to your Vivado 2024.1 vivado.bat path.
  exit /b 2
)
if not exist "%ROOT%vivado_build\" mkdir "%ROOT%vivado_build\"
if not exist "%ROOT%vivado_build\WYXFINALproject.xpr" (
  "%VIVADO_BAT%" -mode batch -source "%ROOT%tools\create_project.tcl" -log "%ROOT%vivado_build\create_project.log" -journal "%ROOT%vivado_build\create_project.jou"
  if errorlevel 1 exit /b %errorlevel%
)
start "" "%VIVADO_BAT%" "%ROOT%vivado_build\WYXFINALproject.xpr"

