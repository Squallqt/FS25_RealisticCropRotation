# Etat actuel apres stabilisation dev

Date: 2026-06-08
Branche: `dev`
Commit stable sans hooks semoir density-map: `1885b13 Stabilize dev without sowing density hooks`
Branche runtime logs conservee: `debug/phase2b-seeding-instrumentation` (`910e665`, upstream `origin/debug/phase2b-seeding-instrumentation`)

Ce document decrit seulement ce qui est prouve par le code, les commandes statiques et les consignes mainteneur de cette session. La finalite complete du mod n'est pas formalisee dans un cahier des charges versionne dans le repo: non prouve avec les sources disponibles.

## Etat runtime prouve sur dev

Le chemin couteux qui accrochait l'historique et la culture active aux callbacks haute frequence `FSDensityMapUtil.updateSowingArea` et `FSDensityMapUtil.updateDirectSowingArea` a ete retire dans `main.lua`.

Preuves:
- `rg -n "FSDensityMapUtil\\.updateSowingArea|FSDensityMapUtil\\.updateDirectSowingArea|wrapDensityMapSowingHook|wrapDensityMapDirectSowingHook|captureCropCandidate|recordTermination\\(" FS25_RealisticCropRotation_repo\\FS25_RealisticCropRotation -g "*.lua"` ne retourne aucun resultat apres `1885b13`.
- `main.lua` ne garde plus que les hooks lifecycle/sync/save:
  - `Mission00.loadMission00Finished = Utils.appendedFunction(...)` ligne 330.
  - `FSBaseMission.saveSavegame = Utils.appendedFunction(...)` ligne 331.
  - `FSBaseMission.sendInitialClientState = Utils.appendedFunction(...)` ligne 332.
  - `BaseMission.delete = Utils.appendedFunction(...)` ligne 334.
- Les hooks HUD restent actifs, mais ils touchent le HUD joueur:
  - `RealisticCropRotationHud.lua` lignes 213-219 overwritent `PlayerHUDUpdater.fieldAddField` et `PlayerHUDUpdater.fieldAddFarmland`.

Resultat:
- Aucun hook RCR sur `FSDensityMapUtil.updateSowingArea`.
- Aucun hook RCR sur `FSDensityMapUtil.updateDirectSowingArea`.
- Aucun hook recolte/destruction RCR reintroduit.
- Aucun write Precision Farming/nitrogen map/spray-level prouve dans le runtime actuel.

## Ce qui reste fonctionnel / gardable

### Bootstrap, lifecycle, sync et sauvegarde

Le mod charge encore ses modules depuis `main.lua`:
- repository, service, manager, HUD, events et frame sont sources lignes 7-14.

Le lifecycle mission reste actif:
- `loadedMission` est accroche a `Mission00.loadMission00Finished` ligne 330.
- la sauvegarde XML est accrochee a `FSBaseMission.saveSavegame` ligne 331.
- l'etat initial client est envoye via `FSBaseMission.sendInitialClientState` ligne 332.

### Historique XML / persistence

Le repository conserve l'historique, les plans, la culture active connue et les vestiges de reliquat:
- creation des tables `history`, `plans`, `lastKnownActiveCrop`, `appliedResidue`: `RealisticCropRotationRepository.lua` lignes 51-54.
- sauvegarde XML: `RealisticCropRotationRepository:saveToXML` ligne 211.
- chargement XML: `RealisticCropRotationRepository:loadFromXML` ligne 307.
- sauvegarde de `lastKnownActiveCrop`: ligne 266.
- chargement de `lastKnownActiveCrop`: lignes 343-345.

Gardable: oui pour persistence XML et affichage historique, sous reserve de ne pas confondre "stockage" avec "moteur de detection d'implantation". Depuis `1885b13`, le moteur de detection semis n'est plus actif.

### UI historique et lecture

L'UI lit l'historique dans le detail panel:
- `RealisticCropRotationFrame:updateDetailPanel` ligne 762.
- lecture `mgr:getHistory(farmlandId)` ligne 793.

La recherche UI ne montre pas de mutation historique depuis `updateDetailPanel`:
- recherche `reconcileActiveCropForFarmland|pushHistoryCrop|setLastKnownActiveCrop` dans `RealisticCropRotationFrame.lua`: aucun appel dans `updateDetailPanel`.
- `sendEvent(RCRPlanUpdateEvent...)` existe ligne 1201 mais concerne le planner, pas l'historique.

