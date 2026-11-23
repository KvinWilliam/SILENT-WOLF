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

## Tendance et volumes

**TENDANCE EMA** est informative et indépendante du signal. Elle compare les EMA 50, 100 et 200 sur la dernière bougie clôturée du TF affiché : haussière si EMA 50 > EMA 100 > EMA 200, baissière dans l'ordre inverse, et indécise sinon. Les données insuffisantes sont indiquées par `n/d`.

**VOLUMES** présente un profil des volumes exécutés par prix sur les 100 dernières bougies du TF, bougie courante incluse. Le nombre de bougies, les 50 gammes de prix et la zone de valeur à 70 % sont modifiables dans les paramètres. Le profil est actualisé par le timer, au plus une fois toutes les cinq secondes.

- **POC** : milieu de la gamme ayant le plus grand volume exécuté.
- **VAH / VAL** : limites haute et basse de la zone de valeur. À partir du POC, les gammes adjacentes les plus volumineuses sont ajoutées jusqu'à atteindre le pourcentage demandé ; à égalité, la gamme basse est choisie.

Ce profil utilise l'historique des transactions fourni par le courtier, pas les volumes de ticks ni le carnet d'ordres en attente. Il exige des ticks identifiés comme transactions avec leur prix et leur volume, et vérifie leur somme contre le volume réel de chaque bougie. Si ces données manquent, sont incomplètes ou changent pendant le calcul, il affiche `n/d` ; aucun volume de remplacement n'est inventé. Le calcul est limité à un million de ticks, y compris les cotations, par passe et à une seconde par tentative ; au-delà, la limite atteinte est indiquée. Cette limitation ou l'absence de volumes exécutés peut notamment concerner le Forex et les indices synthétiques.

Les anciennes rubriques Actions, Sweep du jour et Taux de réussite ainsi que le suivi statistique associé ont été retirés. Les fichiers statistiques déjà présents dans le dossier de données MT5 ne sont pas supprimés.

## Installation

1. Dans MetaTrader 5, choisissez **Fichier > Ouvrir le dossier des données**.
2. Copiez le fichier correspondant à votre marché dans `MQL5\Indicators` (vous pouvez conserver les sous-dossiers `Forex` et `SyntheticIndices`).
3. Ouvrez le fichier `.mq5` dans MetaEditor et compilez-le.
4. Dans le Navigateur de MT5, actualisez **Indicateurs** puis ajoutez l'indicateur au graphique.

Configurez les alertes et, pour le Forex, le décalage GMT du serveur du broker dans les paramètres de l'indicateur. Testez les signaux sur un compte démo avant toute utilisation en conditions réelles.

## Vérification

Avec Node.js, `node tests\indicator-logic.test.js` et `node tests\volume-profile.test.js` vérifient les cas de signal, de tendance et de profil de volumes communs aux deux indicateurs. Ces tests ne remplacent ni la compilation dans MetaEditor ni la vérification sur un graphique MT5.
