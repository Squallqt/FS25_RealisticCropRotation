# Plan — Pulvérisateur RCR (fongicide / nématicide)

## Principes (non négociables)
- **Réaliste** : aucun effet de sol détourné. Un fongicide/nématicide ne fertilise pas, ne chaule pas, ne désherbe pas.
- **Respect du moteur** : pas de monkeypatch/hack en pagaille. Approche GIANTS propre, la plus native possible.
- **Référence = SEUL le gameSource.** BMP est banni, SAUF un point : sa logique d'**effacement progressif de la maladie sur la carte au passage du pulvé** est le comportement à reproduire.
- **Une feature à la fois** : implémentée, puis **testée et validée en runtime** par toi, AVANT de passer à la suivante.
- **En cas de doute je questionne, je n'improvise pas.**

## Rendu final attendu (vision validée)
Un pulvérisateur RCR (RCR_FUNGICIDE / RCR_NEMATICIDE) qui :
1. **Traitements fonctionnels en PRÉVENTIF ET CURATIF** (éventuellement un overlay supplémentaire dans la carte du mod).
2. **Jet coloré** (le .dds existe déjà — il faut le brancher correctement).
3. **Couche visuelle au sol** du traitement, comme l'azote/la chaux, mais dans la **couleur du sprayer custom**.
4. **Overlay maladie de la carte qui s'efface au fur et à mesure du traitement** (BMP gère bien ce cas sur ses overlays).
5. **IA fonctionnelle** en préventif ET curatif.

## Décisions (autonomes)
- **A1 = (a)** : overwrites autorisés s'ils sont **minimaux, froids, justifiés, documentés** (comme PF). Si une feature est réellement impossible, je le dis et on l'abandonne — pas de pattern inventé.
- **A2** : je reconstruis proprement, **incrémentalement**, à partir de l'état actuel.

## Ordre d'implémentation (chaque étape livrée + validée runtime AVANT la suivante)
1. ~~**Jet coloré**~~ — **ABANDONNÉ** : le shader de pulvé natif rend une brume d'eau blanche et n'adopte pas le matériau échangé en jeu (confirmé runtime + gameSource). Non faisable proprement → assets/holder retirés.
2. ✅ **Effet curatif + préventif fonctionnels** — **VALIDÉ** (commit `14a3c69`). Protection **par cellule** (2 bitvector, une par famille), peinte sous la rampe uniquement (per-bande). Une cellule traitée est exclue *pour toujours* (cycle en cours) de la destruction quotidienne — même mécanisme pour curatif (stoppe une infection active) et préventif (empêche une future infection). Le sprayer ne touche JAMAIS le blé réel (seule la passe journalière `propagate()` détruit). Vérifiable en console (`rcrDisease` affiche `protect={FUNGICIDE=X%,NEMATICIDE=Y%}`) et au HUD à pied (lit la protection à la position du joueur).
3. ✅ **Effacement progressif de l'overlay maladie sur la carte** — **VALIDÉ, obtenu gratuitement par le point 2** : l'exclusion par cellule efface l'overlay directement sous la rampe au passage (jamais d'aggravation, jamais tout d'un coup). Bonus : bug de scintillement de l'overlay trouvé et corrigé (double buffering natif, `changeRevision` uniquement sur vrai changement).
4. ✅ **Couche visuelle au sol** — **VALIDÉ**. Peint `SPRAY_TYPE` (rendu fertilisant natif) sur la bande pulvérisée — visuel seul, aucun effet agronomique (jamais `SPRAY_LEVEL`). Éphémère (fade ~1 mois via `onDayChanged`), serveur-autoritaire + persistant (save/load).
5. **IA (préventif + curatif)** — critère : un ouvrier couvre et termine le champ. Piste : `addAIFruitRequirement` sur la grille maladie (cellules infectées).

## Piste envisagée (à valider avant implémentation) — nouvelle vue carte "traitements déposés"
Idée : une 3ᵉ sous-vue sur la carte du mod montrant la couverture de protection (comme le fait déjà `rcrDisease` en console). Techniquement faisable nativement : les 2 bitvector de protection existent déjà, il suffirait d'un rendu overlay de plus (même mécanisme que les 2 vues existantes, double-buffered). À creuser avant de coder : utilité réelle vs redondance avec l'overlay maladie qui recule déjà visiblement.

## Ce qui est HORS de ce chantier (déjà fait, ne pas retoucher)
Système de 9 maladies, destruction journalière/foyers, overlays carte maladie/pression, l10n 27 langues, modDesc, audit perf. Le chantier ci-dessus ne concerne QUE le pulvérisateur.