Gardable: oui pour UI historique actuelle.

### Stade de croissance / informations champ

Le manager construit des informations de champ via `FieldState`:
- `RealisticCropRotationManager:getFieldCropInfo` ligne 784.
- creation `FieldState.new()` ligne 799.
- classification croissance `RealisticCropRotationManager.classifyGrowthStage` ligne 645.
- l'UI consomme `info.growthStageText` dans `RealisticCropRotationFrame.lua` lignes 960 et 973.

Gardable: oui, aucune preuve statique de bug dans le stade de croissance n'a ete etablie dans cette phase.

### Planner simple

Le planner stocke des choix manuels:
- `RealisticCropRotationFrame.lua` envoie `RCRPlanUpdateEvent` ligne 1201 cote client.
- `RCRPlanUpdateEvent:run` applique `manager:setRotationPlanYear` ligne 84.
- `RealisticCropRotationManager:setRotationPlanYear` ligne 387.

Gardable: oui pour stockage manuel simple.

Non implemente: controle calendrier semis/recolte. La recherche `getIsPlantableInPeriod|plantable|calendar|season` ne montre pas d'appel aux fenetres de semis/recolte du jeu dans le planner. Les lignes saison dans l'UI affichent seulement la saison courante (`RealisticCropRotationFrame.lua` lignes 781-786 et 1034-1039).

## Ce qui est desactive ou non actif

### Detection automatique d'implantation

Depuis `1885b13`, aucun hook semoir density-map n'alimente l'historique ni `lastKnownActiveCrop`.

Il reste des fonctions de transition dans le service/manager:
- `RealisticCropRotationManager:recordCropChangeFromHook` ligne 481.
- `RealisticCropRotationService:onCropChangeArea` ligne 197.
- `RealisticCropRotationService:pushHistoryCrop` ligne 127.
- `RealisticCropRotationService:setLastKnownActiveCrop` ligne 169.

Mais aucun appel depuis `main.lua` n'est prouve apres suppression des hooks. Ces fonctions sont donc a considerer comme code non atteint par le runtime hook actuel, sauf appel futur explicite.

Impact connu:
- L'historique existant se charge et s'affiche.
- Une nouvelle implantation ne peut plus etre prouvee comme automatiquement enregistree au semis sur `dev`.
- La culture active connue ne peut plus etre prouvee comme mise a jour automatiquement au semis sur `dev`.

### Azote / Precision Farming

Aucun acces PF dangereux n'est prouve dans le code Lua actuel:
- recherche `g_precisionFarming|precisionFarming|nitrogenMap|NitrogenMap|DensityMapModifier|executeSet|executeAdd|SPRAY_LEVEL|FSDensityMapUtil.updateSprayArea`: aucun resultat Lua apres `1885b13`.

Il reste des textes/config/vestiges:
- `cropConfig.xml` garde des attributs `n1`, `n2`, `residueEvent`.
- `modDesc.xml` decrit encore des comportements azote/PF qui ne sont plus actifs.
- `RealisticCropRotationRepository.lua` garde `appliedResidueSprayLevel` lignes 272 et 354.
- `RCRHistoryResponseEvent.lua` transporte encore `sprayLevel` lignes 84, 90 et 219.

Conclusion: l'azote est neutralise en runtime, mais le modele de donnees et les textes publics gardent des vestiges. A nettoyer avant une reconstruction propre.

## Ce qui reste a reecrire pour une architecture saine

### 1. Moteur d'implantation hors hooks density-map

Besoin prouve: l'ancienne source `FSDensityMapUtil.updateSowingArea/updateDirectSowingArea` est refusee par le mainteneur et a ete retiree. Les logs runtime mainteneur prouvent une frequence elevee:
- semis classique: environ 1642 callbacks afterSuper, 525 avec `changedArea > 0`.
- semis direct: environ 82 callbacks afterSuper, 78 avec `changedArea > 0`.

Sources GIANTS candidates deja identifiees mais non validees:
- `SowingMachine:processSowingMachineArea` appelle les density-map functions lignes 556 et 559: non exploitable comme source finale, car meme granularite de zone.
- `SowingMachine:onEndWorkAreaProcessing` utilise `lastChangedArea` lignes 1050-1058: candidate a tester runtime.
- `WorkArea:onUpdateTick` publie `onStartWorkAreaProcessing` ligne 209 et `onEndWorkAreaProcessing` ligne 326: candidate a tester runtime.
- `FieldState` expose `fruitTypeIndex` et `growthState` lignes 37-38: utile pour lecture/snapshot, pas preuve d'un event d'implantation.

