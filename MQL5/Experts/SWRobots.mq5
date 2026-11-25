#property strict
#property version   "1.00"
#property tester_indicator "Silent Wolf Trading\\silentwolfforex.ex5"
#property tester_indicator "Silent Wolf Trading\\silentwolfindices.ex5"

#include <Trade/Trade.mqh>

enum ENUM_SW_SOURCE
{
   SW_SOURCE_AUTO = 0,    // Automatique (graphique uniquement)
   SW_SOURCE_FOREX = 1,   // silentwolfforex
   SW_SOURCE_INDICES = 2  // silentwolfindices
};

input ENUM_SW_SOURCE InpIndicatorSource = SW_SOURCE_AUTO;
input string InpMonitoredTimeframes = "M5,M15,M30,H1,H4";
input double InpRiskPercent = 10.0;
input double InpMinimumSignalForce = 55.0;
input double InpTp1ClosePercent = 50.0;
input int InpDailyStopLossLimit = 3;
input int InpWeeklyStopLossLimit = 5;
input ulong InpMagicNumber = 20261124;
input int InpDeviationPoints = 20;

const int SW_BUFFER_BUY = 0;
const int SW_BUFFER_SELL = 1;
const int SW_BUFFER_ENTRY = 2;
const int SW_BUFFER_STOP = 3;
const int SW_BUFFER_TP1 = 4;
const int SW_BUFFER_TP2 = 5;
const int SW_BUFFER_FORCE = 6;

#define SW_MAX_TIMEFRAMES 21

struct SwTimeframeState
{
   ENUM_TIMEFRAMES timeframe;
   int indicatorHandle;
   datetime lastObservedBarOpen;
   datetime lastProcessedSignalTime;
   datetime pendingSignalBarTime;
   int pendingSignalReadAttempts;
   ulong nextSignalReadAttemptMs;
};

CTrade Trade;
SwTimeframeState TimeframeStates[SW_MAX_TIMEFRAMES];
int TimeframeCount = 0;
int SelectedIndicatorSource = SW_SOURCE_AUTO;
string SelectedIndicatorPath = "";
bool ConnectionWasAvailable = false;
datetime LastIndicatorWarningTime = 0;
datetime LastPauseWarningTime = 0;

uint SymbolHash(const string symbol)
{
   uint hash = 2166136261;
   for(int i = 0; i < StringLen(symbol); ++i)
      hash = (hash ^ (uint)StringGetCharacter(symbol, i)) * 16777619;
   return hash;
}

string CompactUnsigned(ulong value)
{
   const string digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
   if(value == 0)
      return "0";
   string encoded = "";
   while(value > 0)
   {
      int digit = (int)(value % 36);
      encoded = StringSubstr(digits, digit, 1) + encoded;
      value /= 36;
   }
   return encoded;
}

string InstanceKey(const ENUM_TIMEFRAMES timeframe)
{
   return "I." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + CompactUnsigned((ulong)SymbolHash(_Symbol))
          + "." + IntegerToString((long)timeframe);
}

string SignalStateKey(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                      const string field)
{
   return "S." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + CompactUnsigned((ulong)SymbolHash(_Symbol))
          + "." + IntegerToString((long)timeframe)
          + "." + IntegerToString((long)signalTime) + "." + field;
}

string PositionStateKey(const ulong positionId, const string field)
{
   return "P." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + IntegerToString((long)positionId) + "." + field;
}

string BreakevenKey(const ulong positionId)
{
   return "B." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + IntegerToString((long)positionId);
}

string SignalComment(const datetime signalTime, const ENUM_TIMEFRAMES timeframe)
{
   return "SWR:" + IntegerToString((long)signalTime) + ":"
          + IntegerToString((long)timeframe);
}

bool ParseSignalComment(const string comment, datetime &signalTime,
                        ENUM_TIMEFRAMES &timeframe)
{
   string fields[];
   ushort separator = (ushort)StringGetCharacter(":", 0);
   if(StringSplit(comment, separator, fields) < 3 || fields[0] != "SWR")
      return false;
   long parsedTime = StringToInteger(fields[1]);
   long parsedTimeframe = StringToInteger(fields[2]);
   if(parsedTime <= 0 || parsedTimeframe <= 0)
      return false;
   signalTime = (datetime)parsedTime;
   timeframe = (ENUM_TIMEFRAMES)parsedTimeframe;
   return true;
}

