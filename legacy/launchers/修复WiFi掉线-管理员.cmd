@echo off
chcp 936 >nul
title 修复 WiFi 掉线（管理员）
echo 正在以管理员权限应用网卡参数，过程中会断网约 10 秒 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0legacy\Fix-WifiStability.ps1' -Verb RunAs -Wait"
echo.
echo 完成。
timeout /t 6 >nul