#property strict
#property indicator_chart_window
#property version   "1.00"
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_label1  "Bullish pin bar fusion"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLimeGreen
#property indicator_width1  2

#property indicator_label2  "Bearish pin bar fusion"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrTomato
#property indicator_width2  2

enum ENUM_STOP_BUFFER_MODE
{
   STOP_BUFFER_FIXED_POINTS = 0,
   STOP_BUFFER_ATR = 1
};

enum ENUM_ZONE_MATCH_MODE
{
   ZONE_BODY_OR_WICK_OVERLAP = 0,
   ZONE_BODY_OVERLAP = 1,
   ZONE_WICK_OVERLAP = 2,
   ZONE_BODY_AND_WICK_OVERLAP = 3,
   ZONE_DIRECTIONAL_WICK_OVERLAP = 4
};

enum ENUM_REJECTION_REASON
{
   REJECT_NONE = 0,
   REJECT_SWING,
   REJECT_ZONE,
   REJECT_CONFIRMATION,
   REJECT_STOP,
   REJECT_GEOMETRY,
   REJECT_DATA,
   REJECT_RANGE
};

struct ChartZone
{
   datetime start;
   datetime end;
   double low;
   double high;
   int direction;
};

// P4 : etat d'une lecture de buffer d'indicateur.
//  OK          : valeur exploitable.
//  PENDING     : l'indicateur n'a pas fini de calculer -> relance utile.
//  UNAVAILABLE : serie calculee mais barre sans valeur (debut d'historique)
//                -> rejet du signal, sans relance ni trace repetee.
enum ENUM_INDICATOR_READ
{
   INDICATOR_READ_OK = 0,
   INDICATOR_READ_PENDING = 1,
   INDICATOR_READ_UNAVAILABLE = 2
};

input double InpWickBodyRatio       = 2.0;       // Dominant wick / body: strictly greater than this ratio
input int    InpArrowOffsetPoints    = 20;        // Arrow distance from candle, in points
input int    InpSwingLookbackBars    = 5;         // Bars used to identify pin swings and Dow pivots
input int    InpPinSwingLookbackBars = 10;        // Repli pour les autres unités
input int    InpPinSwingLookbackM5   = 36;        // M5 : nombre de bougies
input int    InpPinSwingLookbackM15  = 12;        // M15 : nombre de bougies
input int    InpPinSwingLookbackM30  = 6;         // M30 : nombre de bougies
input int    InpPinSwingLookbackH1   = 6;         // H1 : nombre de bougies
input int    InpMaxBarsToScan        = 20000;     // Barres rescannées après le calcul initial
input string InpBullishZonePrefix    = "Zone_Haussière_"; // Préfixe des zones d'achat
input string InpBearishZonePrefix    = "Zone_Baissière_"; // Préfixe des zones de vente
input bool   InpExtendZonesRight     = true;      // Zone active après son bord droit
input ENUM_ZONE_MATCH_MODE InpZoneMatchMode = ZONE_DIRECTIONAL_WICK_OVERLAP;
input ENUM_STOP_BUFFER_MODE InpStopBufferMode = STOP_BUFFER_FIXED_POINTS;
input double InpStopBufferPoints    = 1.0;       // Fixed stop buffer in points
input int    InpAtrPeriod            = 14;        // ATR period for stop buffer
input double InpAtrMultiplier        = 0.10;      // ATR fraction beyond pin-bar extreme
input int    InpAdrPeriod            = 14;        // ADR period: completed daily bars
input double InpRsiOversold          = 20.0;
input double InpRsiOverbought        = 80.0;
input double InpMinWickRangeRatio    = 0.0;       // 0 = off ; hypothèse à tester : 0.60
input double InpMaxOppositeWickRatio = 1.0;       // 1 = off ; hypothèse à tester : 0.25
input bool   InpZoneRequireRejection = false;
input bool   InpEnableSound          = true;
input string InpSoundFile            = "alert.wav";
input bool   InpEnablePush           = true;     // Requires MT5 notifications configured
input bool   InpEnableAlertPopup     = true;     // C9 : fenêtre Alert() du terminal
input bool   InpEnableEmail          = false;    // C9 : SendMail (onglet Email du terminal)
input bool   InpFallbackToSinglePin  = true;     // Repli pin simple si la fusion échoue
input bool   InpEnableUnclassifiedFusion = false; // Entrée : fusion sans pattern reconnu
input double InpHaramiCrossMaxBodyRatio = 0.10; // Corps du doji / amplitude maximale
input bool   InpPiercingBeforeHarami = false;    // C2 : Pénétrante/Nuage noir testés avant Harami
input bool   InpRejectIfStopTouched  = true;     // C3 : invalider si la confirmation touche le stop
input bool   InpRequireCloseBeyondPattern = true; // C4 : clôture au-delà du pattern, tous types
input bool   InpAllowZeroBody        = false;    // C5 : accepter un corps nul (plancher = 1 tick)
input double InpMinRangeAtr          = 0.0;      // C6 : range mini de la pin bar en ATR (0 = off)
input int    InpMaxSignalAgeBars     = 10;       // Repli autres unités; 0 = expiration désactivée
input int    InpMaxSignalAgeBarsM5   = 12;       // M5; 0 = expiration désactivée
input int    InpMaxSignalAgeBarsM15  = 8;        // M15; 0 = expiration désactivée
input int    InpMaxSignalAgeBarsM30  = 6;        // M30; 0 = expiration désactivée
input int    InpMaxSignalAgeBarsH1   = 6;        // H1; 0 = expiration désactivée
input bool   InpIncludeSpreadInRisk  = false;    // C12 : inclure le spread courant dans le risque
// P2 : plancher appliqué au corps d'une bougie de corps nul, exprimé en
// fraction du range de cette bougie. 0.0 (défaut) = comportement actuel, le
// plancher reste 1 tick. Avec une valeur > 0, le plancher devient
// MathMax(1 tick, fraction x range) : la mèche dominante doit alors mesurer au
// plus de InpWickBodyRatio x fraction x range. Valeur conseillée pour écarter
// les dojis plats sans écarter les vraies pin bars : 0.10 (soit 10 % du
// range, donc une mèche > 20 % du range avec InpWickBodyRatio = 2.0). Elle
// n'est volontairement pas imposée comme défaut.
input double InpZeroBodyFloorRangeFraction = 0.0; // P2 : plancher de corps nul = fraction du range (0 = off)
input bool   InpShowTable            = true;     // P6 : afficher le panneau de confirmations
// A1 : inside bar activée par défaut avec validation de la pin fusionnée.
// Définition retenue (convention courante, PAS une norme) : range de la
// bougie inside entièrement contenu dans celui de la mère. La couleur des
// bougies est sans importance. Ce n'est PAS un Harami (corps + couleurs).
input bool   InpEnableInsideBar         = true;  // A1 : détecter l'inside bar
input double InpInsideBarMaxRatio       = 1.0;   // A1 : range inside / range mère maximum
input bool   InpInsideBarRequireFusedPin = true;  // Sortie : exiger la forme fusionnée (toujours exigée en entrée)
input bool   InpInsideBarUseForExit     = false; // A6 : inside bar admise en alerte de SORTIE
input bool   InpAutoCompactTable        = true;  // Adapter le nombre de lignes à la hauteur du graphique
// C-R1 : false (défaut) = alerte d'ENTRÉE uniquement à l'ouverture de barre
// (avec rattrapage si des données d'indicateur manquaient alors). true =
// une modification de zone en cours de barre peut aussi émettre l'alerte
// (comportement P3 antérieur).
input bool   InpAlertOnZoneChange       = false; // C-R1 : alerter aussi en cours de barre

double BullishBuffer[];
double BearishBuffer[];
int AtrHandle = INVALID_HANDLE;
datetime LastBarTime = 0;
bool SignalsDirty = true;
bool PositionStateInitialized = false;
int ActiveSignalDirection = 0;
datetime ActiveSignalTime = 0;
datetime LatestSignalTime = 0;
string LatestSignalStatus = "--";
double LatestEntry1Price = 0.0;
double LatestEntry1Risk = EMPTY_VALUE;
int LatestSignalDirection = 0;
string LatestSignalName = "";
double LatestStopPrice = EMPTY_VALUE;      // C12
bool PendingNewBarAlert = false;           // C8
bool IndicatorDataPending = false;         // C10
int DataRetryCount = 0;                    // C10
datetime LastDataWarningTime = 0;          // C10
datetime LastSoundWarningTime = 0;         // C9
datetime LastAdrWarningTime = 0;
const int MaxDataRetries = 10;             // C10
datetime LastEntryAlertBarTime = 0;        // P3 : dernière barre alertée en ENTRÉE
datetime LastExitAlertBarTime = 0;         // P3 : dernière barre traitée en SORTIE
// C-R1 : barre de confirmation pour laquelle l'alerte d'ENTRÉE est armée.
// Armée uniquement à l'ouverture d'une barre ; consommée dès qu'une passe
// complète s'achève avec des données exploitables (alerte émise, ou
// désarmement définitif si aucun signal). Persiste tant que des données
// manquent : la relance au tick suivant peut encore émettre l'alerte
// (rattrapage). Une modification de zone en cours de barre déclenche un
// recalcul mais ne réarme PAS ; InpAlertOnZoneChange = true court-circuite
// cette limitation.
datetime EntryAlertArmedBarTime = 0;       // C-R1
bool ChartEventCreateForced = false;       // P5
bool ChartEventDeleteForced = false;       // P5

// C12: field indexes determine panel rows and colorization.
const int FieldCount     = 17;
double LatestSignalAdr = EMPTY_VALUE;
ENUM_REJECTION_REASON CandidateRejection = REJECT_NONE;
bool CandidatePatternFound = false;
int RejectedByReason[8];
int FoundPatternCount = 0;
int DuplicateSignalCount = 0;
int AcceptedSignalCount = 0;
int UnclassifiedRejectionCount = 0;

string TableCellPrefix = "PatternFusionPinBarCellV2";
string TablePanelName = "PatternFusionPinBarFloatingPanel";
string TableHandleName = "PatternFusionPinBarFloatingHandle";
string TableTitleName = "PatternFusionPinBarFloatingTitle";
int TableX = 0;
int TableY = 12;
bool TablePositionCustomized = false;
ChartZone ChartZones[];

string TablePositionKey(const string axis)
{
   return "PBF.table." + IntegerToString(ChartID()) + "." + axis;
}

int EffectivePinSwingLookbackBars()
{
   if(_Period == PERIOD_M5)  return InpPinSwingLookbackM5;
   if(_Period == PERIOD_M15) return InpPinSwingLookbackM15;
   if(_Period == PERIOD_M30) return InpPinSwingLookbackM30;
   if(_Period == PERIOD_H1)  return InpPinSwingLookbackH1;
   return InpPinSwingLookbackBars;
}

int EffectiveMaxSignalAgeBars()
{
   if(_Period == PERIOD_M5)  return InpMaxSignalAgeBarsM5;
   if(_Period == PERIOD_M15) return InpMaxSignalAgeBarsM15;
   if(_Period == PERIOD_M30) return InpMaxSignalAgeBarsM30;
   if(_Period == PERIOD_H1)  return InpMaxSignalAgeBarsH1;
   return InpMaxSignalAgeBars;
}

// B2/B3 : métriques du panneau. Largeurs mesurées dans OnInit via TextGetSize
// sur les textes les plus longs ; valeurs ci-dessous = replis prudents si la
// mesure échoue (anciennes constantes 108/154, hauteur texte Arial 10 ~13 px).
string TableFontName = "Arial";
const int TableFontSizePoints = 10;   // cohérente avec OBJPROP_FONTSIZE 10
const int TableTextPaddingX = 8;      // B3 : padding horizontal
const int TableBottomMargin = 8;      // B3 : marge basse sous la dernière ligne
const int TableSectionGap = 8;        // B3 : espace vertical entre sections
const int TableTitleBarHeight = 34;  // B3 : bandeau de titre du panneau
int TableTextHeight = 13;             // B2 : hauteur de texte mesurée (repli 13)
int TableHeaderRowHeight = 23;        // B3 : dérivée de TableTextHeight
int TableRowHeight = 21;              // B3 : dérivée de TableTextHeight
int TableLabelColumnWidth = 108;      // B2 : largeur mesurée (repli 108)
int TableValueColumnWidth = 154;      // B2 : largeur mesuree (repli 154)

// C10 : signale une donnée d'indicateur indisponible. Trace limitée à une fois
// par minute pour ne pas inonder le journal à chaque tick.
void ReportDataIssue(const string context)
{
   IndicatorDataPending = true;
   datetime now = TimeCurrent();
   if(LastDataWarningTime == 0 || now - LastDataWarningTime >= 60)
   {
      LastDataWarningTime = now;
      Print("Données indicateur indisponibles (", context, "). Erreur: ",
            GetLastError(), ". Nouvelle tentative au tick suivant.");
   }
}

// SilentWolf: contexte informatif sur le TF du graphique.
int SwRsi7[1] = {INVALID_HANDLE};
int SwRsi14[1] = {INVALID_HANDLE};
int SwEma[3] = {INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE};
string SwLatestRsi;
string SwLatestDivergence = "n/d";
string SwLatestDiv7 = "n/d";
string SwLatestDiv14 = "n/d";
string SwCurrentTrend = "n/d";

string SwTimeframeName()
{
   string name = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(name, "PERIOD_", "");
   return name;
}

void SwReleaseHandles()
{
   if(SwRsi7[0] != INVALID_HANDLE) IndicatorRelease(SwRsi7[0]);
   if(SwRsi14[0] != INVALID_HANDLE) IndicatorRelease(SwRsi14[0]);
   SwRsi7[0] = INVALID_HANDLE;
   SwRsi14[0] = INVALID_HANDLE;
   for(int i = 0; i < 3; ++i)
   {
      if(SwEma[i] != INVALID_HANDLE) IndicatorRelease(SwEma[i]);
      SwEma[i] = INVALID_HANDLE;
   }
}

bool SwInitHandles()
{
   SwRsi7[0] = iRSI(_Symbol, _Period, 7, PRICE_CLOSE);
   SwRsi14[0] = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   if(SwRsi7[0] == INVALID_HANDLE || SwRsi14[0] == INVALID_HANDLE)
      Print("SilentWolf : RSI informatif indisponible sur ", SwTimeframeName(),
            ", erreur ", GetLastError());
   for(int i = 0; i < 3; ++i)
   {
      int period = i == 0 ? 50 : i == 1 ? 100 : 200;
      SwEma[i] = iMA(_Symbol, _Period, period, 0, MODE_EMA, PRICE_CLOSE);
      if(SwEma[i] == INVALID_HANDLE)
         Print("SilentWolf : EMA ", period, " indisponible, erreur ", GetLastError());
   }
   return true;
}

bool SwRead(const int handle, const int shift, double &value)
{
   value = EMPTY_VALUE;
   if(handle == INVALID_HANDLE || shift < 0 || BarsCalculated(handle) <= shift)
      return false;
   double data[1];
   if(CopyBuffer(handle, 0, shift, 1, data) != 1
      || data[0] == EMPTY_VALUE || !MathIsValidNumber(data[0]))
      return false;
   value = data[0];
   return true;
}

int SwLastClosedShift(const ENUM_TIMEFRAMES tf, const datetime at)
{
   int shift = iBarShift(_Symbol, tf, at, false);
   if(shift < 0) return -1;
   datetime barStart = iTime(_Symbol, tf, shift);
   int seconds = PeriodSeconds(tf);
   if(barStart <= 0 || seconds <= 0) return -1;
   datetime barEnd = barStart + seconds;
   if(tf == PERIOD_MN1)
   {
      MqlDateTime month;
      if(!TimeToStruct(barStart, month)) return -1;
      month.day = 1;
      month.mon++;
      if(month.mon > 12)
      {
         month.mon = 1;
         month.year++;
      }
      barEnd = StructToTime(month);
   }
   // Sans bougie suivante, la cloture D1/W1 peut varier avec l'heure du broker.
   if((tf == PERIOD_D1 || tf == PERIOD_W1) && barEnd <= at)
      return -1;
   if(barEnd > at) ++shift;
   return shift;
}

string SwRsiAt(const datetime at)
{
   int shift = SwLastClosedShift((ENUM_TIMEFRAMES)_Period, at);
   if(shift < 0 || Bars(_Symbol, _Period) <= shift + 14)
      return "n/d";
   double fast, slow;
   if(!SwRead(SwRsi7[0], shift, fast) || !SwRead(SwRsi14[0], shift, slow))
      return "n/d";
   string state = "RANGE";
   if(fast <= InpRsiOversold && slow <= InpRsiOversold) state = "SURVENTE";
   else if(fast >= InpRsiOverbought && slow >= InpRsiOverbought) state = "SURACHAT";
   return StringFormat("%s (%.1f / %.1f)", state, fast, slow);
}

bool SwDivergencePivot(const MqlRates &bars[], const int index, const bool high)
{
   for(int offset = 1; offset <= 2; ++offset)
   {
      if(high && (bars[index].high <= bars[index - offset].high
                  || bars[index].high <= bars[index + offset].high))
         return false;
      if(!high && (bars[index].low >= bars[index - offset].low
                   || bars[index].low >= bars[index + offset].low))
         return false;
   }
   return true;
}