bool ParseTimeframeName(string name, ENUM_TIMEFRAMES &timeframe)
{
   StringTrimLeft(name);
   StringTrimRight(name);
   StringToUpper(name);
   if(name == "M1") timeframe = PERIOD_M1;
   else if(name == "M2") timeframe = PERIOD_M2;
   else if(name == "M3") timeframe = PERIOD_M3;
   else if(name == "M4") timeframe = PERIOD_M4;
   else if(name == "M5") timeframe = PERIOD_M5;
   else if(name == "M6") timeframe = PERIOD_M6;
   else if(name == "M10") timeframe = PERIOD_M10;
   else if(name == "M12") timeframe = PERIOD_M12;
   else if(name == "M15") timeframe = PERIOD_M15;
   else if(name == "M20") timeframe = PERIOD_M20;
   else if(name == "M30") timeframe = PERIOD_M30;
   else if(name == "H1") timeframe = PERIOD_H1;
   else if(name == "H2") timeframe = PERIOD_H2;
   else if(name == "H3") timeframe = PERIOD_H3;
   else if(name == "H4") timeframe = PERIOD_H4;
   else if(name == "H6") timeframe = PERIOD_H6;
   else if(name == "H8") timeframe = PERIOD_H8;
   else if(name == "H12") timeframe = PERIOD_H12;
   else if(name == "D1") timeframe = PERIOD_D1;
   else if(name == "W1") timeframe = PERIOD_W1;
   else if(name == "MN1" || name == "MN") timeframe = PERIOD_MN1;
   else return false;
   return true;
}

bool InitializeTimeframes()
{
   string names[];
   string configured = InpMonitoredTimeframes;
   StringReplace(configured, "/", ",");
   StringReplace(configured, ";", ",");
   ushort separator = (ushort)StringGetCharacter(",", 0);
   int configuredCount = StringSplit(configured, separator, names);
   if(configuredCount <= 0)
      return false;

   for(int i = 0; i < configuredCount; ++i)
   {
      ENUM_TIMEFRAMES timeframe;
      if(!ParseTimeframeName(names[i], timeframe))
      {
         Print("SWRobots : timeframe invalide dans InpMonitoredTimeframes : ", names[i]);
         return false;
      }
      bool duplicate = false;
      for(int existing = 0; existing < TimeframeCount; ++existing)
         if(TimeframeStates[existing].timeframe == timeframe)
            duplicate = true;
      if(duplicate)
         continue;
      if(TimeframeCount >= SW_MAX_TIMEFRAMES)
         return false;

      TimeframeStates[TimeframeCount].timeframe = timeframe;
      TimeframeStates[TimeframeCount].indicatorHandle = INVALID_HANDLE;
      TimeframeCount++;
   }
   return TimeframeCount > 0;
}

string IndicatorPathForSource(const int source)
{
   return source == SW_SOURCE_FOREX
          ? "Silent Wolf Trading\\silentwolfforex"
          : "Silent Wolf Trading\\silentwolfindices";
}

bool ValidateIndicatorSource()
{
   if(MQLInfoInteger(MQL_TESTER) && InpIndicatorSource == SW_SOURCE_AUTO)
   {
      Print("SWRobots : dans le testeur, choisissez InpIndicatorSource = "
            "SW_SOURCE_FOREX (silentwolfforex) ou SW_SOURCE_INDICES "
            "(silentwolfindices) dans les paramètres.");
      return false;
   }
   return true;
}

bool EnsureIndicatorSource()
{
   if(SelectedIndicatorSource != SW_SOURCE_AUTO)
      return true;

   int matches = 0;
   int count = ChartIndicatorsTotal(0, 0);
   for(int i = 0; i < count; ++i)
   {
      string shortName = ChartIndicatorName(0, 0, i);
      int source = SW_SOURCE_AUTO;
      if(shortName == "silentwolfforex")
         source = SW_SOURCE_FOREX;
      else if(shortName == "silentwolfindices")
         source = SW_SOURCE_INDICES;
      if(source == SW_SOURCE_AUTO)
         continue;
      SelectedIndicatorSource = source;
      ++matches;
   }

   if(matches == 1)
   {
      SelectedIndicatorPath = IndicatorPathForSource(SelectedIndicatorSource);
      Print("SWRobots a détecté ", SelectedIndicatorPath,
            " ; les timeframes surveillés utilisent ses paramètres par défaut.");
      return true;
   }
   if(matches > 1)
   {
      SelectedIndicatorSource = SW_SOURCE_AUTO;
      datetime now = TimeCurrent();
      if(LastIndicatorWarningTime == 0 || now - LastIndicatorWarningTime >= 60)
      {
         LastIndicatorWarningTime = now;
         Print("SWRobots : plusieurs indicateurs SilentWolf sont attachés. Gardez-en un seul.");
      }
      return false;
   }

   datetime now = TimeCurrent();
   if(LastIndicatorWarningTime == 0 || now - LastIndicatorWarningTime >= 60)
   {
      LastIndicatorWarningTime = now;
      Print("SWRobots attend un indicateur SilentWolf pour identifier la source, "
            "ou un choix explicite dans InpIndicatorSource.");
   }
   return false;
}

