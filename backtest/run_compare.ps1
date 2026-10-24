# 参数对比回测（2026-09-28 ～ 10-22 XAUUSD 震荡段）：生成各组 .set，逐组跑 GridEA_bt，打印每组的统计行
# 用法：.\run_compare.ps1                 跑全部
#       .\run_compare.ps1 -Only 'c_r075_long_fri1_s1'   只跑名字里含这段的组
# 需要先部署 GridEA.mq5 和 GridEA_bt.mq5（见 README），并关闭 FTMO_A 终端
param(
  [string]$Only = '',
  [string]$Root = 'D:\MT5\FTMO_A',
  [int]$TimeoutMin = 20
)
$ErrorActionPreference = 'Stop'

# 区间：c = 核心震荡区间（9-29～10-21 的 H1 影线高低点），w = 全段影线最高 / 最低（9-28～10-22）
$ranges = [ordered]@{
  c = @{ Upper = '4225.38'; Lower = '4066.30'; Starts = [ordered]@{ s1 = '2026.09.28'; s2 = '2026.10.15' } }
  w = @{ Upper = '4275.05'; Lower = '4021.00'; Starts = [ordered]@{ s1 = '2026.09.28' } }
}
$toDate = '2026.10.23'   # 测试器不含结束日，跑到 10-22 收盘

$groups = @()
foreach ($rk in $ranges.Keys) {
  foreach ($risk in '0.5', '0.75') {
    foreach ($dir in 0, 1) {
      foreach ($fri in 1, 0) {
        foreach ($sk in $ranges[$rk].Starts.Keys) {
          $name = 'cmp_{0}_r{1}_{2}_fri{3}_{4}' -f $rk, ($risk.Replace('.', '').PadRight(3, '0')), ($(if ($dir -eq 0) { 'long' } else { 'short' })), $fri, $sk
          $groups += [pscustomobject]@{ Name = $name; Upper = $ranges[$rk].Upper; Lower = $ranges[$rk].Lower; Risk = $risk
                                        Dir = $dir; Fri = $fri; From = $ranges[$rk].Starts[$sk] }
        }
      }
    }
  }
}
if ($Only) { $groups = @($groups | Where-Object { $_.Name -like "*$Only*" }) }
"共 {0} 组" -f $groups.Count

$setDir = Join-Path $Root 'MQL5\Profiles\Tester'
foreach ($g in $groups) {
  $set = @(
    "InpDirection=$($g.Dir)", "InpUpper=$($g.Upper)", "InpLower=$($g.Lower)", 'InpGrids=0', 'InpAtrPeriod=120',
    'InpAtrMult=1.0', 'InpHardSL=0', 'InpInitBalance=100000', "InpRiskPct=$($g.Risk)", 'InpIdeaCapPct=0.95',
    'InpMagic=20261024', ('InpFridayClose=' + $(if ($g.Fri -eq 1) { 'true' } else { 'false' })), 'InpFridayHourNY=8',
    'InpNoGridAfterSL=true', 'InpNotifyTrades=false', 'InpBtWeeklyRestart=true'
  )
  [System.IO.File]::WriteAllText((Join-Path $setDir "$($g.Name).set"), ($set -join "`r`n") + "`r`n", [System.Text.Encoding]::Unicode)
  $t0 = Get-Date
  & (Join-Path $PSScriptRoot 'run_tester.ps1') -Name $g.Name -Expert 'GridEA_tools\GridEA_bt' -From $g.From -To $toDate `
      -SetFile "$($g.Name).set" -TimeoutMin $TimeoutMin -Root $Root | Out-Null
  $agent = Join-Path $PSScriptRoot "logs\$($g.Name)\agent.log"
  $stat = $(if (Test-Path $agent) { Select-String -Path $agent -Pattern 'BTSTAT (.*)$' | Select-Object -Last 1 } else { $null })
  "{0:HH:mm:ss} {1}（{2:N0} 秒）: {3}" -f (Get-Date), $g.Name, ((Get-Date) - $t0).TotalSeconds, $(if ($stat) { $stat.Matches[0].Groups[1].Value } else { '没有统计行' })
}
