//+------------------------------------------------------------------+
//|                                                    GridEA.mq5    |
//|        黄金单方向网格 EA（MT5 对冲账户 / FTMO / XAUUSD）          |
//+------------------------------------------------------------------+
//| 规则摘要                                                         |
//|  - 区间 [下沿, 上沿] 等分 N 格（N=0 时按 H1 ATR 自动），只做一个方向 |
//|  - 做多：开仓线 L0..L(N-1) 挂买入限价，止盈 = 上一条线            |
//|  - 做空：开仓线 L1..LN   挂卖出限价，止盈 = 下一条线              |
//|  - 所有单止损 = 同一个硬止损价；止盈止损挂在服务器上，EA 不修改    |
//|  - 每条开仓线同一时间最多一张单（挂单或持仓）                     |
//|  - 手机删任意一张网格挂单 = 撤单并停止（持仓保留）                |
//|  - 手机平任意一张网格持仓 = 全平并停止                            |
//| 多账户：全局变量按“账号 + 魔术号”命名，不用文件，推送带 [账号 xxx] |
//| FTMO：交易思路风险账本（近 61 分钟平仓 + 持仓 + 挂单 ≤ 上限），     |
//|       每日服务器请求计数（当天 1000 次停止网格）                   |
//+------------------------------------------------------------------+
#property copyright   "GridEA"
#property version     "1.00"
#property description "黄金单方向网格 EA：限价单开仓，止盈=相邻网格线，止损=统一硬止损。"
#property description "手机删网格挂单=撤单停止（持仓保留）；手机平网格持仓=全平停止。"

//==================================================================
// 输入参数
//==================================================================
enum ENUM_GRID_DIRECTION
  {
   GRID_LONG  = 0,   // 做多
   GRID_SHORT = 1    // 做空
  };

input ENUM_GRID_DIRECTION InpDirection     = GRID_LONG; // 1. 方向
input double              InpUpper         = 0.0;       // 2. 上沿价格
input double              InpLower         = 0.0;       // 2. 下沿价格
input int                 InpGrids         = 0;         // 3. 格数 N（0=按 H1 ATR 自动，2～10=手动）
input int                 InpAtrPeriod     = 120;       // 3. ATR 周期（固定 H1，自动格数用）
input double              InpAtrMult       = 1.0;       // 3. ATR 倍数（目标格距 = H1 ATR × 倍数）
input double              InpHardSL        = 0.0;       // 4. 硬止损价（0=自动：做多 下沿-1格 / 做空 上沿+1格）
input double              InpInitBalance   = 0.0;       // 5. 账户初始余额（美元，必填，例如 100000）
input double              InpRiskPct       = 0.5;       // 5. 总风险 %（按初始余额；全部成交并打到硬止损时的总亏损）
input double              InpIdeaCapPct    = 0.95;      // 5. 交易思路风险上限 %（按初始余额，必须大于总风险 %）
input long                InpMagic         = 20261024;  // 6. 魔术号
input bool                InpFridayClose   = true;      // 7. 周五平仓
input int                 InpFridayHourNY  = 8;         // 7. 周五平仓时刻（纽约时间，0～16 点）
input bool                InpNoGridAfterSL = true;      // 8. 硬止损后当天（服务器日期）不允许开新网格
input bool                InpNotifyTrades  = false;     // 9. 每次止盈 / 补挂推送手机通知

//==================================================================
// 常量
//==================================================================
#define MAX_GRIDS          10                // 最多格数
#define MAX_LINES          11                // 网格线数组大小（k = 0..10）
#define REQ_PER_SEC        5                 // 所有交易请求合计每秒上限
#define LINE_RETRY_MS      ((ulong)5000)     // 同一条线下单失败后的冷却
#define SYNC_WAIT_MS       ((ulong)5000)     // 连上服务器后等待订单/历史同步的时间
#define TIME_JUMP_MS       ((ulong)30000)    // 两次运行间隔超过它 = 睡眠/卡住，按断线处理
#define ATR_WAIT_MS        ((ulong)60000)    // 自动格数时等待 ATR 数据的最长时间
#define MARKET_WAIT_MS     ((ulong)60000)    // 休市/禁止交易时暂停发请求的时间
#define CANCEL_RESEND_MS   ((ulong)3000)     // 同一张单撤单/平仓请求的重发间隔
#define STOP_PUSH_WAIT_MS  ((ulong)10000)    // 停止动作 10 秒内做完就合并成一条推送
#define UNRESOLVED_WARN_MS ((ulong)120000)   // 单子消失 2 分钟仍查不到结局 → 提醒
#define ERR_PUSH_SEC       600               // 同类错误推送间隔（秒）
#define SELF_CANCEL_KEEP   (14 * 86400)      // EA 自己撤单的记录保留 14 天
#define PUSH_MAX_LEN       255               // MT5 推送每条最多 255 字
#define REQ_DAY_STOP       1000              // 当天交易请求达到这个数 → 停止网格（FTMO 上限 2000）
#define REQ_DAY_HARD       1900              // 绝对上限：达到后不再发送任何请求
#define LINE_RETRY_MAX_MS  ((ulong)300000)   // 同一条线连续失败时，冷却时间最长 5 分钟
#define IDEA_WINDOW_SEC    (61 * 60)         // 交易思路账本：平仓记录保留 61 分钟（60 分钟 + 1 分钟余量）
#define LEDGER_REFRESH_MS  ((ulong)5000)     // 状态面板上账本数字的刷新间隔

// 保存的状态
#define ST_NONE            0
#define ST_RUNNING         1
#define ST_STOPPED         2

// 未完成的停止动作
#define TD_CANCEL          1                 // 待撤本 EA 挂单
#define TD_CLOSE           2                 // 待平本 EA 持仓

// 停止 / 拒绝原因（< 20 为停止，≥ 20 为拒绝开网格）
#define RS_NONE            0
#define RS_HARD_SL_PRICE   1
#define RS_HARD_SL_DEAL    2
#define RS_MANUAL_DELETE   3
#define RS_MANUAL_CLOSE    4
#define RS_FRIDAY          5
#define RS_FRIDAY_MISSED   6
#define RS_UNKNOWN_CLOSE   7
#define RS_STATE_BAD       8
#define RS_REQ_LIMIT       9
#define RS_CAP_INVALID     10
#define RS_REF_PARAMS      20
#define RS_REF_STOPLEVEL   21
#define RS_REF_PRICE_SL    22
#define RS_REF_WEEKEND     23
#define RS_REF_SL_TODAY    24
#define RS_REF_RESIDUAL    25
#define RS_REF_MINLOT      26
#define RS_REF_NARROW      27
#define RS_REF_ATR         28
#define RS_REF_CALC        29
#define RS_REF_REQ_LIMIT   30

// 停止事件（同一轮里可能同时发现多种）
#define EV_DELETE          1                 // 手动删单
#define EV_CLOSE           2                 // 手动平仓
#define EV_SL              4                 // 止损 / 强平
#define EV_UNKNOWN         8                 // 未知原因平仓

// 运行阶段
enum ENUM_PHASE
  {
   PH_WAIT = 0,     // 等待连接/同步
   PH_STARTING,     // 正在开新网格
   PH_RUNNING,      // 运行中
   PH_STOPPED,      // 已停止 / 已拒绝
   PH_PAUSED,       // 暂停（品种不一致 / 同魔术号双开）
   PH_FATAL         // 拒绝运行（非对冲账户）
  };

// 跟踪中的单子：挂单按订单号，持仓按持仓 ID（POSITION_IDENTIFIER）
struct TrackItem
  {
   ulong  id;        // 订单号 / 持仓 ID
   int    line;      // 网格线编号（-1 = 对不上任何线）
   bool   isOrder;   // true=挂单 false=持仓
   bool   live;      // 本轮在服务器列表里看到了
   bool   seen;      // 曾经在列表里看到过
   double vol;       // 上次看到的手数（检测部分平仓）
   ulong  goneMs;    // 从列表消失的时刻（0=没消失）
   bool   warned;    // 已提醒过“查不到结局”
  };

// 本轮发现的停止事件
struct StopEvents
  {
   int    flags;
   string detail;
  };

//==================================================================
// 全局变量
//==================================================================
bool       g_tester          = false;        // 是否在策略测试器里
long       g_login           = 0;            // 账号
string     g_pfx             = "";           // 终端全局变量前缀：GEA_<账号>_<魔术号>_
string     g_acctPfx         = "";           // 按账号的全局变量前缀：GEA_<账号>_（每日请求计数）
string     g_objPfx          = "";           // 图上对象前缀
double     g_instanceId      = 0.0;          // 本实例 ID（防同魔术号双开）
int        g_atrHandle       = INVALID_HANDLE;
ENUM_PHASE g_phase           = PH_WAIT;
string     g_phaseMsg        = "";           // 图上显示的补充说明
bool       g_started         = false;        // Startup 是否已执行
bool       g_pausedBySymbol  = false;        // 暂停原因：图表品种与网格品种不一致
bool       g_pausedByAccount = false;        // 暂停原因：检测到账户切换
int        g_lastDeinit      = -1;           // 上次 OnDeinit 的原因（区分重启 / 改参数）

// 品种属性
double     g_tick            = 0.0;
double     g_volMin          = 0.0;
double     g_volMax          = 0.0;
double     g_volStep         = 0.0;
bool       g_hasSessions     = true;

// 本轮网格
int        g_N               = 0;            // 格数
double     g_step            = 0.0;          // 格距
double     g_sl              = 0.0;          // 硬止损价
double     g_atr             = 0.0;          // 开网格时的 H1 ATR
bool       g_auto            = false;        // 格数是否自动
int        g_N0              = 0;            // 因最小手数减格之前的格数
int        g_nAtr            = 0;            // 按 ATR 算出的格数（截到 10 之前）
double     g_line[MAX_LINES];                // 网格线价格
double     g_lots[MAX_LINES];                // 每条开仓线的手数（按线号）
int        g_kFrom           = 0;            // 开仓线编号范围
int        g_kTo             = -1;
datetime   g_gridStart       = 0;            // 本轮开始时间（服务器时间，已提前 60 秒）
ulong      g_gridStartMs     = 0;
int        g_reason          = RS_NONE;      // 停止 / 拒绝原因
int        g_todo            = 0;            // 未完成的停止动作

// 跟踪
TrackItem  g_trk[];
bool       g_trkChanged      = true;         // 跟踪的单子有增减（成交、止盈、新挂单等）→ 账本要立即重算
ulong      g_doneDeals[];                    // 已处理过的平仓成交
ulong      g_doneOrders[];                   // 已处理过的撤销挂单

// 交易请求节流
ulong      g_reqMs[REQ_PER_SEC];             // 最近 5 次请求的时刻（环形）
int        g_reqIdx          = 0;
ulong      g_lineRetryMs[MAX_LINES];         // 每条线下次允许下单的时刻
int        g_lineBadPrice[MAX_LINES];        // 每条线连续“价格无效”的次数
int        g_lineFails[MAX_LINES];           // 每条线连续下单失败的次数（冷却时间逐次加倍）
ulong      g_waitUntilMs     = 0;            // 休市/禁止交易时暂停到这个时刻
ulong      g_sentTk[];                       // 最近发过撤单/平仓请求的单号
ulong      g_sentMs[];
int        g_fillIdxPending  = 0;            // 挂单当前使用的成交方式候选
int        g_fillIdxMarket   = 0;            // 平仓当前使用的成交方式候选
ENUM_ORDER_TYPE_FILLING g_fillCand[];        // 成交方式候选
ENUM_ORDER_TYPE_TIME    g_timeType = ORDER_TIME_GTC;

// 连接 / 时间
ulong      g_connSinceMs     = 0;
bool       g_wasDisconnected = false;
ulong      g_lastProcMs      = 0;
datetime   g_lastGoodSrv     = 0;            // 最近一次正常运行的服务器时间
datetime   g_lastLRWrite     = 0;
bool       g_needRecovery    = false;
long       g_srvGmtOffset    = 0;            // 服务器时间 - GMT（秒）

// 开网格流程
int        g_startStage      = 0;            // 1=撤旧挂单 2=检查并开网格
ulong      g_startStageMs    = 0;
bool       g_startCloseOld   = false;        // 开新网格前先平掉上一轮（全平类停止）没平完的持仓
int        g_startOldReason  = RS_NONE;      // 上一轮的停止原因
int        g_startClosedOld  = 0;            // 开新网格前平掉的上一轮持仓数量

// 停止推送
bool       g_stopPushPending = false;
bool       g_stopDoneNotify  = false;
string     g_stopText        = "";
string     g_stopHead        = "";
ulong      g_stopStartMs     = 0;
int        g_stopCanceled    = 0;
int        g_stopClosed      = 0;
bool       g_stopCloseAll    = false;

// 推送队列
string     g_pushQ[];
ulong      g_pushSentMs[];                   // 最近 60 秒内的发送时刻
ulong      g_pushNextMs      = 0;            // 下一条最早的发送时刻
string     g_errKey[];
datetime   g_errTime[];
int        g_recTp           = 0;            // 恢复扫描中发现的止盈次数
bool       g_warnedStrayPos  = false;

// 交易思路风险账本（每次现算，不依赖内存）
double     g_ledClosed       = 0.0;          // 近 61 分钟内平仓的持仓的初始风险
double     g_ledPos          = 0.0;          // 当前持仓的风险
double     g_ledOrd          = 0.0;          // 当前挂单的潜在风险
double     g_ledUsed         = 0.0;          // 合计
bool       g_ledOk           = false;        // 最近一次是否算成功
bool       g_ledUnknown      = false;        // 有没设止损的单（按超限处理）
string     g_ledUnknownText  = "";
datetime   g_ledTime[];                      // 近 61 分钟的平仓记录：平仓时间
double     g_ledRisk[];                      //                       初始风险
ulong      g_ledCalcMs       = 0;
datetime   g_statDay         = 0;            // 每日请求统计：当前统计的服务器日
bool       g_lineDeferred[MAX_LINES];        // 因额度不足暂缓的线
datetime   g_lineDeferUntil[MAX_LINES];      // 预计可挂时间（服务器时间；0 = 要等持仓/挂单减少）

//==================================================================
// 基础工具
//==================================================================
// 统一的毫秒时钟：实盘用系统时钟，测试器用模拟时间
ulong NowMs()
  {
   if(g_tester)
      return (ulong)TimeCurrent() * 1000;
   return GetTickCount64();
  }

string P(const double price)
  {
   return DoubleToString(price, _Digits);
  }

int VolDigits()
  {
   int d = 0;
   double s = g_volStep;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-9)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

string V(const double lots)
  {
   return DoubleToString(lots, VolDigits());
  }

bool IsLong()
  {
   return (InpDirection == GRID_LONG);
  }

string DirText()
  {
   return (IsLong() ? "做多" : "做空");
  }

// 价格按 tick size 取整，再规范到报价精度
double NormPrice(const double price)
  {
   double t = (g_tick > 0.0 ? g_tick : _Point);
   return NormalizeDouble(MathRound(price / t) * t, _Digits);
  }

// 手数按步长向下取整（带极小容差，避免 0.05 因浮点误差变成 0.04），不超过最大手数
double FloorLots(const double raw)
  {
   if(g_volStep <= 0.0 || raw <= 0.0)
      return 0.0;
   double lots = MathFloor(raw / g_volStep + 1e-7) * g_volStep;
   if(g_volMax > 0.0 && lots > g_volMax)
      lots = MathFloor(g_volMax / g_volStep + 1e-7) * g_volStep;
   return NormalizeDouble(lots, VolDigits());
  }

