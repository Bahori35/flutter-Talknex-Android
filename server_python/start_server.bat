@echo off
title Talknex High-Performance Server (Nginx + Uvicorn)
chcp 65001 >nul

cd /d "%~dp0"
set ROOT_DIR=%~dp0..
set NGINX_DIR=%ROOT_DIR%\nginx

echo ======================================================================
echo    Talknex High-Performance Server Suite (Nginx + Uvicorn Backend)
echo ======================================================================
echo.

:: 1. Onceki calisan Nginx surecleri varsa sonlandir
taskkill /F /IM nginx.exe >nul 2>&1

:: 2. Nginx'i baslat
echo [1/2] Nginx Web Hızlandırıcı ve Ters Proxy baslatiliyor...
cd /d "%NGINX_DIR%"
start "" nginx.exe
cd /d "%~dp0"

echo [OK] Nginx Port 3000 uzerinde dinliyor!
echo      - Medya/Video dosyalari: Nginx uzerinden aninda (0 ms gecikme)
echo      - WebSocket ve API: Arka plandaki Uvicorn surecine yonlendiriliyor.
echo.

:: 3. Uvicorn Backend'i baslat (Port 3001)
echo [2/2] Python Uvicorn Backend baslatiliyor (Port: 3001)...
set PORT=3001
python main.py

:: Eger Python kapanirsa Nginx'i de kapat
echo.
echo Sunucu kapatiliyor...
taskkill /F /IM nginx.exe >nul 2>&1
echo Tamamlandi.
pause
