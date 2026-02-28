//+------------------------------------------------------------------+
//|                          SR_Mapping_Foundation_v6_Optimized.mq5   |
//|       v7.1: State Exit + Risk Governor                             |
//|       + Grid vs Trailing Mutual Exclusion                         |
//|       + TP pribadi pada entry pertama                             |
//|       + Basket exit HANYA untuk grid                              |
//|       + Jam trading filter (broker time)                          |
//|       + Stop Loss Mode vs Grid Mode (pilih salah satu)            |
//|       Logika trading & SNR mapping 100% IDENTIK                   |
//+------------------------------------------------------------------+
#property copyright   "SR Mapping Foundation v7.1 (Risk Governor)"
#property version     "7.10"
#property description "CPU Optimized + Trading Hours Filter"
#property description "Grid vs Trailing EXCLUSIVE"
#property description "Entry hanya dalam jam trading, Grid/Trail 24 jam"
#property description "v7.1: Risk Governor — Margin Gate + Trail Anti-Spam"

#include <Trade\\Trade.mqh>

//================ SNR MAPPING =================
//+------------------------------------------------------------------+
//| Input — SR Mapping                                                |
//+------------------------------------------------------------------+
input ENUM_TIMEFRAMES InpSNR_Timeframe = PERIOD_M30;
input int             InpVisualBars    = 200;
input int             InpMaxSNRBars    = 2000;        // MAX bars untuk SNR rebuild

//================ ENTRY LOGIC =================
//+------------------------------------------------------------------+
//| Input — RSI                                                       |
//+------------------------------------------------------------------+
input int             InpRSI_Period     = 14;
input double          InpRSI_Overbought = 70.0;
input double          InpRSI_Oversold   = 30.0;

//================ VOLATILITY ==================
//+------------------------------------------------------------------+
//| Input — ATR Volatility Filter                                     |
//+------------------------------------------------------------------+
input int             InpATR_Period     = 14;
input ENUM_TIMEFRAMES InpATR_Timeframe  = PERIOD_M1;
input int             InpATR_MinPoints  = 1800;
input int             InpATR_MaxPoints  = 2500;

//+------------------------------------------------------------------+
//| Input — Daily Range Trend Filter                                  |
//+------------------------------------------------------------------+
input int             InpDailyRangeThreshold = 5000;
input bool            InpUseTrendFilter      = true;

//================ ORDER =======================
//+------------------------------------------------------------------+
//| Input — Order Management                                          |
//+------------------------------------------------------------------+
input double          InpLotSize        = 0.01;
input int             InpTP_Points      = 5000;        // TP Pribadi (points, 0 = no TP)
input int             InpSlippage       = 30;
input ulong           InpMagicNumber    = 202602;
input string          InpOrderComment   = "RSI_SNR";

//+------------------------------------------------------------------+
//| Input — Filter                                                    |
//+------------------------------------------------------------------+
input int             InpMaxOpenTrades  = 1;
input int             InpSNR_Tolerance  = 50;
input int             InpMinBarsBetweenTrades = 5;
input int             InpMaxSpreadPoints = 1000;

//+------------------------------------------------------------------+
//| Input — Trading Hours Filter (BARU v6.2)                          |
//+------------------------------------------------------------------+
input bool            InpUseTimeFilter  = true;        // Aktifkan filter jam trading
input int             InpStartHour      = 1;           // Jam mulai trading (broker time, 0-23)
input int             InpEndHour        = 21;          // Jam akhir trading (broker time, 0-23)

//+------------------------------------------------------------------+
//| Input — Execution                                                 |
//+------------------------------------------------------------------+
input int             InpMaxRetries     = 3;
input int             InpRetryDelayMs   = 500;

//================ EXIT ENGINE =================
//+------------------------------------------------------------------+
//| Input — Smart Trailing Stop                                       |
//+------------------------------------------------------------------+
input bool            InpUseSmartTrailing = true;
input double          InpTrail_ATR_Mult   = 1.2;
input int             InpTrail_BufferPts  = 300;

//+------------------------------------------------------------------+
//| Input — Stop Loss Mode (BARU v6.3)                                |
//+------------------------------------------------------------------+
input bool            InpUseStopLoss     = false;      // Aktifkan Stop Loss Mode
input int             InpSL_Points       = 5000;       // Stop Loss dalam points

//+------------------------------------------------------------------+
//| Input — Grid Martingale Model A                                   |
//+------------------------------------------------------------------+
input bool            InpUseGrid            = true;
input int             InpGridStepPoints     = 1000;
input double          InpMartingaleFactor   = 2.0;
input int             InpMaxGridLevel       = 5;
input double          InpBasketProfitMoney  = 50.0;
input double          InpMaxLotCap          = 5.0;

