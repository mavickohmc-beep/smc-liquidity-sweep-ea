//+------------------------------------------------------------------+
//|                                                      claude1.mq5 |
//|            SMC Liquidity Sweep + IFVG Entry Strategy            |
//|                                                                  |
//|  Flow:                                                           |
//|   1. Mark Asian & London session highs/lows each day            |
//|   2. Detect sweep: wick pierces level, candle closes back inside |
//|   3. Scan lower TF for IFVG created during the sweep impulse    |
//|   4. Enter when price retraces into the IFVG zone               |
//|   5. 1:2 Risk-to-Reward (TP = 2x SL distance)                  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//=== Inputs =========================================================

input group "=== Session Times (Server Time) ==="
input int    InpAsianStart   = 0;    // Asian Session Start (hour)
input int    InpAsianEnd     = 8;    // Asian Session End (hour)
input int    InpLondonStart  = 8;    // London Session Start (hour)
input int    InpLondonEnd    = 16;   // London Session End (hour)

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpSweepTF = PERIOD_H1;  // Sweep Detection Timeframe
input ENUM_TIMEFRAMES InpEntryTF = PERIOD_M5;  // Entry Timeframe (IFVG)

input group "=== Trade Settings ==="
input double InpLotSize      = 0.01;  // Lot Size
input double InpSLBufferPip  = 5.0;   // SL Buffer beyond sweep candle (pips)
input int    InpMagicNumber  = 98765; // EA Magic Number

input group "=== Session Filters ==="
input bool   InpTradeAsian   = true;  // Trade Asian Session Sweeps
input bool   InpTradeLondon  = true;  // Trade London Session Sweeps
input int    InpFVGLookback  = 50;    // IFVG lookback (bars on Entry TF)

//=== Types ==========================================================

struct SessionLevels
  {
   double   high;
   double   low;
   bool     highSwept;
   bool     lowSwept;
  };

enum SWEEP_TYPE { SWEEP_NONE, SWEEP_BEAR, SWEEP_BULL };

struct SweepState
  {
   SWEEP_TYPE type;
   double     candleHigh;   // sweep candle high → used for SL on short
   double     candleLow;    // sweep candle low  → used for SL on long
   datetime   time;
   bool       entryTaken;
  };

struct IFVGZone
  {
   bool     valid;
   double   top;
   double   bottom;
   datetime startTime;
  };

//=== Globals ========================================================

CTrade        g_trade;
SessionLevels g_asian;
SessionLevels g_london;
SweepState    g_sweep;
IFVGZone      g_ifvg;

datetime      g_lastDay  = 0;
datetime      g_lastBar  = 0;
double        g_pip      = 0.0;

const string  OBJ_ASIAN_H = "SMC_AsianH";
const string  OBJ_ASIAN_L = "SMC_AsianL";
const string  OBJ_LON_H   = "SMC_LonH";
const string  OBJ_LON_L   = "SMC_LonL";
const string  OBJ_FVG     = "SMC_IFVG";
const string  OBJ_SWEEP   = "SMC_Sweep";

//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_pip = (_Digits == 5 || _Digits == 3) ? _Point * 10.0 : _Point;
   ResetDay();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "SMC_");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Day boundary reset
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(today != g_lastDay)
     {
      g_lastDay = today;
      ResetDay();
     }

   //--- On every new SweepTF bar: rebuild levels and check for sweeps
   datetime barNow = iTime(_Symbol, InpSweepTF, 0);
   if(barNow != g_lastBar)
     {
      g_lastBar = barNow;
      BuildSessionLevels(dt);
      DrawSessionLevels();
      if(g_sweep.type == SWEEP_NONE)
         DetectSweep();
     }

   //--- Every tick: check for IFVG entry
   if(g_sweep.type != SWEEP_NONE && !g_sweep.entryTaken && !HasOpenTrade())
      TryIFVGEntry();
  }

//+------------------------------------------------------------------+
void ResetDay()
  {
   g_asian.high     = 0;       g_asian.low      = DBL_MAX;
   g_asian.highSwept = false;  g_asian.lowSwept = false;
   g_london.high    = 0;       g_london.low     = DBL_MAX;
   g_london.highSwept = false; g_london.lowSwept = false;
   g_sweep.type     = SWEEP_NONE;
   g_sweep.entryTaken = false;
   g_ifvg.valid     = false;
   ObjectsDeleteAll(0, "SMC_");
  }

//+------------------------------------------------------------------+
bool HasOpenTrade()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Scan SweepTF bars for today to build session highs/lows          |
//+------------------------------------------------------------------+
void BuildSessionLevels(MqlDateTime &dt)
  {
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   int maxBars = iBars(_Symbol, InpSweepTF);

   double aH = 0, aL = DBL_MAX;
   double lH = 0, lL = DBL_MAX;

   for(int i = 0; i < maxBars; i++)
     {
      datetime t = iTime(_Symbol, InpSweepTF, i);
      if(t < today) break;

      MqlDateTime bd;
      TimeToStruct(t, bd);
      double barH = iHigh(_Symbol, InpSweepTF, i);
      double barL = iLow(_Symbol,  InpSweepTF, i);

      if(bd.hour >= InpAsianStart && bd.hour < InpAsianEnd)
        {
         if(barH > aH) aH = barH;
         if(barL < aL) aL = barL;
        }
      if(bd.hour >= InpLondonStart && bd.hour < InpLondonEnd)
        {
         if(barH > lH) lH = barH;
         if(barL < lL) lL = barL;
        }
     }

   if(aH > 0) { g_asian.high = aH; g_asian.low = aL; }
   if(lH > 0) { g_london.high = lH; g_london.low = lL; }
  }