// FNV-1a 32 位哈希
uint Fnv1a(const string s)
  {
   uint h = (uint)2166136261;
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      h ^= (uint)StringGetCharacter(s, i);
      h *= (uint)16777619;
     }
   return h;
  }

// 网格参数哈希：方向、上下沿、格数、硬止损、风险%、初始余额；自动格数时再加 ATR 周期和倍数
uint GridHash()
  {
   string s = StringFormat("%d|%.5f|%.5f|%d|%.5f|%.5f|%.2f",
                           (int)InpDirection, InpUpper, InpLower, InpGrids, InpHardSL, InpRiskPct, InpInitBalance);
   if(InpGrids == 0)
      s += StringFormat("|A%d|%.5f", InpAtrPeriod, InpAtrMult);
   return Fnv1a(s);
  }

//==================================================================
// 终端全局变量（按账号 + 魔术号隔离；每个终端本来就各有一份）
//==================================================================
void GVSet(const string key, const double value)
  {
   GlobalVariableSet(g_pfx + key, value);
  }

double GVGet(const string key, const double def)
  {
   double v = 0.0;
   if(GlobalVariableGet(g_pfx + key, v))
      return v;
   return def;
  }

void GVDel(const string key)
  {
   GlobalVariableDel(g_pfx + key);
  }

// 记录“本图表上次运行时的账号”的全局变量名：只含魔术号、不含账号，换了账号也读得到
string AcctMarkName()
  {
   return "GEA_M" + IntegerToString(InpMagic) + "_LOGIN";
  }

// 保存本轮网格的全部状态，并立即写盘
void SaveState(const int st)
  {
   GVSet("St", st);
   GVSet("Rs", g_reason);
   GVSet("Td", g_todo);
   GVSet("Hs", (double)GridHash());
   GVSet("Sy", (double)Fnv1a(_Symbol));
   GVSet("T0", (double)g_gridStart);
   GVSet("LR", (double)TimeTradeServer());
   GVSet("N",  g_N);
   GVSet("Sp", g_step);
   GVSet("SL", g_sl);
   GVSet("At", g_atr);
   GVSet("Au", g_auto ? 1.0 : 0.0);
   GVSet("N0", g_N0);
   GVSet("Na", g_nAtr);
   for(int k = 0; k < MAX_LINES; k++)
      GVSet("L" + IntegerToString(k), g_lots[k]);
   GlobalVariablesFlush();
  }

void SaveTodo()
  {
   GVSet("Td", g_todo);
   GlobalVariablesFlush();
  }

// 清除本账号本魔术号的全部状态，但保留“最近一次硬止损日期”（HD）
void ClearState()
  {
   string keep = g_pfx + "HD";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string nm = GlobalVariableName(i);
      if(StringFind(nm, g_pfx) == 0 && nm != keep)
         GlobalVariableDel(nm);
     }
   GlobalVariablesFlush();
  }

// EA 自己撤单前先记下订单号（订单号写在变量名里，避免 double 精度问题）
void AddSelfCancel(const ulong ticket)
  {
   GlobalVariableSet(g_pfx + "X" + IntegerToString((long)ticket), (double)TimeLocal());
   GlobalVariablesFlush();
  }

bool IsSelfCancel(const ulong ticket)
  {
   return GlobalVariableCheck(g_pfx + "X" + IntegerToString((long)ticket));
  }

// 删除 14 天前的“EA 自己撤单”记录
void PurgeSelfCancel()
  {
   string head = g_pfx + "X";
   double now = (double)TimeLocal();
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string nm = GlobalVariableName(i);
      if(StringFind(nm, head) != 0)
         continue;
      double t = 0.0;
      if(GlobalVariableGet(nm, t) && now - t > SELF_CANCEL_KEEP)
         GlobalVariableDel(nm);
     }
  }

// 同一账号同一魔术号只允许一个图表运行：心跳 HB（本地时间）+ 实例 ID HI
bool OtherInstanceAlive()
  {
   double hi = GVGet("HI", 0.0);
   if(hi == 0.0 || hi == g_instanceId)
      return false;
   double hb = GVGet("HB", 0.0);
   return ((double)TimeLocal() - hb < 10.0);
  }

void HeartBeat()
  {
   GVSet("HI", g_instanceId);
   GVSet("HB", (double)TimeLocal());
  }

void ReleaseInstance()
  {
   if(GVGet("HI", 0.0) == g_instanceId)
     {
      GVDel("HI");
      GVDel("HB");
     }
  }

//==================================================================
// 时间：服务器时间 / GMT / 纽约时间
//==================================================================
// 某年某月第 nth 个周日 00:00
datetime NthSunday(const int year, const int month, const int nth)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = month;
   t.day  = 1;
   datetime d = StructToTime(t);
   MqlDateTime w;
   TimeToStruct(d, w);
   int add = (7 - w.day_of_week) % 7 + 7 * (nth - 1);
   return (datetime)((long)d + (long)add * 86400);
  }

// 美国夏令时（按 GMT 判断）：3 月第 2 个周日 07:00 GMT 至 11 月第 1 个周日 06:00 GMT
bool IsUsDstGmt(const datetime gmt)
  {
   MqlDateTime t;
   TimeToStruct(gmt, t);
   long start = (long)NthSunday(t.year, 3, 2) + 7 * 3600;
   long stop  = (long)NthSunday(t.year, 11, 1) + 6 * 3600;
   return ((long)gmt >= start && (long)gmt < stop);
  }

// 美国夏令时（按纽约本地时间判断，02:00 切换）
bool IsUsDstNy(const datetime ny)
  {
   MqlDateTime t;
   TimeToStruct(ny, t);
   long start = (long)NthSunday(t.year, 3, 2) + 2 * 3600;
   long stop  = (long)NthSunday(t.year, 11, 1) + 2 * 3600;
   return ((long)ny >= start && (long)ny < stop);
  }

// 服务器与 GMT 的时差 = TimeTradeServer() - TimeGMT()，四舍五入到半小时
void UpdateServerOffset()
  {
   if(g_tester)
      return;
   long d = (long)TimeTradeServer() - (long)TimeGMT();
   g_srvGmtOffset = (long)MathRound((double)d / 1800.0) * 1800;
  }

// 服务器时间 → 纽约时间。测试器里 TimeGMT() 等于服务器时间，固定按“服务器 = 纽约 + 7 小时”
datetime ServerToNY(const datetime srv)
  {
   if(g_tester)
      return (datetime)((long)srv - 7 * 3600);
   long gmt = (long)srv - g_srvGmtOffset;
   long off = (IsUsDstGmt((datetime)gmt) ? -4 * 3600 : -5 * 3600);
   return (datetime)(gmt + off);
  }

// 纽约时间 → 服务器时间
datetime NYToServer(const datetime ny)
  {
   if(g_tester)
      return (datetime)((long)ny + 7 * 3600);
   long off = (IsUsDstNy(ny) ? -4 * 3600 : -5 * 3600);
   return (datetime)((long)ny - off + g_srvGmtOffset);
  }

long SecOfDay(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return (long)s.hour * 3600 + s.min * 60 + s.sec;
  }

// 服务器日期（当天 00:00）
datetime ServerDay(const datetime srv)
  {
   return (datetime)((long)srv - SecOfDay(srv));
  }

// 不晚于 ny 的最近一个“周五 H 点”（纽约时间）
long LastFridayNY(const datetime ny)
  {
   MqlDateTime t;
   TimeToStruct(ny, t);
   long day0 = (long)ny - SecOfDay(ny);
   int  back = (t.day_of_week - 5 + 7) % 7;
   long fri  = day0 - (long)back * 86400 + (long)InpFridayHourNY * 3600;
   if(fri > (long)ny)
      fri -= 7 * 86400;
   return fri;
  }

// 最近一次周五平仓时刻（服务器时间）
datetime LastFridayCloseSrv(const datetime srvNow)
  {
   return NYToServer((datetime)LastFridayNY(ServerToNY(srvNow)));
  }

// 是否处于“周五平仓时刻之后 ~ 纽约周日 18:00（黄金开盘）之前”
bool InWeekendBlock(const datetime srvNow)
  {
   datetime ny = ServerToNY(srvNow);
   long fri = LastFridayNY(ny);
   long sunOpen = fri - (long)InpFridayHourNY * 3600 + 2 * 86400 + 18 * 3600;
   return ((long)ny >= fri && (long)ny < sunOpen);
  }

// 下次开盘（纽约周日 18:00）的纽约时间
long NextOpenNY(const datetime srvNow)
  {
   datetime ny = ServerToNY(srvNow);
   long openNy = LastFridayNY(ny) - (long)InpFridayHourNY * 3600 + 2 * 86400 + 18 * 3600;
   if(openNy <= (long)ny)
      openNy += 7 * 86400;
   return openNy;
  }

// 日期时间写成“10-26（周一）01:00”
string FmtDay(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   string wd[7] = {"周日", "周一", "周二", "周三", "周四", "周五", "周六"};
   return StringFormat("%02d-%02d（%s）%02d:%02d", s.mon, s.day, wd[s.day_of_week], s.hour, s.min);
  }

// 周末 / 开盘前拒绝开网格时的说明，注明下次开盘的服务器时间和日本时间
string WeekendRefuseText()
  {
   datetime srv = TimeTradeServer();
   datetime ny  = ServerToNY(srv);
   long openNy  = NextOpenNY(srv);
   // 服务器时间：沿用现在“服务器 − 纽约”的差（FTMO 服务器跟着美国夏令时切换，始终是纽约 + 7 小时）
   datetime srvOpen = (datetime)(openNy + ((long)srv - (long)ny));
   // 日本时间 = GMT + 9 小时（日本没有夏令时）
   long gmtOpen = openNy + (IsUsDstNy((datetime)openNy) ? 4 * 3600 : 5 * 3600);
   datetime jstOpen = (datetime)(gmtOpen + 9 * 3600);
   MqlDateTime t;
   TimeToStruct(ny, t);
   string head = (t.day_of_week == 5 ? StringFormat("周五平仓时刻（纽约 %d:00）已过，", InpFridayHourNY) : "");
   return head + "周末 / 开盘前不开网格，请在开盘后重新加载。下次开盘：服务器时间 " + FmtDay(srvOpen) +
          "，日本时间 " + FmtDay(jstOpen);
  }

// 当前是否在品种的交易时段内（服务器时间）
bool InTradeSession(const datetime srv)
  {
   if(!g_hasSessions)
      return true;
   MqlDateTime t;
   TimeToStruct(srv, t);
   long sec = SecOfDay(srv);
   datetime from = 0, to = 0;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)t.day_of_week, i, from, to))
         break;
      long f = (long)from, e = (long)to;
      if(e > f && sec >= f && sec < e)
         return true;
     }
   return false;
  }

//==================================================================
// 品种属性
//==================================================================
void AddFill(const ENUM_ORDER_TYPE_FILLING f)
  {
   int n = ArraySize(g_fillCand);
   ArrayResize(g_fillCand, n + 1);
   g_fillCand[n] = f;
  }

void LoadSymbolInfo()
  {
   g_tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tick <= 0.0)
      g_tick = _Point;
   g_volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   // 品种没有设置交易时段时，就当一直开市（靠“休市”回报来等待）
   g_hasSessions = false;
   datetime f = 0, t = 0;
   for(int d = 0; d < 7 && !g_hasSessions; d++)
      if(SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, 0, f, t))
         g_hasSessions = true;
   // 成交方式候选：SYMBOL_FILLING_MODE 允许的先试，最后用 RETURN 兜底
   ArrayResize(g_fillCand, 0);
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0)
      AddFill(ORDER_FILLING_FOK);
   if((fm & SYMBOL_FILLING_IOC) != 0)
      AddFill(ORDER_FILLING_IOC);
   AddFill(ORDER_FILLING_RETURN);
   // 挂单有效期：优先 GTC，不支持时退回当日有效
   long em = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((em & SYMBOL_EXPIRATION_GTC) != 0)
      g_timeType = ORDER_TIME_GTC;
   else if((em & SYMBOL_EXPIRATION_DAY) != 0)
      g_timeType = ORDER_TIME_DAY;
   else if((em & SYMBOL_EXPIRATION_SPECIFIED) != 0)
      g_timeType = ORDER_TIME_SPECIFIED;
   else if((em & SYMBOL_EXPIRATION_SPECIFIED_DAY) != 0)
      g_timeType = ORDER_TIME_SPECIFIED_DAY;
   else
      g_timeType = ORDER_TIME_GTC;
  }

// 服务器回报“有效期无效”时换下一种有效期
void NextTimeType()
  {
   long em = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if(g_timeType == ORDER_TIME_GTC && (em & SYMBOL_EXPIRATION_DAY) != 0)
      g_timeType = ORDER_TIME_DAY;
   else if(g_timeType != ORDER_TIME_SPECIFIED && (em & SYMBOL_EXPIRATION_SPECIFIED) != 0)
      g_timeType = ORDER_TIME_SPECIFIED;
   else
      g_timeType = ORDER_TIME_GTC;
  }

// 最小止损距离（价格）
double StopsDist()
  {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
  }

//==================================================================
// 网格线
//==================================================================
// 第 k 条开仓线的止盈价（做多 = 上一条线，做空 = 下一条线）
double TpOf(const int k)
  {
   if(IsLong())
      return g_line[k + 1];
   return g_line[k - 1];
  }

void SetEntryRange(const int n)
  {
   if(IsLong())
     {
      g_kFrom = 0;
      g_kTo   = n - 1;
     }
   else
     {
      g_kFrom = 1;
      g_kTo   = n;
     }
  }

// 解析注释 "G<k>"（后面多出的字符忽略）
int LineFromComment(const string c)
  {
   if(StringLen(c) < 2 || StringGetCharacter(c, 0) != 'G')
      return -1;
   int k = 0, nd = 0;
   int len = StringLen(c);
   for(int i = 1; i < len && nd < 3; i++)
     {
      ushort ch = StringGetCharacter(c, i);
      if(ch < '0' || ch > '9')
         break;
      k = k * 10 + (int)(ch - '0');
      nd++;
     }
   if(nd == 0 || k < g_kFrom || k > g_kTo)
      return -1;
   return k;
  }

// 离 price 最近的开仓线（距离超过 tol 返回 -1）
int LineByPrice(const double price, const double tol)
  {
   int best = -1;
   double bd = DBL_MAX;
   for(int k = g_kFrom; k <= g_kTo; k++)
     {
      double d = MathAbs(price - g_line[k]);
      if(d < bd)
        {
         bd = d;
         best = k;
        }
     }
   if(best >= 0 && bd <= tol)
      return best;
   return -1;
  }

// 挂单属于哪条线：先看注释，再按开仓价
int LineOfOrder(const double price, const string cmt)
  {
   int k = LineFromComment(cmt);
   if(k >= 0)
      return k;
   return LineByPrice(price, g_tick * 0.5 + 1e-9);
  }

// 持仓属于哪条线：先看注释，再按止盈价，最后按开仓价
int LineOfPosition(const double openPrice, const double tp, const string cmt)
  {
   int k = LineFromComment(cmt);
   if(k >= 0)
      return k;
   for(int j = g_kFrom; j <= g_kTo; j++)
      if(MathAbs(tp - TpOf(j)) <= g_tick * 0.5 + 1e-9)
         return j;
   return LineByPrice(openPrice, g_step * 0.5);
  }

string LotsText()
  {
   string s = "";
   for(int k = g_kFrom; k <= g_kTo; k++)
      s += StringFormat("%sG%d %s", (s == "" ? "" : " "), k, V(g_lots[k]));
   return s;
  }