//+------------------------------------------------------------------+
//| Input — Tester Visual Control                                     |
//+------------------------------------------------------------------+
input bool            InpShowEntryMarkerInTester = true;

//================ ATR SLTP ====================
//+------------------------------------------------------------------+
//| Adaptive ATR StopLoss / TakeProfit                                |
//+------------------------------------------------------------------+
input bool            InpUseATR_SLTP   = true;
input double          InpSL_ATR_Mult   = 1.6;
input double          InpTP_ATR_Mult   = 2.0;

//+------------------------------------------------------------------+
//| Global — Indicator handles                                        |
//+------------------------------------------------------------------+
int      hFractal = INVALID_HANDLE;
int      hRSI     = INVALID_HANDLE;
int      hATR     = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Global — Array-based SR                                            |
//+------------------------------------------------------------------+
double   Resistance[];
double   Support[];

CTrade   trade;
datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
//| SNR new-bar detection                                              |
//+------------------------------------------------------------------+
datetime lastSNRBarTime = 0;
bool     snrReady       = false;

//+------------------------------------------------------------------+
//| Tester detection                                                   |
//+------------------------------------------------------------------+
bool     isTester = false;

//+------------------------------------------------------------------+
//| Volatility Snapshot                                                |
//+------------------------------------------------------------------+
double   g_ATR_Entry  = 0.0;
ulong    g_ATR_Ticket = 0;

//+------------------------------------------------------------------+
//| Optimization globals                                               |
//+------------------------------------------------------------------+
ulong    g_lastPanelUpdate = 0;
datetime g_lastM1Bar       = 0;
double   g_cachedRSI       = 0.0;
double   g_cachedATR       = 0.0;

//+------------------------------------------------------------------+
//| Cek bar baru di timeframe SNR                                     |
//+------------------------------------------------------------------+
bool IsNewSNRBar()
{
   datetime currentBar = iTime(_Symbol, InpSNR_Timeframe, 0);
   if(currentBar != lastSNRBarTime)
   {
      lastSNRBarTime = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Deteksi filling mode                                               |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetAllowedFillingMode()
{
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Resolve POSITION_TICKET                                            |
//+------------------------------------------------------------------+
ulong ResolvePositionTicket()
{
   for(int p = 0; p < 5; p++)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            return ticket;
      }
      if(!isTester) Sleep(50);
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Cek apakah dalam jam trading (broker time)                        |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!InpUseTimeFilter)
      return(true);

   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(InpStartHour < InpEndHour)
   {
      return(hour >= InpStartHour && hour < InpEndHour);
   }
   else
   {
      return(hour >= InpStartHour || hour < InpEndHour);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   isTester = (bool)MQLInfoInteger(MQL_TESTER);

   //--- v6.3: Validasi mode — Grid dan StopLoss tidak boleh aktif bersamaan
   if(InpUseGrid && InpUseStopLoss)
   {
      Print("=========================================================");
      Print("[SR] FATAL ERROR: InpUseGrid=true DAN InpUseStopLoss=true!");
      Print("[SR] Pilih SATU mode saja:");
      Print("[SR]   - Mode GRID:      InpUseGrid=true,  InpUseStopLoss=false");
      Print("[SR]   - Mode STOP LOSS: InpUseGrid=false, InpUseStopLoss=true");
      Print("[SR]   - Mode NONE:      InpUseGrid=false, InpUseStopLoss=false");
      Print("[SR] EA TIDAK BISA BERJALAN. Ubah setting lalu restart.");
      Print("=========================================================");
      return(INIT_PARAMETERS_INCORRECT);
   }

   hFractal = iFractals(_Symbol, InpSNR_Timeframe);
   if(hFractal == INVALID_HANDLE)
   {
      Print("[SR] FATAL: iFractals() gagal. Error=", GetLastError());
      return(INIT_FAILED);
   }

   hRSI = iRSI(_Symbol, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE)
   {
      Print("[RSI] FATAL: iRSI() gagal. Error=", GetLastError());
      return(INIT_FAILED);
   }

   hATR = iATR(_Symbol, InpATR_Timeframe, InpATR_Period);
   if(hATR == INVALID_HANDLE)
   {
      Print("[ATR] FATAL: iATR() gagal. Error=", GetLastError());
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(GetAllowedFillingMode());

   lastSNRBarTime     = 0;
   snrReady           = false;
   g_ATR_Entry        = 0.0;
   g_ATR_Ticket       = 0;
   g_lastPanelUpdate  = 0;
   g_lastM1Bar        = 0;
   g_cachedRSI        = 0.0;
   g_cachedATR        = 0.0;

   //--- v6.3: Tentukan mode string untuk log
   string modeStr = "NONE";
   if(InpUseGrid)      modeStr = "GRID";
   if(InpUseStopLoss)  modeStr = "STOPLOSS";

   Print("[SR] v7.1 State+RiskGovernor Initialized",
         " | Tester=", (isTester ? "YES" : "NO"),
         " | MaxSNRBars=", InpMaxSNRBars,
         " | Hours=", (InpUseTimeFilter ? StringFormat("%02d:00-%02d:00", InpStartHour, InpEndHour) : "OFF"),
         " | Mode=", modeStr,
         " | SL=", (InpUseStopLoss ? StringFormat("%d pts", InpSL_Points) : "OFF"),
         " | Grid=", (InpUseGrid ? "ON" : "OFF"),
         " | Trailing=", (InpUseSmartTrailing ? "ON" : "OFF"),
         " | TP=", InpTP_Points, " pts");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFractal != INVALID_HANDLE) { IndicatorRelease(hFractal); hFractal = INVALID_HANDLE; }
   if(hRSI != INVALID_HANDLE)     { IndicatorRelease(hRSI);     hRSI = INVALID_HANDLE; }
   if(hATR != INVALID_HANDLE)     { IndicatorRelease(hATR);     hATR = INVALID_HANDLE; }
   ObjectsDeleteAll(0, "SR_");
   ObjectsDeleteAll(0, "ENTRY_");
   Comment("");
}

//+------------------------------------------------------------------+
//| Hitung posisi terbuka                                              |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Hitung posisi per tipe                                             |
//+------------------------------------------------------------------+
int CountPositionsByType(int type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Ambil open price terakhir per tipe                                 |
//+------------------------------------------------------------------+
double GetLastOpenPrice(int type)
{
   double lastPrice = 0.0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime > lastTime)
         {
            lastTime  = openTime;
            lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
   return lastPrice;
}

//+------------------------------------------------------------------+
//| Hitung profit basket                                               |
//+------------------------------------------------------------------+
double GetBasketProfit()
{
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT)
                      + PositionGetDouble(POSITION_SWAP);
      }
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Hitung total lots                                                  |
//+------------------------------------------------------------------+
double GetBasketTotalLots()
{
   double totalLots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0 &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         totalLots += PositionGetDouble(POSITION_VOLUME);
   }
   return totalLots;
}

//+------------------------------------------------------------------+
//| Ambil RSI (raw)                                                    |
//+------------------------------------------------------------------+
double GetRSI_M1_Raw()
{
   double rsiBuffer[];
   ArraySetAsSeries(rsiBuffer, true);
   if(CopyBuffer(hRSI, 0, 0, 3, rsiBuffer) < 3)
      return(-1.0);
   return(NormalizeDouble(rsiBuffer[0], 2));
}

//+------------------------------------------------------------------+
//| Ambil ATR (raw)                                                    |
//+------------------------------------------------------------------+
double GetATR_Points_Raw()
{
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(hATR, 0, 0, 1, atrBuffer) < 1)
      return(0.0);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return(0.0);
   return(atrBuffer[0] / point);
}

