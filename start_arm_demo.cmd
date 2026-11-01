@echo off
setlocal
cd /d "%~dp0arm_monitor"
set PYTHONDONTWRITEBYTECODE=1
where py >nul 2>nul
if not errorlevel 1 (
  py -3 -B monitor.py --mode demo
) else (
  python -B monitor.py --mode demo
)
pause
