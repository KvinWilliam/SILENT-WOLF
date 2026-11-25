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
const int SW_BUFFER_READY = 7;

#define SW_MAX_TIMEFRAMES 21
#define SW_ERROR_FILE_NOT_FOUND 5019

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

class SwTrade : public CTrade
{
public:
   bool ClosePartialByTicket(const ulong ticket, const ulong positionId,
                             const string symbol, const ENUM_POSITION_TYPE type,
                             const double volume)
   {
      ClearStructures();
      if(!PositionSelectByTicket(ticket)
         || PositionGetString(POSITION_SYMBOL) != symbol
         || (ulong)PositionGetInteger(POSITION_IDENTIFIER) != positionId
         || (ulong)PositionGetInteger(POSITION_MAGIC) != m_magic
         || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type
         || PositionGetDouble(POSITION_VOLUME) <= volume)
      {
         Print("SWRobots : position modifiée avant la clôture partielle.");
         return false;
      }
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0
         || !FillingCheck(symbol))
      {
         Print("SWRobots : cotation ou mode de remplissage indisponible pour TP1.");
         return false;
      }
      m_request.action = TRADE_ACTION_DEAL;
      m_request.position = ticket;
      m_request.symbol = symbol;
      m_request.type = type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      m_request.price = type == POSITION_TYPE_BUY ? tick.bid : tick.ask;
      m_request.volume = volume;
      m_request.magic = m_magic;
      m_request.deviation = m_deviation;
      m_request.comment = "SW TP1";
      return OrderSend(m_request, m_result);
   }
};

SwTrade Trade;
SwTimeframeState TimeframeStates[SW_MAX_TIMEFRAMES];
int TimeframeCount = 0;
MqlParam IndicatorConfig[];
bool ConnectionWasAvailable = false;
datetime LastIndicatorWarningTime = 0;
datetime LastPauseWarningTime = 0;
ulong NextPauseCheckMs = 0;

enum ENUM_SW_JOURNAL_PHASE
{
   SW_JOURNAL_READY = 0,
   SW_JOURNAL_PENDING = 1,
   SW_JOURNAL_DONE = 2
};

struct SwJournalRecord
{
   int version;
   int phase;
   long sequence;
   ulong positionId;
   long login;
   ulong magic;
   long signalTime;
   int timeframe;
   ushort server[128];
   ushort symbol[128];
   double entry;
   double stop;
   double tp1;
   double tp2;
   double target;
   double closed;
   double requested;
};

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

string SignalJournalPath(const datetime signalTime, const ENUM_TIMEFRAMES timeframe)
{
   return "SWRobots\\v1\\" + CompactUnsigned((ulong)SymbolHash(AccountInfoString(ACCOUNT_SERVER)))
          + "." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + CompactUnsigned((ulong)SymbolHash(_Symbol))
          + "." + IntegerToString((long)timeframe)
          + "." + IntegerToString((long)signalTime) + ".bin";
}

bool SameJournalRecord(const SwJournalRecord &a, const SwJournalRecord &b)
{
   for(int i = 0; i < 128; ++i)
      if(a.server[i] != b.server[i] || a.symbol[i] != b.symbol[i])
         return false;
   return a.version == b.version && a.phase == b.phase && a.sequence == b.sequence
          && a.positionId == b.positionId && a.login == b.login && a.magic == b.magic
          && a.signalTime == b.signalTime && a.timeframe == b.timeframe
          && a.entry == b.entry && a.stop == b.stop && a.tp1 == b.tp1
          && a.tp2 == b.tp2 && a.target == b.target && a.closed == b.closed
          && a.requested == b.requested;
}

bool ValidJournalRecord(const SwJournalRecord &record)
{
   string server = AccountInfoString(ACCOUNT_SERVER);
   if(StringLen(server) == 0 || StringLen(server) >= 128
      || StringLen(_Symbol) == 0 || StringLen(_Symbol) >= 128)
      return false;
   for(int i = 0; i < 128; ++i)
   {
      ushort serverChar = i < StringLen(server) ? (ushort)StringGetCharacter(server, i) : 0;
      ushort symbolChar = i < StringLen(_Symbol) ? (ushort)StringGetCharacter(_Symbol, i) : 0;
      if(record.server[i] != serverChar || record.symbol[i] != symbolChar)
         return false;
   }
   return record.version == 1 && record.sequence > 0
          && record.login == AccountInfoInteger(ACCOUNT_LOGIN) && record.magic == InpMagicNumber
          && record.signalTime > 0 && record.timeframe > 0
          && record.phase >= SW_JOURNAL_READY && record.phase <= SW_JOURNAL_DONE
          && MathIsValidNumber(record.entry) && record.entry > 0.0
          && MathIsValidNumber(record.stop) && record.stop > 0.0
          && MathIsValidNumber(record.tp1) && record.tp1 > 0.0
          && MathIsValidNumber(record.tp2) && record.tp2 > 0.0
          && MathIsValidNumber(record.target) && record.target >= 0.0
          && MathIsValidNumber(record.closed) && record.closed >= 0.0
          && record.closed <= record.target + 1.0e-8
          && MathIsValidNumber(record.requested) && record.requested >= 0.0
          && (record.phase == SW_JOURNAL_READY || record.positionId > 0)
          && (record.phase != SW_JOURNAL_PENDING || record.requested > 0.0)
          && (record.phase != SW_JOURNAL_DONE
              || (record.target > 0.0 && record.closed + 1.0e-8 >= record.target));
}