bool EnsureIndicatorHandle(const int stateIndex)
{
   if(TimeframeStates[stateIndex].indicatorHandle != INVALID_HANDLE)
      return true;

   if(!EnsureIndicatorSource())
      return false;

   ResetLastError();
   TimeframeStates[stateIndex].indicatorHandle =
      iCustom(_Symbol, TimeframeStates[stateIndex].timeframe, SelectedIndicatorPath, true);
   if(TimeframeStates[stateIndex].indicatorHandle == INVALID_HANDLE)
   {
      datetime now = TimeCurrent();
      if(LastIndicatorWarningTime == 0 || now - LastIndicatorWarningTime >= 60)
      {
         LastIndicatorWarningTime = now;
         Print("SWRobots : impossible de charger SilentWolf sur ",
               EnumToString(TimeframeStates[stateIndex].timeframe),
               ". Erreur: ", GetLastError());
      }
      return false;
   }
   return true;
}

void SaveLastProcessedSignalTime(const int stateIndex)
{
   GlobalVariableSet(InstanceKey(TimeframeStates[stateIndex].timeframe) + ".LAST",
                     (double)TimeframeStates[stateIndex].lastProcessedSignalTime);
}

void MarkCurrentBarProcessed(const int stateIndex)
{
   datetime closedBar = iTime(_Symbol, TimeframeStates[stateIndex].timeframe, 1);
   if(closedBar > TimeframeStates[stateIndex].lastProcessedSignalTime)
   {
      TimeframeStates[stateIndex].lastProcessedSignalTime = closedBar;
      SaveLastProcessedSignalTime(stateIndex);
   }
   TimeframeStates[stateIndex].pendingSignalBarTime = 0;
   TimeframeStates[stateIndex].pendingSignalReadAttempts = 0;
   TimeframeStates[stateIndex].nextSignalReadAttemptMs = 0;
}

bool ConnectedAndReady()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      ConnectionWasAvailable = false;
      for(int i = 0; i < TimeframeCount; ++i)
      {
         TimeframeStates[i].pendingSignalBarTime = 0;
         TimeframeStates[i].pendingSignalReadAttempts = 0;
         MarkCurrentBarProcessed(i);
      }
      return false;
   }
   if(!ConnectionWasAvailable)
   {
      ConnectionWasAvailable = true;
      for(int i = 0; i < TimeframeCount; ++i)
      {
         TimeframeStates[i].lastObservedBarOpen =
            iTime(_Symbol, TimeframeStates[i].timeframe, 0);
         MarkCurrentBarProcessed(i);
      }
      Print("SWRobots reconnecté : les signaux clôturés pendant la déconnexion sont ignorés.");
      return false;
   }
   return true;
}

bool IsDirectionAllowed(const int direction)
{
   long mode = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE, mode))
      return false;
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;
   if(direction > 0 && mode == SYMBOL_TRADE_MODE_SHORTONLY)
      return false;
   if(direction < 0 && mode == SYMBOL_TRADE_MODE_LONGONLY)
      return false;
   return true;
}

bool IsMarketSessionOpen()
{
   if(!IsDirectionAllowed(1) && !IsDirectionAllowed(-1))
      return false;

   MqlDateTime current;
   if(!TimeToStruct(TimeCurrent(), current))
      return false;
   int nowSeconds = current.hour * 3600 + current.min * 60 + current.sec;
   for(uint session = 0; session < 32; ++session)
   {
      datetime from, to;
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)current.day_of_week,
                                 session, from, to))
         break;
      MqlDateTime startParts, endParts;
      if(!TimeToStruct(from, startParts) || !TimeToStruct(to, endParts))
         continue;
      int startSeconds = startParts.hour * 3600 + startParts.min * 60 + startParts.sec;
      int endSeconds = endParts.hour * 3600 + endParts.min * 60 + endParts.sec;
      if(startSeconds == endSeconds)
         return true;
      if(startSeconds < endSeconds && nowSeconds >= startSeconds && nowSeconds < endSeconds)
         return true;
      if(startSeconds > endSeconds && (nowSeconds >= startSeconds || nowSeconds < endSeconds))
         return true;
   }
   return false;
}

bool IsAlignedToTick(const double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(price) || price == EMPTY_VALUE
      || !MathIsValidNumber(tickSize) || tickSize <= 0.0)
      return false;
   return MathAbs(price / tickSize - MathRound(price / tickSize)) < 0.000001;
}