// 格数说明：自动/手动、是否截到上限、是否因最小手数减少
string GridNote()
  {
   if(!g_auto)
      return StringFormat("%d格(手动)", g_N);
   string s = StringFormat("%d格(自动", g_N);
   if(g_nAtr > MAX_GRIDS)
      s += StringFormat(",ATR算出%d格取上限%d", g_nAtr, MAX_GRIDS);
   if(g_N < g_N0)
      s += StringFormat(",因最小手数从%d减为%d", g_N0, g_N);
   return s + ")";
  }

//==================================================================
// ATR、手数、格数
//==================================================================
// 最近一根已收盘 H1 的 ATR（四舍五入到报价精度）；取不到返回 0
double ReadAtr()
  {
   if(g_atrHandle == INVALID_HANDLE)
      return 0.0;
   if(BarsCalculated(g_atrHandle) < InpAtrPeriod + 2)
      return 0.0;
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return 0.0;
   if(buf[0] <= 0.0 || buf[0] == EMPTY_VALUE)
      return 0.0;
   return NormalizeDouble(buf[0], _Digits);
  }

// 从开仓价到硬止损，1 手的亏损额（账户货币）；失败返回 -1
double LossPerLot(const double entry, const double sl)
  {
   double profit = 0.0;
   ENUM_ORDER_TYPE t = (IsLong() ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(t, _Symbol, 1.0, entry, sl, profit))
      return -1.0;
   if(profit >= 0.0)
      return -1.0;
   return -profit;
  }

// 按格数 n 计算网格线、硬止损、每格手数
// 返回 1=全部满足最小手数，0=有格子不足（fail 写明哪格、算出多少），-1=计算失败
int BuildGrid(const int n, double &lines[], double &sl, double &lots[], string &fail)
  {
   fail = "";
   double range = InpUpper - InpLower;
   double step = range / n;
   ArrayInitialize(lines, 0.0);
   ArrayInitialize(lots, 0.0);
   for(int k = 0; k <= n; k++)
      lines[k] = NormPrice(InpLower + step * k);
   lines[n] = NormPrice(InpUpper);
   if(InpHardSL > 0.0)
      sl = NormPrice(InpHardSL);
   else
      sl = (IsLong() ? NormPrice(InpLower - step) : NormPrice(InpUpper + step));
   // 每单风险额 = 账户初始余额 × 总风险% ÷ N
   double risk = InpInitBalance * InpRiskPct / 100.0 / n;
   int kFrom = (IsLong() ? 0 : 1);
   int kTo   = (IsLong() ? n - 1 : n);
   bool ok = true;
   for(int k = kFrom; k <= kTo; k++)
     {
      double lpl = LossPerLot(lines[k], sl);
      if(lpl <= 0.0)
         return -1;
      double raw = risk / lpl;
      lots[k] = FloorLots(raw);
      if(lots[k] < g_volMin - 1e-9)
        {
         ok = false;
         fail += StringFormat("%sG%d %.4f", (fail == "" ? "" : "、"), k, raw);
        }
     }
   return (ok ? 1 : 0);
  }

// 确定格数、格距、硬止损、手数（只在开网格时执行一次）
// 返回 0=成功，-1=等待 ATR 数据，>0=拒绝原因（why 写明）
int ResolveGrid(string &why)
  {
   double lines[MAX_LINES];
   double lots[MAX_LINES];
   double sl = 0.0;
   string fail = "";
   double range = InpUpper - InpLower;
   int n = 0;
   g_atr = ReadAtr();
   if(InpGrids == 0)
     {
      // ① 目标格距 = H1 ATR × 倍数
      if(g_atr <= 0.0)
        {
         if(NowMs() - g_startStageMs < ATR_WAIT_MS)
            return -1;
         why = "H1 ATR 数据未就绪（等待 60 秒仍取不到）";
         return RS_REF_ATR;
        }
      double target = g_atr * InpAtrMult;
      double ratio = range / target;
      // ② 格数 = floor(区间 ÷ 目标格距)（加极小容差，150÷15 不会算成 9）
      g_nAtr = (int)MathFloor(ratio + 1e-9);
      if(g_nAtr < 2)
        {
         why = StringFormat("区间相对波动太窄：区间 %s ÷ 目标格距 %s（H1 ATR %s × %.2f）= %.2f 格，少于 2 格",
                            P(range), P(target), P(g_atr), InpAtrMult, ratio);
         return RS_REF_NARROW;
        }
      // ③ 超过 10 取 10
      n = (g_nAtr > MAX_GRIDS ? MAX_GRIDS : g_nAtr);
      g_N0 = n;
      // ④ 有任何一格低于最小手数 → 格数减 1，重新计算格距、硬止损和全部手数
      string lastFail = "";
      bool ok = false;
      while(n >= 2)
        {
         int r = BuildGrid(n, lines, sl, lots, fail);
         if(r < 0)
           {
            why = "手数计算失败（OrderCalcProfit 失败，可能报价未同步）";
            return RS_REF_CALC;
           }
         if(r > 0)
           {
            ok = true;
            break;
           }
         lastFail = fail;
         n--;
        }
      // ⑤ 少于 2 格 → 拒绝
      if(!ok)
        {
         why = StringFormat("最小手数限制：格数从 %d 减到 2 仍有格子低于 %s 手（2 格时：%s）",
                            g_N0, V(g_volMin), lastFail);
         return RS_REF_MINLOT;
        }
      g_auto = true;
     }
   else
     {
      // 手动格数：不自动调整，手数不足直接拒绝
      n = InpGrids;
      int r = BuildGrid(n, lines, sl, lots, fail);
      if(r < 0)
        {
         why = "手数计算失败（OrderCalcProfit 失败，可能报价未同步）";
         return RS_REF_CALC;
        }
      if(r == 0)
        {
         why = StringFormat("最小手数限制（最小 %s 手）：%s", V(g_volMin), fail);
         return RS_REF_MINLOT;
        }
      g_auto = false;
      g_N0 = n;
      g_nAtr = 0;
     }
   g_N = n;
   g_step = range / n;
   g_sl = sl;
   ArrayCopy(g_line, lines);
   ArrayCopy(g_lots, lots);
   SetEntryRange(n);
   return 0;
  }

//==================================================================
// 统计本品种上的单子
//==================================================================
int CountEaOrders()
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk != 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         c++;
     }
   return c;
  }

int CountEaPositions()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         c++;
     }
   return c;
  }

// 本品种上其他魔术号（含手动开的）的持仓和挂单数量
int CountForeign()
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk != 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) != InpMagic)
         c++;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) != InpMagic)
         c++;
     }
   return c;
  }

//==================================================================
// 推送通知：开头加 [账号 xxx]，每条 ≤ 255 字；MT5 限制每秒 ≤ 2 条、每分钟 ≤ 10 条
//==================================================================
string AcctPrefix()
  {
   long login = (g_login != 0 ? g_login : AccountInfoInteger(ACCOUNT_LOGIN));
   return "[账号 " + IntegerToString(login) + "] ";
  }

string FitPush(const string text)
  {
   string msg = AcctPrefix() + text;
   if(StringLen(msg) > PUSH_MAX_LEN)
      msg = StringSubstr(msg, 0, PUSH_MAX_LEN);
   return msg;
  }

// 写日志并放进推送队列
void Notify(const string text)
  {
   Print(text);
   if(g_tester)
      return;
   int n = ArraySize(g_pushQ);
   ArrayResize(g_pushQ, n + 1);
   g_pushQ[n] = FitPush(text);
  }

// 同类消息 10 分钟内只推送、只写一次日志（很多提醒每个 tick 都会检查，不限流会刷屏）
// 返回 true = 这次发出了；false = 还在 10 分钟限流期内
bool NotifyKey(const string key, const string text)
  {
   datetime now = (g_tester ? TimeCurrent() : TimeLocal());
   int n = ArraySize(g_errKey);
   for(int i = 0; i < n; i++)
     {
      if(g_errKey[i] != key)
         continue;
      if((long)now - (long)g_errTime[i] < ERR_PUSH_SEC)
         return false;
      g_errTime[i] = now;
      Notify(text);
      return true;
     }
   ArrayResize(g_errKey, n + 1);
   ArrayResize(g_errTime, n + 1);
   g_errKey[n]  = key;
   g_errTime[n] = now;
   Notify(text);
   return true;
  }

// 把 next 去掉账号前缀后接到 msg 后面（超过 255 字返回 false）
bool AppendPush(string &msg, const string next)
  {
   string pre = AcctPrefix();
   string body = next;
   if(StringFind(body, pre) == 0)
      body = StringSubstr(body, StringLen(pre));
   if(StringLen(msg) + 3 + StringLen(body) > PUSH_MAX_LEN)
      return false;
   msg += " ‖ " + body;
   return true;
  }

// 按限速发送队列里的推送；积压时合并成一条
void FlushNotify()
  {
   int q = ArraySize(g_pushQ);
   if(q == 0)
      return;
   if(g_tester)
     {
      ArrayResize(g_pushQ, 0);
      return;
     }
   ulong now = GetTickCount64();
   if(now < g_pushNextMs)
      return;
   int keep = 0;
   int ns = ArraySize(g_pushSentMs);
   for(int i = 0; i < ns; i++)
      if(now - g_pushSentMs[i] < 60000)
         g_pushSentMs[keep++] = g_pushSentMs[i];
   ArrayResize(g_pushSentMs, keep);
   if(keep >= 10)
      return;
   string msg = g_pushQ[0];
   int used = 1;
   if(q >= 3 || (q >= 2 && keep >= 7))
      while(used < q && AppendPush(msg, g_pushQ[used]))
         used++;
   ResetLastError();
   if(!SendNotification(msg))
     {
      int err = GetLastError();
      if(err == 4518)   // 推送过于频繁：稍后重发
        {
         g_pushNextMs = now + 5000;
         return;
        }
      PrintFormat("推送失败（错误 %d，请检查 MT5 选项里的推送设置和 MetaQuotes ID）：%s", err, msg);
     }
   ArrayResize(g_pushSentMs, keep + 1);
   g_pushSentMs[keep] = now;
   g_pushNextMs = now + 600;
   int left = q - used;
   for(int i = 0; i < left; i++)
      g_pushQ[i] = g_pushQ[i + used];
   ArrayResize(g_pushQ, left);
  }

// OnDeinit 里直接发送（队列来不及发了）：把队列里剩下的一并合并进去
void SendNow(const string text)
  {
   Print(text);
   if(g_tester)
      return;
   string msg = FitPush(text);
   int q = ArraySize(g_pushQ);
   for(int i = 0; i < q; i++)
      if(!AppendPush(msg, g_pushQ[i]))
         break;
   ArrayResize(g_pushQ, 0);
   if(!SendNotification(msg))
      PrintFormat("推送失败（错误 %d）：%s", GetLastError(), msg);
  }

//==================================================================
// 交易请求
//==================================================================
bool IsOkRet(const uint rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

// 休市 / 禁止交易 / 断线 / 请求过多：暂停一阵，安静等待
bool IsWaitRet(const uint rc)
  {
   return (rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED ||
           rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TOO_MANY_REQUESTS ||
           rc == TRADE_RETCODE_TIMEOUT);
  }

// 偶发的价格类错误：不推送，按冷却时间重试
bool IsQuietRet(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_FROZEN ||
           rc == TRADE_RETCODE_LOCKED || rc == TRADE_RETCODE_INVALID_FILL ||
           rc == TRADE_RETCODE_INVALID_EXPIRATION);
  }

string RetText(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:            return "重新报价";
      case TRADE_RETCODE_REJECT:             return "请求被拒绝";
      case TRADE_RETCODE_TIMEOUT:            return "请求超时";
      case TRADE_RETCODE_INVALID:            return "请求无效";
      case TRADE_RETCODE_INVALID_VOLUME:     return "手数无效";
      case TRADE_RETCODE_INVALID_PRICE:      return "价格无效";
      case TRADE_RETCODE_INVALID_STOPS:      return "止损/止盈无效";
      case TRADE_RETCODE_TRADE_DISABLED:     return "交易被禁止";
      case TRADE_RETCODE_MARKET_CLOSED:      return "休市";
      case TRADE_RETCODE_NO_MONEY:           return "资金不足";
      case TRADE_RETCODE_PRICE_CHANGED:      return "价格已变化";
      case TRADE_RETCODE_PRICE_OFF:          return "没有报价";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "挂单有效期无效";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "请求过于频繁";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "服务器禁止了自动交易";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "终端“算法交易”按钮未开启";
      case TRADE_RETCODE_LOCKED:             return "请求被锁定";
      case TRADE_RETCODE_FROZEN:             return "订单/持仓已冻结";
      case TRADE_RETCODE_INVALID_FILL:       return "不支持的成交方式";
      case TRADE_RETCODE_CONNECTION:         return "与服务器断开";
      case TRADE_RETCODE_LIMIT_ORDERS:       return "挂单数量已达上限";
      case TRADE_RETCODE_LIMIT_VOLUME:       return "总手数已达上限";
      case TRADE_RETCODE_INVALID_ORDER:      return "订单不存在或无效";
      case TRADE_RETCODE_POSITION_CLOSED:    return "持仓已平";
      default:                               return "错误";
     }
  }

// 当天（服务器日期）本账号已发出的交易请求数
int ReqToday()
  {
   if(g_acctPfx == "")
      return 0;
   double d = 0.0, c = 0.0;
   if(!GlobalVariableGet(g_acctPfx + "RQD", d) || (datetime)d != ServerDay(TimeTradeServer()))
      return 0;
   if(!GlobalVariableGet(g_acctPfx + "RQ", c))
      return 0;
   return (int)c;
  }

// 每次真正发往服务器的请求（下单、撤单、平仓、修改）计数 +1：按账号、按服务器日期，存全局变量
void CountRequest()
  {
   if(g_acctPfx == "")
      return;
   int c = ReqToday() + 1;
   GlobalVariableSet(g_acctPfx + "RQD", (double)ServerDay(TimeTradeServer()));
   GlobalVariableSet(g_acctPfx + "RQ", c);
   GlobalVariablesFlush();
  }

// 服务器换日时在日志里记下前一个服务器日的请求总数（EA 重启到了新的一天也会补记一次）
void DailyStatLog()
  {
   if(g_acctPfx == "")
      return;
   datetime today = ServerDay(TimeTradeServer());
   double d = 0.0, c = 0.0;
   bool has = GlobalVariableGet(g_acctPfx + "RQD", d);
   if(g_statDay == 0)
      g_statDay = (has ? (datetime)d : today);
   if(g_statDay == today)
      return;
   int n = 0;
   if(has && (datetime)d == g_statDay && GlobalVariableGet(g_acctPfx + "RQ", c))
      n = (int)c;
   PrintFormat("【统计】服务器日 %s 交易请求 %d 次", TimeToString(g_statDay, TIME_DATE), n);
   g_statDay = today;
  }

// 所有交易请求合计每秒不超过 5 次；当天达到绝对上限后不再发送任何请求
bool CanSend()
  {
   int rq = ReqToday();
   if(rq >= REQ_DAY_HARD)
     {
      NotifyKey("reqhard", StringFormat("今天已发出 %d 次交易请求，接近 FTMO 每天 2000 次上限，EA 不再发送任何请求，请手动处理", rq));
      return false;
     }
   ulong oldest = g_reqMs[g_reqIdx];
   return (oldest == 0 || NowMs() - oldest >= 1000);
  }