//+------------------------------------------------------------------+
//| Cek ATR di zona ranging                                           |
//+------------------------------------------------------------------+
bool IsATR_InRange(double atrPoints)
{
   if(atrPoints < InpATR_MinPoints || atrPoints > InpATR_MaxPoints)
      return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| Deteksi Daily Range                                                |
//+------------------------------------------------------------------+
int DetectDailyRange()
{
   if(!InpUseTrendFilter)
      return(0);

   double dailyOpen  = iOpen(_Symbol, PERIOD_D1, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(dailyOpen <= 0.0 || point <= 0.0)
      return(0);

   double rangePoints = (currentBid - dailyOpen) / point;

   if(rangePoints >= InpDailyRangeThreshold)  return(1);
   if(rangePoints <= -InpDailyRangeThreshold) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
//| Daily Range dalam points                                           |
//+------------------------------------------------------------------+
double GetDailyRangePoints()
{
   double dailyOpen  = iOpen(_Symbol, PERIOD_D1, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(dailyOpen <= 0.0 || currentBid <= 0.0 || point <= 0.0)
      return(0.0);
   return((currentBid - dailyOpen) / point);
}

//+------------------------------------------------------------------+
//| Cek spread                                                        |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   if(InpMaxSpreadPoints <= 0) return(true);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) return(true);
   double spreadPoints = (ask - bid) / point;
   return(spreadPoints <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Cek min bars antar trade                                          |
//+------------------------------------------------------------------+
bool IsMinBarsElapsed()
{
   if(InpMinBarsBetweenTrades <= 0 || lastTradeTime == 0)
      return(true);
   int minutesSinceTrade = (int)((TimeCurrent() - lastTradeTime) / 60);
   return(minutesSinceTrade >= InpMinBarsBetweenTrades);
}

//+------------------------------------------------------------------+
//| NormalizeLot — sesuai SYMBOL_VOLUME_STEP (FIX v6.2.1)            |
//+------------------------------------------------------------------+
double NormalizeLot(double rawLot)
{
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volStep <= 0.0) volStep = 0.01;

   double lot = MathFloor(rawLot / volStep) * volStep;

   if(lot < volMin) lot = volMin;
   if(lot > volMax) lot = volMax;

   int stepDigits = (int)MathCeil(-MathLog10(volStep));
   if(stepDigits < 0) stepDigits = 0;
   lot = NormalizeDouble(lot, stepDigits);

   return lot;
}

//+------------------------------------------------------------------+
//| Draw lightweight entry marker in Strategy Tester                   |
//+------------------------------------------------------------------+
void DrawEntryMarker(bool isBuy, double price)
{
   if(!isTester || !InpShowEntryMarkerInTester)
      return;
   datetime t = TimeCurrent();
   string name = "ENTRY_" + IntegerToString((long)t);
   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   if(isBuy)
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 233);
   else
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 234);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrLime : clrRed);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
}

//+------------------------------------------------------------------+
//| ExecuteBuy — TP PRIBADI + SL Mode v6.3                            |
//+------------------------------------------------------------------+
bool ExecuteBuy(double supportLevel, double rsiValue, double atrPoints)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Adaptive ATR TP
      double tp = 0.0;
      if(InpUseATR_SLTP && atrPoints > 0)
         tp = NormalizeDouble(ask + atrPoints * InpTP_ATR_Mult * point, digits);
      else if(InpTP_Points > 0)
         tp = NormalizeDouble(ask + InpTP_Points * point, digits);

      //--- Adaptive ATR SL
      double sl = 0.0;
      if(InpUseStopLoss)
      {
         if(InpUseATR_SLTP && atrPoints > 0)
            sl = NormalizeDouble(ask - atrPoints * InpSL_ATR_Mult * point, digits);
         else if(InpSL_Points > 0)
            sl = NormalizeDouble(ask - InpSL_Points * point, digits);
      }

      string comment = StringFormat("%s Buy|S:%s|RSI:%.1f|ENTRY",
                        InpOrderComment, DoubleToString(supportLevel, digits), rsiValue);

      if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, comment))
      {
         uint retcode = trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED)
         {
            g_ATR_Entry   = atrPoints;
            g_ATR_Ticket  = ResolvePositionTicket();
            lastTradeTime = TimeCurrent();
            DrawEntryMarker(true, ask);
            return(true);
         }
      }
      if(!isTester && attempt < InpMaxRetries) Sleep(InpRetryDelayMs);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| ExecuteSell — TP PRIBADI + SL Mode v6.3                           |
