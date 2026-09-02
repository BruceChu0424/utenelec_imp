@echo off
chcp 65001 >nul
REM ============================================================
REM  ERP 内网信任初始化（员工电脑一次性执行）
REM  作用：1) 安装公司内部根CA（消除 https 证书警告）
REM        2) 绑定内网域名 imp.utenelec -> 192.168.1.13
REM  用法：右键"以管理员身份运行"
REM ============================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo [错误] 请右键本文件，选择"以管理员身份运行"
  pause
  exit /b 1
)

echo [1/3] 下载并安装内部根证书 ...
curl -fsSL -o "%TEMP%\uten-imp-root-ca.crt" http://192.168.1.13/ca/uten-imp-root-ca.crt
if %errorlevel% neq 0 (
  echo [错误] 无法从服务器下载根证书，请确认能访问 http://192.168.1.13
  pause
  exit /b 1
)
certutil -addstore -f Root "%TEMP%\uten-imp-root-ca.crt"

echo [2/3] 绑定内网域名 imp.utenelec ...
findstr /C:"imp.utenelec" %SystemRoot%\System32\drivers\etc\hosts >nul
if %errorlevel% neq 0 (
  echo 192.168.1.13	imp.utenelec >> %SystemRoot%\System32\drivers\etc\hosts
)

echo [3/3] 完成！ERP 地址：https://imp.utenelec （或 https://192.168.1.13）
echo 浏览器如仍提示不安全，请完全关闭浏览器后重开。
pause