bool ValidJournalTransition(const SwJournalRecord &previous, const SwJournalRecord &next)
{
   if(next.sequence != previous.sequence + 1 || next.entry != previous.entry
      || next.stop != previous.stop || next.tp1 != previous.tp1 || next.tp2 != previous.tp2
      || next.login != previous.login || next.magic != previous.magic
      || next.signalTime != previous.signalTime || next.timeframe != previous.timeframe)
      return false;
   if(previous.positionId == 0)
      return previous.phase == SW_JOURNAL_READY && next.phase == SW_JOURNAL_READY
             && next.positionId > 0 && next.target == 0.0 && next.closed == 0.0
             && next.requested == 0.0;
   if(next.positionId != previous.positionId)
      return false;
   if(previous.phase == SW_JOURNAL_READY)
      return next.phase == SW_JOURNAL_PENDING && next.closed == previous.closed
             && next.target > 0.0
             && (previous.target == 0.0 || next.target == previous.target)
             && next.requested <= next.target - next.closed + 1.0e-8;
   if(previous.phase == SW_JOURNAL_PENDING)
      return (next.phase == SW_JOURNAL_READY || next.phase == SW_JOURNAL_DONE)
             && next.target == previous.target && next.requested == 0.0
             && next.closed > previous.closed
             && next.closed <= previous.closed + previous.requested + 1.0e-8;
   return false;
}

bool ReadSignalJournal(const string path, SwJournalRecord &record)
{
   int file = FileOpen(path, FILE_READ | FILE_BIN);
   if(file == INVALID_HANDLE)
   {
      Print("SWRobots : journal inaccessible ", path, " : ", GetLastError());
      return false;
   }
   ulong size = FileSize(file);
   int recordSize = sizeof(SwJournalRecord);
   if(size == 0 || size % (2 * recordSize) != 0)
   {
      FileClose(file);
      Print("SWRobots : journal incomplet ou corrompu : ", path);
      return false;
   }
   SwJournalRecord previous;
   ZeroMemory(previous);
   bool firstRecord = true;
   while(!FileIsEnding(file))
   {
      SwJournalRecord first, second;
      if(FileReadStruct(file, first) != recordSize || FileReadStruct(file, second) != recordSize
         || !SameJournalRecord(first, second) || !ValidJournalRecord(first)
         || (firstRecord && (first.sequence != 1 || first.phase != SW_JOURNAL_READY
                             || first.positionId != 0
                             || first.target != 0.0 || first.closed != 0.0
                             || first.requested != 0.0))
         || (!firstRecord && !ValidJournalTransition(previous, first)))
      {
         FileClose(file);
         Print("SWRobots : journal incohérent : ", path);
         return false;
      }
      record = first;
      previous = first;
      firstRecord = false;
   }
   FileClose(file);
   return true;
}

bool WriteSignalJournal(const string path, SwJournalRecord &record, const bool create)
{
   if(create)
   {
      ResetLastError();
      if(FileIsExist(path))
      {
         Print("SWRobots : un journal existe déjà pour ce signal : ", path);
         return false;
      }
      int existenceError = GetLastError();
      if(existenceError != 0 && existenceError != SW_ERROR_FILE_NOT_FOUND)
      {
         Print("SWRobots : vérification du journal impossible : ", existenceError);
         return false;
      }
   }
   if(!create)
   {
      SwJournalRecord previous;
      if(!ReadSignalJournal(path, previous) || !ValidJournalTransition(previous, record))
         return false;
   }
   if(!ValidJournalRecord(record)
      || (create && (record.sequence != 1 || record.phase != SW_JOURNAL_READY
                     || record.positionId != 0
                     || record.target != 0.0 || record.closed != 0.0
                     || record.requested != 0.0)))
      return false;
   int file = FileOpen(path, FILE_BIN | FILE_READ | FILE_WRITE);
   if(file == INVALID_HANDLE)
   {
      Print("SWRobots : écriture du journal impossible ", path, " : ", GetLastError());
      return false;
   }
   if(create && FileSize(file) != 0)
   {
      FileClose(file);
      Print("SWRobots : le journal n'est pas vide : ", path);
      return false;
   }
   if(!create && !FileSeek(file, 0, SEEK_END))
   {
      FileClose(file);
      Print("SWRobots : positionnement du journal impossible : ", GetLastError());
      return false;
   }
   int recordSize = sizeof(SwJournalRecord);
   ResetLastError();
   bool written = FileWriteStruct(file, record) == recordSize
                  && FileWriteStruct(file, record) == recordSize;
   FileFlush(file);
   int error = GetLastError();
   FileClose(file);
   SwJournalRecord verified;
   if(!written || error != 0 || !ReadSignalJournal(path, verified)
      || !SameJournalRecord(record, verified))
   {
      Print("SWRobots : sauvegarde du journal non confirmée : ", error);
      return false;
   }
   return true;
}