//+------------------------------------------------------------------+
bool ExecuteSell(double resistanceLevel, double rsiValue, double atrPoints)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      //--- Adaptive ATR TP
      double tp = 0.0;
      if(InpUseATR_SLTP && atrPoints > 0)
         tp = NormalizeDouble(bid - atrPoints * InpTP_ATR_Mult * point, digits);
      else if(InpTP_Points > 0)
         tp = NormalizeDouble(bid - InpTP_Points * point, digits);

      //--- Adaptive ATR SL
      double sl = 0.0;
      if(InpUseStopLoss)
      {
         if(InpUseATR_SLTP && atrPoints > 0)
            sl = NormalizeDouble(bid + atrPoints * InpSL_ATR_Mult * point, digits);
         else if(InpSL_Points > 0)
            sl = NormalizeDouble(bid + InpSL_Points * point, digits);
      }

      string comment = StringFormat("%s Sell|R:%s|RSI:%.1f|ENTRY",
                        InpOrderComment, DoubleToString(resistanceLevel, digits), rsiValue);

      if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, comment))
      {
         uint retcode = trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED)
         {
            g_ATR_Entry   = atrPoints;
            g_ATR_Ticket  = ResolvePositionTicket();
            lastTradeTime = TimeCurrent();
            DrawEntryMarker(false, bid);
            return(true);
         }
      }
      if(!isTester && attempt < InpMaxRetries) Sleep(InpRetryDelayMs);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Margin Safety Gate — prevent grid spam when margin insufficient    |
//+------------------------------------------------------------------+
bool EnoughMargin(double lot, ENUM_ORDER_TYPE type)
{
   double price = (type == ORDER_TYPE_BUY)
      ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double margin;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_FREEMARGIN);

   // safety buffer 30%
   return (freeMargin > margin * 1.3);
}