string SwDivergenceClassify(const double highRecent, const double highOlder,
                            const double lowRecent, const double lowOlder,
                            const double rsiHighRecent, const double rsiHighOlder,
                            const double rsiLowRecent, const double rsiLowOlder)
{
   bool bullish = lowRecent < lowOlder && rsiLowRecent > rsiLowOlder;
   bool bearish = highRecent > highOlder && rsiHighRecent < rsiHighOlder;
   if(bullish && bearish) return "HAUSS.+BAISS.";
   if(bullish) return "HAUSS.";
   if(bearish) return "BAISS.";
   return "AUCUNE";
}

string SwDivergenceFor(const int handle, const MqlRates &bars[], const int firstShift)
{
   int highRecent = -1, highOlder = -1, lowRecent = -1, lowOlder = -1;
   for(int i = 2; i < ArraySize(bars) - 2; ++i)
   {
      if(highOlder < 0 && SwDivergencePivot(bars, i, true))
      {
         if(highRecent < 0) highRecent = i;
         else highOlder = i;
      }
      if(lowOlder < 0 && SwDivergencePivot(bars, i, false))
      {
         if(lowRecent < 0) lowRecent = i;
         else lowOlder = i;
      }
      if(highOlder >= 0 && lowOlder >= 0) break;
   }
   double rh1 = EMPTY_VALUE, rh2 = EMPTY_VALUE, rl1 = EMPTY_VALUE, rl2 = EMPTY_VALUE;
   bool highReady = highOlder >= 0
                    && SwRead(handle, firstShift + highRecent, rh1)
                    && SwRead(handle, firstShift + highOlder, rh2);
   bool lowReady = lowOlder >= 0
                   && SwRead(handle, firstShift + lowRecent, rl1)
                   && SwRead(handle, firstShift + lowOlder, rl2);
   if(!highReady || !lowReady)
   {
      if(lowReady && bars[lowRecent].low < bars[lowOlder].low && rl1 > rl2)
         return "HAUSS. (partiel)";
      if(highReady && bars[highRecent].high > bars[highOlder].high && rh1 < rh2)
         return "BAISS. (partiel)";
      return "n/d";
   }
   return SwDivergenceClassify(bars[highRecent].high, bars[highOlder].high,
                               bars[lowRecent].low, bars[lowOlder].low,
                               rh1, rh2, rl1, rl2);
}

string SwDivergenceAt(const datetime at, string &rsi7, string &rsi14)
{
   rsi7 = "n/d";
   rsi14 = "n/d";
   int shift = SwLastClosedShift((ENUM_TIMEFRAMES)_Period, at);
   const int count = 104;
   if(shift < 0 || Bars(_Symbol, _Period) <= shift + count + 14)
      return "7:n/d 14:n/d";
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   if(CopyRates(_Symbol, _Period, shift, count, bars) != count)
      return "7:n/d 14:n/d";
   rsi7 = SwDivergenceFor(SwRsi7[0], bars, shift);
   rsi14 = SwDivergenceFor(SwRsi14[0], bars, shift);
   return "7:" + rsi7 + " 14:" + rsi14;
}

string SwTrendAt(const int shift)
{
   if(shift < 0 || Bars(_Symbol, _Period) <= shift + 200) return "n/d";
   double a, b, c;
   if(!SwRead(SwEma[0], shift, a) || !SwRead(SwEma[1], shift, b)
      || !SwRead(SwEma[2], shift, c)) return "n/d";
   if(a > b && b > c) return "HAUSSIERE";
   if(a < b && b < c) return "BAISSIERE";
   return "INDECISE";
}

bool SwSupportsVwap()
{
   return _Period == PERIOD_M5 || _Period == PERIOD_M15 || _Period == PERIOD_M30
          || _Period == PERIOD_H1 || _Period == PERIOD_H4;
}

datetime SwVwapAnchor(const datetime barTime)
{
   MqlDateTime parts;
   if(!TimeToStruct(barTime, parts))
      return 0;
   int daysBack = 0;
   if(_Period == PERIOD_H1 || _Period == PERIOD_H4)
      daysBack = parts.day_of_week == 0 ? 6 : parts.day_of_week - 1;
   parts.hour = 0;
   parts.min = 0;
   parts.sec = 0;
   return StructToTime(parts) - daysBack * 86400;
}

double SwVwap = EMPTY_VALUE;
string SwVwapDirection = "n/d";
double SwVwapDistanceAtr = EMPTY_VALUE;
double SwVwapPrice = EMPTY_VALUE;

string SwVwapContext()
{
   if(LatestSignalDirection == 0 || SwVwap == EMPTY_VALUE
      || SwVwapPrice == EMPTY_VALUE || SwVwapDirection == "n/d")
      return "n/d";
   if(LatestSignalDirection > 0 && SwVwapPrice > SwVwap && SwVwapDirection == "HAUSSIER")
      return "ALIGNE";
   if(LatestSignalDirection < 0 && SwVwapPrice < SwVwap && SwVwapDirection == "BAISSIER")
      return "ALIGNE";
   return "NON ALIGNE";
}

bool SwCalculateVwap(const MqlRates &rates[], double &current, double &previous)
{
   int count = ArraySize(rates);
   if(count < 1)
      return false;
   double weighted = 0.0, total = 0.0;
   previous = EMPTY_VALUE;
   for(int i = 0; i < count; ++i)
   {
      if(rates[i].tick_volume < 0 || !MathIsValidNumber(rates[i].high)
         || !MathIsValidNumber(rates[i].low) || !MathIsValidNumber(rates[i].close)
         || rates[i].high == EMPTY_VALUE || rates[i].low == EMPTY_VALUE
         || rates[i].close == EMPTY_VALUE)
         return false;
      if(i == count - 1 && total > 0.0)
         previous = weighted / total;
      double price = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      weighted += price * (double)rates[i].tick_volume;
      total += (double)rates[i].tick_volume;
   }
   if(total <= 0.0 || !MathIsValidNumber(weighted) || !MathIsValidNumber(total))
      return false;
   current = weighted / total;
   return MathIsValidNumber(current);
}

void SwUpdateVwap()
{
   if(!InpShowTable || !SwSupportsVwap())
      return;
   SwVwap = EMPTY_VALUE;
   SwVwapDirection = "n/d";
   SwVwapDistanceAtr = EMPTY_VALUE;
   SwVwapPrice = EMPTY_VALUE;
   datetime barTime = iTime(_Symbol, _Period, 0);
   datetime anchor = SwVwapAnchor(barTime);
   if(barTime <= 0 || anchor <= 0)
      return;
   MqlRates rates[];
   int count = CopyRates(_Symbol, _Period, anchor, barTime, rates);
   long synchronized = 0, firstDate = 0;
   if(count < 1 || rates[count - 1].time != barTime
      || !SeriesInfoInteger(_Symbol, _Period, SERIES_SYNCHRONIZED, synchronized)
      || synchronized == 0
      || !SeriesInfoInteger(_Symbol, _Period, SERIES_FIRSTDATE, firstDate)
      || firstDate <= 0 || firstDate > anchor)
      return;
   double current, previous;
   if(!SwCalculateVwap(rates, current, previous))
      return;
   SwVwap = current;
   SwVwapPrice = rates[count - 1].close;
   if(previous != EMPTY_VALUE && rates[count - 1].tick_volume > 0)
      SwVwapDirection = current > previous ? "HAUSSIER" : current < previous ? "BAISSIER" : "PLAT";
   double atr[];
   if(AtrHandle != INVALID_HANDLE && CopyBuffer(AtrHandle, 0, 1, 1, atr) == 1
      && MathIsValidNumber(atr[0]) && atr[0] != EMPTY_VALUE && atr[0] > 0.0)
      SwVwapDistanceAtr = (rates[count - 1].close - current) / atr[0];
}

void SwRefreshInfo()
{
   SwLatestRsi = "n/d";
   SwLatestDivergence = "n/d";
   SwLatestDiv7 = "n/d";
   SwLatestDiv14 = "n/d";
   SwCurrentTrend = SwTrendAt(1);
   int shift = iBarShift(_Symbol, _Period, LatestSignalTime, true);
   if(LatestSignalTime <= 0 || shift < 1)
      return;
   datetime at = iTime(_Symbol, _Period, shift - 1);
   if(at <= 0)
      return;
   SwLatestRsi = SwRsiAt(at);
   SwLatestDivergence = SwDivergenceAt(at, SwLatestDiv7, SwLatestDiv14);
}

bool RefreshChartZones()
{
   int objectCount = ObjectsTotal(0, 0, OBJ_RECTANGLE);
   if(ArrayResize(ChartZones, objectCount) != objectCount)
   {
      Print("Impossible de mettre en cache les rectangles de zones. Erreur: ",
            GetLastError());
      return false;
   }
   int zoneCount = 0;

   for(int index = 0; index < objectCount; ++index)
   {
      string objectName = ObjectName(0, index, 0, OBJ_RECTANGLE);
      int direction = 0;
      if(StringFind(objectName, InpBullishZonePrefix) == 0)
         direction = 1;
      else if(StringFind(objectName, InpBearishZonePrefix) == 0)
         direction = -1;
      if(direction == 0)
         continue;

      datetime time1 = (datetime)ObjectGetInteger(0, objectName, OBJPROP_TIME, 0);
      datetime time2 = (datetime)ObjectGetInteger(0, objectName, OBJPROP_TIME, 1);
      double price1 = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 0);
      double price2 = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 1);
      ChartZones[zoneCount].start = time1 < time2 ? time1 : time2;
      ChartZones[zoneCount].end = time1 > time2 ? time1 : time2;
      ChartZones[zoneCount].low = MathMin(price1, price2);
      ChartZones[zoneCount].high = MathMax(price1, price2);
      ChartZones[zoneCount].direction = direction;
      ++zoneCount;
   }

   if(ArrayResize(ChartZones, zoneCount) != zoneCount)
   {
      Print("Impossible d'ajuster le cache des rectangles de zones. Erreur: ",
            GetLastError());
      return false;
   }
   return true;
}

// C13 : extrêmes fusionnés d'une plage de barres (indexation série, donc
// newestIndex <= oldestIndex).
void PatternExtremes(const int newestIndex, const int oldestIndex,
                     const double &high[], const double &low[],
                     double &rangeHigh, double &rangeLow)
{
   rangeHigh = high[newestIndex];
   rangeLow = low[newestIndex];
   for(int bar = newestIndex + 1; bar <= oldestIndex; ++bar)
   {
      rangeHigh = MathMax(rangeHigh, high[bar]);
      rangeLow = MathMin(rangeLow, low[bar]);
   }
}

// C13 : règle « RSI renforcé ». direction <= 0 utilise le seuil de surachat.
bool IsRsiStrengthened(const int direction, const double rsi7, const double rsi14)
{
   if(rsi7 == EMPTY_VALUE || rsi14 == EMPTY_VALUE)
      return false;
   if(direction > 0)
      return rsi7 <= InpRsiOversold && rsi14 <= InpRsiOversold;
   return rsi7 >= InpRsiOverbought && rsi14 >= InpRsiOverbought;
}

// Conventions de géométrie, pas des normes : les seuils proposés sont à tester.
bool PassesWickGeometry(const double dominant, const double opposite,
                        const double range)
{
   return range > 0.0 && dominant / range >= InpMinWickRangeRatio
          && opposite / range <= InpMaxOppositeWickRatio;
}

// C5 : plancher de corps explicite, utilisé uniquement si InpAllowZeroBody.
// Valeur de base : 1 tick (SYMBOL_TRADE_TICK_SIZE), à défaut 1 point.
// P2 : plancher relevant à MathMax(1 tick, fraction x range).
double EffectiveBody(const double body, const double range)
{
   if(body > 0.0)
      return body;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double floorValue = tickSize > 0.0 ? tickSize : _Point;
   if(InpZeroBodyFloorRangeFraction > 0.0 && range > 0.0)
      floorValue = MathMax(floorValue, InpZeroBodyFloorRangeFraction * range);
   return floorValue;
}

double CandleBody(const int index, const double &open[], const double &close[])
{
   return MathAbs(close[index] - open[index]);
}

double CandleRange(const int index, const double &high[], const double &low[])
{
   return high[index] - low[index];
}



double UpperWick(const int index, const double &open[], const double &close[],
                 const double &high[])
{
   return high[index] - MathMax(open[index], close[index]);
}

double LowerWick(const int index, const double &open[], const double &close[],
                 const double &low[])
{
   return MathMin(open[index], close[index]) - low[index];
}

bool IsBullishEngulfing(const int i, const double &open[], const double &close[])
{
   return close[i + 1] < open[i + 1] && close[i] > open[i]
       && open[i] < close[i + 1]
       && close[i] > open[i + 1];
}

bool IsBearishEngulfing(const int i, const double &open[], const double &close[])
{
   return close[i + 1] > open[i + 1] && close[i] < open[i]
       && open[i] > close[i + 1]
       && close[i] < open[i + 1];
}

bool IsBullishHarami(const int i, const double &open[], const double &close[])
{
   double previousLow  = MathMin(open[i + 1], close[i + 1]);
   double previousHigh = MathMax(open[i + 1], close[i + 1]);
   double currentLow   = MathMin(open[i], close[i]);
   double currentHigh  = MathMax(open[i], close[i]);
   return close[i + 1] < open[i + 1] && close[i] > open[i]
       && currentLow > previousLow && currentHigh < previousHigh;
}

bool IsBearishHarami(const int i, const double &open[], const double &close[])
{
   double previousLow  = MathMin(open[i + 1], close[i + 1]);
   double previousHigh = MathMax(open[i + 1], close[i + 1]);
   double currentLow   = MathMin(open[i], close[i]);
   double currentHigh  = MathMax(open[i], close[i]);
   return close[i + 1] > open[i + 1] && close[i] < open[i]
       && currentLow > previousLow && currentHigh < previousHigh;
}

bool IsHaramiCross(const int i, const double &open[], const double &high[],
                   const double &low[], const double &close[], int &direction)
{
   direction = 0;
   double range = high[i] - low[i];
   if(range <= 0.0 || MathAbs(close[i] - open[i]) >= InpHaramiCrossMaxBodyRatio * range)
      return false;

   double previousLow = MathMin(open[i + 1], close[i + 1]);
   double previousHigh = MathMax(open[i + 1], close[i + 1]);
   double currentLow = MathMin(open[i], close[i]);
   double currentHigh = MathMax(open[i], close[i]);
   if(previousLow == previousHigh || currentLow <= previousLow || currentHigh >= previousHigh
      || low[i] <= low[i + 1] || high[i] >= high[i + 1])
      return false;

   direction = close[i + 1] < open[i + 1] ? 1 : -1;
   return true;
}

bool IsPiercingLine(const int i, const double &open[], const double &close[])
{
   double midpoint = (open[i + 1] + close[i + 1]) / 2.0;
   return close[i + 1] < open[i + 1] && close[i] > open[i]
       && open[i] < close[i + 1]
       && close[i] > midpoint && close[i] < open[i + 1];
}

bool IsDarkCloudCover(const int i, const double &open[], const double &close[])
{
   double midpoint = (open[i + 1] + close[i + 1]) / 2.0;
   return close[i + 1] > open[i + 1] && close[i] < open[i]
       && open[i] > close[i + 1]
       && close[i] < midpoint && close[i] > open[i + 1];
}

// La bougie inside et son range doivent respecter strictement les limites.
bool IsInsideBar(const int i, const double &high[], const double &low[])
{
   double motherRange = high[i + 1] - low[i + 1];
   if(motherRange <= 0.0)
      return false;

   if(high[i] >= high[i + 1] || low[i] <= low[i + 1])
      return false;

   return (high[i] - low[i]) < InpInsideBarMaxRatio * motherRange;
}

// A6 : participation de l'inside bar. ENTRÉE : InpEnableInsideBar.
// SORTIE : InpEnableInsideBar && InpInsideBarUseForExit.
bool AllowInsideBarForSearch(const bool isExitSearch)
{
   if(!InpEnableInsideBar)
      return false;
   return !isExitSearch || InpInsideBarUseForExit;
}

// A2 : reconnaît un nom de pattern inside bar.
bool IsInsideBarName(const string patternName)
{
   return StringFind(patternName, "Inside bar") == 0;
}