void NoteSend()
  {
   g_reqMs[g_reqIdx] = NowMs();
   g_reqIdx = (g_reqIdx + 1) % REQ_PER_SEC;
   CountRequest();
  }

// 同一张单的撤单/平仓请求 3 秒内不重发
bool RecentlySent(const ulong tk)
  {
   ulong now = NowMs();
   for(int i = ArraySize(g_sentTk) - 1; i >= 0; i--)
      if(g_sentTk[i] == tk && now - g_sentMs[i] < CANCEL_RESEND_MS)
         return true;
   return false;
  }

void NoteSent(const ulong tk)
  {
   int n = ArraySize(g_sentTk);
   if(n >= 50)
     {
      for(int i = 0; i < n - 1; i++)
        {
         g_sentTk[i] = g_sentTk[i + 1];
         g_sentMs[i] = g_sentMs[i + 1];
        }
      n--;
     }
   ArrayResize(g_sentTk, n + 1);
   ArrayResize(g_sentMs, n + 1);
   g_sentTk[n] = tk;
   g_sentMs[n] = NowMs();
  }

// 现在能否发交易请求（forNew=true 表示开新单）。不能时安静等待
bool TradeAllowedNow(const bool forNew)
  {
   if(NowMs() < g_waitUntilMs)
      return false;
   if(!g_tester)
     {
      if(TerminalInfoInteger(TERMINAL_CONNECTED) == 0)
         return false;
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
        {
         NotifyKey("algo", "终端“算法交易”按钮没有开启，EA 无法下单/撤单/平仓，请打开");
         return false;
        }
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
        {
         NotifyKey("algo2", "EA 属性里没有勾选“允许算法交易”，EA 无法交易");
         return false;
        }
      if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
        {
         NotifyKey("acctea", "账户不允许 EA 交易");
         return false;
        }
      if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
         return false;
     }
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   if(forNew)
     {
      if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
         return false;
      if(IsLong() && mode == SYMBOL_TRADE_MODE_SHORTONLY)
         return false;
      if(!IsLong() && mode == SYMBOL_TRADE_MODE_LONGONLY)
         return false;
     }
   return InTradeSession(TimeTradeServer());
  }

// 发送交易请求（所有请求都经过这里计数限速）。useFill=true 时自动选择成交方式
bool SendTrade(MqlTradeRequest &req, MqlTradeResult &res, const bool useFill, int &fillIdx)
  {
   ZeroMemory(res);
   int nc = ArraySize(g_fillCand);
   if(useFill && nc > 0)
     {
      if(fillIdx < 0 || fillIdx >= nc)
         fillIdx = 0;
      bool found = false;
      for(int t = 0; t < nc && !found; t++)
        {
         int idx = (fillIdx + t) % nc;
         req.type_filling = g_fillCand[idx];
         MqlTradeCheckResult chk;
         ZeroMemory(chk);
         if(OrderCheck(req, chk) || chk.retcode == 0)
           {
            fillIdx = idx;
            found = true;
           }
         else if(chk.retcode != TRADE_RETCODE_INVALID_FILL)
           {
            // 本地检查（不发到服务器）已发现其他问题：休市、价格无效、资金不足等
            res.retcode = chk.retcode;
            return false;
           }
        }
      if(!found)
         req.type_filling = ORDER_FILLING_RETURN;   // 本地检查都说不支持，交给服务器判断
     }
   NoteSend();
   bool ok = OrderSend(req, res);
   if(useFill && nc > 0 && res.retcode == TRADE_RETCODE_INVALID_FILL)
      fillIdx = (fillIdx + 1) % nc;
   return (ok && IsOkRet(res.retcode));
  }

// 处理下单/撤单/平仓失败。line ≥ 0 时给该线设置冷却：连续失败 5 秒、10 秒、20 秒……最长 5 分钟
void HandleTradeError(const string what, const uint rc, const int line)
  {
   if(line >= 0)
     {
      if(!IsWaitRet(rc))
         g_lineFails[line]++;      // 休市/断线类不累加
      ulong delay = LINE_RETRY_MS;
      for(int i = 1; i < g_lineFails[line] && delay < LINE_RETRY_MAX_MS; i++)
         delay *= 2;
      if(delay > LINE_RETRY_MAX_MS)
         delay = LINE_RETRY_MAX_MS;
      g_lineRetryMs[line] = NowMs() + delay;
     }
   if(IsWaitRet(rc))
     {
      g_waitUntilMs = NowMs() + MARKET_WAIT_MS;
      Print(what, " 暂缓（", RetText(rc), " ", rc, "），稍后自动继续");
      return;
     }
   if(rc == TRADE_RETCODE_CLIENT_DISABLES_AT)
     {
      NotifyKey("algo", "终端“算法交易”按钮没有开启，EA 无法下单/撤单/平仓，请打开");
      return;
     }
   if(rc == TRADE_RETCODE_INVALID_EXPIRATION)
      NextTimeType();
   if(rc == TRADE_RETCODE_INVALID_PRICE && line >= 0)
     {
      g_lineBadPrice[line]++;
      if(g_lineBadPrice[line] < 5)
        {
         Print(what, " 价格无效（价格刚越过这条线），稍后重试");
         return;
        }
     }
   if(IsQuietRet(rc))
     {
      Print(what, " 失败（", RetText(rc), " ", rc, "），稍后重试");
      return;
     }
   string text = StringFormat("%s 失败：%s（%d）", what, RetText(rc), (int)rc);
   if(!NotifyKey("err" + IntegerToString((long)rc), text))
      Print(text);   // 推送在限流期内：日志照写（失败有冷却，不会刷屏）
  }

// 在第 k 条开仓线挂限价单（带止盈止损）
bool PlaceLimit(const int k)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_PENDING;
   req.symbol    = _Symbol;
   req.magic     = (ulong)InpMagic;
   req.volume    = g_lots[k];
   req.price     = g_line[k];
   req.sl        = g_sl;
   req.tp        = TpOf(k);
   req.type      = (IsLong() ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   req.type_time = g_timeType;
   if(g_timeType == ORDER_TIME_SPECIFIED || g_timeType == ORDER_TIME_SPECIFIED_DAY)
      req.expiration = (datetime)((long)TimeTradeServer() + 7 * 86400);
   req.comment   = "G" + IntegerToString(k);
   string kind = (IsLong() ? "Buy Limit" : "Sell Limit");
   string what = StringFormat("挂单 G%d（%s %s %s手）", k, kind, P(g_line[k]), V(g_lots[k]));
   if(SendTrade(req, res, true, g_fillIdxPending))
     {
      g_lineBadPrice[k] = 0;
      g_lineFails[k] = 0;
      if(res.order > 0)
         TrackAdd(res.order, k, true, false, g_lots[k]);   // 立刻占住这条线，防止重复挂单
      else
         g_lineRetryMs[k] = NowMs() + 10000;               // 成功但没拿到单号：等订单列表刷新
      Print(what, " 成功 #", res.order);
      if(InpNotifyTrades && NowMs() - g_gridStartMs > 30000)
         Notify(StringFormat("补挂 G%d %s %s 止盈%s 手数%s", k, kind, P(g_line[k]), P(TpOf(k)), V(g_lots[k])));
      return true;
     }
   HandleTradeError(what, res.retcode, k);
   return false;
  }

// 撤销本 EA 挂单：返回 1=已撤，0=单子已不存在，-1=失败
int CancelOrder(const ulong tk)
  {
   AddSelfCancel(tk);   // 先记下再撤，免得被当成“手动删单”
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action = TRADE_ACTION_REMOVE;
   req.order  = tk;
   int dummy = 0;
   bool ok = SendTrade(req, res, false, dummy);
   NoteSent(tk);
   if(ok)
      return 1;
   if(!OrderSelect(tk))
      return 0;
   HandleTradeError("撤单 #" + IntegerToString((long)tk), res.retcode, -1);
   return -1;
  }

// 平掉本 EA 持仓：返回 1=已平，0=已不存在（例如刚被服务器止损平掉），-1=失败
int ClosePositionTk(const ulong ptk)
  {
   if(!PositionSelectByTicket(ptk))
      return 0;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return -1;
   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.position  = ptk;
   req.volume    = PositionGetDouble(POSITION_VOLUME);
   req.type      = (pt == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   req.price     = (pt == POSITION_TYPE_BUY ? tick.bid : tick.ask);
   req.deviation = 100;
   req.magic     = (ulong)InpMagic;
   req.comment   = "GridEA close";
   bool ok = SendTrade(req, res, true, g_fillIdxMarket);
   NoteSent(ptk);
   if(ok)
      return 1;
   if(res.retcode == TRADE_RETCODE_POSITION_CLOSED || !PositionSelectByTicket(ptk))
      return 0;
   HandleTradeError("平仓 #" + IntegerToString((long)ptk), res.retcode, -1);
   return -1;
  }

// 撤掉本 EA 在本品种上的全部挂单（限速），返回剩余数量（含刚发出请求、还没消失的）
int CancelAllEaOrders(int &cancelled)
  {
   int left = 0;
   bool can = TradeAllowedNow(false);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      left++;
      if(!can || RecentlySent(tk) || !CanSend())
         continue;
      if(CancelOrder(tk) == 1)
         cancelled++;
     }
   return left;
  }

// 平掉本 EA 在本品种上的全部持仓（限速），返回剩余数量
int CloseAllEaPositions(int &closed)
  {
   int left = 0;
   bool can = TradeAllowedNow(false);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      left++;
      if(!can || RecentlySent(tk) || !CanSend())
         continue;
      if(ClosePositionTk(tk) == 1)
         closed++;
     }
   return left;
  }

//==================================================================
// 跟踪本 EA 的挂单和持仓（防重复挂单 + 实时检测手动操作）
//==================================================================
int TrackFind(const ulong id, const bool isOrder)
  {
   for(int i = ArraySize(g_trk) - 1; i >= 0; i--)
      if(g_trk[i].id == id && g_trk[i].isOrder == isOrder)
         return i;
   return -1;
  }

void TrackAdd(const ulong id, const int line, const bool isOrder, const bool seen, const double vol)
  {
   if(TrackFind(id, isOrder) >= 0)
      return;
   int n = ArraySize(g_trk);
   ArrayResize(g_trk, n + 1);
   g_trkChanged     = true;
   g_trk[n].id      = id;
   g_trk[n].line    = line;
   g_trk[n].isOrder = isOrder;
   g_trk[n].live    = false;
   g_trk[n].seen    = seen;
   g_trk[n].vol     = vol;
   g_trk[n].goneMs  = 0;
   g_trk[n].warned  = false;
  }

void TrackRemove(const int i)
  {
   g_trkChanged = true;
   int n = ArraySize(g_trk);
   for(int j = i; j < n - 1; j++)
      g_trk[j] = g_trk[j + 1];
   ArrayResize(g_trk, n - 1);
  }

bool IsDone(const ulong &arr[], const ulong t)
  {
   for(int i = ArraySize(arr) - 1; i >= 0; i--)
      if(arr[i] == t)
         return true;
   return false;
  }

void MarkDone(ulong &arr[], const ulong t)
  {
   int n = ArraySize(arr);
   if(n >= 2000)
     {
      for(int i = 0; i < 1000; i++)
         arr[i] = arr[n - 1000 + i];
      n = 1000;
     }
   ArrayResize(arr, n + 1);
   arr[n] = t;
  }

void AddEvent(StopEvents &ev, const int flag, const string text)
  {
   ev.flags |= flag;
   if(StringLen(ev.detail) < 120)
      ev.detail += (ev.detail == "" ? "" : "；") + text;
  }

string SourceText(const ENUM_DEAL_REASON rs)
  {
   if(rs == DEAL_REASON_MOBILE)
      return "手机";
   if(rs == DEAL_REASON_WEB)
      return "网页端";
   return "电脑终端";
  }

// 对一笔本 EA 持仓的平仓成交分类（第八条）。deal 必须在当前历史选择里
void ClassifyClose(const ulong deal, const int line, StopEvents &ev, const bool recovery)
  {
   ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   double px = HistoryDealGetDouble(deal, DEAL_PRICE);
   double pr = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) +
               HistoryDealGetDouble(deal, DEAL_COMMISSION);
   string g = (line >= 0 ? "G" + IntegerToString(line) : "G?");
   switch(rs)
     {
      case DEAL_REASON_TP:          // 正常止盈：不算停止
         if(recovery)
            g_recTp++;
         else
            if(InpNotifyTrades)
               Notify(StringFormat("止盈 %s @%s 盈亏 %s", g, P(px), DoubleToString(pr, 2)));
            else
               Print("止盈 ", g, " @", P(px), " 盈亏 ", DoubleToString(pr, 2));
         break;
      case DEAL_REASON_EXPERT:      // EA 自己平仓：不算停止
         break;
      case DEAL_REASON_SL:
         AddEvent(ev, EV_SL, StringFormat("%s 被止损 @%s", g, P(px)));
         break;
      case DEAL_REASON_SO:
         AddEvent(ev, EV_SL, StringFormat("%s 被强平(SO) @%s", g, P(px)));
         break;
      case DEAL_REASON_CLIENT:
      case DEAL_REASON_MOBILE:
      case DEAL_REASON_WEB:
         AddEvent(ev, EV_CLOSE, StringFormat("%s 在%s上被手动平仓", g, SourceText(rs)));
         break;
      default:
         AddEvent(ev, EV_UNKNOWN, StringFormat("%s 被未知原因平仓（原因代码 %d）", g, (int)rs));
         break;
     }
  }

// 处理当前历史选择（HistorySelectByPosition 之后）里新的平仓成交，返回处理的笔数
int ProcessOutDeals(const int line, StopEvents &ev)
  {
   int cnt = 0;
   int nd = HistoryDealsTotal();
   for(int d = 0; d < nd; d++)
     {
      ulong dt = HistoryDealGetTicket(d);
      if(dt == 0)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT)
         continue;
      if(IsDone(g_doneDeals, dt))
         continue;
      MarkDone(g_doneDeals, dt);
      ClassifyClose(dt, line, ev, false);
      cnt++;
     }
   return cnt;
  }

void WarnUnresolved(const int i)
  {
   if(g_trk[i].warned || g_trk[i].goneMs == 0 || NowMs() - g_trk[i].goneMs < UNRESOLVED_WARN_MS)
      return;
   g_trk[i].warned = true;
   NotifyKey("unres", StringFormat("G%d 的%s #%s 已从列表消失，但历史里查不到结果，该格暂停补挂",
                                   g_trk[i].line, (g_trk[i].isOrder ? "挂单" : "持仓"),
                                   IntegerToString((long)g_trk[i].id)));
  }

// 已消失的挂单：查历史里的结局。返回 true = 有结论了，可以移出跟踪
bool ResolveOrder(const int i, StopEvents &ev)
  {
   ulong tk = g_trk[i].id;
   int line = g_trk[i].line;
   if(!HistoryOrderSelect(tk))
     {
      WarnUnresolved(i);
      return false;
     }
   ENUM_ORDER_STATE st = (ENUM_ORDER_STATE)HistoryOrderGetInteger(tk, ORDER_STATE);
   double vInit = HistoryOrderGetDouble(tk, ORDER_VOLUME_INITIAL);
   double vCur  = HistoryOrderGetDouble(tk, ORDER_VOLUME_CURRENT);
   if(st == ORDER_STATE_FILLED)
     {
      TrackAdd(tk, line, false, false, vInit);            // 成交了：持仓 ID = 挂单单号，继续占住这条线
      return true;
     }
   if(st == ORDER_STATE_CANCELED)
     {
      if(vInit - vCur > 1e-8)
         TrackAdd(tk, line, false, false, vInit - vCur);  // 部分成交后被撤：剩下的持仓继续跟踪
      if(!IsSelfCancel(tk) && !IsDone(g_doneOrders, tk))
        {
         MarkDone(g_doneOrders, tk);
         AddEvent(ev, EV_DELETE, StringFormat("G%d 挂单被手动删除", line));
        }
      return true;
     }
   if(st == ORDER_STATE_EXPIRED || st == ORDER_STATE_REJECTED)
      return true;                                        // 到期/被拒：这条线空出来，之后正常补挂
   WarnUnresolved(i);
   return false;                                          // 过渡状态，下一轮再看
  }