double NormalizeVolumeDown(const double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(!MathIsValidNumber(step) || step <= 0.0)
      return 0.0;
   return NormalizeDouble(MathFloor(volume / step + 1.0e-9) * step, 8);
}

bool HasValidPartialVolume(const double volume)
{
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double partial = NormalizeVolumeDown(volume * InpTp1ClosePercent / 100.0);
   double remaining = NormalizeVolumeDown(volume - partial);
   return partial >= minimum && remaining >= minimum;
}

bool CalculatePositionVolume(const int direction, const double entry,
                             const double stop, const bool requirePartial,
                             double &volume)
{
   volume = 0.0;
   double riskCash = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   if(riskCash <= 0.0)
      return false;

   double lossForOneLot = 0.0;
   ENUM_ORDER_TYPE orderType = direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, lossForOneLot))
   {
      Print("SWRobots : OrderCalcProfit a échoué. Erreur: ", GetLastError());
      return false;
   }
   lossForOneLot = MathAbs(lossForOneLot);
   if(!MathIsValidNumber(lossForOneLot) || lossForOneLot <= 0.0)
      return false;

   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double rawVolume = riskCash / lossForOneLot;
   if(rawVolume < minimum)
      return false;
   volume = NormalizeVolumeDown(MathMin(rawVolume, maximum));
   if(volume < minimum || (requirePartial && !HasValidPartialVolume(volume)))
      return false;

   double margin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, volume, entry, margin)
      || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      Print("SWRobots : marge libre insuffisante pour la taille calculée.");
      return false;
   }
   return true;
}

void StoreSignalState(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                      const double entry, const double stop,
                      const double tp1, const double tp2)
{
   GlobalVariableSet(SignalStateKey(signalTime, timeframe, "ENTRY"), entry);
   GlobalVariableSet(SignalStateKey(signalTime, timeframe, "STOP"), stop);
   GlobalVariableSet(SignalStateKey(signalTime, timeframe, "TP1"), tp1);
   GlobalVariableSet(SignalStateKey(signalTime, timeframe, "TP2"), tp2);
}

bool CopySignalStateToPosition(const string comment, const ulong positionId)
{
   datetime signalTime;
   ENUM_TIMEFRAMES timeframe;
   if(!ParseSignalComment(comment, signalTime, timeframe))
      return false;

   string fields[4] = {"ENTRY", "STOP", "TP1", "TP2"};
   for(int i = 0; i < ArraySize(fields); ++i)
   {
      string signalKey = SignalStateKey(signalTime, timeframe, fields[i]);
      if(!GlobalVariableCheck(signalKey))
         return false;
      GlobalVariableSet(PositionStateKey(positionId, fields[i]),
                        GlobalVariableGet(signalKey));
   }
   GlobalVariableSet(PositionStateKey(positionId, "TF"), (double)timeframe);
   GlobalVariableSet(PositionStateKey(positionId, "TIME"), (double)signalTime);
   return true;
}

bool RestorePositionState(const ulong positionId)
{
   if(GlobalVariableCheck(PositionStateKey(positionId, "TP1")))
      return true;

   if(!HistorySelectByPosition(positionId))
      return false;
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN
         || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      if(CopySignalStateToPosition(HistoryDealGetString(deal, DEAL_COMMENT), positionId))
         return true;
   }
   return false;
}

bool HasActiveTradeForSymbol()
{
   bool hedging = AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(!hedging)
         return true;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol
         || (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      return true;
   }
   return false;
}

datetime ServerDayStart(const datetime now)
{
   MqlDateTime parts;
   if(!TimeToStruct(now, parts))
      return 0;
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts);
}

bool PositionIdSeen(const ulong positionId, ulong &seen[])
{
   for(int i = 0; i < ArraySize(seen); ++i)
      if(seen[i] == positionId)
         return true;
   int size = ArraySize(seen);
   if(ArrayResize(seen, size + 1) != size + 1)
      return true;
   seen[size] = positionId;
   return false;
}

bool CountStopLosses(int &todayCount, int &weekCount)
{
   todayCount = 0;
   weekCount = 0;
   datetime now = TimeCurrent();
   datetime todayStart = ServerDayStart(now);
   if(todayStart <= 0)
      return false;
   MqlDateTime today;
   if(!TimeToStruct(todayStart, today))
      return false;
   int daysFromMonday = today.day_of_week == 0 ? 6 : today.day_of_week - 1;
   datetime weekStart = todayStart - daysFromMonday * 86400;
   if(!HistorySelect(weekStart, now))
      return false;

   ulong seen[];
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0
         || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber
         || HistoryDealGetInteger(deal, DEAL_REASON) != DEAL_REASON_SL)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      ulong positionId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(positionId == 0 || GlobalVariableCheck(BreakevenKey(positionId))
         || PositionIdSeen(positionId, seen))
         continue;
      ++weekCount;
      if((datetime)HistoryDealGetInteger(deal, DEAL_TIME) >= todayStart)
         ++todayCount;
   }
   return true;
}