// F1 : le commentaire affirmant que la direction de l'inside bar est
// « résolue en aval » était FAUX — aucune ligne ne l'affectait et la
// comparaison au swing (toujours +1/-1) la rejetait systématiquement, donc
// l'inside bar ne produisait jamais de signal. La direction est désormais
// affectée dans FindConfirmedSignal, immédiatement après la résolution du
// swing et AVANT tout usage de direction (zone, cassure, follow-through,
// stop). FindPattern continue de retourner direction = 0 pour l'inside bar :
// ce contrat est documenté ici et consommé par l'appelant.
bool FindPattern(const int i, const int rates_total,
                 const double &open[], const double &high[],
                 const double &low[], const double &close[],
                 const bool allowInsideBar,
                 int &direction, int &patternLength, string &patternName)
{
   direction = 0;
   patternLength = 0;
   patternName = "";

   if(i + 1 < rates_total)
   {
      if(IsHaramiCross(i, open, high, low, close, direction))
      {
         patternLength = 2;
         patternName = direction > 0 ? "Harami Cross haussier" : "Harami Cross baissier";
         return true;
      }
      if(IsBullishEngulfing(i, open, close))
      {
         direction = 1; patternLength = 2;
         patternName = "Englobante haussiere";
         return true;
      }
      if(IsBearishEngulfing(i, open, close))
      {
         direction = -1; patternLength = 2;
         patternName = "Englobante baissiere";
         return true;
      }
      if(InpPiercingBeforeHarami)
      {
         if(IsPiercingLine(i, open, close))
         {
            direction = 1; patternLength = 2; patternName = "Penetrante haussiere";
            return true;
         }
         if(IsDarkCloudCover(i, open, close))
         {
            direction = -1; patternLength = 2; patternName = "Nuage noir";
            return true;
         }
      }
      if(IsBullishHarami(i, open, close))
      {
         direction = 1; patternLength = 2; patternName = "Harami haussier";
         return true;
      }
      if(IsBearishHarami(i, open, close))
      {
         direction = -1; patternLength = 2; patternName = "Harami baissier";
         return true;
      }
      if(!InpPiercingBeforeHarami)
      {
         if(IsPiercingLine(i, open, close))
         {
            direction = 1; patternLength = 2; patternName = "Penetrante haussiere";
            return true;
         }
         if(IsDarkCloudCover(i, open, close))
         {
            direction = -1; patternLength = 2; patternName = "Nuage noir";
            return true;
         }
      }
      // A2 : l'inside bar est testée EN DERNIER, après tous les patterns
      // existants, quel que soit l'ordre choisi par C2. Une paire à la fois
      // Harami et inside bar garde donc l'étiquette Harami. F1 : direction = 0
      // est ici un CONTRAT VOLONTAIRE, pas une omission — l'appelant
      // (FindConfirmedSignal) affecte direction = patternSwingDirection pour
      // l'inside bar dès que le swing est résolu, avant tout usage de
      // direction. Les extrêmes du pattern sont ceux de la mère (l'inside
      // est contenue dans son range).
      if(allowInsideBar && IsInsideBar(i, high, low))
      {
         patternLength = 2;
         patternName = "Inside bar";
         return true;
      }
   }

   return false;
}

bool FindPatternSwingDirection(const int patternIndex, const int patternLength,
                               const int rates_total,
                               const double &high[], const double &low[],
                               int &direction)
{
   direction = 0;
   int first = patternIndex + patternLength - 1;
   int swingEnd = first + EffectivePinSwingLookbackBars();
   if(swingEnd >= rates_total)
      return false;

   double patternHigh, patternLow;
   PatternExtremes(patternIndex, first, high, low, patternHigh, patternLow);

   bool swingLow = true;
   bool swingHigh = true;
   for(int bar = first + 1; bar <= swingEnd; ++bar)
   {
      if(low[bar] <= patternLow)
         swingLow = false;
      if(high[bar] >= patternHigh)
         swingHigh = false;
   }

   if(swingLow == swingHigh)
      return false;
   direction = swingLow ? 1 : -1;
   return true;
}

bool FindSinglePinBar(const int i, const int rates_total,
                      const double &open[], const double &high[],
                      const double &low[], const double &close[],
                      int &direction, string &patternName)
{
   direction = 0;
   patternName = "";
   double body = CandleBody(i, open, close);
   double range = CandleRange(i, high, low);
   if(range <= 0.0)
      return false;
   // C5 : par défaut un corps nul est rejeté comme auparavant.
   if(body <= 0.0 && !InpAllowZeroBody)
      return false;
   double ratioBody = InpAllowZeroBody ? EffectiveBody(body, range) : body;

   double upper = UpperWick(i, open, close, high);
   double lower = LowerWick(i, open, close, low);
   double bodyLow = MathMin(open[i], close[i]);
   double bodyHigh = MathMax(open[i], close[i]);
   double midpoint = (high[i] + low[i]) / 2.0;

   bool lowerWickPin = lower > InpWickBodyRatio * ratioBody
      && bodyLow > midpoint;
   bool upperWickPin = upper > InpWickBodyRatio * ratioBody
      && bodyHigh < midpoint;

   if(!lowerWickPin && !upperWickPin)
      return false;
   CandidatePatternFound = true;
   if(!(lowerWickPin && PassesWickGeometry(lower, upper, range))
      && !(upperWickPin && PassesWickGeometry(upper, lower, range)))
   {
      CandidateRejection = REJECT_GEOMETRY;
      return false;
   }
   lowerWickPin = lowerWickPin && PassesWickGeometry(lower, upper, range);
   upperWickPin = upperWickPin && PassesWickGeometry(upper, lower, range);

   int patternSwingDirection;
   if(!FindPatternSwingDirection(i, 1, rates_total, high, low,
                                 patternSwingDirection))
   {
      CandidateRejection = REJECT_SWING;
      return false;
   }

   if(patternSwingDirection > 0)
   {
      direction = 1;
      patternName = lowerWickPin ? "Marteau" : "Marteau inverse";
      return true;
   }
   direction = -1;
   patternName = lowerWickPin ? "Pendu" : "Etoile filante";
   return true;
}

bool IsConfirmedPinBar(const int i, const int patternLength,
                       const int direction, string &pinShape,
                       const double &open[], const double &high[],
                       const double &low[], const double &close[])
{
   pinShape = "";
   int first = i + patternLength - 1;
   double fusedOpen = open[first];
   double fusedClose = close[i];
   double fusedHigh, fusedLow;
   PatternExtremes(i, first, high, low, fusedHigh, fusedLow);

   double body = MathAbs(fusedClose - fusedOpen);
   double range = fusedHigh - fusedLow;
   if(range <= 0.0)
      return false;
   // C5 : par défaut un corps fusionné nul est rejeté comme auparavant.
   if(body <= 0.0 && !InpAllowZeroBody)
      return false;
   double ratioBody = InpAllowZeroBody ? EffectiveBody(body, range) : body;

   double midpoint = (fusedHigh + fusedLow) / 2.0;
   double upper = fusedHigh - MathMax(fusedOpen, fusedClose);
   double lower = MathMin(fusedOpen, fusedClose) - fusedLow;

   bool lowerWickPin = fusedOpen > midpoint && fusedClose > midpoint
      && lower > InpWickBodyRatio * ratioBody;
   bool upperWickPin = fusedOpen < midpoint && fusedClose < midpoint
      && upper > InpWickBodyRatio * ratioBody;
   if((lowerWickPin || upperWickPin)
      && !(lowerWickPin && PassesWickGeometry(lower, upper, range))
      && !(upperWickPin && PassesWickGeometry(upper, lower, range)))
   {
      CandidateRejection = REJECT_GEOMETRY;
      return false;
   }
   lowerWickPin = lowerWickPin && PassesWickGeometry(lower, upper, range);
   upperWickPin = upperWickPin && PassesWickGeometry(upper, lower, range);

   if(direction > 0)
   {
      if(lowerWickPin)
         pinShape = "Marteau";
      else if(upperWickPin)
         pinShape = "Marteau inverse";
   }
   else
   {
      if(lowerWickPin)
         pinShape = "Pendu";
      else if(upperWickPin)
         pinShape = "Etoile filante";
   }

   return pinShape != "";
}

bool PriceRangesOverlap(const double firstLow, const double firstHigh,
                        const double secondLow, const double secondHigh)
{
   return firstHigh >= secondLow && secondHigh >= firstLow;
}

// A5 : le mode de zone directionnel (ZONE_DIRECTIONAL_WICK_OVERLAP) pour une
// inside bar se réfère aux mèches de la bougie FUSIONNÉE (mère + inside) :
// signal haussier -> mèche basse fusionnée, signal baissier -> mèche haute
// fusionnée. Les extrêmes de la bougie fusionnée sont exactement ceux de la
// MÈRE (l'inside est contenue), donc l'exigence se ramène pratiquement au
// recouvrement de la mèche de la mère. Comportement volontairement NON
// modifié (réutilisation sans changement, comme imposé par A5) ;
// inadaptation potentielle listée dans les risques résiduels.
bool IsPatternInAnyZone(const int pinBarIndex, const int patternLength,
                        const int direction,
                        const datetime &time[], const double &open[],
                        const double &high[], const double &low[],
                        const double &close[])
{
   int first = pinBarIndex + patternLength - 1;
   double fusedOpen = open[first];
   double fusedClose = close[pinBarIndex];
   double fusedHigh, fusedLow;
   PatternExtremes(pinBarIndex, first, high, low, fusedHigh, fusedLow);

   double bodyLow = MathMin(fusedOpen, fusedClose);
   double bodyHigh = MathMax(fusedOpen, fusedClose);
   double lowerWickLow = fusedLow;
   double lowerWickHigh = bodyLow;
   double upperWickLow = bodyHigh;
   double upperWickHigh = fusedHigh;
   datetime patternStart = time[first];
   datetime patternEnd = time[pinBarIndex] + PeriodSeconds(_Period);

   int zoneCount = ArraySize(ChartZones);
   for(int index = 0; index < zoneCount; ++index)
   {
      if(ChartZones[index].direction != direction)
         continue;
      if(patternEnd < ChartZones[index].start
         || (!InpExtendZonesRight && patternStart > ChartZones[index].end))
         continue;

      double zoneLow = ChartZones[index].low;
      double zoneHigh = ChartZones[index].high;
      bool bodyOverlaps = PriceRangesOverlap(bodyLow, bodyHigh,
                                             zoneLow, zoneHigh);
      bool lowerWickOverlaps = PriceRangesOverlap(lowerWickLow, lowerWickHigh,
                                                  zoneLow, zoneHigh);
      bool upperWickOverlaps = PriceRangesOverlap(upperWickLow, upperWickHigh,
                                                  zoneLow, zoneHigh);
      bool wickOverlaps = lowerWickOverlaps || upperWickOverlaps;
      bool matched = (InpZoneMatchMode == ZONE_DIRECTIONAL_WICK_OVERLAP
                      && (direction > 0 ? lowerWickOverlaps : upperWickOverlaps))
                  || (InpZoneMatchMode == ZONE_BODY_OR_WICK_OVERLAP && (bodyOverlaps || wickOverlaps))
                  || (InpZoneMatchMode == ZONE_BODY_OVERLAP && bodyOverlaps)
                  || (InpZoneMatchMode == ZONE_WICK_OVERLAP && wickOverlaps)
                  || (InpZoneMatchMode == ZONE_BODY_AND_WICK_OVERLAP && bodyOverlaps && wickOverlaps);
      // Zones lues sans date de création : biais d'anticipation sur l'historique.
      bool rejected = direction > 0
         ? fusedLow <= zoneHigh && fusedClose >= zoneLow
         : fusedHigh >= zoneLow && fusedClose <= zoneHigh;
      if(matched && (!InpZoneRequireRejection || rejected))
         return true;
   }

   return false;
}

bool IsFollowThroughCandle(const int i, const int direction,
                           const double &open[], const double &high[],
                           const double &low[], const double &close[])
{
   double body = CandleBody(i, open, close);
   double range = CandleRange(i, high, low);
   if(body <= 0.0 || range <= 0.0 || body <= range - body)
      return false;

   if(direction > 0)
      return close[i] > open[i];

   return close[i] < open[i];
}

bool IsConfirmedSwingPivot(const int index, const bool findHigh,
                           const int rates_total, const double &high[],
                           const double &low[])
{
   int lookback = InpSwingLookbackBars;
   if(index - lookback < 1 || index + lookback >= rates_total)
      return false;

   for(int offset = 1; offset <= lookback; ++offset)
   {
      if(findHigh)
      {
         if(high[index] <= high[index - offset]
            || high[index] <= high[index + offset])
            return false;
      }
      else if(low[index] >= low[index - offset]
              || low[index] >= low[index + offset])
         return false;
   }

   return true;
}

// A3 : la contrainte de cassure s'applique aux Harami (comportement inchangé)
// ET aux inside bars : close de la confirmation au-delà de l'extrême du
// pattern. Pour une inside bar, les extrêmes du pattern sont ceux de la
// MÈRE. Les autres patterns ne sont concernés que si
// InpRequireCloseBeyondPattern = true (C4, inchangé).
bool IsHaramiConfirmationBreakout(const int confirmationIndex,
                                  const int patternIndex,
                                  const int patternLength,
                                  const int direction,
                                  const string patternName,
                                  const double &high[], const double &low[],
                                  const double &close[])
{
   bool requireBreakout = InpRequireCloseBeyondPattern; // C4
   // A3 : Harami et inside bar exigent TOUJOURS la cassure.
   if(StringFind(patternName, "Harami") == 0
      || StringFind(patternName, "Inside bar") == 0)
      requireBreakout = true;

   if(!requireBreakout)
      return true;

   int patternEnd = patternIndex + patternLength - 1;
   double patternHigh, patternLow;
   PatternExtremes(patternIndex, patternEnd, high, low, patternHigh, patternLow);

   if(direction > 0)
      return close[confirmationIndex] > patternHigh;
   return close[confirmationIndex] < patternLow;
}

// C10 : lecture d'un buffer d'indicateur avec remontée d'erreur explicite.
// Source : « CopyBuffer - Timeseries and Indicators Access - MQL5 Reference »
// (https://www.mql5.com/en/docs/series/copybuffer, consultée le 2026-11-12) :
// « Returns the copied data count or -1 in case of an error » et, pour un
// indicateur, « if requested timeseries are not yet built [...] the function
// will immediately return -1 ». Toute lecture courte est donc un échec.
//
// P4 : trois états. BarsCalculated(handle) < 0 ou < ratesTotal -> PENDING.
// Source : « BarsCalculated - Timeseries and Indicators Access - MQL5
// Reference » (https://www.mql5.com/en/docs/series/barscalculated, consultée
// le 2026-11-12) : « Returns the amount of calculated data in the indicator
// buffer or -1 in the case of error (data not calculated yet) ». Série
// intégralement calculée mais valeur vide (ou non strictement positive quand
// requirePositive) -> UNAVAILABLE : rejet sans relance ni trace.
//
// Limite assumée : la page « iATR - Technical Indicators - MQL5 Reference »
// (https://www.mql5.com/en/docs/indicators/iatr, consultée le 2026-11-12) ne
// documente NI le nombre de valeurs valides NI l'absence de valeur sur les
// ma_period premières barres ; point NON VÉRIFIÉ dans la doc officielle.
ENUM_INDICATOR_READ ReadIndicatorBuffer(const int handle, const int barIndex,
                                        const int ratesTotal, double &value,
                                        const string context,
                                        const bool requirePositive)
{
   value = EMPTY_VALUE;
   if(handle == INVALID_HANDLE)
   {
      ReportDataIssue(context + " : handle invalide");
      return INDICATOR_READ_PENDING;
   }

   int calculated = BarsCalculated(handle);
   if(calculated < 0 || (ratesTotal > 0 && calculated < ratesTotal))
   {
      ReportDataIssue(context + " : indicateur pas encore calculé");
      return INDICATOR_READ_PENDING;
   }

   double buffer[1];
   if(CopyBuffer(handle, 0, barIndex, 1, buffer) != 1)
   {
      ReportDataIssue(context);
      return INDICATOR_READ_PENDING;
   }

   if(buffer[0] == EMPTY_VALUE || (requirePositive && buffer[0] <= 0.0))
      return INDICATOR_READ_UNAVAILABLE;

   value = buffer[0];
   return INDICATOR_READ_OK;
}

// C10 : forme booléenne (RSI du panneau et des messages). P4 : une valeur
// structurellement absente ne déclenche plus de relance.
bool ReadIndicatorValue(const int handle, const int barIndex,
                        const int ratesTotal, double &value,
                        const string context)
{
   return ReadIndicatorBuffer(handle, barIndex, ratesTotal, value, context,
                              false) == INDICATOR_READ_OK;
}

bool ReadRsiValue(const int handle, const int barIndex, const int ratesTotal,
                  double &value)
{
   return ReadIndicatorValue(handle, barIndex, ratesTotal, value, "RSI");
}

// C13 : stop calculé AVANT le tracé de la flèche (exigence C3).
bool CalculateStopPrice(const int pinBarIndex, const int patternLength,
                        const int direction, const int ratesTotal,
                        const double &high[],
                        const double &low[], double &stopPrice)
{
   int first = pinBarIndex + patternLength - 1;
   double patternHigh, patternLow;
   PatternExtremes(pinBarIndex, first, high, low, patternHigh, patternLow);

   double buffer = InpStopBufferPoints * _Point;
   if(InpStopBufferMode == STOP_BUFFER_ATR)
   {
      double atrValue;
      // P4 : un ATR structurellement absent rend le stop incalculable mais
      // ne déclenche plus de relance.
      if(ReadIndicatorBuffer(AtrHandle, pinBarIndex, ratesTotal, atrValue,
                             "ATR stop", true) != INDICATOR_READ_OK)
         return false;
      buffer = atrValue * InpAtrMultiplier;
   }

   stopPrice = direction > 0 ? patternLow - buffer : patternHigh + buffer;
   return true;
}

// C6 : filtre de taille. InpMinRangeAtr = 0 désactive le filtre.
// A7 : pour une inside bar, le range du pattern étant celui de la mère (les
// extrêmes fusionnés sont ceux de la mère), le filtre s'applique de fait au
// range de la mère, sans code dédié.
bool PassesMinRangeFilter(const int patternIndex, const int patternLength,
                          const int ratesTotal,
                          const double &high[], const double &low[],
                          ENUM_REJECTION_REASON &rejection)
{
   rejection = REJECT_NONE;
   if(InpMinRangeAtr <= 0.0)
      return true;

   double atrValue;
   if(ReadIndicatorBuffer(AtrHandle, patternIndex, ratesTotal, atrValue,
                          "ATR filtre range", true) != INDICATOR_READ_OK)
   {
      rejection = REJECT_DATA;
      return false;
   }

   double patternHigh, patternLow;
   PatternExtremes(patternIndex, patternIndex + patternLength - 1, high, low,
                   patternHigh, patternLow);
   if((patternHigh - patternLow) < InpMinRangeAtr * atrValue)
   {
      rejection = REJECT_RANGE;
      return false;
   }
   return true;
}