// 已消失的持仓：查它的成交。返回 true = 已全部平仓且处理完
bool ResolvePosition(const int i, StopEvents &ev)
  {
   ulong pid = g_trk[i].id;
   if(!HistorySelectByPosition(pid))
     {
      WarnUnresolved(i);
      return false;
     }
   double vin = 0.0, vout = 0.0;
   int nd = HistoryDealsTotal();
   for(int d = 0; d < nd; d++)
     {
      ulong dt = HistoryDealGetTicket(d);
      if(dt == 0)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      double v = HistoryDealGetDouble(dt, DEAL_VOLUME);
      if(en == DEAL_ENTRY_IN)
         vin += v;
      else
         if(en == DEAL_ENTRY_OUT || en == DEAL_ENTRY_OUT_BY || en == DEAL_ENTRY_INOUT)
            vout += v;
     }
   if(vin <= 0.0 || vout < vin - 1e-8)
     {
      WarnUnresolved(i);   // 历史还没同步完：先不当成空线
      return false;
     }
   ProcessOutDeals(g_trk[i].line, ev);
   return true;
  }

// 同步服务器上的本 EA 挂单/持仓到各条线；处理消失的单子
void SyncTracking(StopEvents &ev)
  {
   ulong now = NowMs();
   int n0 = ArraySize(g_trk);
   for(int i = 0; i < n0; i++)
      g_trk[i].live = false;
   // 本 EA 挂单
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      int idx = TrackFind(tk, true);
      if(idx < 0)
        {
         TrackAdd(tk, LineOfOrder(OrderGetDouble(ORDER_PRICE_OPEN), OrderGetString(ORDER_COMMENT)),
                  true, true, OrderGetDouble(ORDER_VOLUME_CURRENT));
         idx = ArraySize(g_trk) - 1;
        }
      g_trk[idx].live   = true;
      g_trk[idx].seen   = true;
      g_trk[idx].goneMs = 0;
     }
   // 本 EA 持仓（按持仓 ID 跟踪）
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      ulong  pid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double vol = PositionGetDouble(POSITION_VOLUME);
      int idx = TrackFind(pid, false);
      bool updateVol = true;
      if(idx < 0)
        {
         TrackAdd(pid, LineOfPosition(PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_TP),
                                      PositionGetString(POSITION_COMMENT)), false, true, vol);
         idx = ArraySize(g_trk) - 1;
        }
      else
         if(g_trk[idx].seen && vol < g_trk[idx].vol - 1e-8)
           {
            // 手数变少 = 部分平仓：查新增的平仓成交（手动部分平仓也算手动平仓）
            int line = g_trk[idx].line;
            updateVol = (HistorySelectByPosition(pid) && ProcessOutDeals(line, ev) > 0);
           }
      g_trk[idx].live   = true;
      g_trk[idx].seen   = true;
      g_trk[idx].goneMs = 0;
      if(updateVol)
         g_trk[idx].vol = vol;
     }
   // 已从列表消失的单子：查到结局之前这条线仍算“有单”
   for(int i = ArraySize(g_trk) - 1; i >= 0; i--)
     {
      if(g_trk[i].live)
         continue;
      if(g_trk[i].goneMs == 0)
         g_trk[i].goneMs = now;
      bool done = (g_trk[i].isOrder ? ResolveOrder(i, ev) : ResolvePosition(i, ev));
      if(done)
         TrackRemove(i);
     }
  }

// 清理对不上网格线的本 EA 挂单、同一条线上多出来的挂单（理论上不会发生）
void CleanupStrayOrders()
  {
   int n = ArraySize(g_trk);
   for(int i = 0; i < n; i++)
     {
      if(!g_trk[i].isOrder || !g_trk[i].live)
         continue;
      bool extra = (g_trk[i].line < 0);
      for(int j = 0; j < n && !extra; j++)
         if(j != i && g_trk[j].isOrder && g_trk[j].live && g_trk[j].line == g_trk[i].line && g_trk[j].id < g_trk[i].id)
            extra = true;   // 同一条线保留早的、撤掉晚的
      if(!extra || RecentlySent(g_trk[i].id) || !CanSend() || !TradeAllowedNow(false))
         continue;
      Print("撤掉多余/对不上网格线的挂单 #", g_trk[i].id);
      CancelOrder(g_trk[i].id);
     }
   if(g_warnedStrayPos)
      return;
   for(int i = 0; i < n; i++)
      if(!g_trk[i].isOrder && g_trk[i].live && g_trk[i].line < 0)
        {
         g_warnedStrayPos = true;
         Notify(StringFormat("注意：本 EA 持仓 #%s 对不上任何网格线（不影响运行）", IntegerToString((long)g_trk[i].id)));
         break;
        }
  }

// 第 k 条线是否在“能挂限价单的一侧”，且离现价满足最小止损距离
bool Placeable(const int k, const MqlTick &tick)
  {
   double dist = StopsDist();
   if(IsLong())
      return (g_line[k] < tick.ask && tick.ask - g_line[k] >= dist);
   return (g_line[k] > tick.bid && g_line[k] - tick.bid >= dist);
  }

//==================================================================
// FTMO 交易思路风险账本
//   已用风险 = 近 61 分钟内平仓的持仓的初始风险 + 当前持仓的风险 + 当前挂单的潜在风险
//   本品种上的所有单都算（含手动单和其他魔术号）；没设止损的单按超限处理
//   每次现算（交易历史 + 当前持仓/挂单），不依赖内存，重启后自然完整
//==================================================================
double IdeaCap()
  {
   return InpInitBalance * InpIdeaCapPct / 100.0;
  }

bool CapValid()
  {
   return (InpIdeaCapPct > 0.0 && InpIdeaCapPct <= 1.0 && InpRiskPct < InpIdeaCapPct);
  }

string CapInvalidText()
  {
   return StringFormat("交易思路风险上限 %.2f%% 必须大于总风险 %.2f%%，且不超过 1%%", InpIdeaCapPct, InpRiskPct);
  }

// 从 price 到 sl、volume 手的亏损额；止损在盈利一侧时为 0；计算失败返回 -1
double CalcRisk(const bool isBuy, const double volume, const double price, const double sl)
  {
   double profit = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, volume, price, sl, profit))
      return -1.0;
   return (profit < 0.0 ? -profit : 0.0);
  }

// 本 EA 第 k 条开仓线一张单的潜在风险
double LineRisk(const int k)
  {
   return CalcRisk(IsLong(), g_lots[k], g_line[k], g_sl);
  }

bool IsBuyOrderType(const ENUM_ORDER_TYPE t)
  {
   return (t == ORDER_TYPE_BUY || t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT);
  }

// 已平仓持仓的初始风险：开仓价、开仓手数、开仓时的止损（开仓时没有止损就用平仓时的止损）
// 返回 ≥0 = 风险；-1 = 没有止损；-2 = 读取失败。会重置历史选择
double ClosedPositionRisk(const ulong pid)
  {
   if(!HistorySelectByPosition(pid))
      return -2.0;
   double vin = 0.0, pxv = 0.0, slIn = 0.0, slOut = 0.0;
   bool isBuy = true;
   int nd = HistoryDealsTotal();
   for(int d = 0; d < nd; d++)
     {
      ulong dt = HistoryDealGetTicket(d);
      if(dt == 0)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      double sl = HistoryDealGetDouble(dt, DEAL_SL);
      if(en == DEAL_ENTRY_IN)
        {
         double v = HistoryDealGetDouble(dt, DEAL_VOLUME);
         vin += v;
         pxv += v * HistoryDealGetDouble(dt, DEAL_PRICE);
         isBuy = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(dt, DEAL_TYPE) == DEAL_TYPE_BUY);
         if(slIn <= 0.0)
            slIn = sl;
        }
      else
         if(slOut <= 0.0)
            slOut = sl;
     }
   if(vin <= 0.0)
      return -2.0;
   double useSl = (slIn > 0.0 ? slIn : slOut);
   if(useSl <= 0.0)
      return -1.0;
   double r = CalcRisk(isBuy, vin, pxv / vin, useSl);
   return (r < 0.0 ? -2.0 : r);
  }

void MarkUnknown(const string text)
  {
   g_ledUnknown = true;
   if(g_ledUnknownText == "")
      g_ledUnknownText = text;
  }

// 计算交易思路账本，结果放在 g_led* 里。返回 false = 读取或计算失败（这一轮不挂单）
bool ComputeLedger()
  {
   g_ledCalcMs = NowMs();
   g_ledOk = false;
   g_ledClosed = 0.0;
   g_ledPos = 0.0;
   g_ledOrd = 0.0;
   g_ledUsed = 0.0;
   g_ledUnknown = false;
   g_ledUnknownText = "";
   ArrayResize(g_ledTime, 0);
   ArrayResize(g_ledRisk, 0);
   datetime now  = TimeTradeServer();
   datetime from = (datetime)((long)now - IDEA_WINDOW_SEC);
   // 当前持仓的持仓 ID（本品种，所有魔术号）
   ulong openPid[];
   int nOpen = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ArrayResize(openPid, nOpen + 1);
      openPid[nOpen] = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      nOpen++;
     }
   // 1) 近 61 分钟的平仓成交，按持仓 ID 汇总（先收集，后面再逐个查开仓信息）
   if(!HistorySelect(from, (datetime)((long)now + 86400)))
      return false;
   ulong    outPid[];
   datetime outTime[];
   double   outVol[];
   int nOut = 0;
   int nd = HistoryDealsTotal();
   for(int i = 0; i < nd; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT)
         continue;
      datetime t = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
      if(t < from)
         continue;
      ulong  pid = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
      double v   = HistoryDealGetDouble(dt, DEAL_VOLUME);
      int idx = -1;
      for(int j = 0; j < nOut && idx < 0; j++)
         if(outPid[j] == pid)
            idx = j;
      if(idx < 0)
        {
         ArrayResize(outPid, nOut + 1);
         ArrayResize(outTime, nOut + 1);
         ArrayResize(outVol, nOut + 1);
         outPid[nOut]  = pid;
         outTime[nOut] = t;
         outVol[nOut]  = v;
         nOut++;
        }
      else
        {
         if(t > outTime[idx])
            outTime[idx] = t;
         outVol[idx] += v;
        }
     }
   // 2) 已经全部平掉的持仓：按开仓时的初始风险记一笔，平仓满 61 分钟后滑出
   for(int i = 0; i < nOut; i++)
     {
      bool stillOpen = false;
      for(int j = 0; j < nOpen && !stillOpen; j++)
         if(openPid[j] == outPid[i])
            stillOpen = true;
      if(stillOpen)
         continue;                  // 部分平仓、还开着的：在持仓里按开仓手数算
      double r = ClosedPositionRisk(outPid[i]);
      if(r <= -2.0)
         return false;
      if(r < 0.0)
        {
         MarkUnknown("近 61 分钟平掉的持仓 #" + IntegerToString((long)outPid[i]) + " 没有止损");
         continue;
        }
      int nr = ArraySize(g_ledTime);
      ArrayResize(g_ledTime, nr + 1);
      ArrayResize(g_ledRisk, nr + 1);
      g_ledTime[nr] = outTime[i];
      g_ledRisk[nr] = r;
      g_ledClosed += r;
     }
   // 3) 当前持仓：按服务器上当前的止损价；近 61 分钟内部分平掉的手数也加回去
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
        {
         MarkUnknown("持仓 #" + IntegerToString((long)tk) + " 没有止损");
         continue;
        }
      ulong  pid = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      double vol = PositionGetDouble(POSITION_VOLUME);
      for(int j = 0; j < nOut; j++)
         if(outPid[j] == pid)
            vol += outVol[j];
      bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double r = CalcRisk(isBuy, vol, PositionGetDouble(POSITION_PRICE_OPEN), sl);
      if(r < 0.0)
         return false;
      g_ledPos += r;
     }
   // 4) 当前挂单
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY || ot == ORDER_TYPE_SELL)
         continue;                  // 正在执行的市价单：成交后会出现在持仓里
      double sl = OrderGetDouble(ORDER_SL);
      if(sl <= 0.0)
        {
         MarkUnknown("挂单 #" + IntegerToString((long)tk) + " 没有止损");
         continue;
        }
      double px = OrderGetDouble(ORDER_PRICE_OPEN);
      double pxLimit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      if((ot == ORDER_TYPE_BUY_STOP_LIMIT || ot == ORDER_TYPE_SELL_STOP_LIMIT) && pxLimit > 0.0)
         px = pxLimit;
      double r = CalcRisk(IsBuyOrderType(ot), OrderGetDouble(ORDER_VOLUME_CURRENT), px, sl);
      if(r < 0.0)
         return false;
      g_ledOrd += r;
     }
   // 5) 本 EA 刚下但还没出现在列表里、或已从列表消失但还没查到结局的单：按这条线的风险计入
   int nt = ArraySize(g_trk);
   for(int i = 0; i < nt; i++)
     {
      if(g_trk[i].live || g_trk[i].line < g_kFrom || g_trk[i].line > g_kTo)
         continue;
      double r = LineRisk(g_trk[i].line);
      if(r < 0.0)
         return false;
      if(g_trk[i].isOrder)
         g_ledOrd += r;
      else
         g_ledPos += r;
     }
   g_ledUsed = g_ledClosed + g_ledPos + g_ledOrd;
   g_ledOk = true;
   return true;
  }

// 额度不足暂缓第 k 格：按平仓记录逐笔滑出算出预计可挂时间，推送说明（同一格 10 分钟内最多一次）
void DeferLine(const int k, const double r, const double cap)
  {
   double need = g_ledUsed + r - cap;   // 需要滑出的风险
   int n = ArraySize(g_ledTime);
   for(int i = 1; i < n; i++)           // 按平仓时间从早到晚排序
      for(int j = i; j > 0 && g_ledTime[j] < g_ledTime[j - 1]; j--)
        {
         datetime tt = g_ledTime[j];
         g_ledTime[j] = g_ledTime[j - 1];
         g_ledTime[j - 1] = tt;
         double rr = g_ledRisk[j];
         g_ledRisk[j] = g_ledRisk[j - 1];
         g_ledRisk[j - 1] = rr;
        }
   datetime when = 0;
   double freed = 0.0;
   for(int i = 0; i < n && when == 0; i++)
     {
      freed += g_ledRisk[i];
      if(freed >= need - 1e-6)
         when = (datetime)((long)g_ledTime[i] + IDEA_WINDOW_SEC);
     }
   g_lineDeferred[k] = true;
   g_lineDeferUntil[k] = when;
   string eta = "要等现有持仓/挂单减少后才能挂";
   if(when > 0)
     {
      datetime localWhen = (datetime)((long)when - ((long)TimeTradeServer() - (long)TimeLocal()));
      eta = "预计服务器时间 " + TimeToString(when, TIME_MINUTES) + "（本机 " + TimeToString(localWhen, TIME_MINUTES) + "）可挂";
     }
   NotifyKey("idea" + IntegerToString(k),
             StringFormat("交易思路额度不足，G%d 暂缓补挂：已用 %s（近61分钟平仓 %s + 持仓 %s + 挂单 %s）+ 本单 %s = %s > 上限 %s；%s",
                          k, DoubleToString(g_ledUsed, 2), DoubleToString(g_ledClosed, 2), DoubleToString(g_ledPos, 2),
                          DoubleToString(g_ledOrd, 2), DoubleToString(r, 2), DoubleToString(g_ledUsed + r, 2),
                          DoubleToString(cap, 2), eta));
  }

