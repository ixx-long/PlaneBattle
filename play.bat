@echo off
rem ASCII-only shim. cmd.exe re-reads a .bat byte-by-byte in the current ANSI
rem codepage, so any non-ASCII text in here gets mangled and can even break
rem command parsing (chcp 65001 does not help once the line is already read).
rem All Chinese messages live in tools\play.ps1, which is UTF-8 with BOM.
rem Extra arguments are forwarded to the engine, e.g. play.bat --headless --quit-after 90
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\play.ps1" %*
exit /b %ERRORLEVEL%
