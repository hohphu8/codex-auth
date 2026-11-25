@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-auth.ps1" %*