bool IsPaused()
{
   int todayCount, weekCount;
   if(!CountStopLosses(todayCount, weekCount))
   {
      Print("SWRobots : historique des trades indisponible ; aucune nouvelle entrée.");
      return true;
   }
   if(todayCount < InpDailyStopLossLimit && weekCount < InpWeeklyStopLossLimit)
      return false;

   datetime now = TimeCurrent();
   if(LastPauseWarningTime == 0 || now - LastPauseWarningTime >= 60)
   {
      LastPauseWarningTime = now;
      PrintFormat("SWRobots en pause : %d SL aujourd’hui, %d cette semaine.",
                  todayCount, weekCount);
   }
   return true;
}

bool ReadSignalBuffer(const int handle, const int buffer, const int shift,
                      double &value)
{
   value = EMPTY_VALUE;
   if(handle == INVALID_HANDLE || BarsCalculated(handle) <= shift)
      return false;
   double data[1];
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return true;
}

bool TradeResultAccepted()
{
   uint code = Trade.ResultRetcode();
   return code == TRADE_RETCODE_PLACED || code == TRADE_RETCODE_DONE
          || code == TRADE_RETCODE_DONE_PARTIAL;
}

void SkipSignal(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                const string reason)
{
   Print("SWRobots : signal ignoré (", reason, ") sur ",
         _Symbol, " ", EnumToString(timeframe),
         " à ", TimeToString(signalTime, TIME_DATE | TIME_MINUTES), ".");
}

bool ValidSignalPrices(const int direction, const double entry, const double stop,
                       const double tp1, const double tp2)
{
   bool hasSecondTarget = tp2 != EMPTY_VALUE;
   return (direction == 1 || direction == -1)
          && MathIsValidNumber(entry) && MathIsValidNumber(stop)
          && MathIsValidNumber(tp1) && entry != EMPTY_VALUE && stop != EMPTY_VALUE
          && tp1 != EMPTY_VALUE && direction * (entry - stop) > 0.0
          && direction * (tp1 - entry) + _Point * 1.0e-6
             >= 2.0 * direction * (entry - stop)
          && (!hasSecondTarget || (MathIsValidNumber(tp2)
                                    && direction * (tp2 - tp1) > 0.0
                                    && IsAlignedToTick(tp2)))
          && IsAlignedToTick(entry) && IsAlignedToTick(stop) && IsAlignedToTick(tp1);
}

