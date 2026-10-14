@echo off
rem HOPE Dome Sim - Windows start (no Syphon; Syphon is macOS only).
rem Serves this folder on http://localhost:8765 and opens the browser.
cd /d "%~dp0"
start "" "http://localhost:8765/index.html"
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 -m http.server 8765 --bind 127.0.0.1
) else (
  python -m http.server 8765 --bind 127.0.0.1
)
pause