string PositionStateKey(const ulong positionId, const string field)
{
   return "P." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + IntegerToString((long)positionId) + "." + field;
}

string TradeLockKey()
{
   return "L." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
          + "." + CompactUnsigned(InpMagicNumber)
          + "." + CompactUnsigned((ulong)SymbolHash(_Symbol));
}

bool AcquireTradeLock()
{
   string key = TradeLockKey();
   if(!GlobalVariableTemp(key))
   {
      Print("SWRobots : création du verrou impossible : ", GetLastError());
      return false;
   }
   return GlobalVariableSetOnCondition(key, 1.0, 0.0);
}

void ReleaseTradeLock()
{
   if(!GlobalVariableSetOnCondition(TradeLockKey(), 0.0, 1.0))
      Print("SWRobots : libération du verrou impossible : ", GetLastError());
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

bool ValidateIndicatorSource()
{
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("SWRobots : testeur désactivé : l'historique fiable des zones n'est pas disponible.");
      return false;
   }
   return true;
}

void ReleaseIndicatorHandles()
{
   for(int i = 0; i < TimeframeCount; ++i)
   {
      if(TimeframeStates[i].indicatorHandle != INVALID_HANDLE)
         IndicatorRelease(TimeframeStates[i].indicatorHandle);
      TimeframeStates[i].indicatorHandle = INVALID_HANDLE;
   }
}

bool RefreshIndicatorConfiguration()
{
   int matches = 0;
   int selectedSource = SW_SOURCE_AUTO;
   string selectedName = "";
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
      selectedSource = source;
      selectedName = shortName;
      ++matches;
   }
   if(matches != 1 || (InpIndicatorSource != SW_SOURCE_AUTO
                       && InpIndicatorSource != selectedSource))
   {
      ReleaseIndicatorHandles();
      ArrayResize(IndicatorConfig, 0);
      datetime now = TimeCurrent();
      if(LastIndicatorWarningTime == 0 || now - LastIndicatorWarningTime >= 60)
      {
         LastIndicatorWarningTime = now;
         Print("SWRobots : un seul indicateur SilentWolf compatible avec la source choisie doit être attaché.");
      }
      return false;
   }

   int visualHandle = ChartIndicatorGet(0, 0, selectedName);
   if(visualHandle == INVALID_HANDLE)
   {
      ReleaseIndicatorHandles();
      ArrayResize(IndicatorConfig, 0);
      Print("SWRobots : lecture de l'indicateur affiché impossible : ", GetLastError());
      return false;
   }
   ENUM_INDICATOR kind = IND_CUSTOM;
   MqlParam parameters[];
   int parameterCount = IndicatorParameters(visualHandle, kind, parameters);
   IndicatorRelease(visualHandle);
   ENUM_DATATYPE types[] = {
      TYPE_BOOL, TYPE_LONG, TYPE_DOUBLE, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT,
      TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_STRING, TYPE_STRING, TYPE_BOOL,
      TYPE_INT, TYPE_INT, TYPE_DOUBLE, TYPE_INT, TYPE_DOUBLE, TYPE_DOUBLE, TYPE_DOUBLE,
      TYPE_DOUBLE, TYPE_DOUBLE, TYPE_BOOL, TYPE_BOOL, TYPE_STRING, TYPE_BOOL, TYPE_BOOL,
      TYPE_BOOL, TYPE_DOUBLE, TYPE_BOOL, TYPE_BOOL, TYPE_BOOL, TYPE_BOOL, TYPE_DOUBLE,
      TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_INT, TYPE_BOOL, TYPE_DOUBLE, TYPE_BOOL,
      TYPE_DOUBLE, TYPE_BOOL, TYPE_BOOL
   };
   bool compatible = kind == IND_CUSTOM && parameterCount >= 47
                     && ArraySize(parameters) >= 47 && parameters[0].type == TYPE_STRING;
   for(int i = 0; compatible && i < ArraySize(types); ++i)
      compatible = parameters[i + 1].type == types[i];
   if(!compatible || parameters[1].integer_value != 0)
   {
      ReleaseIndicatorHandles();
      ArrayResize(IndicatorConfig, 0);
      Print("SWRobots : paramètres de l'indicateur affiché incompatibles ; recompilez les deux programmes.");
      return false;
   }

   string path = parameters[0].string_value;
   StringReplace(path, "/", "\\");
   string lowerPath = path;
   StringToLower(lowerPath);
   if(StringFind(lowerPath, "indicators\\") == 0)
      path = StringSubstr(path, StringLen("indicators\\"));
   parameters[0].string_value = path;
   parameters[1].integer_value = 1;
   parameters[2].integer_value = ChartID();
   if(ArrayResize(parameters, 47) != 47)
   {
      ReleaseIndicatorHandles();
      ArrayResize(IndicatorConfig, 0);
      Print("SWRobots : mémoire insuffisante pour les paramètres de l'indicateur.");
      return false;
   }
   bool changed = ArraySize(IndicatorConfig) != ArraySize(parameters);
   for(int i = 0; !changed && i < ArraySize(parameters); ++i)
      changed = IndicatorConfig[i].type != parameters[i].type
                || IndicatorConfig[i].integer_value != parameters[i].integer_value
                || IndicatorConfig[i].double_value != parameters[i].double_value
                || IndicatorConfig[i].string_value != parameters[i].string_value;
   if(changed)
   {
      ReleaseIndicatorHandles();
      if(ArrayResize(IndicatorConfig, ArraySize(parameters)) != ArraySize(parameters))
      {
         ArrayResize(IndicatorConfig, 0);
         Print("SWRobots : copie des paramètres de l'indicateur impossible.");
         return false;
      }
      for(int i = 0; i < ArraySize(parameters); ++i)
         IndicatorConfig[i] = parameters[i];
   }
   return true;
}