ENUM_INDICATOR_READ ReadAdrBars(const int firstShift, double &adr)
{
   adr = EMPTY_VALUE;
   MqlRates rates[];
   int count = CopyRates(_Symbol, PERIOD_D1, firstShift, InpAdrPeriod, rates);
   if(count != InpAdrPeriod)
      return INDICATOR_READ_PENDING;
   double total = 0.0;
   for(int i = 0; i < count; ++i)
   {
      double range = rates[i].high - rates[i].low;
      if(!MathIsValidNumber(range) || range <= 0.0)
      {
         datetime now = TimeCurrent();
         if(LastAdrWarningTime == 0 || now - LastAdrWarningTime >= 60)
         {
            LastAdrWarningTime = now;
            Print("ADR indisponible : une bougie D1 a une plage nulle ou invalide.");
         }
         return INDICATOR_READ_UNAVAILABLE;
      }
      total += range;
   }
   adr = total / InpAdrPeriod;
   if(!MathIsValidNumber(adr) || adr <= 0.0)
   {
      adr = EMPTY_VALUE;
      return INDICATOR_READ_UNAVAILABLE;
   }
   return INDICATOR_READ_OK;
}

// Exclure la D1 contenant la clôture du signal.
ENUM_INDICATOR_READ AdrAtSignal(const datetime confirmationCloseTime, double &adr)
{
   adr = EMPTY_VALUE;
   int dayShift = iBarShift(_Symbol, PERIOD_D1, confirmationCloseTime, false);
   if(dayShift < 0)
      return INDICATOR_READ_PENDING;
   return ReadAdrBars(dayShift + 1, adr);
}

bool TargetPrice(const double entry, const double stop, const int direction,
                 const double adr, const int number, double &target)
{
   target = EMPTY_VALUE;
   if(!MathIsValidNumber(entry) || !MathIsValidNumber(stop)
      || stop == EMPTY_VALUE || direction == 0
      || direction * (entry - stop) <= 0.0)
      return false;
   double distance = adr;
   if(distance == EMPTY_VALUE || !MathIsValidNumber(distance) || distance <= 0.0)
      return false;
   // Le mode ADR conserve TP1 = ADR et TP2 = 3 ADR de la v2.03.
   double multiple = number == 1 ? 1.0 : 3.0;
   double raw = entry + direction * distance * multiple;
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(raw) || !MathIsValidNumber(tick) || tick <= 0.0)
      return false;
   target = NormalizeDouble(MathRound(raw / tick) * tick, _Digits);
   return MathIsValidNumber(target) && direction * (target - entry) > 0.0;
}



// P1 : applyStopCheck pilote le seul contrôle C3. Entrées : true. Sortie :
// false, comme dans l'original. Le stop reste calculé dans les deux cas.
// A4 : pour une inside bar, la pin fusionnée est exigée par défaut, en plus
// de la cassure. Le libellé est alors suffixé par la forme.
bool IsConfirmedSignalCandidate(const int confirmationIndex,
                             const int ratesTotal,
                             const datetime &time[], const double &open[],
                             const double &high[], const double &low[],
                             const double &close[], const bool requireZone,
                             const bool applyStopCheck,
                             const int patternIndex, const int patternLength,
                             const int direction, const string &patternName,
                             string &pinShape, double &stopPrice)
{
   stopPrice = EMPTY_VALUE;
   pinShape = "";

   bool isInsideBar = IsInsideBarName(patternName);

   if(isInsideBar)
   {
      if((applyStopCheck || InpInsideBarRequireFusedPin)
         && !IsConfirmedPinBar(patternIndex, patternLength, direction,
                               pinShape, open, high, low, close))
      {
         CandidateRejection = REJECT_GEOMETRY;
         return false;
      }
   }
   else
   {
      if(!IsConfirmedPinBar(patternIndex, patternLength, direction,
                            pinShape, open, high, low, close))
      {
         CandidateRejection = REJECT_GEOMETRY;
         return false;
      }
   }

   // C6 : filtre de taille (désactivé par défaut).
   ENUM_REJECTION_REASON rangeRejection;
   if(!PassesMinRangeFilter(patternIndex, patternLength, ratesTotal, high, low,
                            rangeRejection))
   {
      CandidateRejection = rangeRejection;
      return false;
   }

   if(!IsFollowThroughCandle(confirmationIndex, direction, open, high, low, close)
      || !IsHaramiConfirmationBreakout(confirmationIndex, patternIndex,
                                       patternLength, direction, patternName,
                                       high, low, close))
   {
      CandidateRejection = REJECT_CONFIRMATION;
      return false;
   }
   if(requireZone
      && !IsPatternInAnyZone(patternIndex, patternLength, direction, time,
                             open, high, low, close))
   {
      CandidateRejection = REJECT_ZONE;
      return false;
   }

   // C3 : le stop est calculé ici, avant le tracé de la flèche. P1 : le
   // calcul a lieu même quand applyStopCheck est faux (panneau, RISQUE).
   if(!CalculateStopPrice(patternIndex, patternLength, direction, ratesTotal,
                          high, low, stopPrice))
   {
      stopPrice = EMPTY_VALUE;
      if(!applyStopCheck)
         return true;
      CandidateRejection = REJECT_DATA;
      if(InpRejectIfStopTouched)
         return false;
      return true;
   }

   // C3 : contact strict compte comme invalidation. P1 : ENTRÉES uniquement.
   if(applyStopCheck && InpRejectIfStopTouched)
   {
      if(direction > 0 && low[confirmationIndex] <= stopPrice)
      {
         CandidateRejection = REJECT_STOP;
         return false;
      }
      if(direction < 0 && high[confirmationIndex] >= stopPrice)
      {
         CandidateRejection = REJECT_STOP;
         return false;
      }
   }

   return true;
}

// P1 : true -> ENTRÉE (C3 appliqué) ; false -> SORTIE (C3 non appliqué).
// A6 : allowInsideBar calculé par l'appelant — ENTRÉE : InpEnableInsideBar ;
// SORTIE : InpEnableInsideBar && InpInsideBarUseForExit.
// F1 (CORRECTIF MAJEUR) : pour un pattern inside bar, la direction retournée
// par FindPattern vaut 0 (contrat documenté). Elle est affectée ICI, à partir
// du swing résolu, AVANT la comparaison et AVANT tout usage de direction
// (zone, cassure, follow-through, stop). Sans cela, la comparaison
// patternSwingDirection != direction était vraie systématiquement (le swing
// vaut toujours +1 ou -1 quand il est résolu) et l'inside bar ne produisait
// JAMAIS de signal. Le chemin de SORTIE (AllowInsideBarForSearch(true))
// transite par la même ligne, donc il est couvert par le même correctif.
bool FindConfirmedSignal(const int confirmationIndex, const int rates_total,
                         const datetime &time[], const double &open[],
                         const double &high[], const double &low[],
                         const double &close[], const bool requireZone,
                         const bool applyStopCheck,
                         const bool allowInsideBar,
                         int &direction, int &signalPatternIndex,
                         int &patternLength, string &patternName,
                         double &stopPrice)
{
   stopPrice = EMPTY_VALUE;
   if(confirmationIndex < 1)
      return false;

   int patternIndex = confirmationIndex + 1;
   if(patternIndex >= rates_total)
      return false;

   bool mergedPattern = FindPattern(patternIndex, rates_total, open, high, low,
                                    close, allowInsideBar,
                                    direction, patternLength, patternName);
   if(mergedPattern)
   {
      CandidatePatternFound = true;
      bool mergedAccepted = true;
      int patternSwingDirection;
      if(!FindPatternSwingDirection(patternIndex, patternLength, rates_total,
                                    high, low, patternSwingDirection))
      {
         mergedAccepted = false;
         CandidateRejection = REJECT_SWING;
      }
      else
      {
         // F1 : l'inside bar porte direction = 0 en sortie de FindPattern
         // (contrat documenté). Dès que le swing est résolu, la direction
         // du signal devient celle du swing — avant la comparaison et avant
         // tout usage de direction. Les autres patterns conservent
         // exactement leur comportement (direction != 0 inchangée).
         if(direction == 0 && IsInsideBarName(patternName))
            direction = patternSwingDirection;

         if(patternSwingDirection != direction)
         {
            mergedAccepted = false;
            CandidateRejection = REJECT_SWING;
         }
      }

      string fusedShape = "";
      if(mergedAccepted
         && !IsConfirmedSignalCandidate(confirmationIndex, rates_total, time,
                                        open, high, low, close, requireZone,
                                        applyStopCheck, patternIndex,
                                        patternLength, direction, patternName,
                                        fusedShape, stopPrice))
         mergedAccepted = false;

      if(mergedAccepted)
      {
         // A2/A4 : suffixe « - forme » uniquement si une forme existe. Pour
         // une inside bar sans forme exigée, seul le nom du pattern est
         // retenu ; le libellé dirigé (haussier/baissier) est construit au
         // moment de l'affichage par SignalDisplayName.
         if(fusedShape != "")
            patternName += " - " + fusedShape;
         signalPatternIndex = patternIndex;
         return true;
      }

      // C1 : sans repli, l'échec du chemin fusionné masque le chemin pin
      // simple sur la même barre (comportement d'origine, défaut conservé).
      if(!InpFallbackToSinglePin)
         return false;

      direction = 0;
      patternLength = 0;
      patternName = "";
      stopPrice = EMPTY_VALUE;
   }

   if(FindSinglePinBar(patternIndex, rates_total, open, high, low, close,
                       direction, patternName))
   {
      patternLength = 1;
      string pinShape;
      if(IsConfirmedSignalCandidate(confirmationIndex, rates_total, time,
                                    open, high, low, close, requireZone,
                                    applyStopCheck, patternIndex, patternLength,
                                    direction, patternName, pinShape, stopPrice))
      {
         patternName = pinShape;
         signalPatternIndex = patternIndex;
         return true;
      }
   }

   if(!InpEnableUnclassifiedFusion || !applyStopCheck || mergedPattern
      || patternIndex + 1 >= rates_total)
      return false;

   // Une inside bar désactivée ne doit pas contourner son réglage.
   int recognizedDirection, recognizedLength;
   string recognizedName;
   if(FindPattern(patternIndex, rates_total, open, high, low, close, true,
                  recognizedDirection, recognizedLength, recognizedName))
      return false;

   patternLength = 2;
   if(!FindPatternSwingDirection(patternIndex, patternLength, rates_total,
                                 high, low, direction))
      return false;

   patternName = "Fusion sans pattern";
   string unclassifiedShape;
   if(!IsConfirmedSignalCandidate(confirmationIndex, rates_total, time,
                                  open, high, low, close, requireZone,
                                  applyStopCheck, patternIndex, patternLength,
                                  direction, patternName, unclassifiedShape, stopPrice))
      return false;

   CandidatePatternFound = true;
   patternName += " - " + unclassifiedShape;
   signalPatternIndex = patternIndex;
   return true;
}



double EstimateLoss(const double entryPrice, const double stopPrice,
                    const int direction)
{
   double minimumVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(minimumVolume <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0)
      return EMPTY_VALUE;
   if((direction > 0 && stopPrice >= entryPrice)
      || (direction < 0 && stopPrice <= entryPrice))
      return EMPTY_VALUE;

   double distance = MathAbs(entryPrice - stopPrice);
   // C12 : SYMBOL_SPREAD est un int exprimé en points, converti en prix par
   // _Point. Source : « Symbol Properties - Environment State - MQL5
   // Reference » (https://www.mql5.com/en/docs/constants/environment_state/
   // marketinfoconstants, consultée le 2026-11-12), ligne SYMBOL_SPREAD :
   // « Spread value in points », type int. Désactivé par défaut.
   if(InpIncludeSpreadInRisk)
   {
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPoints > 0)
         distance += (double)spreadPoints * _Point;
   }

   return distance / tickSize * tickValue * minimumVolume;
}

const int TableMaxSections = 2;            // P6 : bornes de nettoyage
const int TableMaxColumns  = 2;            // P6 : bornes de nettoyage

int TableSectionCount()
{
   return 1;
}

int TableColumnCount(const int section)
{
   return section >= 0 && section < TableSectionCount() ? TableMaxColumns : 0;
}

// Nombre de lignes affichées par section, en-tête inclus.
int TableSectionRowCount()
{
   int visibleFields = SwSupportsVwap() ? FieldCount : FieldCount - 4;
   if(InpAutoCompactTable)
   {
      long height = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      if(height > 0)
      {
         int available = (int)height - TableTitleBarHeight - TableBottomMargin
                         - 24 - TableHeaderRowHeight;
         int dataRows = (int)MathMax(0, MathMin(visibleFields, available / TableRowHeight));
         return 1 + dataRows;
      }
   }
   return visibleFields + 1;
}

int TableFieldForRow(const int row)
{
   if(row == 4) return 12;
   if(row == 5) return 11;
   if(row == 6) return 10;
   if(SwSupportsVwap())
   {
      if(row == 7) return 13;
      if(row == 8) return 14;
      if(row == 9) return 15;
      if(row == 10) return 16;
      return row > 10 ? row - 8 : row - 1;
   }
   return row > 6 ? row - 4 : row - 1;
}

int TableColumnWidth(const int section, const int column)
{
   if(section < 0 || section >= 2 || column < 0 || column >= 2)
      return 0;
   return column == 0 ? TableLabelColumnWidth : TableValueColumnWidth;
}

int TableGroupWidth(const int section)
{
   int width = 0;
   for(int column = 0; column < TableColumnCount(section); ++column)
      width += TableColumnWidth(section, column);
   return width;
}

int TableTotalWidth()
{
   int width = 0;
   for(int section = 0; section < TableSectionCount(); ++section)
      width = (int)MathMax(width, TableGroupWidth(section));
   return width + 16;
}

// F3 : hauteur du CONTENU d'une section (sans la marge basse, comptée une
// seule fois, au niveau du panneau, dans TableTotalHeight).
// TableSectionRowCount() inclut déjà la ligne d'en-tête : elle n'est
// ajoutée qu'une fois via TableHeaderRowHeight, puis (lignes - 1) x
// TableRowHeight pour les lignes de données.
int TableSectionHeight()
{
   return TableHeaderRowHeight + (TableSectionRowCount() - 1) * TableRowHeight;
}

// F3 : hauteur totale = bandeau de titre + sections (contenu) + intercalaires
// + UNE marge basse sous la dernière ligne. Formule explicite :
//   TableTitleBarHeight + N x TableSectionHeight() + (N-1) x TableSectionGap
//   + TableBottomMargin
// La hauteur des sections suit le nombre réel de lignes du panneau.
int TableTotalHeight()
{
   return TableTitleBarHeight + TableSectionCount() * TableSectionHeight()
          + (TableSectionCount() - 1) * TableSectionGap + TableBottomMargin;
}

int TableColumnLeftEdge(const int section, const int column)
{
   int edge = TableX + 8;
   for(int index = 0; index < column; ++index)
      edge += TableColumnWidth(section, index);
   return edge;
}

// F3 : cohérent avec la formule de section : l'en-tête occupe
// TableHeaderRowHeight puis chaque ligne de données TableRowHeight.
int TableRowTop(const int section, const int row)
{
   int top = TableY + TableTitleBarHeight
             + section * (TableSectionHeight() + TableSectionGap);
   if(row == 0)
      return top;
   return top + TableHeaderRowHeight + (row - 1) * TableRowHeight;
}

// B6 : libellé d'une ligne. « HEURE » devient « CONFIRMATION » (O5).
// Les lignes RISQUE portent la mention « (spread incl.) » quand
// InpIncludeSpreadInRisk est actif (O6/B6).
string TableLabelCellText(const int field)
{
   if(field == 0) return "CONFIRMATION";
   if(field == 1) return "SETUP";
   if(field == 2) return "SENS";
   if(field == 3) return "ENTREE";
   if(field == 4) return "STOP";
   if(field == 5) return InpIncludeSpreadInRisk ? "RISQUE MIN (spread)" : "RISQUE MIN";
   if(field == 6) return "TP1";
   if(field == 7) return "TP2";
   if(field == 8) return "RSI " + SwTimeframeName();
   if(field == 9) return "DIVERGENCE RSI";
   if(field == 10) return "TENDANCE EMA";
   if(field == 11) return "INTERPRETATION";
   if(field == 12) return "ETAT";
   if(field == 13) return "VWAP";
   if(field == 14) return "VWAP ORIENTATION";
   if(field == 15) return "VWAP DISTANCE / ATR";
   if(field == 16) return "VWAP / SIGNAL";
   return "";
}

// A2 : nom court pour le panneau.
string ShortPatternName(const string signalName)
{
   string shortName = signalName;
   if(StringFind(signalName, "Harami Cross") == 0)
      shortName = "Harami Cross";
   else if(StringFind(signalName, "Englobante") == 0)
      shortName = "Englobante";
   else if(StringFind(signalName, "Harami") == 0)
      shortName = "Harami";
   else if(StringFind(signalName, "Penetrante") == 0)
      shortName = "Pénétrante";
   else if(StringFind(signalName, "Nuage noir") == 0)
      shortName = "Nuage noir";
   else if(StringFind(signalName, "Inside bar") == 0)
      shortName = "Inside bar";
   else if(StringFind(signalName, "Fusion sans pattern") == 0)
      shortName = "Fusion libre";
   else if(StringFind(signalName, "Marteau inverse") == 0)
      shortName = "M. inverse";

   int separator = StringFind(signalName, " - ");
   if(separator >= 0)
      shortName += " / " + StringSubstr(signalName, separator + 3);
   StringReplace(shortName, "Etoile", "Étoile");
   return shortName;
}

