@echo off
chcp 936 >nul
title Clash 关
echo 正在停止 Clash 并清除系统代理 ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0legacy\ClashCtl.ps1" off
echo.
timeout /t 5 >nul