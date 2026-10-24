# GridEA 回测工具

用命令行启动 MT5 策略测试器（`terminal64.exe /config:`）批量回测 GridEA，并自动检查日志。所有脚本只读写测试数据，不会在账户上交易。

**运行前先关掉 MT5 终端**：脚本发现终端在运行时会直接退出，不会关闭你的终端。

## 文件

| 文件 | 作用 |
|---|---|
| `deploy.ps1` | 把 UTF-8 源码转成 UTF-16 放进 MT5 数据目录并编译（`-Kind Scripts` 放进 Scripts） |
| `run_tester.ps1` | 生成配置文件、启动测试器、等结束，把日志和报告复制到 `logs\<场景名>\` |
| `analyze_log.py` | 分析测试代理日志：同一格重复单、挂单参数、交易思路账本、暂缓与补挂、停止、周五平仓时间、每日请求数、报错 |
| `defer_summary.py` | 汇总“额度不足暂缓”的每一段和实际补挂时间 |
| `check_ny_time.py` | 核对实盘用的纽约时间 / 夏令时换算（测试器里测不到） |
| `ExportH1.mq5` | 在测试器里导出 H1 K 线和品种规格，用来挑场景 |
| `FetchTicks.mq5` | 脚本：让终端从服务器下载指定时段的真实 tick（时段写在代码里），完成后自动关闭终端 |
| `scan_h1.py` / `show_days.py` / `show_hours.py` | 浏览导出的 H1 数据 |
| `sets\` | 各场景的参数（`run_tester.ps1` 用的是 MT5 `MQL5\Profiles\Tester\` 里的同名文件） |
| `configs\` | 自动生成的测试器配置文件 |

## 常用命令（PowerShell）

```powershell
cd D:\git\manual_grid\backtest
# 1. 编译 EA
.\deploy.ps1 -Source ..\GridEA.mq5 -TargetRel GridEA.mq5
# 2. 回测（周二开始；Model 4 = 基于真实 tick；-ExecMode -1 = 随机延迟）
.\run_tester.ps1 -Name A_long -Expert GridEA -From 2026.08.25 -To 2026.08.29 -SetFile GridEA_A.set
# 3. 检查（初始余额、总风险%、上限% 与参数一致）
python -I analyze_log.py logs\A_long\agent.log 100000 0.5 0.95
```

`run_tester.ps1` 默认登录 FTMO-Server4 的 541239439（用终端里保存的密码），可用 `-Login`、`-Server` 改。

## 2026-10-24 这一轮的场景

| 场景 | 方向 · 格数 | 时段（服务器时间） | 区间 | 结果 |
|---|---|---|---|---|
| A | 做多 · 手动 5 格 | 2026-08-25 ～ 08-28 | 4580～4680 | 止盈补挂 16 次，周五 8:00（纽约）全平 |
| B | 做空 · 自动（7→5 格） | 2026-07-28 ～ 07-31 | 4020～4120 | 补挂 19 次，周五全平 |
| C | 做多 · 手动 4 格 | 2026-10-20 ～ 10-23 | 4100～4180 | 10-22 打到硬止损 4080，停止后不再挂单 |
| D | 做多 · 自动（4 格） | 2026-08-13 ～ 08-18 | 4320～4400 | 周五全平，下周一、二保持停止 |
| E | 同 A，上限改成 0.51% | 2026-08-25 ～ 08-28 | 4580～4680 | 4 次额度不足暂缓，都在止盈 61 分钟后按时补挂 |
| A_delay | 同 A，随机延迟 | 同 A | 同 A | 无重复单，结果同 A |
