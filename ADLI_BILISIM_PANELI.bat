@echo off
title Talknex Adli Bilisim ve Denetim Paneli
chcp 65001 >nul

cd /d "%~dp0\server_go"

echo ========================================================
echo    Talknex Adli Bilisim ve Sifre Cozucu Paneli
echo ========================================================

python admin_panel.py
