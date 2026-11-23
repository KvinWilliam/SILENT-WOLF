# SILENT-WOLF

Indicateurs MetaTrader 5 de détection de figures de retournement, avec panneaux de confirmations et alertes.

## Indicateurs

- **silentwolfforex** — `MQL5\Indicators\Forex\silentwolfforex.mq5`. Inclut le tracé des sessions de marché (Asie, Francfort, Londres et New York).
- **silentwolfindices** — `MQL5\Indicators\SyntheticIndices\silentwolfindices.mq5`. N'inclut pas les sessions Forex.

Les deux fichiers sont des indicateurs personnalisés MT5, pas des Expert Advisors : ils affichent des signaux et peuvent envoyer des alertes, mais ne passent pas d'ordres.

## Installation

1. Dans MetaTrader 5, choisissez **Fichier > Ouvrir le dossier des données**.
2. Copiez le fichier correspondant à votre marché dans `MQL5\Indicators` (vous pouvez conserver les sous-dossiers `Forex` et `SyntheticIndices`).
3. Ouvrez le fichier `.mq5` dans MetaEditor et compilez-le.
4. Dans le Navigateur de MT5, actualisez **Indicateurs** puis ajoutez l'indicateur au graphique.

Configurez les alertes et, pour le Forex, le décalage GMT du serveur du broker dans les paramètres de l'indicateur. Testez les signaux sur un compte démo avant toute utilisation en conditions réelles.