bool PlaceSignalOrder(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                      const int direction,
                      const double entry, const double stop,
                      const double tp1, const double tp2, const double force)
{
   if(force < InpMinimumSignalForce)
   {
      SkipSignal(signalTime, timeframe, "force inférieure au minimum");
      return false;
   }
   if(!IsMarketSessionOpen() || !IsDirectionAllowed(direction))
   {
      SkipSignal(signalTime, timeframe, "marché fermé ou sens non autorisé");
      return false;
   }
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)
      || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
      || !MQLInfoInteger(MQL_TRADE_ALLOWED)
      || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      SkipSignal(signalTime, timeframe, "connexion ou trading indisponible");
      return false;
   }
   if(IsPaused())
   {
      SkipSignal(signalTime, timeframe, "limite de pertes atteinte");
      return false;
   }
   if(HasActiveTradeForSymbol())
   {
      SkipSignal(signalTime, timeframe, "position ou ordre déjà actif sur le symbole");
      return false;
   }

   bool hasSecondTarget = tp2 != EMPTY_VALUE;
   if(!ValidSignalPrices(direction, entry, stop, tp1, tp2))
   {
      SkipSignal(signalTime, timeframe, "prix d’entrée, stop ou TP indisponible/invalide");
      return false;
   }

   long expirationMode = 0;
   if(!SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE, expirationMode)
      || (expirationMode & SYMBOL_EXPIRATION_DAY) == 0)
   {
      SkipSignal(signalTime, timeframe,
                 "le broker ne prend pas en charge l’expiration fin de journée");
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      SkipSignal(signalTime, timeframe, "cotations indisponibles");
      return false;
   }
   if((direction > 0 && entry >= tick.ask)
      || (direction < 0 && entry <= tick.bid))
   {
      SkipSignal(signalTime, timeframe, "le prix a déjà dépassé l’entrée exacte");
      return false;
   }

   double volume = 0.0;
   if(!CalculatePositionVolume(direction, entry, stop, hasSecondTarget, volume))
   {
      SkipSignal(signalTime, timeframe, "money management ou volume minimal invalide");
      return false;
   }

   double finalTarget = hasSecondTarget ? tp2 : tp1;
   StoreSignalState(signalTime, timeframe, entry, stop, tp1, finalTarget);
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);
   string comment = SignalComment(signalTime, timeframe);
   bool submitted = direction > 0
                    ? Trade.BuyLimit(volume, entry, _Symbol, stop, finalTarget,
                                    ORDER_TIME_DAY, 0, comment)
                    : Trade.SellLimit(volume, entry, _Symbol, stop, finalTarget,
                                      ORDER_TIME_DAY, 0, comment);
   if(!submitted || !TradeResultAccepted())
   {
      PrintFormat("SWRobots : ordre refusé (%u - %s). Le signal ne sera pas rejoué.",
                  Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("SWRobots : ordre en attente %s, volume %.8f, entrée %.*f, SL %.*f, "
               "TP1 %.*f, TP2 %s, force %.0f%%.",
               direction > 0 ? "achat" : "vente", volume,
               _Digits, entry, _Digits, stop, _Digits, tp1,
               hasSecondTarget ? DoubleToString(tp2, _Digits) : "n/d", force);
   return true;
}

void ProcessPendingSignal(const int stateIndex)
{
   ENUM_TIMEFRAMES timeframe = TimeframeStates[stateIndex].timeframe;
   datetime pendingBarTime = TimeframeStates[stateIndex].pendingSignalBarTime;
   if(pendingBarTime <= 0)
      return;
   if(iTime(_Symbol, timeframe, 1) != pendingBarTime)
   {
      MarkCurrentBarProcessed(stateIndex);
      return;
   }
   if(GetTickCount64() < TimeframeStates[stateIndex].nextSignalReadAttemptMs)
      return;
   if(!EnsureIndicatorHandle(stateIndex))
   {
      TimeframeStates[stateIndex].nextSignalReadAttemptMs = GetTickCount64() + 1000;
      return;
   }

   int handle = TimeframeStates[stateIndex].indicatorHandle;
   double buyArrow, sellArrow, entry, stop, tp1, tp2, force;
   if(!ReadSignalBuffer(handle, SW_BUFFER_BUY, 1, buyArrow)
      || !ReadSignalBuffer(handle, SW_BUFFER_SELL, 1, sellArrow)
      || !ReadSignalBuffer(handle, SW_BUFFER_ENTRY, 1, entry)
      || !ReadSignalBuffer(handle, SW_BUFFER_STOP, 1, stop)
      || !ReadSignalBuffer(handle, SW_BUFFER_TP1, 1, tp1)
      || !ReadSignalBuffer(handle, SW_BUFFER_TP2, 1, tp2)
      || !ReadSignalBuffer(handle, SW_BUFFER_FORCE, 1, force))
   {
      ++TimeframeStates[stateIndex].pendingSignalReadAttempts;
      TimeframeStates[stateIndex].nextSignalReadAttemptMs = GetTickCount64() + 1000;
      if(TimeframeStates[stateIndex].pendingSignalReadAttempts >= 5)
      {
         SkipSignal(pendingBarTime, timeframe, "buffers de l’indicateur indisponibles");
         MarkCurrentBarProcessed(stateIndex);
      }
      return;
   }

   datetime signalTime = pendingBarTime;
   MarkCurrentBarProcessed(stateIndex);
   bool buy = buyArrow != EMPTY_VALUE && MathIsValidNumber(buyArrow);
   bool sell = sellArrow != EMPTY_VALUE && MathIsValidNumber(sellArrow);
   if(buy == sell)
   {
      if(buy)
         SkipSignal(signalTime, timeframe, "signaux achat et vente simultanés");
      return;
   }
   if(force == EMPTY_VALUE || !MathIsValidNumber(force))
   {
      SkipSignal(signalTime, timeframe, "force du signal indisponible");
      return;
   }
   PlaceSignalOrder(signalTime, timeframe, buy ? 1 : -1,
                    entry, stop, tp1, tp2, force);
}

void PollClosedBar(const int stateIndex)
{
   ENUM_TIMEFRAMES timeframe = TimeframeStates[stateIndex].timeframe;
   datetime currentBarOpen = iTime(_Symbol, timeframe, 0);
   if(currentBarOpen <= 0)
      return;
   if(TimeframeStates[stateIndex].lastObservedBarOpen == 0)
   {
      TimeframeStates[stateIndex].lastObservedBarOpen = currentBarOpen;
      return;
   }
   if(currentBarOpen != TimeframeStates[stateIndex].lastObservedBarOpen)
   {
      datetime previousBarOpen = TimeframeStates[stateIndex].lastObservedBarOpen;
      TimeframeStates[stateIndex].lastObservedBarOpen = currentBarOpen;
      datetime closedBarTime = iTime(_Symbol, timeframe, 1);
      int periodSeconds = PeriodSeconds(timeframe);
      if(closedBarTime <= 0
         || closedBarTime <= TimeframeStates[stateIndex].lastProcessedSignalTime)
         return;
      if(periodSeconds > 0 && previousBarOpen > 0
         && currentBarOpen - previousBarOpen > periodSeconds * 2)
      {
         TimeframeStates[stateIndex].lastProcessedSignalTime = closedBarTime;
         SaveLastProcessedSignalTime(stateIndex);
         SkipSignal(closedBarTime, timeframe,
                    "intervalle de marché fermé ou gap de bougies");
         return;
      }
      TimeframeStates[stateIndex].pendingSignalBarTime = closedBarTime;
      TimeframeStates[stateIndex].pendingSignalReadAttempts = 0;
      TimeframeStates[stateIndex].nextSignalReadAttemptMs = 0;
   }
   ProcessPendingSignal(stateIndex);
}

bool ClosePartial(const ulong ticket, const string symbol,
                  const ENUM_POSITION_TYPE type, const double volume)
{
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   bool hedging = AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   bool submitted;
   if(hedging)
      submitted = Trade.PositionClosePartial(ticket, volume);
   else if(type == POSITION_TYPE_BUY)
      submitted = Trade.Sell(volume, symbol, 0.0, 0.0, 0.0, "SW TP1");
   else
      submitted = Trade.Buy(volume, symbol, 0.0, 0.0, 0.0, "SW TP1");
   return submitted && TradeResultAccepted();
}

void ManageOpenPositions()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)
      || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
      || !MQLInfoInteger(MQL_TRADE_ALLOWED)
      || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol
         || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ulong positionId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      if(positionId == 0 || !RestorePositionState(positionId))
      {
         Print("SWRobots : informations de gestion introuvables pour la position ", ticket,
               " ; SL et TP serveur restent actifs.");
         continue;
      }
      double tp1 = GlobalVariableGet(PositionStateKey(positionId, "TP1"));
      double tp2 = GlobalVariableGet(PositionStateKey(positionId, "TP2"));
      double initialStop = GlobalVariableGet(PositionStateKey(positionId, "STOP"));
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentTp = PositionGetDouble(POSITION_TP);
      double currentSl = PositionGetDouble(POSITION_SL);
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         continue;

      bool tp1Reached = type == POSITION_TYPE_BUY ? tick.bid >= tp1 : tick.ask <= tp1;
      string tp1DoneKey = PositionStateKey(positionId, "TP1DONE");
      if(tp2 != tp1 && tp1Reached && !GlobalVariableCheck(tp1DoneKey))
      {
         double partialVolume = NormalizeVolumeDown(
            currentVolume * InpTp1ClosePercent / 100.0);
         double remaining = NormalizeVolumeDown(currentVolume - partialVolume);
         double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(partialVolume >= minVolume && remaining >= minVolume)
         {
            if(ClosePartial(ticket, _Symbol, type, partialVolume))
               GlobalVariableSet(tp1DoneKey, (double)TimeCurrent());
            else
               PrintFormat("SWRobots : clôture partielle TP1 refusée (%u - %s).",
                           Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
         }
      }

      double risk = MathAbs(entry - initialStop);
      bool breakevenReached = type == POSITION_TYPE_BUY
                              ? tick.bid >= entry + risk
                              : tick.ask <= entry - risk;
      string breakevenKey = BreakevenKey(positionId);
      string retryKey = PositionStateKey(positionId, "BERETRY");
      double lastBreakevenAttempt = GlobalVariableCheck(retryKey)
                                    ? GlobalVariableGet(retryKey) : 0.0;
      if(breakevenReached && !GlobalVariableCheck(breakevenKey)
         && TimeCurrent() - (datetime)lastBreakevenAttempt >= 30)
      {
         bool stopAlreadyProtected = type == POSITION_TYPE_BUY
                                     ? currentSl >= entry && currentSl > 0.0
                                     : currentSl <= entry && currentSl > 0.0;
         if(stopAlreadyProtected)
            GlobalVariableSet(breakevenKey, (double)TimeCurrent());
         else
         {
            GlobalVariableSet(retryKey, (double)TimeCurrent());
            Trade.SetExpertMagicNumber(InpMagicNumber);
            bool modified = Trade.PositionModify(ticket, entry, currentTp);
            if(modified && TradeResultAccepted())
            {
               GlobalVariableSet(breakevenKey, (double)TimeCurrent());
               GlobalVariableDel(retryKey);
            }
            else
               PrintFormat("SWRobots : déplacement au break-even refusé (%u - %s).",
                           Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
         }
      }
      string noStopWarningKey = PositionStateKey(positionId, "NOSLWARN");
      if(currentSl <= 0.0 && !GlobalVariableCheck(noStopWarningKey))
      {
         GlobalVariableSet(noStopWarningKey, (double)TimeCurrent());
         Print("SWRobots : attention, la position ", ticket, " n’a pas de stop serveur.");
      }
      else if(currentSl > 0.0 && GlobalVariableCheck(noStopWarningKey))
         GlobalVariableDel(noStopWarningKey);
   }
}