//+------------------------------------------------------------------+
//| ManageGrid — FIX: lot normalization + basket pre-check            |
//+------------------------------------------------------------------+
void ManageGrid(int cachedBuyCount, int cachedSellCount)
{
   if(!InpUseGrid) return;
   if(cachedBuyCount == 0 && cachedSellCount == 0) return;

   //--- FIX: Jangan buka grid baru jika basket sudah capai target
   double liveBasket = GetBasketProfit();
   if(liveBasket >= InpBasketProfitMoney) return;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- BUY GRID
   if(cachedBuyCount > 0 && cachedSellCount == 0)
   {
      if(cachedBuyCount >= InpMaxGridLevel) return;

      double lastPrice = GetLastOpenPrice(POSITION_TYPE_BUY);
      double gridStep  = InpGridStepPoints * point;

      if(lastPrice > 0.0 && bid <= lastPrice - gridStep)
      {
         double rawLot = InpLotSize * MathPow(InpMartingaleFactor, cachedBuyCount);
         double lot = NormalizeLot(rawLot);
         if(lot > InpMaxLotCap) lot = NormalizeLot(InpMaxLotCap);

         //--- v7.1: Margin safety gate
         if(!EnoughMargin(lot, ORDER_TYPE_BUY))
         {
            Print("[GRID] BLOCKED — Not enough margin for Buy lot=", DoubleToString(lot, 2));
            return;
         }

         string comment = StringFormat("%s Buy|GRID|G%d", InpOrderComment, cachedBuyCount);
         trade.Buy(lot, _Symbol, ask, 0.0, 0.0, comment);
      }
   }

   //--- SELL GRID
   if(cachedSellCount > 0 && cachedBuyCount == 0)
   {
      if(cachedSellCount >= InpMaxGridLevel) return;

      double lastPrice = GetLastOpenPrice(POSITION_TYPE_SELL);
      double gridStep  = InpGridStepPoints * point;

      if(lastPrice > 0.0 && ask >= lastPrice + gridStep)
      {
         double rawLot = InpLotSize * MathPow(InpMartingaleFactor, cachedSellCount);
         double lot = NormalizeLot(rawLot);
         if(lot > InpMaxLotCap) lot = NormalizeLot(InpMaxLotCap);

         //--- v7.1: Margin safety gate
         if(!EnoughMargin(lot, ORDER_TYPE_SELL))
         {
            Print("[GRID] BLOCKED — Not enough margin for Sell lot=", DoubleToString(lot, 2));
            return;
         }

         string comment = StringFormat("%s Sell|GRID|G%d", InpOrderComment, cachedSellCount);
         trade.Sell(lot, _Symbol, bid, 0.0, 0.0, comment);
      }
   }
}

//+------------------------------------------------------------------+
//| CloseAllPositions — retry + verifikasi                            |
//| Return: true jika SEMUA posisi EA berhasil ditutup                |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   for(int attempt = 1; attempt <= InpMaxRetries; attempt++)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         if(!trade.PositionClose(ticket))
         {
            Print("[GRID FIX] Close FAILED ticket=", ticket,
                  " attempt=", attempt,
                  " error=", GetLastError());
         }
         else
         {
            uint retcode = trade.ResultRetcode();
            if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
            {
               Print("[GRID FIX] Close REJECTED ticket=", ticket,
                     " retcode=", retcode,
                     " attempt=", attempt);
            }
         }
      }

      //--- Verifikasi: cek apakah masih ada posisi tersisa
      int remaining = CountOpenPositions();
      if(remaining == 0)
         return true;

      if(attempt < InpMaxRetries)
      {
         if(!isTester) Sleep(InpRetryDelayMs);
      }
   }

   int finalRemaining = CountOpenPositions();
   if(finalRemaining > 0)
   {
      Print("[GRID FIX] WARNING: ", finalRemaining, " posisi masih terbuka setelah ",
            InpMaxRetries, " retry attempts!");
   }
   return (finalRemaining == 0);
}

//+------------------------------------------------------------------+
//| CheckBasketClose — real-time recalc + retry + verify              |
//+------------------------------------------------------------------+
void CheckBasketClose(double cachedBasket)
{
   //--- Quick check dengan cached value dulu (optimasi CPU)
   if(cachedBasket < InpBasketProfitMoney)
      return;

   //--- Recalculate basket REAL-TIME sebelum close
   double liveBasket = GetBasketProfit();
   if(liveBasket < InpBasketProfitMoney)
      return;

   Print("[BASKET] Target tercapai! Live=$", DoubleToString(liveBasket, 2),
         " / Target=$", DoubleToString(InpBasketProfitMoney, 2),
         " — Closing ALL positions...");

   //--- Close semua dengan retry + verifikasi
   bool allClosed = CloseAllPositions();

   if(allClosed)
   {
      g_ATR_Entry  = 0.0;
      g_ATR_Ticket = 0;
      Print("[BASKET] Semua posisi berhasil ditutup.");
   }
   else
   {
      Print("[BASKET] WARNING: Masih ada posisi terbuka, akan retry di tick berikutnya.");
   }
}

//+------------------------------------------------------------------+
//| Get broker minimum stop distance                                   |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(point <= 0.0 || stopLevel <= 0)
      return 0.0;

   return stopLevel * point;
}