// A2/A7 : libellé complet du signal dans les alertes et le panneau.
// « Inside bar » porte une direction, exprimée ici ; les autres patterns
// portent déjà leur sens.
string SignalDisplayName(const string patternName, const int direction)
{
   string label = patternName;
   if(IsInsideBarName(patternName))
      label = (direction > 0 ? "Inside bar haussier" : "Inside bar baissier")
              + StringSubstr(patternName, StringLen("Inside bar"));
   StringReplace(label, "haussiere", "haussière");
   StringReplace(label, "baissiere", "baissière");
   StringReplace(label, "Penetrante", "Pénétrante");
   StringReplace(label, "Etoile", "Étoile");
   return label;
}

// C12 : affichage d'un prix de stop ("n/d" si non calculable).
string PriceText(const double price)
{
   if(price == EMPTY_VALUE)
      return "n/d";
   return DoubleToString(price, _Digits);
}

string RiskText(const double risk)
{
   if(risk == EMPTY_VALUE)
      return "n/d";

   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   string text = DoubleToString(risk, 2);
   return currency == "" ? text : text + " " + currency;
}

// ADR = moyenne des ranges high-low des InpAdrPeriod dernières bougies D1 clôturées.
bool CalculateAdr(double &adr)
{
   ENUM_INDICATOR_READ result = ReadAdrBars(1, adr);
   if(result == INDICATOR_READ_PENDING)
      ReportDataIssue("ADR courant");
   return result == INDICATOR_READ_OK;
}

string AdrText(const double value)
{
   if(value == EMPTY_VALUE || !MathIsValidNumber(value) || value <= 0.0)
      return "n/d";
   return DoubleToString(value, _Digits);
}

string TakeProfitText(const int number)
{
   double target = EMPTY_VALUE;
   if(!TargetPrice(LatestEntry1Price, LatestStopPrice, LatestSignalDirection,
                   LatestSignalAdr, number, target)
      || LatestSignalDirection * (LatestEntry1Price - LatestStopPrice) <= 0)
      return "n/d";
   double ratio = LatestSignalDirection * (target - LatestEntry1Price)
                  / MathAbs(LatestEntry1Price - LatestStopPrice);
   return DoubleToString(target, _Digits) + " (" + DoubleToString(ratio, 2) + " R)";
}

// Suivi théorique : les OHLC ne permettent pas de déterminer l'ordre intrabar.
string SignalStatus(const int signalIndex, const int direction, const double entry,
                    const double stop, const double adr, const double &high[], const double &low[])
{
   if(signalIndex < 1) return "--";
   if(stop == EMPTY_VALUE || !MathIsValidNumber(stop)
      || !MathIsValidNumber(entry) || direction * (entry - stop) <= 0.0)
      return "n/d (STOP)";
   double tp1 = EMPTY_VALUE, tp2 = EMPTY_VALUE;
   bool hasTp1 = TargetPrice(entry, stop, direction, adr, 1, tp1);
   bool hasTp2 = TargetPrice(entry, stop, direction, adr, 2, tp2);
   int maxSignalAgeBars = EffectiveMaxSignalAgeBars();
   bool tp1Reached = false;
   for(int bar = signalIndex - 1; bar >= 0; --bar)
   {
      int age = signalIndex - bar - (bar == 0 ? 1 : 0);
      if(maxSignalAgeBars > 0 && age > maxSignalAgeBars)
         return tp1Reached ? "TP1 ATTEINT / PÉRIMÉ" : "PÉRIMÉ";
      bool stopTouched = direction > 0 ? low[bar] <= stop : high[bar] >= stop;
      bool tp1Touched = hasTp1 && (direction > 0 ? high[bar] >= tp1 : low[bar] <= tp1);
      bool tp2Touched = hasTp2 && (direction > 0 ? high[bar] >= tp2 : low[bar] <= tp2);
      if(stopTouched && ((!tp1Reached && tp1Touched) || tp2Touched))
         return "ORDRE INTRABAR INCONNU";
      if(stopTouched)
         return tp1Reached ? "TP1 ATTEINT / STOP TOUCHÉ" : "STOP TOUCHÉ";
      if(tp2Touched) return "TP2 ATTEINT";
      if(tp1Touched) tp1Reached = true;
   }
   if(tp1Reached) return "TP1 ATTEINT";
   if(!hasTp1 || !hasTp2) return "ACTIF (TP n/d)";
   return "ACTIF";
}

bool SignalIsActive(const string status)
{
   return status == "ACTIF" || status == "ACTIF (TP n/d)" || status == "TP1 ATTEINT";
}

// A partial divergence is evidence of its direction, but not of the absence
// of the other direction.
string SwInterpretation(const int direction, const string rsi7, const string rsi14)
{
   if(direction == 0) return "--";
   bool bullish = StringFind(rsi7, "HAUSS.") >= 0 || StringFind(rsi14, "HAUSS.") >= 0;
   bool bearish = StringFind(rsi7, "BAISS.") >= 0 || StringFind(rsi14, "BAISS.") >= 0;
   bool incomplete = StringFind(rsi7, "n/d") >= 0 || StringFind(rsi14, "n/d") >= 0
                     || StringFind(rsi7, "partiel") >= 0 || StringFind(rsi14, "partiel") >= 0;
   string result;
   if(bullish && bearish) result = "MIXTE";
   else if(bullish || bearish)
      result = ((direction > 0 && bullish) || (direction < 0 && bearish))
               ? "CONCORDANTE" : "OPPOSEE";
   else return incomplete ? "n/d" : "AUCUNE";
   return incomplete ? result + " (partiel)" : result;
}

bool HasOppositeExit(const int signalIndex, const int direction, const int ratesTotal,
                     const datetime &time[], const double &open[], const double &high[],
                     const double &low[], const double &close[])
{
   for(int bar = signalIndex - 1; bar >= 1; --bar)
   {
      int exitDirection, patternIndex, patternLength;
      string patternName;
      double stop;
      if(FindConfirmedSignal(bar, ratesTotal, time, open, high, low, close,
                             false, false, AllowInsideBarForSearch(true),
                             exitDirection, patternIndex, patternLength, patternName, stop)
         && exitDirection != direction)
         return true;
   }
   return false;
}

int DisplayedSignalIndex(const int latestIndex, const int previousShift, const int scanLimit)
{
   if(latestIndex < 0 && previousShift > scanLimit)
      return previousShift;
   return latestIndex;
}

string TableCellText(const int section, const int row, const int column)
{
   if(row == 0)
      return column == 0 ? "SIGNAL" : "DERNIER";
   int field = TableFieldForRow(row);
   if(column == 0) return TableLabelCellText(field);
   if(field == 10) return SwCurrentTrend;
   if(field == 13) return PriceText(SwVwap);
   if(field == 14) return SwVwapDirection;
   if(field == 15) return SwVwapDistanceAtr == EMPTY_VALUE ? "n/d"
                          : DoubleToString(SwVwapDistanceAtr, 2) + " ATR";
   if(field == 16) return SwVwapContext();
   if(LatestSignalTime == 0) return "--";
   if(field == 0) return TimeToString(LatestSignalTime, TIME_DATE | TIME_MINUTES);
   if(field == 1) return ShortPatternName(LatestSignalName);
   if(field == 2) return LatestSignalDirection > 0 ? "Achat" : "Vente";
   if(field == 3) return PriceText(LatestEntry1Price);
   if(field == 4) return PriceText(LatestStopPrice);
   if(field == 5) return RiskText(LatestEntry1Risk);
   if(field == 6) return TakeProfitText(1);
   if(field == 7) return TakeProfitText(2);
   if(field == 8) return SwLatestRsi;
   if(field == 9) return SwLatestDivergence;
   if(field == 11) return SwInterpretation(LatestSignalDirection, SwLatestDiv7, SwLatestDiv14);
   if(field == 12) return LatestSignalStatus;
   return "";
}

void RemoveObsoleteWideTableCells()
{
   for(int section = 0; section < 2; ++section)
      for(int row = 0; row < 3; ++row)
         for(int column = 2; column < 7; ++column)
         {
            string cellName = TableCellPrefix + IntegerToString(section) + "_"
               + IntegerToString(row) + "_" + IntegerToString(column);
            ObjectDelete(0, cellName + "_bg");
            ObjectDelete(0, cellName + "_text");
         }
}

// P6 : suppression des objets d'une section. Bornes maximales volontaires
// (et non TableColumnCount, qui vaut 0 pour une section masquée).
void DeleteTableSectionObjects(const int section)
{
   for(int row = 0; row <= 21; ++row)
      for(int column = 0; column < TableMaxColumns; ++column)
      {
         string cellName = TableCellPrefix + IntegerToString(section) + "_"
            + IntegerToString(row) + "_" + IntegerToString(column);
         ObjectDelete(0, cellName + "_bg");
         ObjectDelete(0, cellName + "_text");
      }
}

// P6 : suppression de tout le panneau (cadre, poignée, titre, cellules).
void DeleteTableObjects()
{
   for(int section = 0; section < TableMaxSections; ++section)
      DeleteTableSectionObjects(section);
   ObjectDelete(0, TablePanelName);
   ObjectDelete(0, TableHandleName);
   ObjectDelete(0, TableTitleName);
}

// B2 : mesure réelle du texte via TextGetSize. Sources : « TextGetSize -
// Object Functions - MQL5 Reference » (https://www.mql5.com/en/docs/objects/
// textgetsize, consultée le 2026-11-13) : « bool TextGetSize(const string
// text, uint &width, uint &height) » — « The function returns the line width
// and height at the current font settings » ; « TextSetFont - Object
// Functions - MQL5 Reference » (https://www.mql5.com/en/docs/objects/
// textsetfont, consultée le 2026-11-13) : « bool TextSetFont(const string
// name, int size, uint flags, int orientation=0) » — « Arial font with the
// size -120 (12 pt) is used by default », la taille négative étant exprimée
// en dixièmes de point. La police « Arial » -100 reproduit OBJPROP_FONTSIZE
// 10 utilisée par les OBJ_LABEL du panneau.
// La doc ne précise PAS si TextGetSize mesure dans les mêmes conditions
// qu'un OBJ_LABEL (rendu DPI, aliasing) : point NON VÉRIFIÉ. Estimation
// prudente gardée en repli si la mesure échoue.
void MeasureTableMetrics()
{
   if(!TextSetFont(TableFontName, -TableFontSizePoints * 10, 0)) return;
   uint width = 0, height = 0;
   if(TextGetSize("CONFIRMATION", width, height) && height > 0)
      TableTextHeight = (int)height;
   int labelWidth = 0;
   for(int field = 0; field < FieldCount; ++field)
      if(TextGetSize(TableLabelCellText(field), width, height) && (int)width > labelWidth)
         labelWidth = (int)width;
   string samples[6] = {"Harami Cross / Étoile filante",
                        "SURACHAT (100.0 / 100.0)", "1234567.89 (12.34 R)",
                        "1234567.89 USD", "7:HAUSS. (partiel) 14:BAISS. (partiel)",
                        "+123.45 ATR"};
   int valueWidth = 0;
   for(int index = 0; index < 6; ++index)
      if(TextGetSize(samples[index], width, height) && (int)width > valueWidth)
         valueWidth = (int)width;
   if(labelWidth > 0) TableLabelColumnWidth = labelWidth + 2 * TableTextPaddingX;
   if(valueWidth > 0) TableValueColumnWidth = valueWidth + 2 * TableTextPaddingX;
   TableHeaderRowHeight = TableTextHeight + 10;
   TableRowHeight = TableTextHeight + 8;
}

// F2 : décalage vertical COHÉRENT avec l'ancrage. Les cellules utilisent
// ANCHOR_LEFT (« Anchor point to the left in the center », source :
// « Methods of Object Binding - Objects Constants - MQL5 Reference »,
// https://www.mql5.com/en/docs/constants/objectconstants/enum_anchorpoint,
// consultée le 2026-11-13) : le point d'ancrage est au MILIEU GAUCHE du
// texte, donc le décalage vertical doit placer ce milieu au milieu de la
// cellule, soit LA MOITIÉ DE LA HAUTEUR DE CELLULE — et non
// (hauteur - texte)/2, qui n'est valable que pour un ancrage en haut à 
// gauche (ANCHOR_LEFT_UPPER). Avant F2, le milieu du texte tombait ~4 px
// sous le haut de la cellule : les traits de grille traversaient le haut
// des lettres et « SIGNAL »/« RÉCENT » débordaient au-dessus du bandeau.
int TableCellTextYOffset(const int row)
{
   if(row == 0)
      return TableHeaderRowHeight / 2;
   return TableRowHeight / 2;
}

void SetTableCell(const int section, const int row, const int column,
                  const string text,
                  const color backgroundColor, const color foregroundColor)
{
   string cellName = TableCellPrefix + IntegerToString(section) + "_"
      + IntegerToString(row) + "_" + IntegerToString(column);
   string textName = cellName + "_text";
   int leftEdge = TableColumnLeftEdge(section, column);
   int yPosition = TableRowTop(section, row);

   if(ObjectFind(0, textName) < 0)
      ObjectCreate(0, textName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, textName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   // F2 : ANCHOR_LEFT = milieu gauche du texte (doc ENUM_ANCHOR_POINT). Le
   // décalage TableCellTextYOffset place ce milieu au centre vertical de la
   // cellule. Cohérent pour les lignes de données ET le bandeau.
   ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, textName, OBJPROP_XDISTANCE, leftEdge + TableTextPaddingX);
   ObjectSetInteger(0, textName, OBJPROP_YDISTANCE,
                    yPosition + TableCellTextYOffset(row));
   // G1 : parametres couleurs — backgroundColor = couleur de FOND de la
   // cellule (ou du bandeau pour la ligne 0) ; foregroundColor = couleur du
   // TEXTE (contraste), passee par l'appelant : ligne 0 ->
   // (couleur du bandeau, couleur de contraste), lignes de donnees ->
   // (fond de cellule, texte). L'ancienne surcharge
   // « if(row == 0) cellTextColor = backgroundColor; » peignait le titre
   // dans la couleur de son PROPRE bandeau : noir sur noir en theme clair.
   // Supprimee : la valeur par defaut (foregroundColor) est la couleur de
   // contraste correcte pour la ligne 0 comme pour les autres. Les regles
   // SENS et QUALITÉ ne changent pas.
   color cellTextColor = foregroundColor;
   if(column == 1 && row > 0 && TableFieldForRow(row) == 2)
   {
      if(LatestSignalTime != 0)
         cellTextColor = LatestSignalDirection > 0 ? clrLimeGreen : clrTomato;
   }
   ObjectSetInteger(0, textName, OBJPROP_COLOR, cellTextColor);
   ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, TableFontSizePoints);
   ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, textName, OBJPROP_HIDDEN, true);
   // G4 : ZORDER ne gere QUE la priorite des evenements souris (quel objet
   // reçoit clic et glisser-deposer), PAS l'ordre de dessin : le dessin suit
   // l'ordre de creation des objets. Source : « Priority of objects
   // (Z-Order) », MQL5 Book (https://www.mql5.com/en/book/applications/
   // objects/objects_z_order, consultee le 2026-11-13). La valeur 2 est
   // conservee pour la priorite d'interaction ; le texte apparait au-dessus
   // de son fond parce qu'il est cree APRES lui dans UpdateSignalTable,
   // pas grace au ZORDER.
   ObjectSetInteger(0, textName, OBJPROP_ZORDER, 2);
   ObjectSetString(0, textName, OBJPROP_FONT, TableFontName);
   ObjectSetString(0, textName, OBJPROP_TEXT, text);
}

