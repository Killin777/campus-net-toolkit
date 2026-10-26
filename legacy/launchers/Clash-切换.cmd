@echo off
chcp 936 >nul
title Clash ÇÐ»»
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0legacy\ClashCtl.ps1" toggle
echo.
timeout /t 4 >nul