int OnInit()
{
   if(!ValidateIndicatorSource())
      return INIT_PARAMETERS_INCORRECT;

   if(!InitializeTimeframes()
      || InpRiskPercent <= 0.0 || InpRiskPercent > 100.0
      || InpMinimumSignalForce < 0.0 || InpMinimumSignalForce > 100.0
      || InpTp1ClosePercent <= 0.0 || InpTp1ClosePercent >= 100.0
      || InpDailyStopLossLimit < 1 || InpWeeklyStopLossLimit < 1
      || InpDeviationPoints < 0 || InpMagicNumber == 0)
   {
      Print("SWRobots : paramètres d’entrée invalides.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   Trade.SetTypeFillingBySymbol(_Symbol);

   if(InpIndicatorSource != SW_SOURCE_AUTO)
   {
      SelectedIndicatorSource = InpIndicatorSource;
      SelectedIndicatorPath = IndicatorPathForSource(SelectedIndicatorSource);
   }
   else
      EnsureIndicatorSource();

   for(int i = 0; i < TimeframeCount; ++i)
   {
      ENUM_TIMEFRAMES timeframe = TimeframeStates[i].timeframe;
      TimeframeStates[i].lastObservedBarOpen = iTime(_Symbol, timeframe, 0);
      string lastKey = InstanceKey(timeframe) + ".LAST";
      if(GlobalVariableCheck(lastKey))
         TimeframeStates[i].lastProcessedSignalTime =
            (datetime)GlobalVariableGet(lastKey);
      else
      {
         TimeframeStates[i].lastProcessedSignalTime = iTime(_Symbol, timeframe, 1);
         SaveLastProcessedSignalTime(i);
      }
   }

   ConnectionWasAvailable = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(!EventSetTimer(1))
   {
      Print("SWRobots : impossible d’initialiser le timer. Erreur: ", GetLastError());
      return INIT_FAILED;
   }
   string timeframeList = "";
   for(int i = 0; i < TimeframeCount; ++i)
   {
      if(i > 0)
         timeframeList += ", ";
      timeframeList += EnumToString(TimeframeStates[i].timeframe);
      EnsureIndicatorHandle(i);
   }
   Print("SWRobots prêt sur ", _Symbol, " ; timeframes surveillés : ", timeframeList, ".");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < TimeframeCount; ++i)
   {
      if(TimeframeStates[i].indicatorHandle != INVALID_HANDLE)
      {
         IndicatorRelease(TimeframeStates[i].indicatorHandle);
         TimeframeStates[i].indicatorHandle = INVALID_HANDLE;
      }
   }
}

void OnTick()
{
   if(!ConnectedAndReady())
      return;
   ManageOpenPositions();
   for(int i = 0; i < TimeframeCount; ++i)
      PollClosedBar(i);
}

void OnTimer()
{
   if(!ConnectedAndReady())
      return;
   ManageOpenPositions();
   for(int i = 0; i < TimeframeCount; ++i)
      PollClosedBar(i);
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0
      || !HistoryDealSelect(transaction.deal))
      return;
   if((ulong)HistoryDealGetInteger(transaction.deal, DEAL_MAGIC) != InpMagicNumber
      || HistoryDealGetInteger(transaction.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   ulong positionId = (ulong)HistoryDealGetInteger(transaction.deal, DEAL_POSITION_ID);
   string comment = HistoryDealGetString(transaction.deal, DEAL_COMMENT);
   if(positionId > 0 && !CopySignalStateToPosition(comment, positionId))
      Print("SWRobots : impossible de rattacher les données du signal à la position ",
            positionId, ".");
}