//+------------------------------------------------------------------+
//| Draw dashed horizontal lines for session levels                  |
//+------------------------------------------------------------------+
void DrawSessionLevels()
  {
   if(g_asian.high > 0 && g_asian.low < DBL_MAX)
     {
      DrawHLine(OBJ_ASIAN_H, g_asian.high, clrDarkOrange, "Asian High");
      DrawHLine(OBJ_ASIAN_L, g_asian.low,  clrDarkOrange, "Asian Low");
     }
   if(g_london.high > 0 && g_london.low < DBL_MAX)
     {
      DrawHLine(OBJ_LON_H, g_london.high, clrDodgerBlue, "London High");
      DrawHLine(OBJ_LON_L, g_london.low,  clrDodgerBlue, "London Low");
     }
  }

//+------------------------------------------------------------------+
void DrawHLine(const string name, double price, color clr, string tooltip)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0,  name, OBJPROP_PRICE,   price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,   clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,   STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,   1);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP, tooltip + ": " + DoubleToString(price, _Digits));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Detect sweep: bar[1] wick pierces session level, closes inside   |
//+------------------------------------------------------------------+
void DetectSweep()
  {
   double ph = iHigh(_Symbol,  InpSweepTF, 1);
   double pl = iLow(_Symbol,   InpSweepTF, 1);
   double pc = iClose(_Symbol, InpSweepTF, 1);
   datetime pt = iTime(_Symbol, InpSweepTF, 1);

   // Asian High Sweep → bearish (price pushed above high, closed below)
   if(InpTradeAsian && g_asian.high > 0 && !g_asian.highSwept)
      if(ph > g_asian.high && pc < g_asian.high)
        {
         g_asian.highSwept = true;
         ActivateSweep(SWEEP_BEAR, ph, pl, pt);
         PrintFormat("[SMC] BEARISH sweep — Asian High %.5f  |  bar H=%.5f  C=%.5f", g_asian.high, ph, pc);
         return;
        }

   // Asian Low Sweep → bullish
   if(InpTradeAsian && g_asian.low < DBL_MAX && !g_asian.lowSwept)
      if(pl < g_asian.low && pc > g_asian.low)
        {
         g_asian.lowSwept = true;
         ActivateSweep(SWEEP_BULL, ph, pl, pt);
         PrintFormat("[SMC] BULLISH sweep — Asian Low %.5f  |  bar L=%.5f  C=%.5f", g_asian.low, pl, pc);
         return;
        }

   // London High Sweep → bearish
   if(InpTradeLondon && g_london.high > 0 && !g_london.highSwept)
      if(ph > g_london.high && pc < g_london.high)
        {
         g_london.highSwept = true;
         ActivateSweep(SWEEP_BEAR, ph, pl, pt);
         PrintFormat("[SMC] BEARISH sweep — London High %.5f  |  bar H=%.5f  C=%.5f", g_london.high, ph, pc);
         return;
        }

   // London Low Sweep → bullish
   if(InpTradeLondon && g_london.low < DBL_MAX && !g_london.lowSwept)
      if(pl < g_london.low && pc > g_london.low)
        {
         g_london.lowSwept = true;
         ActivateSweep(SWEEP_BULL, ph, pl, pt);
         PrintFormat("[SMC] BULLISH sweep — London Low %.5f  |  bar L=%.5f  C=%.5f", g_london.low, pl, pc);
         return;
        }
  }