// 补挂：开仓线既没有挂单也没有持仓、且在可挂一侧 → 先查交易思路账本，额度够才挂
//（离价格近的先判断，逐格独立：额度够哪格就挂哪格）
void PlaceMissing(const MqlTick &tick)
  {
   bool occ[MAX_LINES];
   for(int k = 0; k < MAX_LINES; k++)
      occ[k] = false;
   int n = ArraySize(g_trk);
   for(int i = 0; i < n; i++)
      if(g_trk[i].line >= 0 && g_trk[i].line < MAX_LINES)
         occ[g_trk[i].line] = true;
   for(int k = 0; k < MAX_LINES; k++)
      g_lineDeferred[k] = false;    // 每轮重新判断哪些格因额度不足暂缓
   if(!TradeAllowedNow(true))
      return;
   int cand[];
   int nc = 0;
   ulong now = NowMs();
   for(int j = 0; j < g_N; j++)
     {
      int k = (IsLong() ? g_kTo - j : g_kFrom + j);
      if(occ[k] || now < g_lineRetryMs[k] || !Placeable(k, tick))
         continue;
      ArrayResize(cand, nc + 1);
      cand[nc] = k;
      nc++;
     }
   if(nc == 0)
      return;
   // 单子有变化就立即重算账本；没变化时（例如长时间暂缓）最多每秒重算一次
   if(!g_ledOk || g_trkChanged || NowMs() - g_ledCalcMs >= 1000)
     {
      g_trkChanged = false;
      if(!ComputeLedger())
         return;                    // 历史读取/计算失败：这一轮先不挂
     }
   if(g_ledUnknown)
     {
      NotifyKey("ideanosl", _Symbol + " 上有没设止损的单（" + g_ledUnknownText + "），交易思路风险无法计算，网格暂停补挂");
      return;
     }
   double cap = IdeaCap();
   for(int i = 0; i < nc; i++)
     {
      int k = cand[i];
      double r = LineRisk(k);
      if(r < 0.0)
         continue;
      if(g_ledUsed + r > cap + 1e-6)
        {
         DeferLine(k, r, cap);      // 额度不足：这一格先不挂，等最早的平仓记录滑出
         continue;
        }
      if(!CanSend())
         return;
      if(PlaceLimit(k))
        {
         PrintFormat("  交易思路：已用 %.2f（平仓 %.2f + 持仓 %.2f + 挂单 %.2f）+ 本单 %.2f = %.2f ≤ 上限 %.2f",
                     g_ledUsed, g_ledClosed, g_ledPos, g_ledOrd, r, g_ledUsed + r, cap);
         g_ledUsed += r;
         g_ledOrd  += r;
         g_lineDeferred[k] = false;
        }
     }
  }

//==================================================================
// 停止
//==================================================================
string ReasonText(const int rs)
  {
   switch(rs)
     {
      case RS_HARD_SL_PRICE: return "硬止损（价格触及止损线）";
      case RS_HARD_SL_DEAL:  return "硬止损（持仓被止损/强平）";
      case RS_MANUAL_DELETE: return "手动删单";
      case RS_MANUAL_CLOSE:  return "手动平仓";
      case RS_FRIDAY:        return "周五平仓";
      case RS_FRIDAY_MISSED: return "补执行周五平仓（周五平仓时刻 EA 没在运行）";
      case RS_UNKNOWN_CLOSE: return "持仓被未知原因平仓";
      case RS_STATE_BAD:     return "保存的状态数据不完整";
      case RS_REQ_LIMIT:     return "当天交易请求数达到 1000 次";
      case RS_CAP_INVALID:   return "交易思路风险上限设置不合法";
      case RS_REF_PARAMS:    return "参数不合法";
      case RS_REF_STOPLEVEL: return "格距/止损距离小于最小止损距离";
      case RS_REF_PRICE_SL:  return "价格已越过硬止损";
      case RS_REF_WEEKEND:   return "周末 / 开盘前不开网格";
      case RS_REF_SL_TODAY:  return "今天已发生过硬止损";
      case RS_REF_RESIDUAL:  return "本 EA 还有残留持仓";
      case RS_REF_MINLOT:    return "最小手数限制";
      case RS_REF_NARROW:    return "区间相对波动太窄";
      case RS_REF_ATR:       return "H1 ATR 数据未就绪";
      case RS_REF_CALC:      return "手数计算失败";
      case RS_REF_REQ_LIMIT: return "当天交易请求数已达 1000 次";
      default:               return "未知";
     }
  }

// 停止原因是否属于“全平”类：硬止损、手机平仓、周五平仓（含补执行）
// 其余（手机删单、移除 EA、不明原因平仓、请求数达上限、拒绝开网格、没有停止原因）都属于“保留持仓”类
bool IsCloseAllReason(const int rs)
  {
   return (rs == RS_HARD_SL_PRICE || rs == RS_HARD_SL_DEAL || rs == RS_MANUAL_CLOSE ||
           rs == RS_FRIDAY || rs == RS_FRIDAY_MISSED);
  }

string StopSummary(const bool done)
  {
   string s = (g_stopHead != "" ? g_stopHead + "，" : "") + "网格已停止 —— " + g_stopText + "。";
   if(!done)
      return s + "正在撤单" + (g_stopCloseAll ? "/平仓" : "") + "（休市或失败时开市后自动继续）";
   s += StringFormat("已撤挂单 %d 张", g_stopCanceled);
   if(g_stopCloseAll)
      s += StringFormat("，已平仓 %d 张", g_stopClosed);
   else
      s += StringFormat("，持仓 %d 张保留（各带止盈止损）", CountEaPositions());
   if(g_reason == RS_UNKNOWN_CLOSE)
      s += "。请人工检查";
   return s;
  }

// 继续执行未完成的停止动作（先撤挂单，再平持仓），完成时推送
void ContinueStopActions()
  {
   if((g_todo & TD_CANCEL) != 0)
     {
      if(CancelAllEaOrders(g_stopCanceled) == 0)
        {
         g_todo &= ~TD_CANCEL;
         SaveTodo();
        }
     }
   if((g_todo & TD_CANCEL) == 0 && (g_todo & TD_CLOSE) != 0)
     {
      if(CloseAllEaPositions(g_stopClosed) == 0)
        {
         g_todo &= ~TD_CLOSE;
         SaveTodo();
        }
     }
   if(g_stopPushPending)
     {
      if(g_todo == 0)
        {
         Notify(StopSummary(true));
         g_stopPushPending = false;
        }
      else
         if(NowMs() - g_stopStartMs > STOP_PUSH_WAIT_MS)
           {
            Notify(StopSummary(false));
            g_stopPushPending = false;
            g_stopDoneNotify = true;
           }
     }
   else
      if(g_stopDoneNotify && g_todo == 0)
        {
         g_stopDoneNotify = false;
         Notify(StringFormat("停止动作已完成（%s）：共撤挂单 %d 张，平仓 %d 张", g_stopText, g_stopCanceled, g_stopClosed));
        }
  }

// 停止：先存盘（状态=已停止 + 待办动作），再撤单/平仓；没做完的下一轮继续
void StopGrid(const int code, const bool closeAll, const bool hard, const string detail)
  {
   if(g_phase == PH_STOPPED)
      return;
   g_reason = code;
   g_todo = TD_CANCEL | (closeAll ? TD_CLOSE : 0);
   if(hard)
      GVSet("HD", (double)ServerDay(TimeTradeServer()));   // 记录“今天发生过硬止损”
   SaveState(ST_STOPPED);
   g_phase = PH_STOPPED;
   g_phaseMsg = "如需重新开网格：移除 EA 后重新加载，或修改网格参数";
   ArrayResize(g_trk, 0);
   g_stopText = ReasonText(code) + (detail != "" ? "：" + detail : "");
   g_stopCloseAll = closeAll;
   g_stopCanceled = 0;
   g_stopClosed = 0;
   g_stopPushPending = true;
   g_stopDoneNotify = false;
   g_stopStartMs = NowMs();
   Print("网格停止 —— ", g_stopText);
   DrawGrid(true);
   ContinueStopActions();
  }

// 根据本轮发现的事件停止：有手动平仓或止损 → 全平；只有删单/未知原因 → 撤单、保留持仓
void ExecuteEvents(const StopEvents &ev)
  {
   if(ev.flags == 0)
      return;
   bool hard = ((ev.flags & EV_SL) != 0);
   bool closeAll = ((ev.flags & (EV_CLOSE | EV_SL)) != 0);
   int code = RS_MANUAL_DELETE;
   if((ev.flags & EV_CLOSE) != 0)
      code = RS_MANUAL_CLOSE;
   else
      if(hard)
         code = RS_HARD_SL_DEAL;
      else
         if((ev.flags & EV_UNKNOWN) != 0)
            code = RS_UNKNOWN_CLOSE;
   StopGrid(code, closeAll, hard, ev.detail);
  }

//==================================================================
// 历史扫描（重启 / 断线重连 / 睡眠唤醒后执行）
//==================================================================
// 扫描本轮网格开始以来的全部历史，按第七条规则找出手动平仓、手动删单、止损/强平
bool ScanGridHistory(StopEvents &ev)
  {
   if(g_gridStart <= 0)
      return true;
   if(!HistorySelect(g_gridStart, (datetime)((long)TimeTradeServer() + 86400)))
      return false;
   // 1) 本轮网格的持仓：开仓成交（DEAL_ENTRY_IN）的魔术号 = 本 EA，且开仓时间不早于本轮开始
   ulong ownPid[];
   int   ownLine[];
   int   nOwn = 0;
   int nd = HistoryDealsTotal();
   for(int i = 0; i < nd; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      if(HistoryDealGetInteger(dt, DEAL_MAGIC) != InpMagic)
         continue;
      if((datetime)HistoryDealGetInteger(dt, DEAL_TIME) < g_gridStart)
         continue;
      double px = HistoryDealGetDouble(dt, DEAL_PRICE);
      int line = LineOfOrder(px, HistoryDealGetString(dt, DEAL_COMMENT));
      if(line < 0)
         line = LineByPrice(px, g_step * 0.5);
      ArrayResize(ownPid, nOwn + 1);
      ArrayResize(ownLine, nOwn + 1);
      ownPid[nOwn]  = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
      ownLine[nOwn] = line;
      nOwn++;
     }
   // 2) 这些持仓的平仓成交（不看平仓成交自己的魔术号，手动平仓时它可能是 0）
   for(int i = 0; i < nd; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY && en != DEAL_ENTRY_INOUT)
         continue;
      ulong pid = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
      int idx = -1;
      for(int j = 0; j < nOwn && idx < 0; j++)
         if(ownPid[j] == pid)
            idx = j;
      if(idx < 0 || IsDone(g_doneDeals, dt))
         continue;
      MarkDone(g_doneDeals, dt);
      ClassifyClose(dt, ownLine[idx], ev, true);
     }
   // 3) 本轮网格挂出、被撤销、且不是 EA 自己撤的挂单
   int no = HistoryOrdersTotal();
   for(int i = 0; i < no; i++)
     {
      ulong ot = HistoryOrderGetTicket(i);
      if(ot == 0 || HistoryOrderGetString(ot, ORDER_SYMBOL) != _Symbol)
         continue;
      if(HistoryOrderGetInteger(ot, ORDER_MAGIC) != InpMagic)
         continue;
      if((ENUM_ORDER_STATE)HistoryOrderGetInteger(ot, ORDER_STATE) != ORDER_STATE_CANCELED)
         continue;
      if((datetime)HistoryOrderGetInteger(ot, ORDER_TIME_SETUP) < g_gridStart)
         continue;
      if(IsSelfCancel(ot) || IsDone(g_doneOrders, ot))
         continue;
      MarkDone(g_doneOrders, ot);
      int line = LineOfOrder(HistoryOrderGetDouble(ot, ORDER_PRICE_OPEN), HistoryOrderGetString(ot, ORDER_COMMENT));
      AddEvent(ev, EV_DELETE, StringFormat("G%d 挂单被手动删除", line));
     }
   return true;
  }

// 按第七-3 条：用持仓 ID 找到开仓成交，看开仓成交的魔术号（会重置历史选择）
bool PositionIsOurs(const ulong pid)
  {
   if(!HistorySelectByPosition(pid))
      return false;
   int nd = HistoryDealsTotal();
   for(int i = 0; i < nd; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return (HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagic);
     }
   return false;
  }

