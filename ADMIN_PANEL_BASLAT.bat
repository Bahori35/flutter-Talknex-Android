@echo off
title Talknex Guvenlik ve Adli Denetim Admin Paneli
echo ===================================================
echo     Talknex Windows Guvenlik ve Denetim Paneli     
echo ===================================================
echo Panel baslatiliyor, lutfen bekleyin...
cd /d "%~dp0\server_python"
py admin_panel.py
pause