//+------------------------------------------------------------------+
void ActivateSweep(SWEEP_TYPE type, double h, double l, datetime t)
  {
   g_sweep.type       = type;
   g_sweep.candleHigh = h;
   g_sweep.candleLow  = l;
   g_sweep.time       = t;
   g_sweep.entryTaken = false;
   g_ifvg.valid       = false;

   // Arrow on sweep candle
   if(ObjectFind(0, OBJ_SWEEP) >= 0) ObjectDelete(0, OBJ_SWEEP);
   double arrowPrice = (type == SWEEP_BEAR) ? h : l;
   int    arrowCode  = (type == SWEEP_BEAR) ? 234 : 233;  // down/up arrow
   color  arrowClr   = (type == SWEEP_BEAR) ? clrRed : clrLime;
   ObjectCreate(0, OBJ_SWEEP, OBJ_ARROW, 0, t, arrowPrice);
   ObjectSetInteger(0, OBJ_SWEEP, OBJPROP_ARROWCODE, arrowCode);
   ObjectSetInteger(0, OBJ_SWEEP, OBJPROP_COLOR, arrowClr);
   ObjectSetInteger(0, OBJ_SWEEP, OBJPROP_WIDTH, 2);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Entry logic: find IFVG, then enter when price fills it           |
//+------------------------------------------------------------------+
void TryIFVGEntry()
  {
   if(!g_ifvg.valid)
     {
      if(!FindIFVG()) return;
      DrawIFVGBox();
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_sweep.type == SWEEP_BULL)
     {
      // Low swept → expect UP
      // Bearish FVG is now IFVG (support) → enter LONG when ask drops into zone
      if(ask <= g_ifvg.top && ask >= g_ifvg.bottom)
        {
         double sl   = g_sweep.candleLow - InpSLBufferPip * g_pip;
         double dist = ask - sl;
         double tp   = ask + 2.0 * dist;
         if(dist > 0 && g_trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "SMC-IFVG-Long"))
           {
            g_sweep.entryTaken = true;
            PrintFormat("[SMC] LONG  entry=%.5f  SL=%.5f  TP=%.5f  RR=1:2", ask, sl, tp);
           }
        }
     }
   else
     {
      // High swept → expect DOWN
      // Bullish FVG is now IFVG (resistance) → enter SHORT when bid rises into zone
      if(bid >= g_ifvg.bottom && bid <= g_ifvg.top)
        {
         double sl   = g_sweep.candleHigh + InpSLBufferPip * g_pip;
         double dist = sl - bid;
         double tp   = bid - 2.0 * dist;
         if(dist > 0 && g_trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "SMC-IFVG-Short"))
           {
            g_sweep.entryTaken = true;
            PrintFormat("[SMC] SHORT entry=%.5f  SL=%.5f  TP=%.5f  RR=1:2", bid, sl, tp);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Scan EntryTF for the most recent qualifying FVG                  |
//|                                                                  |
//| 3-candle pattern  (index: i+2=oldest, i+1=middle, i=newest)     |
//|                                                                  |
//| Bullish FVG  → fast UP move  → gap: [high(i+2), low(i)]        |
//|   condition : low(i) > high(i+2)                                |
//|   used for SWEEP_BEAR (IFVG = resistance → SHORT)               |
//|                                                                  |
//| Bearish FVG  → fast DOWN move → gap: [high(i), low(i+2)]       |
//|   condition : high(i) < low(i+2)                                |
//|   used for SWEEP_BULL (IFVG = support → LONG)                   |
//+------------------------------------------------------------------+
bool FindIFVG()
  {
   int bars     = iBars(_Symbol, InpEntryTF);
   int lookback = MathMin(InpFVGLookback, bars - 3);

   for(int i = 1; i <= lookback; i++)
     {
      double h_new = iHigh(_Symbol, InpEntryTF, i);
      double l_new = iLow(_Symbol,  InpEntryTF, i);
      double h_old = iHigh(_Symbol, InpEntryTF, i + 2);
      double l_old = iLow(_Symbol,  InpEntryTF, i + 2);

      if(g_sweep.type == SWEEP_BEAR)
        {
         // Looking for bullish FVG (fast up move left gap) → IFVG = resistance
         if(l_new > h_old)
           {
            g_ifvg.valid     = true;
            g_ifvg.bottom    = h_old;
            g_ifvg.top       = l_new;
            g_ifvg.startTime = iTime(_Symbol, InpEntryTF, i + 2);
            PrintFormat("[SMC] IFVG found (bullish FVG → resistance): [%.5f – %.5f]", g_ifvg.bottom, g_ifvg.top);
            return true;
           }
        }
      else
        {
         // Looking for bearish FVG (fast down move left gap) → IFVG = support
         if(h_new < l_old)
           {
            g_ifvg.valid     = true;
            g_ifvg.bottom    = h_new;
            g_ifvg.top       = l_old;
            g_ifvg.startTime = iTime(_Symbol, InpEntryTF, i + 2);
            PrintFormat("[SMC] IFVG found (bearish FVG → support): [%.5f – %.5f]", g_ifvg.bottom, g_ifvg.top);
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
void DrawIFVGBox()
  {
   if(ObjectFind(0, OBJ_FVG) >= 0) ObjectDelete(0, OBJ_FVG);

   datetime t2   = TimeCurrent() + PeriodSeconds(InpSweepTF) * 10;
   color    clr  = (g_sweep.type == SWEEP_BEAR) ? clrLightCoral : clrLightGreen;

   ObjectCreate(0, OBJ_FVG, OBJ_RECTANGLE, 0, g_ifvg.startTime, g_ifvg.top, t2, g_ifvg.bottom);
   ObjectSetInteger(0, OBJ_FVG, OBJPROP_COLOR,   clr);
   ObjectSetInteger(0, OBJ_FVG, OBJPROP_FILL,    true);
   ObjectSetInteger(0, OBJ_FVG, OBJPROP_BACK,    true);
   ObjectSetString(0,  OBJ_FVG, OBJPROP_TOOLTIP, "IFVG Entry Zone");
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