void UpdateSignalTable()
{
   // P6 : panneau masqué -> aucun objet résiduel sur le graphique.
   if(!InpShowTable)
   {
      DeleteTableObjects();
      ChartRedraw(0);
      return;
   }

   // P6/B4 : les sections masquées (input ou auto-compaction) sont nettoyées
   // avant le tracé.
   for(int hidden = TableSectionCount(); hidden < TableMaxSections; ++hidden)
      DeleteTableSectionObjects(hidden);
   for(int section = 0; section < TableSectionCount(); ++section)
      for(int row = TableSectionRowCount(); row <= 21; ++row)
         for(int column = 0; column < TableMaxColumns; ++column)
         {
            string obsolete = TableCellPrefix + IntegerToString(section) + "_"
                              + IntegerToString(row) + "_" + IntegerToString(column);
            if(ObjectFind(0, obsolete + "_bg") >= 0)
               ObjectDelete(0, obsolete + "_bg");
            if(ObjectFind(0, obsolete + "_text") >= 0)
               ObjectDelete(0, obsolete + "_text");
         }

   color backgroundColor = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   color foregroundColor = (color)ChartGetInteger(0, CHART_COLOR_FOREGROUND);

   if(ObjectFind(0, TablePanelName) < 0)
      ObjectCreate(0, TablePanelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, TablePanelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, TablePanelName, OBJPROP_XDISTANCE, TableX);
   ObjectSetInteger(0, TablePanelName, OBJPROP_YDISTANCE, TableY);
   ObjectSetInteger(0, TablePanelName, OBJPROP_XSIZE, TableTotalWidth());
   ObjectSetInteger(0, TablePanelName, OBJPROP_YSIZE, TableTotalHeight());
   ObjectSetInteger(0, TablePanelName, OBJPROP_BGCOLOR, backgroundColor);
   ObjectSetInteger(0, TablePanelName, OBJPROP_COLOR, foregroundColor);
   ObjectSetInteger(0, TablePanelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, TablePanelName, OBJPROP_BACK, false);
   ObjectSetInteger(0, TablePanelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, TablePanelName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, TablePanelName, OBJPROP_ZORDER, 0);

   if(ObjectFind(0, TableHandleName) < 0)
      ObjectCreate(0, TableHandleName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, TableHandleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, TableHandleName, OBJPROP_XDISTANCE, TableX);
   ObjectSetInteger(0, TableHandleName, OBJPROP_YDISTANCE, TableY);
   ObjectSetInteger(0, TableHandleName, OBJPROP_XSIZE, TableTotalWidth());
   ObjectSetInteger(0, TableHandleName, OBJPROP_YSIZE, 28);
   ObjectSetInteger(0, TableHandleName, OBJPROP_BGCOLOR, backgroundColor);
   ObjectSetInteger(0, TableHandleName, OBJPROP_COLOR, foregroundColor);
   ObjectSetInteger(0, TableHandleName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, TableHandleName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, TableHandleName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, TableHandleName, OBJPROP_ZORDER, 10);

   if(ObjectFind(0, TableTitleName) < 0)
      ObjectCreate(0, TableTitleName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, TableTitleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, TableTitleName, OBJPROP_ANCHOR, ANCHOR_CENTER);
   ObjectSetInteger(0, TableTitleName, OBJPROP_XDISTANCE, TableX + TableTotalWidth() / 2);
   ObjectSetInteger(0, TableTitleName, OBJPROP_YDISTANCE, TableY + 14);
   ObjectSetInteger(0, TableTitleName, OBJPROP_COLOR, foregroundColor);
   ObjectSetInteger(0, TableTitleName, OBJPROP_FONTSIZE, TableFontSizePoints);
   ObjectSetInteger(0, TableTitleName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, TableTitleName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, TableTitleName, OBJPROP_ZORDER, 11);
   ObjectSetString(0, TableTitleName, OBJPROP_FONT, TableFontName);
   string timeframe = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(timeframe, "PERIOD_", "");
   ObjectSetString(0, TableTitleName, OBJPROP_TEXT,
                   StringFormat("SILENTWOLF | %s", timeframe));

   for(int section = 0; section < TableSectionCount(); ++section)
      for(int row = 0; row < TableSectionRowCount(); ++row)
         for(int column = 0; column < TableColumnCount(section); ++column)
         {
            string cellName = TableCellPrefix + IntegerToString(section) + "_"
               + IntegerToString(row) + "_" + IntegerToString(column) + "_bg";
            int leftEdge = TableColumnLeftEdge(section, column);
            int yPosition = TableRowTop(section, row);
            if(ObjectFind(0, cellName) < 0)
               ObjectCreate(0, cellName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
            ObjectSetInteger(0, cellName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, cellName, OBJPROP_XDISTANCE, leftEdge);
            ObjectSetInteger(0, cellName, OBJPROP_YDISTANCE, yPosition);
            ObjectSetInteger(0, cellName, OBJPROP_XSIZE,
                             TableColumnWidth(section, column));
            ObjectSetInteger(0, cellName, OBJPROP_YSIZE,
                             row == 0 ? TableHeaderRowHeight : TableRowHeight);
            ObjectSetInteger(0, cellName, OBJPROP_BGCOLOR,
                             row == 0 ? foregroundColor : backgroundColor);
            ObjectSetInteger(0, cellName, OBJPROP_COLOR, foregroundColor);
            ObjectSetInteger(0, cellName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
            ObjectSetInteger(0, cellName, OBJPROP_BACK, false);
            ObjectSetInteger(0, cellName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, cellName, OBJPROP_HIDDEN, true);
            ObjectSetInteger(0, cellName, OBJPROP_ZORDER, 1);
            SetTableCell(section, row, column,
                         TableCellText(section, row, column),
                         row == 0 ? foregroundColor : backgroundColor,
                         row == 0 ? backgroundColor : foregroundColor);
         }

   ChartRedraw(0);
}

// C9 : émission centralisée. Les canaux sont indépendants. Sources :
// « PlaySound - Common Functions - MQL5 Reference »
// (https://www.mql5.com/en/docs/common/playsound, consultée le 2026-11-12) :
// « The file must be located in terminal_directory\\Sounds or its
// sub-directory », « Only WAV files are played », retour « true - if the
// file is found, otherwise - false » ; la même page précise que PlaySound
// ne fonctionne pas dans le testeur de stratégies. « SendMail - Network
// Functions - MQL5 Reference »
// (https://www.mql5.com/en/docs/common/sendmail, consultée le 2026-11-12) :
// retour « true - if an email is put into the send queue », et « Sending
// can be prohibited in settings ». L'échec est donc rapporté.
void RaiseAlert(const string message)
{
   if(InpEnableAlertPopup)
      Alert(message);
   if(InpEnableSound && !PlaySound(InpSoundFile))
   {
      datetime now = TimeCurrent();
      if(LastSoundWarningTime == 0 || now - LastSoundWarningTime >= 60)
      {
         LastSoundWarningTime = now;
         Print("PlaySound a échoué pour \"", InpSoundFile,
               "\". Le fichier .wav doit se trouver dans <terminal>\\Sounds. Erreur: ",
               GetLastError());
      }
   }
   if(InpEnablePush)
   {
      if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
         Print("Notification ignorée : les notifications MT5 ne sont pas activées.");
      else if(MQLInfoInteger(MQL_TESTER))
         Print("Notification impossible : SendNotification ne fonctionne pas dans le testeur MT5.");
      else
      {
         ResetLastError();
         if(!SendNotification(StringSubstr(message, 0, 255)))
            Print("SendNotification a échoué. Erreur: ", GetLastError());
      }
   }
   if(InpEnableEmail)
   {
      if(!TerminalInfoInteger(TERMINAL_EMAIL_ENABLED))
         Print("SendMail ignoré : l'email n'est pas activé dans le terminal.");
      else if(!SendMail("Pattern Fusion Pin Bar", message))
         Print("SendMail a échoué. Erreur: ", GetLastError());
   }
}

int OnInit()
{
   if(InpBullishZonePrefix == "" || InpBearishZonePrefix == ""
      || StringFind(InpBullishZonePrefix, InpBearishZonePrefix) == 0
      || StringFind(InpBearishZonePrefix, InpBullishZonePrefix) == 0)
   {
      Print("Préfixes de zones invalides : ils doivent être non vides et distincts, sans chevauchement.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpWickBodyRatio <= 0.0 || InpArrowOffsetPoints < 0
      || InpMaxBarsToScan < 1
      || InpSwingLookbackBars < 1
      || InpPinSwingLookbackBars < 1 || InpPinSwingLookbackM5 < 1
      || InpPinSwingLookbackM15 < 1 || InpPinSwingLookbackM30 < 1
      || InpPinSwingLookbackH1 < 1
      || InpStopBufferPoints < 0.0
      || InpAtrPeriod < 1 || InpAdrPeriod < 1 || InpAtrMultiplier < 0.0
      || InpMinRangeAtr < 0.0 || InpMaxSignalAgeBars < 0
      || InpMaxSignalAgeBarsM5 < 0 || InpMaxSignalAgeBarsM15 < 0
      || InpMaxSignalAgeBarsM30 < 0 || InpMaxSignalAgeBarsH1 < 0
      || InpRsiOversold < 0.0 || InpRsiOverbought > 100.0
      || InpRsiOversold >= InpRsiOverbought
      || InpMinWickRangeRatio < 0.0 || InpMinWickRangeRatio > 1.0
      || InpMaxOppositeWickRatio < 0.0 || InpMaxOppositeWickRatio > 1.0
      || InpHaramiCrossMaxBodyRatio < 0.0 || InpHaramiCrossMaxBodyRatio > 1.0
      || InpZeroBodyFloorRangeFraction < 0.0
      // A1 : validation des nouveaux inputs, même mécanisme que les autres.
      || InpInsideBarMaxRatio <= 0.0)
      return INIT_PARAMETERS_INCORRECT;

   // B2 : mesure des métriques du panneau (repli prudent si échec).
   MeasureTableMetrics();

   long chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   long chartHeight = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   RemoveObsoleteWideTableCells();
   TableX = (int)chartWidth - TableTotalWidth() - 12;
   if(TableX < 8)
      TableX = 8;
   TableY = (int)chartHeight - TableTotalHeight() - 12;
   if(TableY < 8)
      TableY = 8;
   double savedX, savedY;
   if(GlobalVariableCheck(TablePositionKey("x"))
      && GlobalVariableCheck(TablePositionKey("y")))
   {
      if(GlobalVariableGet(TablePositionKey("x"), savedX)
         && GlobalVariableGet(TablePositionKey("y"), savedY))
      {
         TableX = (int)MathMax(0, MathMin(savedX, MathMax(0, chartWidth - TableTotalWidth())));
         TableY = (int)MathMax(0, MathMin(savedY, MathMax(0, chartHeight - TableTotalHeight())));
         TablePositionCustomized = true;
      }
      else
         Print("Impossible de restaurer la position du panneau. Erreur: ", GetLastError());
   }

   // C6 : l'ATR est aussi nécessaire au filtre de taille, pas seulement au stop.
   bool atrRequired = InpStopBufferMode == STOP_BUFFER_ATR
                      || InpMinRangeAtr > 0.0;
   if(atrRequired || (InpShowTable && SwSupportsVwap()))
      AtrHandle = iATR(_Symbol, _Period, InpAtrPeriod);
   if(!atrRequired && InpShowTable && SwSupportsVwap() && AtrHandle == INVALID_HANDLE)
      Print("ATR du VWAP indisponible. Erreur: ", GetLastError());
   if(atrRequired && AtrHandle == INVALID_HANDLE)
   {
      Print("Impossible de créer les handles RSI/ATR. Erreur: ", GetLastError());
      if(AtrHandle != INVALID_HANDLE)
         IndicatorRelease(AtrHandle);
      return INIT_FAILED;
   }

   SwInitHandles();
   if(InpEnablePush && MQLInfoInteger(MQL_TESTER))
      Print("Notifications push indisponibles dans le testeur MT5.");
   else if(InpEnablePush && !TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      Print("Notifications push désactivées dans MT5 : configurez l'onglet Notifications et le MetaQuotes ID.");

   SetIndexBuffer(0, BullishBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, BearishBuffer, INDICATOR_DATA);
   ArraySetAsSeries(BullishBuffer, true);
   ArraySetAsSeries(BearishBuffer, true);
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME, "silentwolfindices");
   Print("PinBarFusion : les signaux historiques sont recalculés avec les zones actuelles ; "
         "ils ne prouvent pas qu'une zone existait au moment du signal.");

   // C11 : CHARTEVENT_OBJECT_CREATE et CHARTEVENT_OBJECT_DELETE ne sont
   // délivrés que si CHART_EVENT_OBJECT_CREATE / _DELETE sont vrais pour le
   // graphique. Source : « Types of Chart Events - Chart Constants - MQL5
   // Reference » (https://www.mql5.com/en/docs/constants/chartconstants/
   // enum_chartevents, consultée le 2026-11-12) : « Graphical object created
   // (if CHART_EVENT_OBJECT_CREATE=true is set for the chart) », idem pour
   // DELETE. Les deux propriétés sont de type bool et figurent dans la liste
   // ChartSetInteger / ChartGetInteger : « Chart Properties - Chart Constants
   // - MQL5 Reference » (https://www.mql5.com/en/docs/constants/chartconstants/
   // enum_chart_property, consultée le 2026-11-12) ; cette page ne les marque
   // pas « r/o » et ne documente PAS leur valeur par défaut. Le défaut false
   // n'est affirmé que par le MQL5 Book, source secondaire : « Event-related
   // chart properties » (https://www.mql5.com/en/book/applications/events/
   // events_properties) : « By default, all properties have the false value ».
   //
   // P5 : la propriété appartient au GRAPHIQUE, pas au programme. Le MQL5 Book
   // (même page, source secondaire) précise qu'une modification « affects all
   // other programs running on the same chart and remains in effect even after
   // the original program terminates ». On ne force donc que ce qui était
   // faux, on mémorise ce qu'on a changé, et OnDeinit ne restaurera que cela.
   // Risque assumé, non supprimable en MQL5 (aucun comptage de références) :
   //  - si un autre programme du graphique avait DÉJÀ activé ces événements,
   //    notre lecture renvoie true, on ne touche à rien, rien ne sera
   //    restauré (cas sain) ;
   //  - mais si un autre programme les active APRÈS nous sans les avoir lus,
   //    notre restauration au retrait de l'indicateur les lui coupera.
   ChartEventCreateForced = false;
   ChartEventDeleteForced = false;
   if(ChartGetInteger(0, CHART_EVENT_OBJECT_CREATE) == 0)
      ChartEventCreateForced = ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE,
                                               true);
   if(ChartGetInteger(0, CHART_EVENT_OBJECT_DELETE) == 0)
      ChartEventDeleteForced = ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE,
                                               true);
   int drawingResult = DrawingInit();
   if(drawingResult != INIT_SUCCEEDED)
      return drawingResult;
   if(!EventSetTimer(5))
   {
      Print("Impossible de démarrer le timer. Erreur: ", GetLastError());
      DrawingDeinit();
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   if(rates_total < 5)
      return 0;

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   bool firstCalculation = LastBarTime == 0;
   bool newBar = !firstCalculation && time[0] != LastBarTime;
   // C8 : l'alerte de la barre est mémorisée dès sa détection. Elle n'est
   // consommée qu'une fois le recalcul mené à bien, donc un échec de
   // RefreshChartZones() ne la perd plus.
   if(newBar)
   {
      int previousBarShift = iBarShift(_Symbol, _Period, LastBarTime, true);
      if(previousBarShift > 1)
         PrintFormat("PinBarFusion : %d barres intermédiaires non alertées ; "
                     "les alertes historiques ne sont pas reconstituées.",
                     previousBarShift - 1);
      PendingNewBarAlert = true;
      // P3 (b) : le compteur de relances est réarmé à chaque nouvelle barre.
      DataRetryCount = 0;
   }
   bool fullRecalculation = prev_calculated == 0 || SignalsDirty;
   bool recalculateSignals = fullRecalculation || newBar || PendingNewBarAlert;
   if(!recalculateSignals && LatestSignalTime > 0)
   {
      int shift = iBarShift(_Symbol, _Period, LatestSignalTime, true);
      if(shift < 1)
         recalculateSignals = true;
      else if(LatestSignalStatus != "SORTIE CONTRAIRE")
      {
         string status = SignalStatus(shift, LatestSignalDirection, LatestEntry1Price,
                                      LatestStopPrice, LatestSignalAdr, high, low);
         if(status != LatestSignalStatus)
         {
            LatestSignalStatus = status;
            if(!SignalIsActive(status) && ActiveSignalTime == LatestSignalTime)
            {
               ActiveSignalDirection = 0;
               ActiveSignalTime = 0;
            }
            if(InpShowTable) UpdateSignalTable();
         }
      }
   }
   if(!recalculateSignals)
      return rates_total;

   // C-R1 : l'alerte d'ENTRÉE est armée UNIQUEMENT à l'ouverture d'une
   // nouvelle barre (newBar, ou premier calcul pour un chargement à chaud).
   // Les recalculs en cours de barre (SignalsDirty, par exemple après une
   // modification de zone) ne réarment PAS ; ils peuvent seulement rattraper
   // une alerte armée non encore consommée (données manquantes à l'ouverture).
   if(newBar || firstCalculation)
      EntryAlertArmedBarTime = time[1];
   // InpAlertOnZoneChange = true rétablit le comportement P3 antérieur :
   // tout recalcul complet peut armer l'alerte pour la barre de confirmation
   // courante.
   if(InpAlertOnZoneChange && fullRecalculation)
      EntryAlertArmedBarTime = time[1];

   int oldestSignalIndex = fullRecalculation ? rates_total - 2
                                            : MathMin(rates_total - 2, InpMaxBarsToScan);
   int previousShift = LatestSignalTime > 0
                       ? iBarShift(_Symbol, _Period, LatestSignalTime, true) : -1;
   datetime previousTime = LatestSignalTime;
   int previousDirection = LatestSignalDirection;
   string previousName = LatestSignalName;
   double previousEntry = LatestEntry1Price;
   double previousRisk = LatestEntry1Risk;
   double previousStop = LatestStopPrice;

   if(fullRecalculation)
   {
      // C8 : en cas d'échec, LastBarTime n'est pas avancé, donc newBar reste
      // vrai au tick suivant et le recalcul est bien retenté.
      if(!RefreshChartZones())
      {
         SignalsDirty = true;
         return rates_total;
      }
      ArrayInitialize(BullishBuffer, EMPTY_VALUE);
      ArrayInitialize(BearishBuffer, EMPTY_VALUE);
   }
   else
   {
      // Effacer aussi la flèche précédente si elle est hors de la plage rescannée.
      if(previousShift >= 0 && previousShift < rates_total)
      {
         BullishBuffer[previousShift] = EMPTY_VALUE;
         BearishBuffer[previousShift] = EMPTY_VALUE;
      }
      int clearUpperBound = MathMin(rates_total - 1, oldestSignalIndex + 1);
      for(int index = 0; index <= clearUpperBound; ++index)
      {
         BullishBuffer[index] = EMPTY_VALUE;
         BearishBuffer[index] = EMPTY_VALUE;
      }
   }
   // C8 : la barre est acquise, l'horodatage peut avancer.
   LastBarTime = time[0];
   // P3 (a) : au tout premier calcul, la barre de confirmation déjà fermée est
   // marquée comme déjà traitée, en ENTRÉE comme en SORTIE. Sans ce marquage,
   // les déclencheurs d'alerte émettraient une alerte pour un signal purement
   // historique au chargement de l'indicateur.
   if(firstCalculation)
   {
      LastEntryAlertBarTime = time[1];
      LastExitAlertBarTime = time[1];
   }
   SignalsDirty = false;
   IndicatorDataPending = false;
   LatestSignalTime = 0;
   LatestSignalStatus = "--";
   LatestEntry1Price = 0.0;
   LatestEntry1Risk = EMPTY_VALUE;
   LatestSignalDirection = 0;
   LatestSignalName = "";
   LatestStopPrice = EMPTY_VALUE;
   int latestSignalIndex = -1;
   LatestSignalAdr = EMPTY_VALUE;
   if(fullRecalculation)
   {
      ArrayInitialize(RejectedByReason, 0);
      FoundPatternCount = 0;
      DuplicateSignalCount = 0;
      AcceptedSignalCount = 0;
      UnclassifiedRejectionCount = 0;
   }
   bool bullishSwingSignalUsed = false;
   bool bearishSwingSignalUsed = false;
   datetime lastBullishSignalTime = 0;
   datetime lastBearishSignalTime = 0;
   bool currentBarEntrySignal = false;
   int currentBarEntryDirection = 0;
   string currentBarEntryName = "";
   int currentBarEntryPatternIndex = -1;
   bool trackedSignalFound = false;
   bool trackedSignalActive = false;
   datetime latestActiveTime = 0;
   int latestActiveDirection = 0;

   for(int i = oldestSignalIndex; i >= 1; --i)
   {
      int pivotIndex = i + InpSwingLookbackBars;
      if(bullishSwingSignalUsed
         && IsConfirmedSwingPivot(pivotIndex, true, rates_total, high, low)
         && time[pivotIndex] > lastBullishSignalTime)
         bullishSwingSignalUsed = false;
      if(bearishSwingSignalUsed
         && IsConfirmedSwingPivot(pivotIndex, false, rates_total, high, low)
         && time[pivotIndex] > lastBearishSignalTime)
         bearishSwingSignalUsed = false;

      int direction, patternIndex, patternLength;
      string patternName;
      double signalStopPrice;
      // P1 : recherche d'ENTRÉE -> requireZone = true, applyStopCheck = true.
      // A6 : inside bar admise selon InpEnableInsideBar.
      CandidateRejection = REJECT_NONE;
      CandidatePatternFound = false;
      bool accepted = FindConfirmedSignal(i, rates_total, time, open, high, low, close,
                                          true, true, AllowInsideBarForSearch(false),
                                          direction, patternIndex, patternLength,
                                          patternName, signalStopPrice);
      if(fullRecalculation && CandidatePatternFound)
      {
         ++FoundPatternCount;
         if(!accepted && CandidateRejection > REJECT_NONE && CandidateRejection <= REJECT_RANGE)
            ++RejectedByReason[(int)CandidateRejection];
         else if(!accepted)
            ++UnclassifiedRejectionCount;
      }
      if(!accepted)
         continue;

      if((direction > 0 && bullishSwingSignalUsed)
         || (direction < 0 && bearishSwingSignalUsed))
      {
         if(fullRecalculation)
            ++DuplicateSignalCount;
         continue;
      }

      if(fullRecalculation)
         ++AcceptedSignalCount;

      if(direction > 0)
      {
         bullishSwingSignalUsed = true;
         lastBullishSignalTime = time[i];
      }
      else
      {
         bearishSwingSignalUsed = true;
         lastBearishSignalTime = time[i];
      }

      if(i == 1)
      {
         currentBarEntrySignal = true;
         currentBarEntryDirection = direction;
         currentBarEntryName = patternName;
         currentBarEntryPatternIndex = patternIndex;
      }

      // C3/C13 : le stop vient de FindConfirmedSignal, déjà calculé avant le
      // tracé de la flèche. Plus de second appel à CalculateStopPrice.
      double stopPrice = signalStopPrice;
      double entry1 = close[i];
      double entry1Risk = stopPrice == EMPTY_VALUE
                          ? EMPTY_VALUE : EstimateLoss(entry1, stopPrice, direction);

      int maxAge = EffectiveMaxSignalAgeBars();
      bool trackCandidate = time[i] == ActiveSignalTime && direction == ActiveSignalDirection;
      bool initializeCandidate = !PositionStateInitialized
                                 && (maxAge <= 0 || i - 1 <= maxAge);
      if(trackCandidate || initializeCandidate)
      {
         double candidateAdr = EMPTY_VALUE;
         AdrAtSignal(time[i - 1], candidateAdr);
         string candidateStatus = SignalStatus(i, direction, entry1, stopPrice,
                                               candidateAdr, high, low);
         if(trackCandidate)
         {
            trackedSignalFound = true;
            trackedSignalActive = SignalIsActive(candidateStatus);
         }
         if(initializeCandidate && SignalIsActive(candidateStatus)
            && !HasOppositeExit(i, direction, rates_total, time, open, high, low, close))
         {
            latestActiveTime = time[i];
            latestActiveDirection = direction;
         }
      }

      latestSignalIndex = i;
      LatestSignalTime = time[i];
      LatestEntry1Price = entry1;
      LatestEntry1Risk = entry1Risk;
      LatestSignalDirection = direction;
      LatestSignalName = patternName;
      LatestStopPrice = stopPrice;
   }

   int displayedIndex = DisplayedSignalIndex(latestSignalIndex, previousShift, oldestSignalIndex);
   if(displayedIndex != latestSignalIndex)
   {
      latestSignalIndex = displayedIndex;
      LatestSignalTime = previousTime;
      LatestSignalDirection = previousDirection;
      LatestSignalName = previousName;
      LatestEntry1Price = previousEntry;
      LatestEntry1Risk = previousRisk;
      LatestStopPrice = previousStop;
   }
   if(latestSignalIndex >= 1)
   {
      ENUM_INDICATOR_READ adrRead = AdrAtSignal(time[latestSignalIndex - 1], LatestSignalAdr);
      if(adrRead == INDICATOR_READ_PENDING)
         ReportDataIssue("ADR du dernier signal");
      LatestSignalStatus = SignalStatus(latestSignalIndex, LatestSignalDirection,
                                        LatestEntry1Price, LatestStopPrice,
                                        LatestSignalAdr, high, low);
      if(SignalIsActive(LatestSignalStatus)
         && HasOppositeExit(latestSignalIndex, LatestSignalDirection, rates_total,
                            time, open, high, low, close))
         LatestSignalStatus = "SORTIE CONTRAIRE";
      if(previousShift > oldestSignalIndex && ActiveSignalTime == LatestSignalTime
         && ActiveSignalDirection == LatestSignalDirection)
      {
         trackedSignalFound = true;
         trackedSignalActive = SignalIsActive(LatestSignalStatus);
      }
   }

   if(fullRecalculation)
      PrintFormat("SilentWolf : patterns=%d acceptes=%d doublons=%d non classes=%d swing=%d zone=%d confirmation=%d stop=%d geometrie=%d donnees=%d range=%d",
                  FoundPatternCount, AcceptedSignalCount, DuplicateSignalCount,
                  UnclassifiedRejectionCount, RejectedByReason[REJECT_SWING],
                  RejectedByReason[REJECT_ZONE], RejectedByReason[REJECT_CONFIRMATION],
                  RejectedByReason[REJECT_STOP], RejectedByReason[REJECT_GEOMETRY],
                  RejectedByReason[REJECT_DATA], RejectedByReason[REJECT_RANGE]);

   if(ActiveSignalDirection != 0 && (!trackedSignalFound || !trackedSignalActive))
   {
      ActiveSignalDirection = 0;
      ActiveSignalTime = 0;
   }

   if(!PositionStateInitialized)
   {
      ActiveSignalDirection = latestActiveDirection;
      ActiveSignalTime = latestActiveTime;
      PositionStateInitialized = true;
   }

   SwRefreshInfo();
   UpdateSignalTable();

   // C8 : PendingNewBarAlert est consommé ici, après un recalcul complet.
   PendingNewBarAlert = false;
   int confirmationIndex = 1;

   // P3 (a) étendu à la SORTIE : l'évaluation de sortie n'est plus
   // conditionnée par PendingNewBarAlert mais par la barre de confirmation
   // déjà traitée. L'évaluation est idempotente.
   if(LastExitAlertBarTime != time[confirmationIndex])
   {
      int direction, patternIndex, patternLength;
      string patternName;
      double alertStopPrice;

      // P1 : recherche de SORTIE -> requireZone = false ET
      // applyStopCheck = false. A6 : inside bar admise selon
      // InpEnableInsideBar && InpInsideBarUseForExit. F1 : la direction de
      // l'inside bar est résolue par le même correctif dans
      // FindConfirmedSignal, donc le chemin de SORTIE est cohérent.
      bool confirmedPattern = FindConfirmedSignal(confirmationIndex, rates_total,
                                                   time, open, high, low, close,
                                                   false, false,
                                                   AllowInsideBarForSearch(true),
                                                   direction, patternIndex,
                                                   patternLength, patternName,
                                                   alertStopPrice);
      if(confirmedPattern && ActiveSignalDirection != 0
         && direction != ActiveSignalDirection)
      {
         // P3 : une seule alerte de SORTIE par barre de confirmation.
         LastExitAlertBarTime = time[confirmationIndex];
         string exitSide = ActiveSignalDirection > 0 ? "achat" : "vente";
         // A7 : nom affiché (libellé dirigé pour l'inside bar).
         string exitPatternLabel = SignalDisplayName(patternName, direction);
         string message = StringFormat("SORTIE %s: signal contraire %s sur %s (%s), entrée suivie depuis %s",
                                       exitSide, exitPatternLabel, _Symbol,
                                       EnumToString((ENUM_TIMEFRAMES)_Period),
                                       TimeToString(ActiveSignalTime, TIME_DATE | TIME_MINUTES));
         RaiseAlert(message);
         ActiveSignalDirection = 0;
         ActiveSignalTime = 0;
      }
   }

   // P3 (a) + C-R1 : l'alerte d'ENTRÉE est émise uniquement si la barre de
   // confirmation courante est ARMÉE. Le marquage EntryAlertArmedBarTime
   // n'est posé qu'à l'ouverture d'une barre ; les recalculs en cours de
   // barre ne peuvent donc que rattraper une alerte armée non consommée
   // (données manquantes à l'ouverture), jamais en émettre une nouvelle pour
   // la même barre fermée. Une fois la passe achevée avec des données
   // exploitables, le marqueur d'armement est consommé, ET
   // LastEntryAlertBarTime est posé : aucun doublon possible, ni par
   // recalcul complet ultérieur ni par relance.
   if(currentBarEntrySignal
      && EntryAlertArmedBarTime == time[confirmationIndex]
      && LastEntryAlertBarTime != time[confirmationIndex])
   {
      LastEntryAlertBarTime = time[confirmationIndex];
      // P3 : l'entrée de cette barre est traitée, la question de la sortie
      // de la même barre est réglée.
      LastExitAlertBarTime = time[confirmationIndex];
      EntryAlertArmedBarTime = 0;
      int direction = currentBarEntryDirection;
      string patternName = currentBarEntryName;
      // A7 : libellé dirigé pour l'inside bar dans le message d'alerte.
      string patternLabel = SignalDisplayName(patternName, direction);
      string side = direction > 0 ? "achat" : "vente";
      if(LatestSignalTime == time[confirmationIndex] && SignalIsActive(LatestSignalStatus))
      {
         ActiveSignalDirection = LatestSignalDirection;
         ActiveSignalTime = LatestSignalTime;
      }
      else
      {
         ActiveSignalDirection = 0;
         ActiveSignalTime = 0;
      }
      double rsi7 = EMPTY_VALUE, rsi14 = EMPTY_VALUE;
      SwRead(SwRsi7[0], currentBarEntryPatternIndex, rsi7);
      SwRead(SwRsi14[0], currentBarEntryPatternIndex, rsi14);
      bool strengthened = IsRsiStrengthened(direction, rsi7, rsi14);
      string rsiStatus = rsi7 == EMPTY_VALUE || rsi14 == EMPTY_VALUE
                         ? "qualité RSI indisponible"
                         : (strengthened ? "signal renforcé" : "signal standard");
      string rsi7Text = rsi7 == EMPTY_VALUE ? "n/d" : DoubleToString(rsi7, 1);
      string rsi14Text = rsi14 == EMPTY_VALUE ? "n/d" : DoubleToString(rsi14, 1);
      string message = StringFormat("ENTRÉE %s : %s confirmé sur %s (%s), RSI7=%s RSI14=%s, %s",
                                    side, patternLabel, _Symbol,
                                    EnumToString((ENUM_TIMEFRAMES)_Period),
                                    rsi7Text, rsi14Text, rsiStatus);
      RaiseAlert(message);
   }

   if(latestSignalIndex >= 1)
   {
      if(LatestSignalDirection > 0)
         BullishBuffer[latestSignalIndex] = low[latestSignalIndex] - InpArrowOffsetPoints * _Point;
      else
         BearishBuffer[latestSignalIndex] = high[latestSignalIndex] + InpArrowOffsetPoints * _Point;
   }

   // C-R1 : consommation de l'armement quand la passe s'achève sans alerte
   // émise (pas de signal, ou signal déjà alerté). IndicatorDataPending est
   // faux quand toutes les données sont exploitables ; s'il reste vrai,
   // l'armement persiste et la relance au tick suivant pourra émettre
   // l'alerte en rattrapage.
   if(EntryAlertArmedBarTime == time[confirmationIndex] && !IndicatorDataPending)
      EntryAlertArmedBarTime = 0;

   // C10 : une donnée d'indicateur manquante déclenche une nouvelle tentative
   // au tick suivant, bornée à MaxDataRetries pour éviter une boucle infinie
   // de recalculs complets.
   if(IndicatorDataPending)
   {
      if(DataRetryCount < MaxDataRetries)
      {
         ++DataRetryCount;
         SignalsDirty = true;
      }
      else if(DataRetryCount == MaxDataRetries)
      {
         ++DataRetryCount;
         Print("Abandon des nouvelles tentatives apres ", MaxDataRetries,
               " essais : donnees RSI/ATR toujours indisponibles.");
      }
   }
   else
      DataRetryCount = 0;

   return rates_total;
}

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   DrawingChartEvent(id, lparam, dparam, sparam);
   if(id == CHARTEVENT_OBJECT_DRAG && sparam == TableHandleName)
   {
      TableX = (int)ObjectGetInteger(0, TableHandleName, OBJPROP_XDISTANCE);
      TableY = (int)ObjectGetInteger(0, TableHandleName, OBJPROP_YDISTANCE);

      long chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      long chartHeight = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      int maxX = (int)chartWidth - TableTotalWidth();
      int maxY = (int)chartHeight - TableTotalHeight();
      if(maxX < 0) maxX = 0;
      if(maxY < 0) maxY = 0;
      if(TableX < 0) TableX = 0;
      if(TableY < 0) TableY = 0;
      if(TableX > maxX) TableX = maxX;
      if(TableY > maxY) TableY = maxY;

      ObjectSetInteger(0, TableHandleName, OBJPROP_SELECTED, false);
      TablePositionCustomized = true;
      if(GlobalVariableSet(TablePositionKey("x"), TableX) == 0
         || GlobalVariableSet(TablePositionKey("y"), TableY) == 0)
         Print("Impossible d'enregistrer la position du panneau. Erreur: ", GetLastError());
      UpdateSignalTable();
      return;
   }

   if(id == CHARTEVENT_CHART_CHANGE)
   {
      long chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      long chartHeight = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
      int maxX = (int)chartWidth - TableTotalWidth() - 12;
      int maxY = (int)chartHeight - TableTotalHeight() - 12;
      if(maxX < 0) maxX = 0;
      if(maxY < 0) maxY = 0;
      if(TablePositionCustomized)
      {
         if(TableX > maxX) TableX = maxX;
         if(TableY > maxY) TableY = maxY;
      }
      else
      {
         TableX = maxX;
         TableY = maxY;
      }
      // B4 : le rendu réapplique l'auto-compaction (TableSectionCount lit
      // CHART_HEIGHT_IN_PIXELS à chaque appel).
      UpdateSignalTable();
      return;
   }

   if(id == CHARTEVENT_OBJECT_CREATE || id == CHARTEVENT_OBJECT_DELETE
      || id == CHARTEVENT_OBJECT_CHANGE || id == CHARTEVENT_OBJECT_DRAG)
   {
      // Seuls les préfixes des zones directionnelles déclenchent un recalcul.
      //
      // P7 : cas du renommage manuel. NON CONFIRMÉ par la documentation
      // officielle. La page « OnChartEvent - Event Handling - MQL5 Reference »
      // (https://www.mql5.com/en/docs/event_handlers/onchartevent, consultée
      // le 2026-11-12) indique seulement que sparam porte le nom de l'objet
      // créé, modifié ou supprimé ; elle ne dit rien du renommage. Le MQL5
      // Book, source secondaire, affirme : « When renaming an object manually
      // (from the properties dialog), the terminal generates a sequence of
      // events CHARTEVENT_OBJECT_DELETE, CHARTEVENT_OBJECT_CREATE,
      // CHARTEVENT_OBJECT_CHANGE » (« Graphical object events »,
      // https://www.mql5.com/en/book/applications/events/events_objects). Si
      // cette séquence est exacte, un renommage vers OU depuis le préfixe
      // produit au moins un événement ; mais AUCUNE source consultée ne
      // précise si chaque événement porte l'ancien ou le nouveau nom. Le
      // filtre ci-dessous ne peut donc pas être déclaré exhaustif : un
      // renommage dont tous les événements porteraient un nom hors préfixe ne
      // serait rafraîchi qu'au prochain recalcul complet. sparam vide est
      // traité comme inconnu, donc conservateur.
      if(StringFind(sparam, "PatternFusionPinBar") == 0)
         return;
      if(sparam == "" || StringFind(sparam, InpBullishZonePrefix) == 0
         || StringFind(sparam, InpBearishZonePrefix) == 0)
         SignalsDirty = true;
   }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SwReleaseHandles();
   DrawingDeinit();
   // P5 : on ne restaure QUE ce que cet indicateur a lui-même forcé dans
   // OnInit, et seulement si la propriété est encore vraie (si un autre
   // programme l'a déjà remise à false, il n'y a rien à défaire).
   //
   // Choix de conception : la restauration a lieu pour TOUS les codes de
   // `reason`, y compris les ré-initialisations (REASON_RECOMPILE = 2,
   // REASON_CHARTCHANGE = 3, REASON_PARAMETERS = 5, REASON_TEMPLATE = 7).
   // Justification : « OnDeinit - Event Handling - MQL5 Reference »
   // (https://www.mql5.com/en/docs/event_handlers/ondeinit, consultée le
   // 2026-11-12) indique que l'événement Deinit précède « a re-initialization
   // due to the change of a symbol or a chart period » et le changement des
   // entrées ; le programme est donc déchargé et ses variables globales
   // perdues. Ne pas restaurer dans ces cas ferait perdre la mémoire de
   // l'état d'origine : la propriété resterait forcée à true indéfiniment si
   // le rechargement échoue (OnInit renvoyant INIT_PARAMETERS_INCORRECT, par
   // exemple). La même page ne dit rien d'une restauration automatique des
   // propriétés du graphique par le terminal, et aucune page officielle
   // consultée ne documente une telle restauration : point NON VÉRIFIÉ,
   // d'où le choix prudent de restaurer nous-mêmes. Conséquence sur un
   // changement d'unité de temps : la propriété est remise à false puis
   // forcée par le nouvel OnInit ; les commandes de propriétés de graphique
   // étant placées dans la file d'attente du graphique (« Chart Operations -
   // MQL5 Reference », https://www.mql5.com/en/docs/chart_operations), l'ordre
   // est préservé et la valeur finale est correcte. Les codes de `reason`
   // sont répertoriés dans « Uninitialization Reason Codes - Named Constants -
   // MQL5 Reference » (https://www.mql5.com/en/docs/constants/namedconstants/
   // uninit, consultée le 2026-11-12).
   if(ChartEventCreateForced
      && ChartGetInteger(0, CHART_EVENT_OBJECT_CREATE) != 0)
      ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, false);
   if(ChartEventDeleteForced
      && ChartGetInteger(0, CHART_EVENT_OBJECT_DELETE) != 0)
      ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, false);
   ChartEventCreateForced = false;
   ChartEventDeleteForced = false;

   if(AtrHandle != INVALID_HANDLE)
      IndicatorRelease(AtrHandle);

   // P6 : nettoyage par DeleteTableObjects, qui balaye les bornes maximales
   // et supprime aussi cadre, poignée et titre. Une boucle utilisant
   // TableColumnCount(section) vaudrait 0 pour une section masquée : avec
   // le panneau réduit à une section, les cellules de la section PRÉCÉDENT
   // auraient survécu au retrait de l'indicateur.
   DeleteTableObjects();

   for(int row = 0; row < 3; ++row)
      for(int column = 0; column < 10; ++column)
      {
         string cellName = TableCellPrefix + IntegerToString(row) + "_"
            + IntegerToString(column);
         ObjectDelete(0, cellName + "_bg");
         ObjectDelete(0, cellName + "_text");

         string oldCellName = "PatternFusionPinBarCell" + IntegerToString(row)
            + "_" + IntegerToString(column);
         ObjectDelete(0, oldCellName + "_bg");
         ObjectDelete(0, oldCellName + "_text");
      }
   for(int row = 0; row < 3; ++row)
      for(int column = 0; column < 7; ++column)
      {
         string oldCellName = "PatternFusionPinBarCellV2" + IntegerToString(row)
            + "_" + IntegerToString(column);
         ObjectDelete(0, oldCellName + "_bg");
         ObjectDelete(0, oldCellName + "_text");
      }

   ObjectDelete(0, "PatternFusionPinBarTableBackground");
   ObjectDelete(0, "PatternFusionPinBarTableHeader");
   ObjectDelete(0, "PatternFusionPinBarTableLatest");
   ObjectDelete(0, "PatternFusionPinBarTablePrevious");
}

