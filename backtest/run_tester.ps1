# GridEA 回测运行脚本（针对便携终端，默认槽位 D:\MT5\FTMO_A）
# 用法示例：
#   .\run_tester.ps1 -Name A_long -Expert GridEA -From 2026.08.25 -To 2026.08.29 -SetFile GridEA_A.set
#   .\run_tester.ps1 -Name export -Expert GridEA_tools\ExportH1 -From 2026.01.01 -To 2026.10.24 -Model 2
# 命令行回测会启动这个槽位的终端，所以运行前必须先关闭该槽位的终端（其他槽位不受影响）。
# 不指定 -Login 时，用该终端里保存的账户登录。
# 生成的配置文件在 backtest\configs\，报告在 <槽位>\GridEA_reports\，日志复制到 backtest\logs\<Name>\
param(
  [Parameter(Mandatory = $true)] [string]$Name,
  [Parameter(Mandatory = $true)] [string]$Expert,     # 相对 MQL5\Experts，不带扩展名
  [Parameter(Mandatory = $true)] [string]$From,       # yyyy.MM.dd
  [Parameter(Mandatory = $true)] [string]$To,
  [int]$Model = 4,                                    # 4 = 基于真实 tick 的每一个点
  [string]$SetFile = "",                              # <槽位>\MQL5\Profiles\Tester\ 下的 .set 文件名
  [int]$TimeoutMin = 9,
  [int]$ExecMode = 0,                                 # 0 = 无延迟，-1 = 随机延迟，>0 = 固定延迟毫秒
  [string]$Root = 'D:\MT5\FTMO_A',                    # 便携终端所在文件夹（槽位）
  [string]$Login = "",                                # 留空 = 用终端里保存的账户
  [string]$Server = ""
)
$ErrorActionPreference = 'Stop'
$term = Join-Path $Root 'terminal64.exe'
if (Get-Process -Name terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $term }) {
  throw "$Root 的终端正在运行，未启动测试（不会关闭你的终端）。请先关闭它再回测"
}

$cfgDir = Join-Path $PSScriptRoot 'configs'
$logDir = Join-Path $PSScriptRoot "logs\$Name"
New-Item -ItemType Directory -Force $cfgDir, $logDir, (Join-Path $Root 'GridEA_reports') | Out-Null

$lines = @()
if ($Login) { $lines += '[Common]', "Login=$Login"; if ($Server) { $lines += "Server=$Server" } }
$lines += @(
  '[Tester]', "Expert=$Expert", 'Symbol=XAUUSD', 'Period=H1', "Model=$Model",
  "ExecutionMode=$ExecMode", 'Optimization=0', "FromDate=$From", "ToDate=$To", 'ForwardMode=0',
  'Deposit=100000', 'Currency=USD', 'Leverage=1:100', 'ProfitInPips=0', 'Visual=0',
  'UseLocal=1', 'UseRemote=0', 'UseCloud=0',
  'ShutdownTerminal=1', 'ReplaceReport=1', "Report=GridEA_reports\$Name"
)
if ($SetFile) { $lines += "ExpertParameters=$SetFile" }
$cfg = Join-Path $cfgDir "$Name.ini"
[System.IO.File]::WriteAllText($cfg, ($lines -join "`r`n") + "`r`n", [System.Text.Encoding]::Unicode)

# 记下各日志文件当前的长度，测试后只取新增部分（便携模式下日志都在槽位文件夹里）
function LogPaths($day) {
  @{
    terminal = Join-Path $Root "logs\$day.log"
    tester   = Join-Path $Root "Tester\logs\$day.log"
    agent    = Join-Path $Root "Tester\Agent-127.0.0.1-3000\logs\$day.log"
  }
}
$today = Get-Date -Format 'yyyyMMdd'
$logs = LogPaths $today
$start = @{}
foreach ($k in $logs.Keys) { $start[$k] = $(if (Test-Path $logs[$k]) { (Get-Item $logs[$k]).Length } else { 0 }) }

$t0 = Get-Date
$p = Start-Process -FilePath $term -ArgumentList '/portable', "/config:`"$cfg`"" -WorkingDirectory $Root -PassThru
if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) {
  Stop-Process -Id $p.Id -Force   # 只结束本脚本自己启动的测试终端
  Write-Output "超时（$TimeoutMin 分钟），已结束本次启动的测试终端"
}
$sec = [int]((Get-Date) - $t0).TotalSeconds
Write-Output "测试终端已退出，用时 $sec 秒"

# 测试跨过本机午夜时，日志会写进新日期的文件：两天的新增部分都取
$endDay = Get-Date -Format 'yyyyMMdd'
$logs2 = $(if ($endDay -ne $today) { LogPaths $endDay } else { @{} })
foreach ($k in $logs.Keys) {
  $text = ''
  $f = $logs[$k]
  if (Test-Path $f) {
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $from = [int]$start[$k]
    if ($bytes.Length -gt $from) { $text = [System.Text.Encoding]::Unicode.GetString($bytes, $from, $bytes.Length - $from) }
  }
  if ($logs2.ContainsKey($k) -and (Test-Path $logs2[$k])) {
    $text += [System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($logs2[$k])).TrimStart([char]0xFEFF)
  }
  if ($text -eq '') { Write-Output "没有找到 $k 日志的新内容：$f"; continue }
  [System.IO.File]::WriteAllText((Join-Path $logDir "$k.log"), $text, [System.Text.Encoding]::UTF8)
}
$rep = Join-Path $Root "GridEA_reports\$Name.htm"
if (Test-Path $rep) { Copy-Item $rep $logDir -Force; Write-Output "报告：$rep" } else { Write-Output "没有找到报告：$rep" }
Get-ChildItem $logDir | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Output
