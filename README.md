# SILENT-WOLF

Indicateurs MetaTrader 5 de détection de figures de retournement, avec panneaux de confirmations et alertes.

## Indicateurs

- **silentwolfforex** — `MQL5\Indicators\Forex\silentwolfforex.mq5`. Inclut le tracé des sessions de marché (Asie, Francfort, Londres et New York).
- **silentwolfindices** — `MQL5\Indicators\SyntheticIndices\silentwolfindices.mq5`. N'inclut pas les sessions Forex.

Les deux fichiers sont des indicateurs personnalisés MT5, pas des Expert Advisors : ils affichent des signaux et peuvent envoyer des alertes, mais ne passent pas d'ordres.

## Signal et interprétation

Chaque indicateur affiche au maximum une flèche et un panneau pour le dernier signal confirmé sur le symbole et l'unité de temps du graphique. Il reste affiché jusqu'au prochain signal, même s'il n'est plus actif ; la ligne **ETAT** indique notamment son expiration, le stop, TP2 ou une sortie opposée. TP1 seul ne termine pas le signal. Le suivi du stop et des objectifs inclut la bougie en cours ; si l'ADR nécessaire aux objectifs est indisponible, ceux-ci ne peuvent pas être vérifiés.

Au chargement ou après une modification de zone, les signaux sont recalculés sur l'historique disponible et les zones actuelles. Entre ces recalculs, `InpMaxBarsToScan` limite le nombre de bougies rescannées ; le dernier signal déjà trouvé reste affiché même lorsqu'il sort de cette plage, tant que sa bougie reste disponible dans l'historique.

La rubrique **INTERPRETATION** compare le sens du signal aux divergences RSI 7 et 14 à la confirmation : concordante si elles vont dans le sens du signal, opposée si elles vont dans le sens contraire, mixte si les deux sens sont présents, aucune s'il n'y a pas de divergence, et `n/d` si les données nécessaires manquent. Un résultat marqué `partiel` repose sur des données incomplètes ; il ne signifie pas que l'autre sens est absent.

## Tendance et VWAP

**TENDANCE EMA** est informative et indépendante du signal. Elle compare les EMA 50, 100 et 200 sur la dernière bougie clôturée du TF affiché : haussière si EMA 50 > EMA 100 > EMA 200, baissière dans l'ordre inverse, et indécise sinon. Les données insuffisantes sont indiquées par `n/d`.

Le **VWAP** est un indicateur de contexte, sans effet sur la sélection des signaux ou des alertes. Il est calculé avec le prix moyen de chaque bougie `(haut + bas + clôture) / 3`, pondéré par son **volume de ticks**, bougie courante comprise. Il s'agit d'une approximation à partir des bougies, pas d'un volume exécuté ni d'un carnet d'ordres.

Sur M5, M15 et M30, le calcul repart à minuit chaque jour ; sur H1 et H4, il repart le lundi à minuit. Ces limites utilisent l'heure du serveur du courtier et la période de la bougie courante : en l'absence de nouvelles bougies, la dernière période reste affichée. Les lignes VWAP sont masquées sur les autres TF.

Le panneau indique la valeur, l'orientation par comparaison au VWAP calculé sans la bougie courante, et la distance signée `(clôture courante - VWAP) / ATR` ; l'ATR utilise la dernière bougie clôturée et `InpAtrPeriod` (14 par défaut). Le contexte est **aligné** pour un achat si le prix est au-dessus et le VWAP monte, ou pour une vente si le prix est au-dessous et le VWAP descend. Il compare le contexte actuel au dernier signal affiché, même si celui-ci a expiré. Les valeurs sont mises à jour par le timer toutes les cinq secondes ; une orientation exige au moins une bougie précédente avec du volume dans la même période. `n/d` indique des données insuffisantes ou indisponibles. L'auto-compaction peut masquer des lignes si le graphique est trop petit.

Les anciennes rubriques Actions, Sweep du jour et Taux de réussite ainsi que le suivi statistique associé ont été retirés. Les fichiers statistiques déjà présents dans le dossier de données MT5 ne sont pas supprimés.

## Installation

1. Dans MetaTrader 5, choisissez **Fichier > Ouvrir le dossier des données**.
2. Copiez le fichier correspondant à votre marché dans `MQL5\Indicators` (vous pouvez conserver les sous-dossiers `Forex` et `SyntheticIndices`).
3. Ouvrez le fichier `.mq5` dans MetaEditor et compilez-le.
4. Dans le Navigateur de MT5, actualisez **Indicateurs** puis ajoutez l'indicateur au graphique.

Les notifications push sont activées par défaut pour les nouvelles instances (`InpEnablePush=true`) ; vérifiez aussi ce paramètre sur les instances déjà installées. Sur le téléphone, installez MT5 et trouvez votre **MetaQuotes ID** dans les paramètres Messages. Sur MT5 ordinateur, ouvrez **Outils > Options > Notifications**, activez les notifications, renseignez cet ID et utilisez le bouton **Test**. Le terminal doit rester connecté et l'indicateur chargé ; les anciens signaux ne déclenchent pas de notification au chargement. Les erreurs d'envoi et une configuration désactivée sont signalées dans le journal Experts. Les notifications ne fonctionnent pas dans le testeur de stratégie MT5. Un succès d'envoi depuis le terminal ne garantit pas la réception sur le téléphone.

Configurez aussi, pour le Forex, le décalage GMT du serveur du broker dans les paramètres de l'indicateur. Testez les signaux sur un compte démo avant toute utilisation en conditions réelles.

## Vérification

Avec Node.js, `node tests\indicator-logic.test.js` et `node tests\vwap.test.js` vérifient les cas de signal, de tendance et de VWAP communs aux deux indicateurs. Ces tests ne remplacent ni la compilation dans MetaEditor ni la vérification sur un graphique MT5.
