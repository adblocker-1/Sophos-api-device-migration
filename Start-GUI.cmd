@echo off
rem Startet die grafische Oberflaeche der Sophos Geraete-Migration (ohne Konsolenfenster).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Sophos-DeviceMigration-GUI.ps1"
