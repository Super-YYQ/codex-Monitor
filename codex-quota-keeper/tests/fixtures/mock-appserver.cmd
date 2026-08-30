@echo off
rem npm-style wrapper: forwards to the PowerShell mock app-server
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-appserver.ps1" %*
