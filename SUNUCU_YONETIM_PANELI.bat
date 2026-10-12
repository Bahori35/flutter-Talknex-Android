@echo off
title Talknex Server Control Center
chcp 65001 >nul

cd /d "%~dp0\server_python"

echo ========================================================
echo    Talknex Server Control Center Baslatiliyor...
echo ========================================================

python server_manager_gui.py

