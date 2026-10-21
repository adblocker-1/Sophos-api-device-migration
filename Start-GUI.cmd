@echo off
rem Starts the graphical user interface of the Sophos device migration (without a console window).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Sophos-DeviceMigration-GUI.ps1"
