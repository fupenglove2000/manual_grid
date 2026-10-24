# GridEA 回测工具

用命令行启动 MT5 策略测试器（`terminal64.exe /portable /config:`）批量回测 GridEA，并自动检查日志。默认针对便携终端 `D:\MT5\FTMO_A`（回测工具和 tick 数据只放在这个槽位）。所有脚本只读写测试数据，不会在账户上交易。

**运行前先关掉 FTMO_A 的终端**：命令行回测会自己启动这个槽位的终端，同一个文件夹不能同时开两个。脚本发现它在运行时会直接退出，不会关闭你的终端；其他槽位开着没关系。

**只在周末用命令行回测**：测试终端就是 FTMO_A 本身，图表上的实盘 GridEA 会跟着启动；回测结束后终端自动关闭，实盘 EA 也就停了。做完要从快捷方式重新打开 FTMO_A。平时请在运行中的 FTMO_A 里用策略测试器（Ctrl+R）手动回测，不影响实盘 EA。`FetchTicks` 脚本同理：下载完会关闭整个终端。

## 文件

| 文件 | 作用 |
|---|---|
| `deploy.ps1` | 把 UTF-8 源码转成 UTF-16 放进槽位的 `MQL5\` 并用该槽位的 MetaEditor（便携模式）编译。`-Kind Scripts` 放进 Scripts，`-Root` 指定槽位（默认 `D:\MT5\FTMO_A`） |
| `run_tester.ps1` | 生成配置文件、以便携模式启动测试器、等结束，把日志和报告复制到 `logs\<场景名>\`。`-Root` 指定槽位 |
| `GridEA_bt.mq5` | 回测版 EA：包含 `..\GridEA.mq5`，周五平仓后下周开盘自动重开网格（模拟手动重新加载），结束时在日志打印 `BTSTAT` 统计行。部署到 `GridEA_tools\` |
| `run_compare.ps1` | 参数对比回测（2026-09-28～10-22 震荡段）：生成各组 .set，逐组跑 GridEA_bt |
| `compare_summary.py` | 汇总 `logs\cmp_*` 的统计行，输出对比表（Markdown） |
| `analyze_log.py` | 分析测试代理日志：同一格重复单、挂单参数、交易思路账本、暂缓与补挂、停止、周五平仓时间、每日请求数、报错 |
| `defer_summary.py` | 汇总“额度不足暂缓”的每一段和实际补挂时间 |
| `check_ny_time.py` | 核对实盘用的纽约时间 / 夏令时换算（测试器里测不到） |
| `ExportH1.mq5` | 在测试器里导出 H1 K 线和品种规格，用来挑场景 |
| `FetchTicks.mq5` | 脚本：让终端从服务器下载指定时段的真实 tick（时段写在代码里），完成后自动关闭终端 |
| `scan_h1.py` / `show_days.py` / `show_hours.py` | 浏览导出的 H1 数据 |
| `sets\` | 各场景的参数（`run_tester.ps1` 用的是 `D:\MT5\FTMO_A\MQL5\Profiles\Tester\` 里的同名文件，UTF-16 编码） |
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

# 参数对比（先部署 GridEA.mq5，再部署回测版；回测版从上一级目录包含 GridEA.mq5）
.\deploy.ps1 -Source .\GridEA_bt.mq5 -TargetRel GridEA_tools\GridEA_bt.mq5
.\run_compare.ps1                        # 全部组；-Only c_r075 只跑名字含这段的组
python -I compare_summary.py --out=compare_results.md
```

`run_tester.ps1` 默认用槽位终端里保存的账户登录（需要你先在该终端登录过并保存密码），也可以用 `-Login`、`-Server` 指定。

## 2026-10-24 这一轮的场景

| 场景 | 方向 · 格数 | 时段（服务器时间） | 区间 | 结果 |
|---|---|---|---|---|
| A | 做多 · 手动 5 格 | 2026-08-25 ～ 08-28 | 4580～4680 | 止盈补挂 16 次，周五 8:00（纽约）全平 |
| B | 做空 · 自动（7→5 格） | 2026-07-28 ～ 07-31 | 4020～4120 | 补挂 19 次，周五全平 |
| C | 做多 · 手动 4 格 | 2026-10-20 ～ 10-23 | 4100～4180 | 10-22 打到硬止损 4080，停止后不再挂单 |
| D | 做多 · 自动（4 格） | 2026-08-13 ～ 08-18 | 4320～4400 | 周五全平，下周一、二保持停止 |
| E | 同 A，上限改成 0.51% | 2026-08-25 ～ 08-28 | 4580～4680 | 4 次额度不足暂缓，都在止盈 61 分钟后按时补挂 |
| A_delay | 同 A，随机延迟 | 同 A | 同 A | 无重复单，结果同 A |

## 2026-10-25 参数对比（GridEA_bt）

2026-09-28～10-22 震荡段，24 组：
- 核心区间 4066.30～4225.38，16 组：风险 0.5 / 0.75% × 多 / 空 × 周五平仓开 / 关 × 9-28 / 10-15 开始；
- 全段影线高低点 4021.00～4275.05，8 组。

结果和各列的含义见 `compare_results.md`（由 `compare_summary.py` 生成）。
