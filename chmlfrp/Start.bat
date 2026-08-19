@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ————————————————————————————————————————————————
echo.
echo       MCSM FRP 模板集市 - *ChmlfFrp*
echo                  作者: 语千🍥
echo               QQ交流群: 941830180
echo.
echo ————————————————————————————————————————————————
echo.

echo [*] 正在启动 ChmlfFrp 启动器...
echo [!] 请使用 PowerShell 版本以获得完整功能
echo.

powershell.exe -ExecutionPolicy Bypass -File "%~dp0start.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [x] 启动失败，错误代码: %ERRORLEVEL%
    pause
    exit /b %ERRORLEVEL%
)

pause