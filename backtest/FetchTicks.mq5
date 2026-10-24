//+------------------------------------------------------------------+
//| FetchTicks.mq5 —— 回测辅助脚本（放在 MQL5\Scripts）               |
//| 对每个回测时段调用 CopyTicksRange，让终端从服务器下载真实 tick，   |
//| 完成后把结果写到公共文件夹并关闭终端。只读数据，不做任何交易。     |
//+------------------------------------------------------------------+
#property version "1.00"

void OnStart()
  {
   datetime fromT[] = {D'2026.07.27', D'2026.08.10', D'2026.08.24', D'2026.10.19'};
   datetime toT[]   = {D'2026.08.01', D'2026.08.19', D'2026.08.29', D'2026.10.24'};
   int h = FileOpen("GridEA_fetch_ticks.txt", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   for(int i = 0; i < ArraySize(fromT); i++)
     {
      MqlTick ticks[];
      int last = -2, n = -1;
      for(int attempt = 0; attempt < 20; attempt++)
        {
         ResetLastError();
         n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, (ulong)fromT[i] * 1000, (ulong)toT[i] * 1000);
         if(n > 0 && n == last)
            break;               // 连续两次数量相同：下载完成
         last = n;
         Sleep(3000);
        }
      string first = (n > 0 ? TimeToString(ticks[0].time, TIME_DATE | TIME_SECONDS) : "-");
      string lastT = (n > 0 ? TimeToString(ticks[n - 1].time, TIME_DATE | TIME_SECONDS) : "-");
      string line = StringFormat("%s ~ %s : %d ticks (first %s, last %s, err %d)",
                                 TimeToString(fromT[i], TIME_DATE), TimeToString(toT[i], TIME_DATE), n, first, lastT, GetLastError());
      Print(line);
      if(h != INVALID_HANDLE)
         FileWrite(h, line);
     }
   if(h != INVALID_HANDLE)
      FileClose(h);
   TerminalClose(0);
  }
//+------------------------------------------------------------------+
