@echo off
chcp 936 >nul
title Clash 开
echo 正在启动 Clash 并设置系统代理 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0legacy\ClashCtl.ps1" on
echo.
timeout /t 5 >nul