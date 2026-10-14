@echo off
title Talknex Worker Server 4
chcp 65001 >nul

echo ========================================================
echo    Talknex Go Worker Node 4 Baslatiliyor...
echo    Port: 3001 | Kume Modu: Aktif
echo ========================================================

if exist talknex_server.exe (
    talknex_server.exe
) else (
    echo [HATA] talknex_server.exe bulunamadi! Lutfen bu klasore talknex_server.exe kopyalayin.
    pause
)
