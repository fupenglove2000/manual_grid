# GridEA 回测运行脚本
# 用法示例：
#   .\run_tester.ps1 -Name A_long -Expert GridEA -From 2026.03.02 -To 2026.03.07 -SetFile GridEA_A.set
#   .\run_tester.ps1 -Name export -Expert GridEA_tools\ExportH1 -From 2026.01.01 -To 2026.10.24 -Model 2
# 生成的配置文件在 backtest\configs\，报告在 <数据目录>\GridEA_reports\，日志复制到 backtest\logs\<Name>\
param(
  [Parameter(Mandatory = $true)] [string]$Name,
  [Parameter(Mandatory = $true)] [string]$Expert,     # 相对 MQL5\Experts，不带扩展名
  [Parameter(Mandatory = $true)] [string]$From,       # yyyy.MM.dd
  [Parameter(Mandatory = $true)] [string]$To,
  [int]$Model = 4,                                    # 4 = 基于真实 tick 的每一个点
  [string]$SetFile = "",                              # MQL5\Profiles\Tester\ 下的 .set 文件名
  [int]$TimeoutMin = 9,
  [int]$ExecMode = 0,                                 # 0 = 无延迟，-1 = 随机延迟，>0 = 固定延迟毫秒
  [string]$Login = "541239439",
  [string]$Server = "FTMO-Server4"
)
$ErrorActionPreference = 'Stop'
$term = 'C:\Program Files\MetaTrader 5\terminal64.exe'
$data = Join-Path $env:APPDATA 'MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075'
if (Get-Process -Name terminal64 -ErrorAction SilentlyContinue) { throw "已有 MT5 终端在运行，未启动测试（不会关闭你正在运行的终端）" }

$cfgDir = Join-Path $PSScriptRoot 'configs'
$logDir = Join-Path $PSScriptRoot "logs\$Name"
New-Item -ItemType Directory -Force $cfgDir, $logDir, (Join-Path $data 'GridEA_reports') | Out-Null

$lines = @(
  '[Common]', "Login=$Login", "Server=$Server",
  '[Tester]', "Expert=$Expert", 'Symbol=XAUUSD', 'Period=H1', "Model=$Model",
  "ExecutionMode=$ExecMode", 'Optimization=0', "FromDate=$From", "ToDate=$To", 'ForwardMode=0',
  'Deposit=100000', 'Currency=USD', 'Leverage=1:100', 'ProfitInPips=0', 'Visual=0',
  'UseLocal=1', 'UseRemote=0', 'UseCloud=0',
  'ShutdownTerminal=1', 'ReplaceReport=1', "Report=GridEA_reports\$Name"
)
if ($SetFile) { $lines += "ExpertParameters=$SetFile" }
$cfg = Join-Path $cfgDir "$Name.ini"
[System.IO.File]::WriteAllText($cfg, ($lines -join "`r`n") + "`r`n", [System.Text.Encoding]::Unicode)

# 记下各日志文件当前的长度，测试后只取新增部分
$today = Get-Date -Format 'yyyyMMdd'
$logs = @{
  terminal = Join-Path $data "logs\$today.log"
  tester   = Join-Path $data "Tester\logs\$today.log"
  agent    = Join-Path $env:APPDATA "MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-3000\logs\$today.log"
}
$start = @{}
foreach ($k in $logs.Keys) { $start[$k] = $(if (Test-Path $logs[$k]) { (Get-Item $logs[$k]).Length } else { 0 }) }

$t0 = Get-Date
$p = Start-Process -FilePath $term -ArgumentList "/config:`"$cfg`"" -PassThru
if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
  Stop-Process -Id $p.Id -Force   # 只结束本脚本自己启动的测试终端
  Write-Output "超时（$TimeoutMin 分钟），已结束本次启动的测试终端"
}
$sec = [int]((Get-Date) - $t0).TotalSeconds
Write-Output "测试终端已退出，用时 $sec 秒"

foreach ($k in $logs.Keys) {
  $f = $logs[$k]
  if (-not (Test-Path $f)) { continue }
  $bytes = [System.IO.File]::ReadAllBytes($f)
  $from = [int]$start[$k]
  if ($bytes.Length -le $from) { continue }
  $chunk = New-Object byte[] ($bytes.Length - $from)
  [Array]::Copy($bytes, $from, $chunk, 0, $chunk.Length)
  [System.IO.File]::WriteAllText((Join-Path $logDir "$k.log"), [System.Text.Encoding]::Unicode.GetString($chunk), [System.Text.Encoding]::UTF8)
}
$rep = Join-Path $data "GridEA_reports\$Name.htm"
if (Test-Path $rep) { Copy-Item $rep $logDir -Force; Write-Output "报告：$rep" } else { Write-Output "没有找到报告：$rep" }
Get-ChildItem $logDir | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Output