input group "Couleurs des rectangles"
input color Rectangle1Color = clrDodgerBlue;     // Rectangle haussier
input color Rectangle3Color = clrMediumSeaGreen; // Rectangle baissier

input group "Couleurs des lignes de tendance"
input color Trendline1Color = clrDeepSkyBlue; // Ligne haussiere
input color Trendline3Color = clrLimeGreen;   // Ligne baissiere

input group "Aimant des rectangles et lignes"
input int MagnetDistancePixels = 12; // 0 desactive l'aimant

#define PREFIX "MT5_DRAWING_TOOLS_"
#define BUTTON_WIDTH 120
#define BUTTON_HEIGHT 25
#define BUTTON_GAP 8
#define TOOL_COUNT 4
#define PANEL_X 12
#define PANEL_Y 34
#define BULL_ZONE ("Zone_Haussi" + ShortToString(232) + "re_")
#define BEAR_ZONE ("Zone_Baissi" + ShortToString(232) + "re_")
#define BULL_LINE ("Ligne_Haussi" + ShortToString(232) + "re_")
#define BEAR_LINE ("Ligne_Baissi" + ShortToString(232) + "re_")

enum DrawingTool
{
   TOOL_NONE = -1,
   TOOL_RECTANGLE_BULL,
   TOOL_RECTANGLE_BEAR,
   TOOL_TRENDLINE_BULL,
   TOOL_TRENDLINE_BEAR
};

