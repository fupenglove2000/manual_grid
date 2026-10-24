# 把 UTF-8 源码转成 UTF-16 放进便携终端的 MQL5 目录，用该终端自己的 MetaEditor（便携模式）编译，输出编译结果
# 用法：.\deploy.ps1 -Source ..\GridEA.mq5 -TargetRel GridEA.mq5 [-Kind Scripts] [-Root D:\MT5\FTMO_B]
param(
  [Parameter(Mandatory = $true)] [string]$Source,
  [Parameter(Mandatory = $true)] [string]$TargetRel,
  [string]$Kind = 'Experts',                          # Experts 或 Scripts
  [string]$Root = 'D:\MT5\FTMO_A'                     # 便携终端所在文件夹（槽位）
)
$ErrorActionPreference = 'Stop'
$dst = Join-Path $Root "MQL5\$Kind\$TargetRel"
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
$text = [System.IO.File]::ReadAllText((Resolve-Path $Source).Path, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($dst, $text, [System.Text.Encoding]::Unicode)
$log = [System.IO.Path]::ChangeExtension($dst, '.compile.log')
if (Test-Path $log) { Remove-Item $log -Force }
Start-Process -FilePath (Join-Path $Root 'MetaEditor64.exe') -ArgumentList '/portable', ('/compile:"' + $dst + '"'), ('/log:"' + $log + '"') -Wait | Out-Null
Get-Content $log -Encoding Unicode | Where-Object { $_ -match 'Result|error|warning' }
Remove-Item $log -Force
