@echo off
rem Lets you type "wplm" in cmd or PowerShell. This bin folder is what goes on PATH
rem (not the folder with wplm.ps1, which PowerShell's default policy would refuse to run).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\wplm.ps1" %*