DrawingTool active_tool = TOOL_NONE;
bool waiting_for_second_point = false;
datetime first_time;
double first_price;
uint object_counter = 0;

int DrawingInit()
{
   if(MagnetDistancePixels < 0 || MagnetDistancePixels > 200)
   {
      Print("La distance de l'aimant doit etre comprise entre 0 et 200 pixels.");
      return INIT_PARAMETERS_INCORRECT;
   }
   for(int i = 0; i < TOOL_COUNT; i++)
   {
      if(!CreateToolButton(i))
      {
         Print("Impossible de creer le bouton de dessin ", i + 1, " : erreur ", GetLastError());
         DrawingDeinit();
         return INIT_FAILED;
      }
   }

   ChartRedraw(0);
   return INIT_SUCCEEDED;
}

void DrawingDeinit()
{
   for(int i = 0; i < TOOL_COUNT; i++)
      ObjectDelete(0, ButtonName(i));
   ChartRedraw(0);
}

void DrawingChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_DRAG)
   {
      if(MagnetDistancePixels > 0)
      {
         ENUM_OBJECT type = (ENUM_OBJECT)ObjectGetInteger(0, sparam, OBJPROP_TYPE);
         if(((StringFind(sparam, InpBullishZonePrefix) == 0 ||
              StringFind(sparam, InpBearishZonePrefix) == 0 ||
              StringFind(sparam, "ZONE_") == 0 ||
              StringFind(sparam, BULL_ZONE) == 0 ||
              StringFind(sparam, BEAR_ZONE) == 0 ||
              StringFind(sparam, "Zone_Haussi" + ShortToString(232) + "e_") == 0 ||
              StringFind(sparam, "Zone_Baissi" + ShortToString(232) + "e_") == 0) && type == OBJ_RECTANGLE) ||
            ((StringFind(sparam, BULL_LINE) == 0 ||
              StringFind(sparam, BEAR_LINE) == 0 ||
              StringFind(sparam, "Ligne_Haussi" + ShortToString(232) + "e_") == 0 ||
              StringFind(sparam, "Ligne_Baissi" + ShortToString(232) + "e_") == 0) && type == OBJ_TREND) ||
            (StringFind(sparam, PREFIX + "SHAPE_") == 0 &&
             (type == OBJ_RECTANGLE || type == OBJ_TREND)))
            SnapObject(sparam);
      }
      return;
   }

   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      int tool = ToolFromButton(sparam);
      if(tool >= 0)
      {
         active_tool = (active_tool == (DrawingTool)tool) ? TOOL_NONE : (DrawingTool)tool;
         waiting_for_second_point = false;
         UpdateButtonStates();
      }
      return;
   }

   if(id == CHARTEVENT_CLICK && active_tool != TOOL_NONE)
   {
      // The button click also generates a chart click.
      int chartWidth = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
      int panelLeft = chartWidth - PANEL_X - 2 * BUTTON_WIDTH - BUTTON_GAP;
      if(lparam >= panelLeft && lparam < chartWidth - PANEL_X &&
         dparam >= PANEL_Y && dparam < PANEL_Y + 2 * BUTTON_HEIGHT + BUTTON_GAP)
      {
         int y_offset = (int)dparam - PANEL_Y;
         int x_offset = (int)lparam - panelLeft;
         if(y_offset % (BUTTON_HEIGHT + BUTTON_GAP) < BUTTON_HEIGHT &&
            x_offset % (BUTTON_WIDTH + BUTTON_GAP) < BUTTON_WIDTH)
            return;
      }
      if(InpShowTable && ObjectFind(0, TablePanelName) >= 0 &&
         lparam >= TableX && lparam < TableX + TableTotalWidth() &&
         dparam >= TableY && dparam < TableY + TableTotalHeight())
         return;
      int sub_window;
      datetime clicked_time;
      double clicked_price;
      if(!ChartXYToTimePrice(0, (int)lparam, (int)dparam,
                             sub_window, clicked_time, clicked_price) || sub_window != 0)
         return;

      SnapPoint((int)lparam, (int)dparam, clicked_time, clicked_price);

      if(!waiting_for_second_point)
      {
         first_time = clicked_time;
         first_price = clicked_price;
         waiting_for_second_point = true;
         UpdateButtonStates();
         return;
      }

      if(DrawSelectedTool(clicked_time, clicked_price))
      {
         waiting_for_second_point = false;
         active_tool = TOOL_NONE;
         UpdateButtonStates();
      }
   }
}

bool SnapPoint(const int x, const int y, datetime &point_time, double &point_price)
{
   if(MagnetDistancePixels == 0)
      return false;

   int width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS, 0);
   if(width <= 0 || x < 0 || x >= width)
      return false;

   int left_x = (int)MathMax(0, x - MagnetDistancePixels);
   int right_x = (int)MathMin(width - 1, x + MagnetDistancePixels);
   int window;
   datetime left_time, right_time;
   double unused_price;
   if(!ChartXYToTimePrice(0, left_x, y, window, left_time, unused_price) || window != 0 ||
      !ChartXYToTimePrice(0, right_x, y, window, right_time, unused_price) || window != 0)
      return false;

   int bars = Bars(_Symbol, _Period);
   if(bars <= 0)
   {
      Print("Aimant indisponible : historique des bougies non charge.");
      return false;
   }
   int left_shift = iBarShift(_Symbol, _Period, left_time, false);
   int right_shift = iBarShift(_Symbol, _Period, right_time, false);
   // A screen edge can lie before the oldest available candle.
   if(left_shift < 0) left_shift = bars - 1;
   if(right_shift < 0) right_shift = bars - 1;
   int start = (int)MathMax(0, MathMin(left_shift, right_shift) - 1);
   int end = (int)MathMin(bars - 1, MathMax(left_shift, right_shift) + 1);

   MqlRates rates[];
   ResetLastError();
   int copied = CopyRates(_Symbol, _Period, start, end - start + 1, rates);
   if(copied <= 0)
   {
      Print("Aimant indisponible : lecture des bougies impossible, erreur ", GetLastError());
      return false;
   }

   long best_distance = (long)MagnetDistancePixels * MagnetDistancePixels + 1;
   bool found = false;
   for(int i = 0; i < copied; i++)
   {
      for(int extreme = 0; extreme < 2; extreme++)
      {
         double price = extreme == 0 ? rates[i].high : rates[i].low;
         int candle_x, candle_y;
         if(!ChartTimePriceToXY(0, 0, rates[i].time, price, candle_x, candle_y))
            continue;
         long dx = (long)candle_x - x;
         long dy = (long)candle_y - y;
         long distance = dx * dx + dy * dy;
         if(distance < best_distance)
         {
            best_distance = distance;
            point_time = rates[i].time;
            point_price = price;
            found = true;
         }
      }
   }
   return found;
}

void SnapObject(const string name)
{
   bool changed = false;
   for(int point = 0; point < 2; point++)
   {
      datetime time = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, point);
      double price = ObjectGetDouble(0, name, OBJPROP_PRICE, point);
      int x, y;
      if(ChartTimePriceToXY(0, 0, time, price, x, y) &&
         SnapPoint(x, y, time, price))
      {
         if(!ObjectMove(0, name, point, time, price))
            Print("Impossible d'ajuster ", name, " : erreur ", GetLastError());
         else
            changed = true;
      }
   }
   if(changed)
   {
      if(StringFind(name, InpBullishZonePrefix) == 0 ||
         StringFind(name, InpBearishZonePrefix) == 0)
         SignalsDirty = true;
      ChartRedraw(0);
   }
}

bool CreateToolButton(const int index)
{
   string name = ButtonName(index);
   if(!ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
      return false;

   int row = index / 2;
   int column = index % 2;
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,
                    PANEL_X + BUTTON_WIDTH + (1 - column) * (BUTTON_WIDTH + BUTTON_GAP));
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,
                    PANEL_Y + row * (BUTTON_HEIGHT + BUTTON_GAP));
   ObjectSetInteger(0, name, OBJPROP_XSIZE, BUTTON_WIDTH);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, BUTTON_HEIGHT);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, ToolColor(index));
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, ToolLabel(index));
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   return true;
}

void UpdateButtonStates()
{
   for(int i = 0; i < TOOL_COUNT; i++)
   {
      ObjectSetInteger(0, ButtonName(i), OBJPROP_STATE, i == (int)active_tool);
      string text = ToolLabel(i);
      if(i == (int)active_tool)
         text = waiting_for_second_point ? "Point 2 : cliquez" : "Point 1 : cliquez";
      ObjectSetString(0, ButtonName(i), OBJPROP_TEXT, text);
   }
   ChartRedraw(0);
}

bool DrawSelectedTool(const datetime second_time, const double second_price)
{
   string name;
   do
   {
      object_counter++;
      name = ShapePrefix((int)active_tool) + IntegerToString((int)TimeLocal())
             + "_" + IntegerToString((int)object_counter);
   }
   while(ObjectFind(0, name) >= 0);

   color tool_color = ToolColor((int)active_tool);

   if(active_tool <= TOOL_RECTANGLE_BEAR)
   {
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                       first_time, first_price, second_time, second_price))
      {
         Alert("Impossible de creer le rectangle : erreur ", GetLastError());
         return false;
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, tool_color);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   else
   {
      if(!ObjectCreate(0, name, OBJ_TREND, 0,
                       first_time, first_price, second_time, second_price))
      {
         Alert("Impossible de creer la ligne : erreur ", GetLastError());
         return false;
      }
      ObjectSetInteger(0, name, OBJPROP_COLOR, tool_color);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }

   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
   if(active_tool <= TOOL_RECTANGLE_BEAR)
      SignalsDirty = true;
   return true;
}

int ToolFromButton(const string name)
{
   for(int i = 0; i < TOOL_COUNT; i++)
      if(name == ButtonName(i))
         return i;
   return -1;
}

string ButtonName(const int index)
{
   return PREFIX + "BUTTON_" + IntegerToString(index + 1);
}

string ToolLabel(const int index)
{
   string type = index < 2 ? "Rect. " : "Ligne ";
   return type + (index % 2 == 0 ? "hausse" : "baisse");
}

string ShapePrefix(const int index)
{
   bool bullish = index % 2 == 0;
   if(index < 2)
      return bullish ? InpBullishZonePrefix : InpBearishZonePrefix;
   return bullish ? BULL_LINE : BEAR_LINE;
}

color ToolColor(const int index)
{
   switch(index)
   {
      case 0: return Rectangle1Color;
      case 1: return Rectangle3Color;
      case 2: return Trendline1Color;
      case 3: return Trendline3Color;
   }
   return clrWhite;
}

void OnTimer()
{
   SwRefreshInfo();
   SwUpdateVwap();
   if(InpShowTable) UpdateSignalTable();
}
