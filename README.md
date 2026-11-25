# SILENT-WOLF

Indicateurs MetaTrader 5 de détection de figures de retournement, avec panneaux de confirmations et alertes.

## Indicateurs

- **silentwolfforex** — `MQL5\Indicators\Forex\silentwolfforex.mq5`. Inclut le tracé des sessions de marché (Asie, Francfort, Londres et New York).
- **silentwolfindices** — `MQL5\Indicators\SyntheticIndices\silentwolfindices.mq5`. N'inclut pas les sessions Forex.
- **SWRobots** — `MQL5\Experts\SWRobots.mq5`. EA d'exécution qui lit les signaux et prix exposés par l'indicateur SilentWolf du graphique.

Les indicateurs affichent des signaux et peuvent envoyer des alertes d'entrée uniquement, mais ne passent pas d'ordres. Une sortie opposée reste indiquée dans l'état du panneau sans déclencher d'alerte. SWRobots est un programme distinct qui utilise l'interface de buffers de l'indicateur.

## SWRobots

Attachez **un seul** indicateur SilentWolf (Forex ou SyntheticIndices) au graphique, puis SWRobots au même graphique. `InpMonitoredTimeframes` contient la liste des TF séparés par des virgules ou des barres obliques (par défaut `M5,M15,M30,H1,H4`). En mode `InpIndicatorSource=AUTO`, l'indicateur attaché sert à détecter la source Forex/Indices ; les instances créées pour les TF surveillés utilisent les paramètres par défaut de SilentWolf, et ne recopient pas les paramètres personnalisés de l'indicateur visuel. Si aucun indicateur n'est attaché, choisissez explicitement Forex ou indices pour charger la source par défaut. Les buffers utilisés sont : 0 achat, 1 vente, 2 entrée, 3 stop, 4 TP1, 5 TP2 et 6 force du signal en pourcentage.

Dans le testeur de stratégie MT5, sélectionnez obligatoirement `SW_SOURCE_FOREX` pour `silentwolfforex` ou `SW_SOURCE_INDICES` pour `silentwolfindices` dans `InpIndicatorSource`. Le mode automatique est réservé au graphique normal et ne démarre pas le test.

SWRobots recherche les indicateurs compilés dans `MQL5\Indicators\Silent Wolf Trading\silentwolfforex.ex5` et `MQL5\Indicators\Silent Wolf Trading\silentwolfindices.ex5`. Copiez les fichiers `.mq5` actuels dans ce dossier du terminal et compilez-les dans MetaEditor ; recompilez également SWRobots. L'indicateur et le robot doivent provenir de la même version, notamment pour le paramètre interne `InpInternalBufferOnly`.

`InpInternalBufferOnly` est réservé aux instances internes de SWRobots : laissez-le désactivé pour l'indicateur affiché, afin de conserver les outils et alertes. Les appels `iCustom` externes qui fournissent des paramètres positionnels doivent aussi ajouter ce booléen en première position.

La correspondance entre les instances multi-TF du robot et les signaux de l'indicateur affiché, notamment pour les zones dessinées sur le graphique et les paramètres personnalisés, n'est pas encore garantie. Les alertes de l'indicateur restent limitées au TF de son graphique.

SWRobots traite les signaux de chaque TF surveillé à la clôture, filtre ceux sous `InpMinimumSignalForce` (55 % par défaut), calcule le volume pour risquer `InpRiskPercent` de l'equity au stop (10 % par défaut, hors frais et glissement), et place un ordre limite au prix d'entrée signalé, expirant à la fin de la journée broker. Il ne maintient qu'un ordre ou une position SWRobots par symbole pour éviter les entrées simultanées issues de plusieurs TF. Avec deux objectifs, il clôture 50 % à TP1 et laisse le solde jusqu'à TP2 ; avec un seul objectif, il clôture toute la position à TP1. Il passe le stop au break-even à 1R. Il suspend les nouvelles entrées après 3 SL dans la journée ou 5 dans la semaine du serveur broker ; les sorties au break-even ne sont pas comptées. Ces limites s'agrègent par numéro magique : conservez le même `InpMagicNumber` sur les graphiques pour partager une pause. Les positions ne sont pas fermées automatiquement en fin de journée.

Un ordre déjà accepté par le serveur peut s'exécuter pendant une déconnexion et reste actif jusqu'à son expiration. Le stop initial et TP2 sont envoyés au serveur ; la gestion de TP1 et le déplacement au break-even nécessitent que le terminal et l'EA fonctionnent. En compte netting, une position déjà ouverte sur le symbole empêche une nouvelle entrée sur ce symbole.

## Signal