bool EnsureIndicatorHandle(const int stateIndex)
{
   if(!RefreshIndicatorConfiguration())
      return false;
   if(TimeframeStates[stateIndex].indicatorHandle != INVALID_HANDLE)
      return true;

   ResetLastError();
   TimeframeStates[stateIndex].indicatorHandle =
      IndicatorCreate(_Symbol, TimeframeStates[stateIndex].timeframe, IND_CUSTOM,
                      ArraySize(IndicatorConfig), IndicatorConfig);
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

bool SaveLastProcessedSignalTime(const int stateIndex)
{
   if(GlobalVariableSet(InstanceKey(TimeframeStates[stateIndex].timeframe) + ".LAST",
                        (double)TimeframeStates[stateIndex].lastProcessedSignalTime) == 0)
   {
      Print("SWRobots : sauvegarde de la dernière bougie impossible : ", GetLastError());
      return false;
   }
   GlobalVariablesFlush();
   return true;
}

bool MarkCurrentBarProcessed(const int stateIndex)
{
   bool saved = true;
   datetime closedBar = iTime(_Symbol, TimeframeStates[stateIndex].timeframe, 1);
   if(closedBar > TimeframeStates[stateIndex].lastProcessedSignalTime)
   {
      TimeframeStates[stateIndex].lastProcessedSignalTime = closedBar;
      saved = SaveLastProcessedSignalTime(stateIndex);
   }
   TimeframeStates[stateIndex].pendingSignalBarTime = 0;
   TimeframeStates[stateIndex].pendingSignalReadAttempts = 0;
   TimeframeStates[stateIndex].nextSignalReadAttemptMs = 0;
   return saved;
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

bool StoreSignalState(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                      const double entry, const double stop,
                      const double tp1, const double tp2)
{
   SwJournalRecord record;
   ZeroMemory(record);
   record.version = 1;
   record.phase = SW_JOURNAL_READY;
   record.sequence = 1;
   record.login = AccountInfoInteger(ACCOUNT_LOGIN);
   record.magic = InpMagicNumber;
   record.signalTime = (long)signalTime;
   record.timeframe = (int)timeframe;
   record.entry = entry;
   record.stop = stop;
   record.tp1 = tp1;
   record.tp2 = tp2;
   string server = AccountInfoString(ACCOUNT_SERVER);
   if(StringLen(server) == 0 || StringLen(server) >= 128
      || StringLen(_Symbol) == 0 || StringLen(_Symbol) >= 128)
   {
      Print("SWRobots : identité de compte ou symbole invalide pour le journal.");
      return false;
   }
   for(int i = 0; i < StringLen(server); ++i)
      record.server[i] = (ushort)StringGetCharacter(server, i);
   for(int i = 0; i < StringLen(_Symbol); ++i)
      record.symbol[i] = (ushort)StringGetCharacter(_Symbol, i);
   if(!WriteSignalJournal(SignalJournalPath(signalTime, timeframe), record, true))
      return false;
   return true;
}

bool CopySignalStateToPosition(const string comment, const ulong positionId)
{
   datetime signalTime;
   ENUM_TIMEFRAMES timeframe;
   if(!ParseSignalComment(comment, signalTime, timeframe))
      return false;

   SwJournalRecord record;
   string journalPath = SignalJournalPath(signalTime, timeframe);
   if(!ReadSignalJournal(journalPath, record))
      return false;
   if(record.signalTime != (long)signalTime || record.timeframe != (int)timeframe)
   {
      Print("SWRobots : identité de signal incohérente dans le journal.");
      return false;
   }
   if(record.positionId == 0)
   {
      record.sequence++;
      record.positionId = positionId;
      if(!WriteSignalJournal(journalPath, record, false))
         return false;
   }
   if(record.positionId != positionId)
   {
      Print("SWRobots : journal déjà lié à une autre position.");
      return false;
   }

   string readyKey = PositionStateKey(positionId, "READY");
   if(GlobalVariableCheck(readyKey) && !GlobalVariableDel(readyKey))
   {
      Print("SWRobots : invalidation de l'état position impossible : ", GetLastError());
      return false;
   }
   string fields[4] = {"ENTRY", "STOP", "TP1", "TP2"};
   for(int i = 0; i < ArraySize(fields); ++i)
   {
      double value;
      if(i == 0) value = record.entry;
      else if(i == 1) value = record.stop;
      else if(i == 2) value = record.tp1;
      else value = record.tp2;
      if(GlobalVariableSet(PositionStateKey(positionId, fields[i]), value) == 0)
      {
         Print("SWRobots : enregistrement de la position impossible : ", GetLastError());
         return false;
      }
   }
   if(GlobalVariableSet(PositionStateKey(positionId, "TF"), (double)timeframe) == 0
      || GlobalVariableSet(PositionStateKey(positionId, "TIME"), (double)signalTime) == 0
      || GlobalVariableSet(readyKey, 1.0) == 0)
   {
      Print("SWRobots : validation de l'état position impossible : ", GetLastError());
      return false;
   }
   GlobalVariablesFlush();
   return true;
}

bool RestorePositionState(const ulong positionId)
{
   if(GlobalVariableCheck(PositionStateKey(positionId, "READY"))
      && GlobalVariableCheck(PositionStateKey(positionId, "ENTRY"))
      && GlobalVariableCheck(PositionStateKey(positionId, "STOP"))
      && GlobalVariableCheck(PositionStateKey(positionId, "TP1"))
      && GlobalVariableCheck(PositionStateKey(positionId, "TP2"))
      && GlobalVariableCheck(PositionStateKey(positionId, "TF"))
      && GlobalVariableCheck(PositionStateKey(positionId, "TIME")))
   {
      double signalTime, timeframe, entry, stop, tp1, tp2;
      SwJournalRecord record;
      if(GlobalVariableGet(PositionStateKey(positionId, "TIME"), signalTime)
         && GlobalVariableGet(PositionStateKey(positionId, "TF"), timeframe)
         && GlobalVariableGet(PositionStateKey(positionId, "ENTRY"), entry)
         && GlobalVariableGet(PositionStateKey(positionId, "STOP"), stop)
         && GlobalVariableGet(PositionStateKey(positionId, "TP1"), tp1)
         && GlobalVariableGet(PositionStateKey(positionId, "TP2"), tp2)
         && ReadSignalJournal(SignalJournalPath((datetime)signalTime, (ENUM_TIMEFRAMES)timeframe), record)
         && record.positionId == positionId
         && record.signalTime == (long)signalTime && record.timeframe == (int)timeframe
         && record.entry == entry && record.stop == stop
         && record.tp1 == tp1 && record.tp2 == tp2)
         return true;
   }

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
      string symbol;
      long magic;
      if(ticket == 0 || !PositionGetString(POSITION_SYMBOL, symbol)
         || !PositionGetInteger(POSITION_MAGIC, magic))
      {
         Print("SWRobots : lecture d'une position impossible ; entrée bloquée : ", GetLastError());
         return true;
      }
      if(symbol != _Symbol)
         continue;
      if(!hedging)
         return true;
      if((ulong)magic == InpMagicNumber)
         return true;
   }
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      string symbol;
      long magic;
      if(ticket == 0 || !OrderGetString(ORDER_SYMBOL, symbol)
         || !OrderGetInteger(ORDER_MAGIC, magic))
      {
         Print("SWRobots : lecture d'un ordre impossible ; entrée bloquée : ", GetLastError());
         return true;
      }
      if(symbol != _Symbol || (hedging && (ulong)magic != InpMagicNumber))
         continue;
      return true;
   }
   return false;
}