// 今天（服务器日期）是否发生过本 EA 的硬止损：保存的日期 + 扫描今天的历史（双保险）
bool HardStopToday()
  {
   datetime today = ServerDay(TimeTradeServer());
   if((datetime)GVGet("HD", 0.0) == today)
      return true;
   if(!HistorySelect(today, (datetime)((long)TimeTradeServer() + 86400)))
      return false;
   ulong pids[];
   int n = 0;
   int nd = HistoryDealsTotal();
   for(int i = 0; i < nd; i++)
     {
      ulong dt = HistoryDealGetTicket(i);
      if(dt == 0 || HistoryDealGetString(dt, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY en = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
      if(en != DEAL_ENTRY_OUT && en != DEAL_ENTRY_OUT_BY)
         continue;
      ENUM_DEAL_REASON rs = (ENUM_DEAL_REASON)HistoryDealGetInteger(dt, DEAL_REASON);
      if(rs != DEAL_REASON_SL && rs != DEAL_REASON_SO)
         continue;
      ArrayResize(pids, n + 1);
      pids[n] = (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID);
      n++;
     }
   for(int i = 0; i < n; i++)
      if(PositionIsOurs(pids[i]))
         return true;
   return false;
  }

// 重启 / 断线重连 / 睡眠唤醒后：查这段时间有没有手动操作或止损（第九条）
void RecoveryCheck(const bool isRestart, const datetime lastRun, const bool quiet, const bool paramEdit)
  {
   StopEvents ev;
   ev.flags = 0;
   ev.detail = "";
   g_recTp = 0;
   if(!ScanGridHistory(ev))
     {
      g_needRecovery = true;   // 历史读取失败：下一轮再查，期间不补挂
      return;
     }
   long offMin = (lastRun > 0 ? ((long)TimeTradeServer() - (long)lastRun) / 60 : 0);
   if(offMin < 0)
      offMin = 0;
   if(ev.flags != 0)
     {
      g_stopHead = (isRestart ? "重启后检查到手动操作/止损" : "断线恢复后检查到手动操作/止损");
      ExecuteEvents(ev);
      return;
     }
   string tp = (g_recTp > 0 && InpNotifyTrades ? StringFormat("，期间止盈 %d 次", g_recTp) : "");
   if(paramEdit)
      Notify("参数已更新（网格参数未变），网格继续运行");
   else
      if(isRestart && !quiet)
         Notify(StringFormat("重启恢复：离线约 %d 分钟，未发现手动操作，网格继续运行%s", (int)offMin, tp));
      else
         if(!isRestart && offMin >= 10)
            Notify(StringFormat("断线/睡眠恢复：离线约 %d 分钟，未发现手动操作，网格继续运行%s", (int)offMin, tp));
  }

//==================================================================
// 启动
//==================================================================
// 用保存的值重建本轮网格（重启后沿用，不重新计算格数和手数）
bool RestoreGrid()
  {
   int n = (int)GVGet("N", 0.0);
   if(n < 2 || n > MAX_GRIDS)
      return false;
   g_N = n;
   g_step = (InpUpper - InpLower) / n;
   for(int k = 0; k < MAX_LINES; k++)
      g_line[k] = 0.0;
   for(int k = 0; k <= n; k++)
      g_line[k] = NormPrice(InpLower + g_step * k);
   g_line[n] = NormPrice(InpUpper);
   g_sl          = GVGet("SL", 0.0);
   g_atr         = GVGet("At", 0.0);
   g_auto        = (GVGet("Au", 0.0) > 0.5);
   g_N0          = (int)GVGet("N0", n);
   g_nAtr        = (int)GVGet("Na", 0.0);
   g_gridStart   = (datetime)GVGet("T0", 0.0);
   SetEntryRange(n);
   for(int k = 0; k < MAX_LINES; k++)
      g_lots[k] = GVGet("L" + IntegerToString(k), 0.0);
   if(g_sl <= 0.0)
      return false;
   for(int k = g_kFrom; k <= g_kTo; k++)
      if(g_lots[k] <= 0.0)
         return false;
   return true;
  }

// 网格参数没变：沿用保存的状态（重启 / 断电恢复 / 只改了非网格参数）
void ResumeSaved(const int st)
  {
   bool ok = RestoreGrid();
   g_reason = (int)GVGet("Rs", 0.0);
   g_todo   = (int)GVGet("Td", 0.0);
   bool quiet     = (g_lastDeinit == REASON_CHARTCHANGE || g_lastDeinit == REASON_RECOMPILE);
   bool paramEdit = (g_lastDeinit == REASON_PARAMETERS);
   if(st == ST_STOPPED)
     {
      g_phase = PH_STOPPED;
      g_phaseMsg = (g_reason >= RS_REF_PARAMS ? "修改网格参数，或移除 EA 后重新加载，可以再试" :
                    "如需重新开网格：移除 EA 后重新加载，或修改网格参数");
      if(!ok || g_reason >= RS_REF_PARAMS)
         g_N = 0;
      if(g_N >= 2)
         DrawGrid(true);
      if(g_todo != 0)
        {
         // 上次停止动作没做完（例如撤到一半断电）：继续做完，做完推送
         g_stopText = ReasonText(g_reason);
         g_stopCloseAll = ((g_todo & TD_CLOSE) != 0);
         g_stopDoneNotify = true;
        }
      if(paramEdit)
         Notify("参数已更新（网格参数未变）。网格仍是停止状态；如需重新开网格：移除 EA 后重新加载，或修改网格参数");
      return;
     }
   // 运行中
   g_phase = PH_RUNNING;
   g_phaseMsg = "";
   if(!ok)
     {
      StopGrid(RS_STATE_BAD, false, false, "无法恢复网格，撤挂单、持仓保留");
      return;
     }
   ulong now = NowMs();
   g_gridStartMs = (now > 60000 ? now - 60000 : 0);   // 恢复后的挂单都算“补挂”
   g_lastGoodSrv = (datetime)GVGet("LR", 0.0);
   g_lastLRWrite = TimeTradeServer();
   DrawGrid(false);
   RecoveryCheck(true, g_lastGoodSrv, quiet, paramEdit);
  }

// 开新网格：先撤上一轮遗留的挂单；上一轮是“全平”类停止时，再平掉没平完的持仓；然后做检查
// “保留持仓”类或没有停止原因：持仓是你故意留下的，绝不自动平仓（按第五-7 条拒绝）
void BeginNewGrid(const int oldSt)
  {
   g_startOldReason = (oldSt == ST_STOPPED ? (int)GVGet("Rs", 0.0) : RS_NONE);
   g_startCloseOld  = IsCloseAllReason(g_startOldReason);
   g_startClosedOld = 0;
   g_phase = PH_STARTING;
   g_startStage = 1;
   g_startStageMs = NowMs();
   ArrayResize(g_trk, 0);
   g_N = 0;
   g_reason = RS_NONE;
   g_todo = 0;
   DeleteGrid();
   g_phaseMsg = "正在开新网格…";
  }

// 开网格前检查（第五条）。返回 0=通过，-1=等待 ATR，>0=拒绝原因
int PreCheck(string &why)
  {
   if(!CheckParams(why))
      return RS_REF_PARAMS;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(MathAbs(bal - InpInitBalance) > 0.5 * InpInitBalance)
     {
      why = StringFormat("填写的账户初始余额 %s 和当前账户余额 %s 相差超过 50%%，请检查是否多填或少填了一个 0",
                         DoubleToString(InpInitBalance, 2), DoubleToString(bal, 2));
      return RS_REF_PARAMS;
     }
   datetime srv = TimeTradeServer();
   if(InpFridayClose && InWeekendBlock(srv))
     {
      why = WeekendRefuseText();
      return RS_REF_WEEKEND;
     }
   if(InpNoGridAfterSL && HardStopToday())
     {
      why = "今天（服务器日期 " + TimeToString(ServerDay(srv), TIME_DATE) + "）已发生过硬止损，按设置今天不再开新网格";
      return RS_REF_SL_TODAY;
     }
   int rq = ReqToday();
   if(rq >= REQ_DAY_STOP)
     {
      why = StringFormat("今天（服务器日期）已发出 %d 次交易请求，达到 %d 次，今天不再开新网格（FTMO 每天上限 2000 次）",
                         rq, REQ_DAY_STOP);
      return RS_REF_REQ_LIMIT;
     }
   int npos = CountEaPositions();
   if(npos > 0)
     {
      why = StringFormat("本 EA（魔术号 %s）还有 %d 张持仓。旧挂单已撤，持仓保留（各带止盈止损）。请先平掉残留持仓，再开新网格",
                         IntegerToString(InpMagic), npos);
      return RS_REF_RESIDUAL;
     }
   int rc = ResolveGrid(why);
   if(rc != 0)
      return rc;
   double sd = StopsDist();
   if(g_step < sd || g_step < g_tick * 2)
     {
      why = StringFormat("格距 %s 小于最小止损距离 %s（或太小），止盈止损挂不上", P(g_step), P(sd));
      return RS_REF_STOPLEVEL;
     }
   double slGap = (IsLong() ? g_line[g_kFrom] - g_sl : g_sl - g_line[g_kTo]);
   if(slGap < sd || slGap <= 0.0)
     {
      why = StringFormat("硬止损离最近一条开仓线只有 %s，小于最小止损距离 %s", P(slGap), P(sd));
      return RS_REF_STOPLEVEL;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     {
      why = "取不到当前报价";
      return RS_REF_CALC;
     }
   if(IsLong() && tick.bid <= g_sl)
     {
      why = StringFormat("当前 Bid %s 已经越过硬止损 %s", P(tick.bid), P(g_sl));
      return RS_REF_PRICE_SL;
     }
   if(!IsLong() && tick.ask >= g_sl)
     {
      why = StringFormat("当前 Ask %s 已经越过硬止损 %s", P(tick.ask), P(g_sl));
      return RS_REF_PRICE_SL;
     }
   return 0;
  }

// 参数合法性（第五-2 条）
bool CheckParams(string &why)
  {
   if(InpLower <= 0.0 || InpUpper <= InpLower)
     {
      why = "上沿必须大于下沿，且都大于 0";
      return false;
     }
   if(InpGrids != 0 && (InpGrids < 2 || InpGrids > MAX_GRIDS))
     {
      why = "格数只能填 0（自动）或 2～10";
      return false;
     }
   if(InpGrids == 0)
     {
      if(InpAtrPeriod < 1)
        {
         why = "ATR 周期必须大于等于 1";
         return false;
        }
      if(InpAtrMult <= 0.0)
        {
         why = "ATR 倍数必须大于 0";
         return false;
        }
      if(g_atrHandle == INVALID_HANDLE)
        {
         why = "无法创建 H1 ATR 指标";
         return false;
        }
     }
   if(InpInitBalance <= 0.0)
     {
      why = "必须填写账户初始余额（美元，例如 100000）";
      return false;
     }
   if(InpRiskPct <= 0.0)
     {
      why = "总风险百分比必须大于 0";
      return false;
     }
   if(!CapValid())
     {
      why = CapInvalidText();
      return false;
     }
   if(InpMagic <= 0)
     {
      why = "魔术号必须大于 0";
      return false;
     }
   if(InpFridayClose && (InpFridayHourNY < 0 || InpFridayHourNY > 16))
     {
      why = "周五平仓时刻只能是纽约时间 0～16 点（黄金纽约 17:00 收盘）";
      return false;
     }
   if(InpHardSL < 0.0)
     {
      why = "硬止损价不能为负数";
      return false;
     }
   if(InpHardSL > 0.0 && IsLong() && InpHardSL >= InpLower)
     {
      why = StringFormat("做多时硬止损（%s）必须低于下沿（%s）", P(InpHardSL), P(InpLower));
      return false;
     }
   if(InpHardSL > 0.0 && !IsLong() && InpHardSL <= InpUpper)
     {
      why = StringFormat("做空时硬止损（%s）必须高于上沿（%s）", P(InpHardSL), P(InpUpper));
      return false;
     }
   return true;
  }

// 拒绝开网格：保存“已拒绝”（同参数重启后保持不动），推送原因
void Refuse(const int code, const string why)
  {
   g_reason = code;
   g_todo = 0;
   g_gridStart = 0;
   g_N = 0;
   SaveState(ST_STOPPED);
   g_phase = PH_STOPPED;
   g_phaseMsg = "已拒绝开网格：" + why;
   DeleteGrid();
   Notify("拒绝开网格：" + why);
  }

// 检查全部通过：保存状态、画线、推送，进入运行
void FinalizeStart()
  {
   g_gridStart = (datetime)((long)TimeTradeServer() - 60);   // 提前 60 秒，容忍本地估算的服务器时间误差
   g_gridStartMs = NowMs();
   g_reason = RS_NONE;
   g_todo = 0;
   SaveState(ST_RUNNING);
   ArrayResize(g_trk, 0);
   ArrayResize(g_doneDeals, 0);
   ArrayResize(g_doneOrders, 0);
   for(int k = 0; k < MAX_LINES; k++)
     {
      g_lineRetryMs[k] = 0;
      g_lineBadPrice[k] = 0;
      g_lineFails[k] = 0;
      g_lineDeferred[k] = false;
      g_lineDeferUntil[k] = 0;
     }
   g_warnedStrayPos = false;
   g_phase = PH_RUNNING;
   g_phaseMsg = "";
   g_lastLRWrite = TimeTradeServer();
   g_lastGoodSrv = g_lastLRWrite;
   DrawGrid(false);
   MqlTick tick;
   double px = (SymbolInfoTick(_Symbol, tick) ? tick.bid : 0.0);
   string atrTxt = (g_atr > 0.0 ? P(g_atr) : "无");
   string ratio  = (g_atr > 0.0 ? DoubleToString(g_step / g_atr, 2) : "-");
   string idea = "思路风险待计算";
   if(ComputeLedger() && !g_ledUnknown)
      idea = "思路风险已用" + DoubleToString(g_ledUsed, 0) + "/上限" + DoubleToString(IdeaCap(), 0);
   Notify(StringFormat("开网格 %s %s-%s 现价%s｜H1 ATR %s｜%s 格距%s=%s×ATR｜止损%s｜%s｜%s",
                       DirText(), P(InpLower), P(InpUpper), P(px), atrTxt, GridNote(),
                       P(g_step), ratio, P(g_sl), LotsText(), idea));
   int foreign = CountForeign();
   if(foreign > 0)
      Notify(StringFormat("注意：%s 上已有 %d 张手动（或其他魔术号）的持仓/挂单，不受网格管理", _Symbol, foreign));
  }

// 开网格流程：阶段 1 撤旧挂单，阶段 2 检查并开网格
void StartingStep()
  {
   if(g_startStage == 1)
     {
      int cancelled = 0;
      int left = CancelAllEaOrders(cancelled);
      if(left > 0)
        {
         g_phaseMsg = "正在撤销上一轮遗留的挂单…";
         return;
        }
      if(g_startCloseOld)
        {
         if(CloseAllEaPositions(g_startClosedOld) > 0)
           {
            g_phaseMsg = "正在平掉上一轮（" + ReasonText(g_startOldReason) + "）没平完的持仓…";
            return;
           }
         g_startCloseOld = false;
         if(g_startClosedOld > 0)
            Notify(StringFormat("开新网格前：已平掉上一轮（%s）没平完的持仓 %d 张", ReasonText(g_startOldReason), g_startClosedOld));
        }
      g_startStage = 2;
      g_startStageMs = NowMs();
     }
   string why = "";
   int rc = PreCheck(why);
   if(rc < 0)
     {
      g_phaseMsg = "等待 H1 ATR 数据…";
      return;
     }
   if(rc > 0)
     {
      Refuse(rc, why);
      return;
     }
   FinalizeStart();
  }

// 连上服务器且数据同步后执行一次：判断开新网格、重启续跑、还是保持停止
void Startup()
  {
   g_login   = AccountInfoInteger(ACCOUNT_LOGIN);
   g_acctPfx = "GEA_" + IntegerToString(g_login) + "_";
   g_pfx     = g_acctPfx + IntegerToString(InpMagic) + "_";
   LoadSymbolInfo();
   // 账户切换：本图表上次运行时的账号和当前账号不一致 → 暂停，必须重新加载 EA
   double lastLogin = 0.0;
   if(GlobalVariableGet(AcctMarkName(), lastLogin) && lastLogin > 0.0 && (long)lastLogin != g_login)
     {
      g_phase = PH_PAUSED;
      g_pausedByAccount = true;
      g_phaseMsg = StringFormat("检测到账户切换（原账号 %s → 当前账号 %s），EA 已暂停（不开网格、不挂单、不撤单、不平仓），请确认后重新加载 EA",
                                IntegerToString((long)lastLogin), IntegerToString(g_login));
      Notify(g_phaseMsg);
      return;
     }
   GlobalVariableSet(AcctMarkName(), (double)g_login);
   GlobalVariablesFlush();
   if(OtherInstanceAlive())
     {
      g_phase = PH_PAUSED;
      g_phaseMsg = "同一账号、同一魔术号的 GridEA 已在另一个图表运行，本图表的 EA 不工作";
      Notify(g_phaseMsg);
      return;
     }
   HeartBeat();
   g_lastDeinit = (int)GVGet("DR", -1.0);
   GVDel("DR");
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      g_phase = PH_FATAL;
      g_phaseMsg = "账户不是对冲模式（Hedging），EA 拒绝运行";
      Notify(g_phaseMsg);
      return;
     }
   PurgeSelfCancel();
   int st = (int)GVGet("St", 0.0);
   if(st != ST_NONE)
     {
      if((uint)GVGet("Sy", 0.0) != Fnv1a(_Symbol))
        {
         g_phase = PH_PAUSED;
         g_pausedBySymbol = true;
         g_phaseMsg = "图表品种和本轮网格的品种不一致，EA 暂停（不挂单、不撤单），切回原品种即可恢复";
         Notify(g_phaseMsg);
         return;
        }
      if((uint)GVGet("Hs", 0.0) == GridHash())
        {
         ResumeSaved(st);
         return;
        }
     }
   BeginNewGrid(st);
  }

//==================================================================
// 主循环（OnTick、1 秒定时器、交易事件都调用它）
//==================================================================
// 已连接、连上后已等待同步、有有效报价
bool ConnectionReady()
  {
   if(g_tester)
      return true;
   if(TerminalInfoInteger(TERMINAL_CONNECTED) == 0)
     {
      if(g_connSinceMs != 0)
         g_wasDisconnected = true;
      g_connSinceMs = 0;
      return false;
     }
   ulong now = NowMs();
   if(g_connSinceMs == 0)
      g_connSinceMs = now;
   if(now - g_connSinceMs < SYNC_WAIT_MS)
      return false;
   if(AccountInfoInteger(ACCOUNT_LOGIN) == 0)
      return false;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;
   return true;
  }

void RunningStep()
  {
   if(g_needRecovery)
     {
      g_needRecovery = false;
      RecoveryCheck(false, g_lastGoodSrv, false, false);
      if(g_phase != PH_RUNNING || g_needRecovery)
         return;
     }
   // 运行中把“交易思路风险上限”改得不合法（≤ 总风险% 或 > 1%）→ 停止（撤单，持仓保留）
   if(!CapValid())
     {
      StopGrid(RS_CAP_INVALID, false, false, CapInvalidText());
      return;
     }
   StopEvents ev;
   ev.flags = 0;
   ev.detail = "";
   SyncTracking(ev);
   if(ev.flags != 0)
     {
      ExecuteEvents(ev);
      return;
     }
   MqlTick tick;
   bool haveTick = (SymbolInfoTick(_Symbol, tick) && tick.bid > 0.0 && tick.ask > 0.0);
   // 硬止损（价格）：做多 Bid ≤ 止损，做空 Ask ≥ 止损
   if(haveTick)
     {
      if(IsLong() && tick.bid <= g_sl)
        {
         StopGrid(RS_HARD_SL_PRICE, true, true, StringFormat("Bid %s ≤ 止损 %s", P(tick.bid), P(g_sl)));
         return;
        }
      if(!IsLong() && tick.ask >= g_sl)
        {
         StopGrid(RS_HARD_SL_PRICE, true, true, StringFormat("Ask %s ≥ 止损 %s", P(tick.ask), P(g_sl)));
         return;
        }
     }
   // 周五平仓：本轮网格跨过了一个“周五 H 点（纽约）”就全平（EA 当时不在线的话恢复后补执行）
   if(InpFridayClose)
     {
      datetime srv = TimeTradeServer();
      datetime fri = LastFridayCloseSrv(srv);
      if(g_gridStart < fri)
        {
         bool missed = ((long)srv - (long)fri > 120);
         StopGrid(missed ? RS_FRIDAY_MISSED : RS_FRIDAY, true, false,
                  StringFormat("纽约时间周五 %d:00", InpFridayHourNY));
         return;
        }
     }
   // 当天交易请求达到 1000 次 → 停止网格（撤单，持仓保留）
   int rq = ReqToday();
   if(rq >= REQ_DAY_STOP)
     {
      StopGrid(RS_REQ_LIMIT, false, false, StringFormat("今天已发出 %d 次（FTMO 每天上限 2000 次）", rq));
      return;
     }
   CleanupStrayOrders();
   if(haveTick)
      PlaceMissing(tick);
  }

void Process()
  {
   ulong now = NowMs();
   if(!g_tester && g_lastProcMs != 0 && now - g_lastProcMs > TIME_JUMP_MS && g_phase == PH_RUNNING)
      g_needRecovery = true;   // 两次运行间隔太长（睡眠/卡住）：按断线处理
   g_lastProcMs = now;
   FlushNotify();
   if(g_phase == PH_FATAL || g_phase == PH_PAUSED)
     {
      ShowStatus();
      return;
     }
   if(!ConnectionReady())
     {
      ShowStatus();
      return;
     }
   if(g_wasDisconnected)
     {
      g_wasDisconnected = false;
      if(g_phase == PH_RUNNING)
         g_needRecovery = true;
     }
   UpdateServerOffset();
   if(!g_started)
     {
      g_started = true;
      Startup();
      ShowStatus();
      return;
     }
   HeartBeat();
   DailyStatLog();
   if(g_phase == PH_STARTING)
      StartingStep();
   else
      if(g_phase == PH_RUNNING)
         RunningStep();
      else
         if(g_phase == PH_STOPPED)
            ContinueStopActions();
   if(g_phase == PH_RUNNING)
     {
      datetime srv = TimeTradeServer();
      if((long)srv - (long)g_lastLRWrite >= 60)
        {
         GVSet("LR", (double)srv);   // 最后一次正常运行时间，每分钟更新
         g_lastLRWrite = srv;
        }
      g_lastGoodSrv = srv;
     }
   // 周末 / 开盘前被拒绝：图上的提示随时间更新（开盘后改成提醒重新加载）
   if(g_phase == PH_STOPPED && g_reason == RS_REF_WEEKEND)
      g_phaseMsg = (InWeekendBlock(TimeTradeServer()) ? "已拒绝开网格：" + WeekendRefuseText() :
                    "此前因周末 / 开盘前被拒绝开网格。现在已开盘，请重新加载 EA（从图上移除后再拖上去）");
   ShowStatus();
  }

//==================================================================
// 图上显示
//==================================================================
string PhaseText()
  {
   switch(g_phase)
     {
      case PH_WAIT:
         return "等待连接服务器 / 同步数据";
      case PH_STARTING:
         return "正在开网格";
      case PH_RUNNING:
         return "运行中";
      case PH_STOPPED:
         if(g_reason >= RS_REF_PARAMS)
            return "已拒绝开网格（" + ReasonText(g_reason) + "）";
         return "已停止（" + ReasonText(g_reason) + "）" + (g_todo != 0 ? "，撤单/平仓进行中" : "");
      case PH_PAUSED:
         return "暂停";
      case PH_FATAL:
         return "拒绝运行";
      default:
         return "";
     }
  }

void ShowStatus()
  {
   string s = "GridEA  " + AcctPrefix() + _Symbol + "  魔术号 " + IntegerToString(InpMagic) + "\n";
   s += "状态：" + PhaseText();
   if(!g_tester && TerminalInfoInteger(TERMINAL_CONNECTED) == 0)
      s += "（未连接服务器）";
   s += "\n";
   if(g_N >= 2)
     {
      s += StringFormat("%s  %s - %s  %s  格距 %s  硬止损 %s\n", DirText(), P(InpLower), P(InpUpper),
                        GridNote(), P(g_step), P(g_sl));
      s += "手数：" + LotsText() + "\n";
     }
   if(g_phase == PH_RUNNING)
     {
      s += StringFormat("本 EA 挂单 %d 张，持仓 %d 张\n", CountEaOrders(), CountEaPositions());
      if(NowMs() - g_ledCalcMs >= LEDGER_REFRESH_MS)
         ComputeLedger();
      if(!g_ledOk)
         s += "交易思路风险：计算中…\n";
      else
         if(g_ledUnknown)
            s += "交易思路风险：有没设止损的单（" + g_ledUnknownText + "），暂停补挂\n";
         else
            s += StringFormat("交易思路风险：已用 %s / 上限 %s（近61分钟平仓 %s + 持仓 %s + 挂单 %s）\n",
                              DoubleToString(g_ledUsed, 2), DoubleToString(IdeaCap(), 2), DoubleToString(g_ledClosed, 2),
                              DoubleToString(g_ledPos, 2), DoubleToString(g_ledOrd, 2));
      string d = "";
      for(int k = g_kFrom; k <= g_kTo; k++)
         if(g_lineDeferred[k])
            d += " G" + IntegerToString(k) +
                 (g_lineDeferUntil[k] > 0 ? "（预计 " + TimeToString(g_lineDeferUntil[k], TIME_MINUTES) + "）" : "");
      if(d != "")
         s += "额度不足暂缓：" + d + "\n";
     }
   if(g_acctPfx != "")
      s += StringFormat("今日交易请求：%d / %d（FTMO 每天上限 2000）\n", ReqToday(), REQ_DAY_STOP);
   if(g_phaseMsg != "")
      s += g_phaseMsg + "\n";
   Comment(s);
  }

void MakeHLine(const string name, const double price, const color clr, const int width,
               const ENUM_LINE_STYLE style, const string text)
  {
   if(ObjectFind(0, name) < 0)
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
         return;
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, text);
  }

// 运行中：开仓线彩色细线、止盈专用线灰色虚线、硬止损红色粗线；停止后全部变灰
void DrawGrid(const bool grey)
  {
   DeleteGrid();
   if(g_N < 2)
      return;
   color entryClr = (IsLong() ? clrDodgerBlue : clrOrange);
   for(int k = 0; k <= g_N; k++)
     {
      bool entry = (k >= g_kFrom && k <= g_kTo);
      string text;
      color  c;
      if(entry)
        {
         text = StringFormat("G%d %s 止盈%s %s手", k, P(g_line[k]), P(TpOf(k)), V(g_lots[k]));
         c = (grey ? clrGray : entryClr);
        }
      else
        {
         text = "止盈线 " + P(g_line[k]);
         c = (grey ? clrGray : clrSilver);
        }
      MakeHLine(g_objPfx + "L" + IntegerToString(k), g_line[k], c, 1, (entry ? STYLE_SOLID : STYLE_DOT), text);
     }
   MakeHLine(g_objPfx + "SL", g_sl, (grey ? clrGray : clrRed), 3, STYLE_SOLID, "硬止损 " + P(g_sl));
   ChartRedraw(0);
  }

void DeleteGrid()
  {
   ObjectsDeleteAll(0, g_objPfx);
   ChartRedraw(0);
  }

//==================================================================
// 移除 EA
//==================================================================
// 移除 EA 时撤掉本 EA 的全部挂单：OnDeinit 只有 2.5 秒，用异步请求，仍遵守每秒最多 5 次
int CancelOnRemove(int &total)
  {
   total = 0;
   ulong tks[];
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      ArrayResize(tks, total + 1);
      tks[total] = tk;
      total++;
     }
   if(total == 0)
      return 0;
   if(!g_tester && (TerminalInfoInteger(TERMINAL_CONNECTED) == 0 || TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0))
      return 0;
   int sent = 0;
   ulong t0 = GetTickCount64();
   for(int i = 0; i < total; i++)
     {
      while(!CanSend() && GetTickCount64() - t0 < 2000)
         Sleep(50);
      if(!CanSend())
         break;
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_REMOVE;
      req.order  = tks[i];
      NoteSend();
      if(OrderSendAsync(req, res))
         sent++;
     }
   return sent;
  }

