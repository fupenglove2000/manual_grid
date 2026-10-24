# 把 UTF-8 源码转成 UTF-16 复制到 MT5 的 MQL5\Experts 下并编译，输出编译结果
# 用法：.\deploy.ps1 -Source D:\git\manual_grid\GridEA.mq5 -TargetRel GridEA.mq5
param(
  [Parameter(Mandatory = $true)] [string]$Source,
  [Parameter(Mandatory = $true)] [string]$TargetRel,
  [string]$Kind = 'Experts'                           # Experts 或 Scripts
)
$ErrorActionPreference = 'Stop'
$experts = Join-Path $env:APPDATA "MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\$Kind"
$dst = Join-Path $experts $TargetRel
New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
$text = [System.IO.File]::ReadAllText($Source, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($dst, $text, [System.Text.Encoding]::Unicode)
$log = [System.IO.Path]::ChangeExtension($dst, '.compile.log')
if (Test-Path $log) { Remove-Item $log -Force }
Start-Process -FilePath 'C:\Program Files\MetaTrader 5\metaeditor64.exe' -ArgumentList ('/compile:"' + $dst + '"'), ('/log:"' + $log + '"') -Wait | Out-Null
Get-Content $log -Encoding Unicode | Where-Object { $_ -match 'Result|error|warning' }
Remove-Item $log -Force
