# Etat actuel apres stabilisation dev

Date: 2026-06-08
Branche: `dev`
Base stable: `8ba40ff Document stabilized dev state`

Ce document decrit l'etat prouve de `dev` apres stabilisation. `dev` est un squelette stable, pas un mod feature-complete.

## Etat prouve

Actif sur `dev`:
- chargement du mod et des modules;
- lifecycle mission, sauvegarde XML et sync multijoueur;
- lecture/affichage de l'historique sauvegarde;
- stockage manuel du planner;
- panneau champ en lecture seule quand les donnees base-game existent.

Non prouve actif sur `dev`:
- application de reliquat azote;
- ecriture Precision Farming sur nitrogen map;
- detection automatique semis/recolte reconnectee;
- regles calendrier du planner.

Les anciens hooks semoir density-map restent retires. Aucun hook `FSDensityMapUtil.updateSowingArea` ou `FSDensityMapUtil.updateDirectSowingArea` ne doit etre rebranche dans ce nettoyage.

## Nettoyage limite de cette phase

Cette phase ne reconstruit pas de feature et ne change pas l'UI publique.

Nettoyage effectue:
- restauration de ce document suivi, qui etait supprime dans le working tree;
- correction de commentaires internes qui parlaient encore de depot azote actif;
- marquage interne de `appliedResidue` / `sprayLevel` comme payload legacy de compatibilite save/load/sync.

Non touche volontairement:
- `modDesc.xml`;
- `l10n/*.xml`;
- hooks runtime;
- moteur de rotation;
- planner calendrier;
- comportement final du mod.

## Vestiges laisses volontairement

`n1`, `n2` et `residueEvent` restent dans `cropConfig.xml`.

Raison: ils sont encore lus par `main.lua`, `RealisticCropRotationService.lua` et le planner/status UI. Les supprimer maintenant serait une modification fonctionnelle non prouvee sure.

`appliedResidue` et `sprayLevel` restent dans repository/save/load/sync.

Raison: ils font partie du format XML sauvegarde et du payload MP `RCRHistoryResponseEvent`. Les retirer casserait potentiellement la compatibilite save/load ou le wire format multijoueur. Ils sont donc documentes comme legacy au lieu d'etre supprimes.

## Preuves attendues

Validation a relancer apres chaque nettoyage:
- `luac -p` sur tous les Lua;
- grep global azote/PF/spray-level;
- `git diff --check`;
- `git diff` relu avant commit.

Les occurrences restantes d'azote/PF/spray-level doivent etre soit des vestiges documentes, soit des textes publics non modifies dans cette phase, soit les libelles historiques `N-1` / `N-2`.
