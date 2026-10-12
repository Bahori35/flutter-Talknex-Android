@echo off
title Talknex Go Server Control Center
chcp 65001 >nul

cd /d "%~dp0\server_go"

echo ========================================================
echo    Talknex Go Server Control Center Baslatiliyor...
echo ========================================================

python server_manager_gui.py
