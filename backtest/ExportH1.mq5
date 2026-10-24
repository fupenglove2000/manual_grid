//+------------------------------------------------------------------+
//| ExportH1.mq5 —— 回测辅助：在策略测试器里运行                      |
//| 测试结束时把 H1 K 线、品种规格、账户信息导出到公共文件夹           |
//| （%APPDATA%\MetaQuotes\Terminal\Common\Files），用来挑选回测场景  |
//+------------------------------------------------------------------+
#property version "1.00"

input datetime InpFrom = D'2026.01.01 00:00';   // 导出起点

void OnTick()
  {
  }

void OnDeinit(const int reason)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_H1, InpFrom, TimeCurrent(), r);
   int h = FileOpen("GridEA_XAUUSD_H1.csv", FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_ANSI, ',');
   if(h != INVALID_HANDLE)
     {
      FileWrite(h, "time", "open", "high", "low", "close", "tick_volume", "spread");
      for(int i = 0; i < n; i++)
         FileWrite(h, TimeToString(r[i].time, TIME_DATE | TIME_MINUTES),
                   DoubleToString(r[i].open, _Digits), DoubleToString(r[i].high, _Digits),
                   DoubleToString(r[i].low, _Digits), DoubleToString(r[i].close, _Digits),
                   IntegerToString(r[i].tick_volume), IntegerToString(r[i].spread));
      FileClose(h);
     }
   int s = FileOpen("GridEA_XAUUSD_spec.txt", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(s != INVALID_HANDLE)
     {
      FileWrite(s, "bars=" + IntegerToString(n));
      FileWrite(s, "login=" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
      FileWrite(s, "server=" + AccountInfoString(ACCOUNT_SERVER));
      FileWrite(s, "margin_mode=" + IntegerToString(AccountInfoInteger(ACCOUNT_MARGIN_MODE)));
      FileWrite(s, "currency=" + AccountInfoString(ACCOUNT_CURRENCY));
      FileWrite(s, "leverage=" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
      FileWrite(s, "contract_size=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), 2));
      FileWrite(s, "tick_size=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 5));
      FileWrite(s, "tick_value=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5));
      FileWrite(s, "digits=" + IntegerToString(_Digits));
      FileWrite(s, "volume_min=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2));
      FileWrite(s, "volume_max=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), 2));
      FileWrite(s, "volume_step=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2));
      FileWrite(s, "stops_level=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)));
      FileWrite(s, "freeze_level=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)));
      FileWrite(s, "filling_mode=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)));
      FileWrite(s, "expiration_mode=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE)));
      FileWrite(s, "execution_mode=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE)));
      for(int d = 0; d < 7; d++)
        {
         datetime f = 0, t = 0;
         string line = "session_" + IntegerToString(d) + "=";
         for(uint i = 0; i < 5 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, i, f, t); i++)
            line += StringFormat("%s-%s ", TimeToString(f, TIME_MINUTES), TimeToString(t, TIME_MINUTES));
         FileWrite(s, line);
        }
      FileClose(s);
     }
   PrintFormat("ExportH1: %d bars exported", n);
  }
//+------------------------------------------------------------------+