//+------------------------------------------------------------------+
//| State detector — any position in profit?                           |
//+------------------------------------------------------------------+
bool IsPositionInProfit()
{
   if(PositionsTotal() == 0)
      return false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0.0)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ApplySmartTrailing                                                 |
//+------------------------------------------------------------------+
void ApplySmartTrailing()
{
   if(!InpUseSmartTrailing) return;
   if(g_ATR_Entry <= 0.0 || g_ATR_Ticket == 0) return;

   if(!PositionSelectByTicket(g_ATR_Ticket))
   {
      g_ATR_Entry  = 0.0;
      g_ATR_Ticket = 0;
      return;
   }

   //--- v7: Safety — trailing NEVER activates in loss
   double posProfit = PositionGetDouble(POSITION_PROFIT);
   if(posProfit <= 0.0) return;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(point <= 0.0) return;

   double triggerDistance = g_ATR_Entry * InpTrail_ATR_Mult * point;

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl        = PositionGetDouble(POSITION_SL);
   double tp        = PositionGetDouble(POSITION_TP);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
   {
      double profitDistance = bid - openPrice;
      if(profitDistance <= 0.0) return;
      if(profitDistance > triggerDistance)
      {
         double newSL = NormalizeDouble(bid - InpTrail_BufferPts * point, digits);
         //--- v7.1: Skip if SL movement too small (anti-spam)
         if(MathAbs(newSL - sl) < 50 * point)
            return;
         double minStop = GetMinStopDistance();
         if(newSL > sl && (bid - newSL) > minStop)
            trade.PositionModify(g_ATR_Ticket, newSL, tp);
      }
   }

   if(type == POSITION_TYPE_SELL)
   {
      double profitDistance = openPrice - ask;
      if(profitDistance <= 0.0) return;
      if(profitDistance > triggerDistance)
      {
         double newSL = NormalizeDouble(ask + InpTrail_BufferPts * point, digits);
         //--- v7.1: Skip if SL movement too small (anti-spam)
         if(sl != 0.0 && MathAbs(newSL - sl) < 50 * point)
            return;
         double minStop = GetMinStopDistance();
         if((newSL < sl || sl == 0.0) && (newSL - ask) > minStop)
            trade.PositionModify(g_ATR_Ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| BuildSNR — bar-limited                                            |
//+------------------------------------------------------------------+
void BuildSNR()
{
   int rawBars     = iBars(_Symbol, InpSNR_Timeframe);
   int rates_total = MathMin(rawBars, InpMaxSNRBars);

   if(rates_total < 10)
   {
      snrReady = false;
      return;
   }

   if(BarsCalculated(hFractal) <= 0)
   {
      snrReady = false;
      return;
   }

   ArraySetAsSeries(Resistance, false);
   ArraySetAsSeries(Support, false);
   ArrayResize(Resistance, rates_total);
   ArrayResize(Support, rates_total);
   ArrayInitialize(Resistance, 0.0);
   ArrayInitialize(Support, 0.0);
   ArraySetAsSeries(Resistance, true);
   ArraySetAsSeries(Support, true);

   double FractalUpperBuffer[];
   double FractalLowerBuffer[];
   double High[];
   double Low[];
   datetime Time[];

   if(CopyBuffer(hFractal, 0, 0, rates_total, FractalUpperBuffer) < rates_total) { snrReady = false; return; }
   if(CopyBuffer(hFractal, 1, 0, rates_total, FractalLowerBuffer) < rates_total) { snrReady = false; return; }
   if(CopyHigh(_Symbol, InpSNR_Timeframe, 0, rates_total, High) < rates_total)   { snrReady = false; return; }
   if(CopyLow (_Symbol, InpSNR_Timeframe, 0, rates_total, Low)  < rates_total)   { snrReady = false; return; }
   if(CopyTime(_Symbol, InpSNR_Timeframe, 0, rates_total, Time)  < rates_total)  { snrReady = false; return; }

   ArraySetAsSeries(FractalUpperBuffer, true);
   ArraySetAsSeries(FractalLowerBuffer, true);
   ArraySetAsSeries(High, true);
   ArraySetAsSeries(Low, true);
   ArraySetAsSeries(Time, true);

   for(int i = rates_total - 2; i >= 0; i--)
   {
      if(FractalUpperBuffer[i] != EMPTY_VALUE)
         Resistance[i] = High[i];
      else
         Resistance[i] = Resistance[i + 1];

      if(FractalLowerBuffer[i] != EMPTY_VALUE)
         Support[i] = Low[i];
      else
         Support[i] = Support[i + 1];
   }

   if(!isTester && InpVisualBars > 0)
      DrawHistoricalArrows(Time, rates_total);

   snrReady = true;
}

//+------------------------------------------------------------------+
//| Expert tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewSNRBar())
      BuildSNR();

   if(!snrReady) return;
   if(BarsCalculated(hRSI) <= 0) return;
   if(BarsCalculated(hATR) <= 0) return;

   //--- Cache RSI/ATR per M1 bar
   datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
   if(currentM1 != g_lastM1Bar)
   {
      g_lastM1Bar  = currentM1;
      g_cachedRSI  = GetRSI_M1_Raw();
      g_cachedATR  = GetATR_Points_Raw();
   }

   double rsiValue  = g_cachedRSI;
   double atrPoints = g_cachedATR;

   //--- Cache position counts (1x per tick)
   int totalPositions = CountOpenPositions();
   int buyCount       = CountPositionsByType(POSITION_TYPE_BUY);
   int sellCount      = CountPositionsByType(POSITION_TYPE_SELL);
   double basket      = GetBasketProfit();
   double totalLots   = GetBasketTotalLots();

   //=================================================================
   // ENTRY LOGIC — jam trading filter di paling atas
   //=================================================================
   if(!IsWithinTradingHours())
   {
      // Di luar jam trading — skip entry
      // Grid/Trailing/Basket tetap jalan di bawah
   }
   else if(InpMaxOpenTrades > 0 && totalPositions >= InpMaxOpenTrades)
   {
      // skip
   }
   else if(!IsMinBarsElapsed())
   {
      // skip
   }
   else if(!IsSpreadAcceptable())
   {
      // skip
   }
   else if(!IsATR_InRange(atrPoints))
   {
      // skip
   }
   else
   {
      int dailyDirection = DetectDailyRange();

      if(dailyDirection != 0 && rsiValue >= 0)
      {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

         double currentResistance = Resistance[0];
         double currentSupport    = Support[0];
         double tolerance         = InpSNR_Tolerance * point;

         if(dailyDirection == 1)
         {
            if(currentSupport > 0.0 &&
               ask >= (currentSupport - tolerance) &&
               ask <= (currentSupport + tolerance) &&
               rsiValue <= InpRSI_Oversold)
            {
               ExecuteBuy(currentSupport, rsiValue, atrPoints);
            }
         }

         if(dailyDirection == -1)
         {
            if(currentResistance > 0.0 &&
               bid <= (currentResistance + tolerance) &&
               bid >= (currentResistance - tolerance) &&
               rsiValue >= InpRSI_Overbought)
            {
               ExecuteSell(currentResistance, rsiValue, atrPoints);
            }
         }
      }
   }

   //=================================================================
   // STATE BASED EXIT ENGINE (v7)
   // LOSS STATE  → GRID ENGINE ACTIVE
   // PROFIT STATE → TRAILING ENGINE ACTIVE
   // Mutual exclusion: grid and trailing NEVER run simultaneously
   //=================================================================

   if(totalPositions > 0)
   {
      bool inProfit = IsPositionInProfit();

      if(inProfit)
      {
         //--- PROFIT STATE: trailing protects profit
         if(InpUseSmartTrailing && totalPositions == 1)
            ApplySmartTrailing();
      }
      else
      {
         //--- LOSS STATE: grid recovery averaging
         if(InpUseGrid)
            ManageGrid(buyCount, sellCount);
      }

      //--- Basket close: independent safety net (only for multi-position grids)
      if(totalPositions > 1)
         CheckBasketClose(GetBasketProfit());
   }

   //=================================================================
   // Panel — skip di tester, throttle di live
   //=================================================================
   if(!isTester)
   {
      if(GetTickCount() - g_lastPanelUpdate > 250)
      {
         g_lastPanelUpdate = GetTickCount();
         UpdatePanel(rsiValue, atrPoints, totalPositions, buyCount, sellCount, basket, totalLots);
      }
   }
}

//+------------------------------------------------------------------+
//| Panel update                                                       |
//+------------------------------------------------------------------+
void UpdatePanel(double rsiValue, double atrPoints, int totalPos,
                 int buyCount, int sellCount, double basket, double totalLots)
{
   double dailyRange = GetDailyRangePoints();
   int    dailyDir   = DetectDailyRange();

   string atrStatus = "IDEAL";
   if(atrPoints < InpATR_MinPoints) atrStatus = "DEAD";
   else if(atrPoints > InpATR_MaxPoints) atrStatus = "VOLATILE";

   string dailyStatus = "NEUTRAL";
   if(!InpUseTrendFilter) dailyStatus = "OFF";
   else if(dailyDir == 1) dailyStatus = "BULLISH";
   else if(dailyDir == -1) dailyStatus = "BEARISH";

   //--- v6.3: Tentukan exit mode berdasarkan mode aktif
   bool gridActive = (InpUseGrid && totalPos > 1);
   string exitMode;
   if(InpUseStopLoss)
      exitMode = StringFormat("STOPLOSS (%d pts)", InpSL_Points);
   else if(gridActive)
      exitMode = "GRID+BASKET";
   else
      exitMode = "TP+TRAILING";

   string gridStatus;
   if(InpUseStopLoss)
      gridStatus = "OFF (SL Mode)";
   else if(gridActive)
      gridStatus = StringFormat("ACTIVE Lvl=%d/%d", (buyCount > 0 ? buyCount : sellCount), InpMaxGridLevel);
   else if(InpUseGrid)
      gridStatus = "STANDBY";
   else
      gridStatus = "OFF";

   //--- v6.3: Mode label
   string modeLabel;
   if(InpUseStopLoss)       modeLabel = "STOP LOSS";
   else if(InpUseGrid)      modeLabel = "GRID";
   else                     modeLabel = "NONE";

   //--- Jam trading status
   bool inHours = IsWithinTradingHours();
   string timeStatus;
   if(!InpUseTimeFilter)
      timeStatus = "OFF (24h)";
   else if(inHours)
      timeStatus = StringFormat("ACTIVE (%02d:00-%02d:00)", InpStartHour, InpEndHour);
   else
      timeStatus = StringFormat("CLOSED (open %02d:00-%02d:00)", InpStartHour, InpEndHour);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread     = (point > 0) ? (currentAsk - currentBid) / point : 0;

   MqlDateTime dt;
   TimeCurrent(dt);

   Comment(StringFormat(
      "=== SR v6.3 HOURS+OPT+%s ===\n"
      "Broker Time : %02d:%02d:%02d\n"
      "Trade Hours : %s\n"
      "-------------------------\n"
      "R[0]: %s | S[0]: %s\n"
      "RSI: %.1f | ATR: %.0f [%s]\n"
      "Daily: %.0f [%s]\n"
      "-------------------------\n"
      "Mode: %s\n"
      "EXIT: %s\n"
      "Grid: %s\n"
      "Basket: $%.2f / $%.2f\n"
      "Trail: %s\n"
      "-------------------------\n"
      "Pos: %d (B:%d S:%d)\n"
      "Lots: %.2f | Spread: %.0f\n"
      "=========================",
      modeLabel,
      dt.hour, dt.min, dt.sec,
      timeStatus,
      DoubleToString(Resistance[0], _Digits),
      DoubleToString(Support[0], _Digits),
      rsiValue, atrPoints, atrStatus,
      dailyRange, dailyStatus,
      modeLabel,
      exitMode,
      gridStatus,
      basket, InpBasketProfitMoney,
      (InpUseSmartTrailing && !gridActive) ? "READY" : "OFF",
      totalPos, buyCount, sellCount,
      totalLots, spread
   ));
}

//+------------------------------------------------------------------+
//| DrawHistoricalArrows                                               |
//+------------------------------------------------------------------+
void DrawHistoricalArrows(const datetime &Time[], int rates_total)
{
   if(isTester) return;

   int limit = MathMin(InpVisualBars, rates_total - 1);

   for(int i = 0; i < limit; i++)
   {
      string rName = "SR_ArrowR_" + IntegerToString(i);
      if(Resistance[i] > 0.0)
      {
         if(ObjectFind(0, rName) < 0)
         {
            ObjectCreate(0, rName, OBJ_ARROW, 0, Time[i], Resistance[i]);
            ObjectSetInteger(0, rName, OBJPROP_ARROWCODE, 119);
            ObjectSetInteger(0, rName, OBJPROP_COLOR, clrRed);
            ObjectSetInteger(0, rName, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, rName, OBJPROP_BACK, true);
            ObjectSetInteger(0, rName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, rName, OBJPROP_HIDDEN, true);
         }
         else
         {
            ObjectSetInteger(0, rName, OBJPROP_TIME, 0, Time[i]);
            ObjectSetDouble(0, rName, OBJPROP_PRICE, 0, Resistance[i]);
         }
      }
      else
         ObjectDelete(0, rName);

      string sName = "SR_ArrowS_" + IntegerToString(i);
      if(Support[i] > 0.0)
      {
         if(ObjectFind(0, sName) < 0)
         {
            ObjectCreate(0, sName, OBJ_ARROW, 0, Time[i], Support[i]);
            ObjectSetInteger(0, sName, OBJPROP_ARROWCODE, 119);
            ObjectSetInteger(0, sName, OBJPROP_COLOR, clrDodgerBlue);
            ObjectSetInteger(0, sName, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, sName, OBJPROP_BACK, true);
            ObjectSetInteger(0, sName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, sName, OBJPROP_HIDDEN, true);
         }
         else
         {
            ObjectSetInteger(0, sName, OBJPROP_TIME, 0, Time[i]);
            ObjectSetDouble(0, sName, OBJPROP_PRICE, 0, Support[i]);
         }
      }
      else
         ObjectDelete(0, sName);
   }
}
//+------------------------------------------------------------------+
