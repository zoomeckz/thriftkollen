@echo off
chcp 65001 >nul
title Thriftkollen - scrape
echo Hamtar priser fran Blocket och Tradera och pushar till GitHub. Det tar nagra minuter...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\scrape.ps1" -Push %*
echo.
pause
