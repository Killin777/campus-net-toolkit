@echo off
chcp 936 >nul
if exist "%~dp0网络优化器.exe" (
  start "" "%~dp0网络优化器.exe"
  exit /b
)
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0src\网络优化器.ps1"