Les signaux sont calculés uniquement sur M5, M15, M30, H1 et H4. Chaque indicateur affiche au maximum une flèche et un panneau pour le dernier signal confirmé sur le symbole et l'unité de temps du graphique. Il reste affiché jusqu'au prochain signal, même s'il n'est plus actif ; la ligne **ETAT** indique notamment son expiration, le stop, l'objectif final ou une sortie opposée. TP1 et TP2 utilisent les deux niveaux les plus proches situés à au moins 2R dans le sens du signal, parmi l'Open de la période et la clôture de la période précédente en D1, W1 et MN. Si un seul niveau convient, TP1 est l'objectif final et TP2 reste `n/d` ; si aucun ne convient, TP1 est calculé à 2R, arrondi au tick dans le sens du signal. Le calcul exige les données des trois périodes. Les niveaux sont déterminés à la confirmation ; le suivi du stop et des objectifs inclut la bougie en cours. Le ratio 2R est calculé sur la distance entre l'entrée et le stop, hors frais et spread.

Les patterns reconnus à une ou deux bougies et les fusions libres sont recherchés automatiquement en entrée, sans option d'activation. Si un pattern reconnu à deux bougies échoue, une pin bar simple est aussi recherchée, sauf pour une inside bar ; la fusion libre est réservée aux cas sans pattern reconnu. Les inside bars sont vérifiées automatiquement en entrée : leur fusion doit former une pin bar et satisfaire les filtres de validation habituels, dont `InpInsideBarMaxRatio`. Elles ne déclenchent pas de sortie, même si elles correspondent aussi à un autre pattern.

Au chargement ou après une modification de zone, les signaux sont recalculés sur l'historique disponible et les zones actuelles. Entre ces recalculs, `InpMaxBarsToScan` limite le nombre de bougies rescannées ; le dernier signal déjà trouvé reste affiché même lorsqu'il sort de cette plage, tant que sa bougie reste disponible dans l'historique.

**FORCE DU SIGNAL** additionne trois composantes à la confirmation : 40 % pour le setup confirmé ; jusqu'à 30 % pour le RSI, avec 15 % par RSI 7/14 en survente pour un achat ou en surachat pour une vente (seuils configurables, 20/80 par défaut) ; et jusqu'à 30 % pour les divergences, avec 30 % si RSI 7 et 14 vont tous deux dans le sens du signal, sinon 15 % pour les cas connus (mixte, contraire ou aucune divergence). Des données de divergence absentes ou partielles donnent 0 % pour cette composante ; un RSI absent ne rapporte pas son propre bonus.

## Tendance

**TENDANCE EMA** est informative et indépendante du signal, y compris en mensuel. Elle compare les EMA 50, 100 et 200 sur la dernière bougie clôturée du TF affiché : haussière si EMA 50 > EMA 100 > EMA 200, baissière dans l'ordre inverse, et indécise sinon. Les données insuffisantes sont indiquées par `n/d`.

Les rectangles de sessions Forex utilisent l'historique M5, y compris sur les graphiques d'unités supérieures ; ils nécessitent que cet historique soit disponible.

Les anciennes rubriques Actions, Sweep du jour et Taux de réussite ainsi que le suivi statistique associé ont été retirés. Les fichiers statistiques déjà présents dans le dossier de données MT5 ne sont pas supprimés.

## Installation

1. Dans MetaTrader 5, choisissez **Fichier > Ouvrir le dossier des données**.
2. Copiez le fichier correspondant à votre marché dans `MQL5\Indicators` (vous pouvez conserver les sous-dossiers `Forex` et `SyntheticIndices`).
3. Ouvrez le fichier `.mq5` dans MetaEditor et compilez-le.
4. Dans le Navigateur de MT5, actualisez **Indicateurs** puis ajoutez l'indicateur au graphique.

Les notifications push sont activées par défaut pour les nouvelles instances (`InpEnablePush=true`) ; vérifiez aussi ce paramètre sur les instances déjà installées. Sur le téléphone, installez MT5 et trouvez votre **MetaQuotes ID** dans les paramètres Messages. Sur MT5 ordinateur, ouvrez **Outils > Options > Notifications**, activez les notifications, renseignez cet ID et utilisez le bouton **Test**. Le terminal doit rester connecté et l'indicateur chargé ; les anciens signaux ne déclenchent pas de notification au chargement. Les erreurs d'envoi et une configuration désactivée sont signalées dans le journal Experts. Les notifications ne fonctionnent pas dans le testeur de stratégie MT5. Un succès d'envoi depuis le terminal ne garantit pas la réception sur le téléphone.

Configurez aussi, pour le Forex, le décalage GMT du serveur du broker dans les paramètres de l'indicateur. Testez les signaux sur un compte démo avant toute utilisation en conditions réelles.

## Vérification

Avec Node.js, `node tests\indicator-logic.test.js`, `node tests\pattern-selection.test.js` et `node tests\alerts.test.js` vérifient des cas de signal, de sélection de pattern et d'alerte communs aux deux indicateurs. Ces tests ne remplacent ni la compilation dans MetaEditor ni la vérification sur un graphique MT5.
