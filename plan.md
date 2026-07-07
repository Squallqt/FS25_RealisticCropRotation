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
2. **Effet curatif + préventif fonctionnels** — critère : pulvériser soigne (curatif) et protège (préventif) ; vérifiable état/console.
3. **Effacement progressif de l'overlay maladie sur la carte** — critère : recule au passage, jamais d'aggravation.
4. ✅ **Couche visuelle au sol** — **VALIDÉ** : on peint `WATER_LEVEL` (aspect humide) sur la bande pulvérisée. Visuel seul (aucun effet agronomique, rien ne le consomme), éphémère (fade ~1 mois via `onDayChanged`), serveur-autoritaire + persistant (save/load).
5. **IA (préventif + curatif)** — critère : un ouvrier couvre et termine le champ. Piste : `addAIFruitRequirement` sur la grille maladie (cellules infectées).

## Ce qui est HORS de ce chantier (déjà fait, ne pas retoucher)
Système de 9 maladies, destruction journalière/foyers, overlays carte maladie/pression, l10n 27 langues, modDesc, audit perf. Le chantier ci-dessus ne concerne QUE le pulvérisateur.
