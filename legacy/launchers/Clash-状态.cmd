@echo off
chcp 936 >nul
title Clash ??
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0legacy\ClashCtl.ps1" status
echo.
timeout /t 6 >nul