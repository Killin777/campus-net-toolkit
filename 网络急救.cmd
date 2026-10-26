@echo off
chcp 936 >nul
title ÍøÂç¼±¾È
echo ¼ì²é´úÀí²ÐÁô / Ë¢ÐÂ DNS / ¼ì²âÍø¹Ø ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0legacy\ClashCtl.ps1" fix
echo.
timeout /t 6 >nul