bool HasPendingEntryForSymbol()
{
   bool hedging = AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      string symbol;
      long magic;
      if(ticket == 0 || !OrderGetString(ORDER_SYMBOL, symbol)
         || !OrderGetInteger(ORDER_MAGIC, magic))
      {
         Print("SWRobots : lecture d'un ordre en attente impossible : ", GetLastError());
         return true;
      }
      if(symbol == _Symbol && (!hedging || (ulong)magic == InpMagicNumber))
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

bool RememberPositionId(const ulong positionId, ulong &seen[], bool &alreadySeen)
{
   alreadySeen = false;
   for(int i = 0; i < ArraySize(seen); ++i)
      if(seen[i] == positionId)
      {
         alreadySeen = true;
         return true;
      }
   int size = ArraySize(seen);
   if(ArrayResize(seen, size + 1) != size + 1)
   {
      Print("SWRobots : mémoire insuffisante pour compter les stops.");
      return false;
   }
   seen[size] = positionId;
   return true;
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

   ulong seenWeek[], seenToday[];
   for(int i = 0; i < HistoryDealsTotal(); ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      long dealMagic, reason;
      if(deal == 0 || !HistoryDealGetInteger(deal, DEAL_MAGIC, dealMagic)
         || !HistoryDealGetInteger(deal, DEAL_REASON, reason))
      {
         Print("SWRobots : transaction illisible pendant le comptage des stops : ", GetLastError());
         return false;
      }
      if((ulong)dealMagic != InpMagicNumber || reason != DEAL_REASON_SL)
         continue;
      long entry, positionId, dealTime;
      double profit;
      if(!HistoryDealGetInteger(deal, DEAL_ENTRY, entry)
         || !HistoryDealGetInteger(deal, DEAL_POSITION_ID, positionId)
         || !HistoryDealGetInteger(deal, DEAL_TIME, dealTime)
         || !HistoryDealGetDouble(deal, DEAL_PROFIT, profit))
      {
         Print("SWRobots : détails du stop illisibles : ", GetLastError());
         return false;
      }
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      if(positionId <= 0 || !MathIsValidNumber(profit) || dealTime <= 0)
      {
         Print("SWRobots : détails du stop invalides.");
         return false;
      }
      if(profit >= 0.0)
         continue;
      bool alreadySeen;
      if(!RememberPositionId((ulong)positionId, seenWeek, alreadySeen))
         return false;
      if(!alreadySeen)
         ++weekCount;
      if((datetime)dealTime >= todayStart)
      {
         if(!RememberPositionId((ulong)positionId, seenToday, alreadySeen))
            return false;
         if(!alreadySeen)
            ++todayCount;
      }
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

void CancelPendingOrdersWhenPaused()
{
   if(GetTickCount64() < NextPauseCheckMs)
      return;
   NextPauseCheckMs = GetTickCount64() + 5000;
   if(!IsPaused())
      return;

   Trade.SetExpertMagicNumber(InpMagicNumber);
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
      {
         Print("SWRobots : ordre illisible pendant la pause : ", GetLastError());
         continue;
      }
      long magic;
      string comment;
      if(!OrderGetInteger(ORDER_MAGIC, magic) || !OrderGetString(ORDER_COMMENT, comment))
      {
         Print("SWRobots : propriétés d'ordre illisibles pendant la pause : ", GetLastError());
         continue;
      }
      if((ulong)magic != InpMagicNumber || StringFind(comment, "SWR:") != 0)
         continue;
      if(!Trade.OrderDelete(ticket) || Trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintFormat("SWRobots : annulation de l'ordre %I64u impossible (%u - %s).",
                     ticket, Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   }
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

bool PlaceSignalOrderLocked(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
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
   if(!StoreSignalState(signalTime, timeframe, entry, stop, tp1, finalTarget))
   {
      SkipSignal(signalTime, timeframe, "enregistrement du signal impossible");
      return false;
   }
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
      PrintFormat("SWRobots : ordre non confirmé (%u - %s). Vérifiez le broker ; "
                  "le signal ne sera pas rejoué.",
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

bool PlaceSignalOrder(const datetime signalTime, const ENUM_TIMEFRAMES timeframe,
                      const int direction, const double entry, const double stop,
                      const double tp1, const double tp2, const double force)
{
   if(!AcquireTradeLock())
   {
      SkipSignal(signalTime, timeframe, "verrou de trading indisponible");
      return false;
   }
   bool placed = PlaceSignalOrderLocked(signalTime, timeframe, direction,
                                        entry, stop, tp1, tp2, force);
   ReleaseTradeLock();
   return placed;
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
   double buyArrow, sellArrow, entry, stop, tp1, tp2, force, ready;
   if(!ReadSignalBuffer(handle, SW_BUFFER_READY, 1, ready)
      || ready != 1.0
      || !ReadSignalBuffer(handle, SW_BUFFER_BUY, 1, buyArrow)
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
   if(!MarkCurrentBarProcessed(stateIndex))
   {
      SkipSignal(signalTime, timeframe, "sauvegarde de la bougie impossible");
      return;
   }
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

bool ClosePartial(const ulong ticket, const ulong positionId, const string symbol,
                  const ENUM_POSITION_TYPE type, const double volume)
{
   Trade.SetExpertMagicNumber(InpMagicNumber);
   Trade.SetDeviationInPoints(InpDeviationPoints);
   bool submitted = Trade.ClosePartialByTicket(ticket, positionId, symbol, type, volume);
   return submitted && (Trade.ResultRetcode() == TRADE_RETCODE_DONE
                        || Trade.ResultRetcode() == TRADE_RETCODE_DONE_PARTIAL);
}

// Volume déjà clôturé par ce robot sur la position, établi depuis les deals du
// courtier (identifiés par position et numéro magique). Retourne false si
// l'historique est illisible.
bool ClosedVolumeFromHistory(const ulong positionId, double &closed)
{
   closed = 0.0;
   if(!HistorySelectByPosition(positionId))
      return false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         return false;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT
         || (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      closed += HistoryDealGetDouble(deal, DEAL_VOLUME);
   }
   return true;
}

// Une demande TP1 en attente est résolue seulement si les deals prouvent un
// volume exécuté non nul et compatible avec la demande ; sinon la situation
// reste bloquée pour intervention manuelle.
bool ReconcilePendingPartial(const string path, SwJournalRecord &record)
{
   double historyClosed;
   if(!ClosedVolumeFromHistory(record.positionId, historyClosed))
      return false;
   double executed = historyClosed - record.closed;
   if(!MathIsValidNumber(executed) || executed <= 1.0e-8
      || executed > record.requested + 1.0e-8)
      return false;
   record.sequence++;
   record.closed += executed;
   record.requested = 0.0;
   record.phase = record.closed + 1.0e-8 >= record.target
                  ? SW_JOURNAL_DONE : SW_JOURNAL_READY;
   return WriteSignalJournal(path, record, false);
}

void ManagePartialTarget(const ulong ticket, const ulong positionId,
                         const ENUM_POSITION_TYPE type, const double currentVolume)
{
   double signalTime, signalTimeframe;
   if(!GlobalVariableGet(PositionStateKey(positionId, "TIME"), signalTime)
      || !GlobalVariableGet(PositionStateKey(positionId, "TF"), signalTimeframe))
      return;
   string doneKey = PositionStateKey(positionId, "TP1DONE");
   if(GlobalVariableCheck(doneKey))
      return;
   string warningKey = PositionStateKey(positionId, "TP1WARN");
   if(GlobalVariableCheck(warningKey)
      && TimeCurrent() - (datetime)GlobalVariableGet(warningKey) < 60)
      return;
   string path = SignalJournalPath((datetime)signalTime, (ENUM_TIMEFRAMES)signalTimeframe);
   SwJournalRecord record;
   if(!ReadSignalJournal(path, record))
   {
      GlobalVariableSet(warningKey, (double)TimeCurrent());
      Print("SWRobots : TP1 désactivé pour la position ", ticket,
            " ; journal absent ou invalide, réconciliation manuelle nécessaire.");
      return;
   }
   if(record.positionId != positionId || record.signalTime != (long)signalTime
      || record.timeframe != (int)signalTimeframe)
   {
      GlobalVariableSet(warningKey, (double)TimeCurrent());
      Print("SWRobots : journal TP1 lié à une autre position.");
      return;
   }
   if(record.phase == SW_JOURNAL_DONE)
   {
      GlobalVariableSet(doneKey, 1.0);
      return;
   }
   if(record.phase == SW_JOURNAL_PENDING)
   {
      if(ReconcilePendingPartial(path, record))
      {
         Print("SWRobots : clôture TP1 de la position ", ticket,
               " réconciliée depuis l'historique du courtier.");
         if(record.phase == SW_JOURNAL_DONE)
            GlobalVariableSet(doneKey, 1.0);
         return;
      }
      double lastWarning = GlobalVariableCheck(warningKey)
                           ? GlobalVariableGet(warningKey) : 0.0;
      if(lastWarning == 0.0 || TimeCurrent() - (datetime)lastWarning >= 60)
      {
         Print("SWRobots : clôture TP1 de la position ", ticket,
               " à réconcilier manuellement ; aucune nouvelle tentative automatique.");
         GlobalVariableSet(warningKey, (double)TimeCurrent());
      }
      return;
   }
   double targetVolume = record.target > 0.0 ? record.target
                         : NormalizeVolumeDown(currentVolume * InpTp1ClosePercent / 100.0);
   double closedVolume = record.closed;
   double partialVolume = NormalizeVolumeDown(targetVolume - closedVolume);
   double remaining = NormalizeVolumeDown(currentVolume - partialVolume);
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(partialVolume < minVolume || remaining < minVolume)
      return;
   record.sequence++;
   record.target = targetVolume;
   record.phase = SW_JOURNAL_PENDING;
   record.requested = partialVolume;
   if(!WriteSignalJournal(path, record, false))
   {
      Print("SWRobots : sauvegarde de la clôture TP1 impossible : ", GetLastError());
      return;
   }
   if(!ClosePartial(ticket, positionId, _Symbol, type, partialVolume))
   {
      PrintFormat("SWRobots : clôture TP1 non confirmée (%u - %s) ; "
                  "réconciliation manuelle nécessaire.",
                  Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
      return;
   }
   double executed = Trade.ResultVolume();
   if(!MathIsValidNumber(executed) || executed <= 0.0 || executed > partialVolume + 1.0e-8)
   {
      Print("SWRobots : volume TP1 incertain ; réconciliation manuelle nécessaire.");
      return;
   }
   record.sequence++;
   record.closed = closedVolume + executed;
   record.requested = 0.0;
   record.phase = record.closed + 1.0e-8 >= targetVolume
                  ? SW_JOURNAL_DONE : SW_JOURNAL_READY;
   if(!WriteSignalJournal(path, record, false))
   {
      Print("SWRobots : volume TP1 non sauvegardé ; réconciliation manuelle nécessaire.");
      return;
   }
}

struct PositionStateCacheEntry
{
   ulong positionId;
   ulong nextCheckMs;
   ulong nextWarningMs;
   bool  valid;
};

#define POSITION_STATE_CACHE_SIZE 16
PositionStateCacheEntry PositionStateCache[POSITION_STATE_CACHE_SIZE];
int PositionStateCacheNext = 0;

// Évite de relire le journal sur disque (ou l'historique broker) à chaque tick
// pour chaque position : le résultat de la restauration est conservé 5 secondes.
bool RestorePositionStateCached(const ulong positionId, const ulong ticket)
{
   ulong now = GetTickCount64();
   int slot = -1;
   for(int i = 0; i < POSITION_STATE_CACHE_SIZE; ++i)
      if(PositionStateCache[i].positionId == positionId)
      {
         slot = i;
         break;
      }
   if(slot >= 0 && now < PositionStateCache[slot].nextCheckMs)
      return PositionStateCache[slot].valid;
   if(slot < 0)
   {
      slot = PositionStateCacheNext;
      PositionStateCacheNext = (PositionStateCacheNext + 1) % POSITION_STATE_CACHE_SIZE;
      PositionStateCache[slot].positionId = positionId;
      PositionStateCache[slot].nextWarningMs = 0;
   }
   bool valid = RestorePositionState(positionId);
   PositionStateCache[slot].valid = valid;
   PositionStateCache[slot].nextCheckMs = now + 5000;
   if(!valid && now >= PositionStateCache[slot].nextWarningMs)
   {
      PositionStateCache[slot].nextWarningMs = now + 60000;
      Print("SWRobots : informations de gestion introuvables pour la position ", ticket,
            " ; SL et TP serveur restent actifs.");
   }
   return valid;
}

void ManageOpenPositionsLocked()
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
      if(positionId == 0 || !RestorePositionStateCached(positionId, ticket))
         continue;
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
      if(tp2 != tp1 && tp1Reached && !HasPendingEntryForSymbol())
         ManagePartialTarget(ticket, positionId, type, currentVolume);

      double risk = MathAbs(entry - initialStop);
      bool breakevenReached = type == POSITION_TYPE_BUY
                              ? tick.bid >= entry + risk
                              : tick.ask <= entry - risk;
      string retryKey = PositionStateKey(positionId, "BERETRY");
      double lastBreakevenAttempt = GlobalVariableCheck(retryKey)
                                    ? GlobalVariableGet(retryKey) : 0.0;
      bool stopAlreadyProtected = type == POSITION_TYPE_BUY
                                  ? currentSl >= entry && currentSl > 0.0
                                  : currentSl <= entry && currentSl > 0.0;
      if(breakevenReached && !stopAlreadyProtected
         && TimeCurrent() - (datetime)lastBreakevenAttempt >= 30)
      {
         if(GlobalVariableSet(retryKey, (double)TimeCurrent()) == 0)
            Print("SWRobots : sauvegarde du délai break-even impossible : ", GetLastError());
         else
         {
            Trade.SetExpertMagicNumber(InpMagicNumber);
            bool modified = Trade.PositionModify(ticket, entry, currentTp);
            if(modified && Trade.ResultRetcode() == TRADE_RETCODE_DONE)
            {
               if(!GlobalVariableDel(retryKey))
                  Print("SWRobots : nettoyage du délai break-even impossible : ", GetLastError());
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

void ManageOpenPositions()
{
   if(!AcquireTradeLock())
      return;
   ManageOpenPositionsLocked();
   ReleaseTradeLock();
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
         if(!SaveLastProcessedSignalTime(i))
            return INIT_FAILED;
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

void RunCycle()
{
   if(!ConnectedAndReady())
      return;
   CancelPendingOrdersWhenPaused();
   ManageOpenPositions();
   for(int i = 0; i < TimeframeCount; ++i)
      PollClosedBar(i);
}

void OnTick()
{
   RunCycle();
}

void OnTimer()
{
   RunCycle();
}

void OnTradeTransaction(const MqlTradeTransaction &transaction,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD || transaction.deal == 0
      || !HistoryDealSelect(transaction.deal))
      return;
   if(HistoryDealGetString(transaction.deal, DEAL_SYMBOL) != _Symbol
      || (ulong)HistoryDealGetInteger(transaction.deal, DEAL_MAGIC) != InpMagicNumber
      || HistoryDealGetInteger(transaction.deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
      return;

   ulong positionId = (ulong)HistoryDealGetInteger(transaction.deal, DEAL_POSITION_ID);
   string comment = HistoryDealGetString(transaction.deal, DEAL_COMMENT);
   if(positionId > 0 && AcquireTradeLock())
   {
      if(!CopySignalStateToPosition(comment, positionId))
         Print("SWRobots : impossible de rattacher les données du signal à la position ",
               positionId, ".");
      ReleaseTradeLock();
   }
}
