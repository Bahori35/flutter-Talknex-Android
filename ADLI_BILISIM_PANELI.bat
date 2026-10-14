@echo off
title Talknex Bilisim ve Denetim Paneli
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

cd /d "%~dp0\server_go"

echo ========================================================
echo    Talknex Bilisim ve Sifre Cozucu Paneli
echo ========================================================

python admin_panel.py