Travail requis:
- definir une source bas niveau acceptable;
- prouver sa frequence runtime;
- prouver les donnees disponibles: farmlandId, fruitType, surface/ratio, debut/fin;
- seulement ensuite reconnecter `pushHistoryCrop` et `setLastKnownActiveCrop`.

### 2. Deduplication et transitions historiques

Le repository interdit deux cultures identiques consecutives:
- `RealisticCropRotationRepository:pushEntry` ligne 128.
- garde anti doublon `entries[1].crop == cropName` lignes 135-138.

Besoin mainteneur connu: deux semis consecutifs de ble doivent produire deux entrees distinctes. Ce besoin n'est pas corrige.

Travail requis:
- ne pas retirer simplement le garde sans moteur de transition;
- dedupliquer par evenement d'implantation valide, pas par callback zone;
- definir quand une implantation est "terminee" ou "suffisante" pour historiser.

### 3. Couverts

Le service exclut les couverts de l'historique:
- `isCoverCropForRotationHistory` ligne 106.
- `pushHistoryCrop` retourne false pour couvert lignes 127-134.
- `onCropChangeArea` separe `pushHistoryCrop` et `setLastKnownActiveCrop` lignes 206-215.

Etat actuel: logique presente mais non prouvee atteignable depuis le runtime, car les hooks semoir sont retires.

Travail requis:
- revalider cette logique seulement quand un nouveau moteur d'implantation existe.

### 4. Seuil surface / changedArea

La logique actuelle `onCropChangeArea` filtre seulement `changedArea <= 0`:
- `RealisticCropRotationService.lua` lignes 201-202.

Il n'y a pas de seuil cumule 90% prouve dans le code actuel. Depuis `1885b13`, ce chemin n'est plus atteint depuis les hooks semoir.

Travail requis:
- definir un seuil metier si necessaire;
- le calculer par parcelle ou champ, pas par callback density-map.

### 5. Azote propre

Le futur azote ne doit pas vivre dans `main.lua`. Preuve de dette actuelle:
- `main.lua` charge encore les donnees `nitrogen` depuis `cropConfig.xml` lignes 44-74.
- `RealisticCropRotationService.lua` contient encore `getNitrogenValues` lignes 60-64 et des noms `nitrogenDepositLock` lignes 18-28.
- le runtime n'ecrit plus PF/spray-level.

Travail requis:
- creer un module dedie azote ou nettoyer le service avant reintroduction;
- isoler les APIs GIANTS/PF;
- ne rebrancher l'azote qu'apres preuves runtime et tests statiques.

### 6. Planner calendrier semis/recolte

Non implemente. Les textes de saison existent dans l'UI et les l10n, mais aucun appel prouve aux fenetres GIANTS de semis/recolte dans le planner.

Travail requis:
- verifier les APIs GIANTS de calendrier dans gameSource;
- implementer un signalement ou blocage selon specification mainteneur.

### 7. ModDesc et textes publics

`modDesc.xml` annonce encore l'azote et Precision Farming:
- `modDesc.xml` lignes 11-26.

Etat actuel: ces promesses ne correspondent plus au runtime stabilise sans azote. Changement de texte non effectue dans cette phase.

Travail requis:
- soit adapter la description publique a l'etat sans azote;
- soit attendre la reconstruction azote avant publication.

## Prochaine direction recommandee

1. Garder `dev` comme base stable sans hooks semoir density-map.
2. Utiliser `debug/phase2b-seeding-instrumentation` ou une nouvelle branche debug depuis `dev` pour les dumps runtime.
3. Tester uniquement les candidates GIANTS plus propres (`onEndWorkAreaProcessing`, lifecycle WorkArea, snapshot FieldState controle).
4. Reconnecter l'historique et `lastKnownActiveCrop` seulement apres preuve runtime de frequence acceptable et de donnees suffisantes.
5. Ne pas reconstruire l'azote avant d'avoir un moteur d'implantation sain.

Question ouverte mainteneur:
- La finalite fonctionnelle prioritaire du mod doit-elle etre: historique de rotation fiable uniquement, ou historique + planner + futur azote agronomique complet ?