//==================================================================
// 事件处理
//==================================================================
int OnInit()
  {
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_objPfx = "GEA_" + IntegerToString(InpMagic) + "_";
   g_pfx = "";
   g_login = 0;
   g_phase = PH_WAIT;
   g_phaseMsg = "等待连接服务器并同步订单/历史…";
   g_started = false;
   g_pausedBySymbol = false;
   g_pausedByAccount = false;
   g_acctPfx = "";
   g_startOldReason = RS_NONE;
   g_startClosedOld = 0;
   g_ledOk = false;
   g_ledCalcMs = 0;
   g_statDay = 0;
   g_lastDeinit = -1;
   g_N = 0;
   g_reason = RS_NONE;
   g_todo = 0;
   g_gridStart = 0;
   g_connSinceMs = 0;
   g_wasDisconnected = false;
   g_lastProcMs = 0;
   g_needRecovery = false;
   g_waitUntilMs = 0;
   g_startStage = 0;
   g_stopPushPending = false;
   g_stopDoneNotify = false;
   g_stopHead = "";
   g_warnedStrayPos = false;
   g_instanceId = (double)((long)(GetMicrosecondCount() % 1000000000) + 1);
   ArrayResize(g_trk, 0);
   ArrayResize(g_doneDeals, 0);
   ArrayResize(g_doneOrders, 0);
   ArrayResize(g_sentTk, 0);
   ArrayResize(g_sentMs, 0);
   g_reqIdx = 0;
   for(int i = 0; i < REQ_PER_SEC; i++)
      g_reqMs[i] = 0;
   for(int k = 0; k < MAX_LINES; k++)
     {
      g_line[k] = 0.0;
      g_lots[k] = 0.0;
      g_lineRetryMs[k] = 0;
      g_lineBadPrice[k] = 0;
      g_lineFails[k] = 0;
      g_lineDeferred[k] = false;
      g_lineDeferUntil[k] = 0;
     }
   g_atrHandle = iATR(_Symbol, PERIOD_H1, (InpAtrPeriod >= 1 ? InpAtrPeriod : 1));
   LoadSymbolInfo();
   if(!EventSetTimer(1))
     {
      Print("无法创建 1 秒定时器");
      return INIT_FAILED;
     }
   ShowStatus();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_acctPfx != "")
      PrintFormat("【统计】服务器日 %s 截至目前交易请求 %d 次", TimeToString(ServerDay(TimeTradeServer()), TIME_DATE), ReqToday());
   bool removing = (reason == REASON_REMOVE || reason == REASON_CHARTCLOSE || reason == REASON_TEMPLATE);
   bool ready    = (g_started && g_pfx != "");
   bool owner    = (ready && (g_phase == PH_RUNNING || g_phase == PH_STOPPED || g_phase == PH_STARTING));
   if(owner && removing)
     {
      // 移除 EA：撤掉本 EA 所有挂单，持仓保留，清除保存的状态（保留硬止损日期）
      int keep = CountEaPositions();
      int total = 0;
      int sent = CancelOnRemove(total);
      GlobalVariableDel(AcctMarkName());
      ClearState();
      SendNow(StringFormat("EA 已从图表移除：已发出撤单请求 %d/%d 张，持仓 %d 张保留（各带止盈止损）。请在手机上确认挂单已全部撤销",
                           sent, total, keep));
     }
   else
      if(ready && removing && g_phase == PH_PAUSED && g_pausedBySymbol)
        {
         GlobalVariableDel(AcctMarkName());
         ClearState();
         SendNow("EA 已从图表移除。注意：图表品种已不是网格品种，原品种上的网格挂单没有撤销，请人工检查");
        }
      else
         if(ready && removing && g_phase == PH_PAUSED && g_pausedByAccount)
           {
            // 账户切换暂停中被移除：只清掉账户记录，不动任何账户的网格状态，也不撤单平仓
            GlobalVariableDel(AcctMarkName());
            GlobalVariablesFlush();
            Print("EA 已移除（账户切换暂停中）：已清除账户记录，没有撤单或平仓");
           }
         else
         if(ready && !removing && (owner || (g_phase == PH_PAUSED && g_pausedBySymbol)))
           {
            // 重启、改参数、切换周期等：保留状态，记下原因
            if(g_phase == PH_RUNNING)
               GVSet("LR", (double)TimeTradeServer());
            GVSet("DR", reason);
            GlobalVariablesFlush();
           }
   if(ready)
      ReleaseInstance();
   DeleteGrid();
   Comment("");
   if(g_atrHandle != INVALID_HANDLE)
     {
      if(!IndicatorRelease(g_atrHandle))
         Print("ATR 指标句柄释放失败");
      g_atrHandle = INVALID_HANDLE;
     }
  }

void OnTick()
  {
   Process();
  }

void OnTimer()
  {
   Process();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   // 交易事件只用来“马上同步一次”；判断以服务器现状和历史为准，不依赖事件不丢
   if(NowMs() - g_lastProcMs >= 200)
      Process();
  }
//+------------------------------------------------------------------+
