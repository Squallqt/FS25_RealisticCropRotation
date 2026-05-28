# SOWING PLANNER AUDIT — FS25_FieldRotation

**Date** : 2026-05-28  
**Scope** : Audit uniquement — zéro patch  
**Statut** : Prêt pour validation

---

## 1. PLAN STORAGE — MODÈLE ACTUEL

**Fichier** : `scripts/FieldRotationRepository.lua`

### Structure de données (ligne 43–57)

```lua
self.history = {}              -- history[farmlandId] = { {crop=...}, ... }
self.plans   = {}              -- plans[farmlandId]   = { crop1, crop2, crop3, crop4 }
self.lastKnownActiveCrop = {}
self.nitrogenMaskPeriod  = 0
```

Le plan est une table de **4 chaînes crop** (nom uppercase ou `""`).  
Aucune donnée de période/date de semis n'est stockée actuellement.

### API CRUD (lignes 87–113)

| Fonction | Signature | Notes |
|---|---|---|
| `getPlan` | `(farmlandId)` → `{"","","",""}` | Ligne 87 |
| `setPlanYear` | `(farmlandId, yearIdx 1–4, cropName)` | Ligne 95 |
| `clearPlan` | `(farmlandId)` → `bool` | Ligne 104 |

---

## 2. SAVE / LOAD — XML

**Fichier** : `scripts/FieldRotationRepository.lua` lignes 157–323  
**Fichier cible** : `{savegame}/fieldRotation.xml`  
**Version courante** : `FieldRotationRepository.SAVE_VERSION = 1` (ligne 8)

### Format XML actuel (lignes 157–241)

```xml
<fieldRotation version="1" nitrogenMaskPeriod="X">
  <farmland id="123" lastKnownActiveCrop="WHEAT">
    <entry(0) crop="MAIZE"/>
    <plan(0) year1="BARLEY" year2="LEGUME" year3="" year4=""/>
  </farmland>
</fieldRotation>
```

Le XML ne contient **aucun attribut de période de semis** par slot.

---

## 3. SYNC MP — ÉVÉNEMENTS

**Dossier** : `events/`

| Classe | Direction | Payload actuel |
|---|---|---|
| `FRHistoryRequestEvent` | Client→Server | aucun |
| `FRHistoryResponseEvent` | Server→Client | history + plans + activeCrops |
| `FRPlanUpdateEvent` | Client→Server | farmlandId, yearIdx, cropName |

### FRPlanUpdateEvent — wireStream (lignes 29–32)

```lua
streamWriteInt32(streamId, tonumber(self.farmlandId) or 0)
streamWriteInt8(streamId, tonumber(self.yearIdx) or 0)
streamWriteString(streamId, tostring(self.cropName or ""))
```

Aucun champ `period` dans le flux actuellement.

### FRHistoryResponseEvent — sérialisation plans (lignes ~140–155)

La boucle lit `year1..year4` comme chaîne crop simple. Pas de période.

---

## 4. UI SLOTS — RENDU

**Fichier** : `gui/FieldRotationFrame.lua` et `gui/FieldRotationFrame.xml`

### Sélecteurs de plan (lignes 522–545)

```lua
local selectors = self.planSlotSelector  -- table[4] de MultiTextOption/Selector
for i = 1, 4 do
    local selector = selectors[i]
    FocusManager:linkElements(selector, FocusManager.TOP, ...)
    FocusManager:linkElements(selector, FocusManager.BOTTOM, ...)
end
```

4 widgets `planSlotSelector[1..4]`, navigables verticalement.  
Aucun widget de sélection de période associé à ces slots actuellement.

### Labels de saison actuels (ligne 57–60)

```lua
FieldRotationFrame.SEASON_KEY = {
    [0] = "fr_season_spring", [1] = "fr_season_summer",
    [2] = "fr_season_autumn", [3] = "fr_season_winter",
}
```

Utilisé pour le bandeau de saison en cours (saison, pas période).

---

## 5. SÉLECTEUR DE CULTURE — LOGIQUE

**Fichier** : `gui/FieldRotationFrame.lua`  
**Fonction** : `buildPlanCropList()` (lignes 560–617)

### Construction de la liste (lignes 575–591)

```lua
for _, fruitType in pairs(g_fruitTypeManager.fruitTypes) do
    -- Filtre 1 : a un nom
    -- Filtre 2 : harvestTransitions non vide (culture récoltable)
    -- Filtre 3 : fillType avec hudOverlayFilename (icône HUD)
    -- Filtre 4 : famille != "COVER" (pas de couvre-sol)
    table.insert(self.planCropList, fruitType.name)
end
```

**Aucun filtre saisonnier** : toutes les cultures récoltables sont proposées quelle que soit la saison ou la période cible.

---

## 6. GAME SOURCE — PÉRIODES DE SEMIS

### 6.1 Données XML par fruit

**Preuve** : `docs/FS25_Pallegney/maps/foliage/wheat/wheat.xml` (lignes 113–148)

```xml
<growth>
  <seasonal initialState="harvestReady">
    <period name="EARLY_SPRING" plantingAllowed="true">
      <update startState="invisible" endState="greenSmall" />
    </period>
    <period name="MID_SPRING" />
    ...
    <period name="LATE_WINTER" plantingAllowed="true">
      <update startState="invisible" endState="greenSmall" />
    </period>
  </seasonal>
</growth>
```

L'attribut `plantingAllowed="true"` est positionné sur les `<period>` où le semis est autorisé.  
Sa **valeur par défaut est `false`** (absence = interdit).

### Exemples de fenêtres de semis (prouvées)

| Culture | Fichier | Périodes autorisées |
|---|---|---|
| WHEAT | `foliage/wheat/wheat.xml:115–147` | EARLY_SPRING (1), LATE_WINTER (12) |
| WINTERWHEAT | `foliage/wheat/winterWheat.xml:145–151` | EARLY_AUTUMN (7), MID_AUTUMN (8) |
| MAIZE | `foliage/maize/maize.xml:247–250` | MID_SPRING (2), LATE_SPRING (3) |

### 6.2 Mapping periode name → entier

Déduit de l'ordre déclaratif dans les XMLs fruit (12 périodes dans l'ordre) :

| Index | Nom XML |
|---|---|
| 1 | EARLY_SPRING |
| 2 | MID_SPRING |
| 3 | LATE_SPRING |
| 4 | EARLY_SUMMER |
| 5 | MID_SUMMER |
| 6 | LATE_SUMMER |
| 7 | EARLY_AUTUMN |
| 8 | MID_AUTUMN |
| 9 | LATE_AUTUMN |
| 10 | EARLY_WINTER |
| 11 | MID_WINTER |
| 12 | LATE_WINTER |

L'entier `g_currentMission.environment.currentPeriod` correspond à cet index 1–12.  
**Source** : `FieldRotationService.lua:89` utilise `g_currentMission.environment.currentPeriod` comme entier.

### 6.3 Chargement en mémoire

**Preuve** : `gameSource/dataS/scripts/fruits/FruitTypeDesc.lua:632`

```lua
self:loadGrowth(xmlFile, "foliageType.growth")
```

Le corps de `loadGrowth` est **stripped** dans notre gameSource (lignes vides 1–150).  
Mais l'appel est prouvé → les données sont chargées dans `FruitTypeDesc` au démarrage de mission.

### 6.4 API runtime prouvée — `getIsPlantableInPeriod`

**Preuves multiples** :

| Fichier | Ligne | Code |
|---|---|---|
| `SowingMachine.lua` | 857 | `fruitDesc:getIsPlantableInPeriod(g_currentMission.missionInfo.growthMode, g_currentMission.environment.currentPeriod)` |
| `SowingMachine.lua` | 1016 | idem |
| `TreePlanter.lua` | 506 | `fruitTypeDesc:getIsPlantableInPeriod(growthMode, currentPeriod)` |
| `PlaceableVine.lua` | 390 | idem |

**Signature complète** :
```lua
local ok = fruitTypeDesc:getIsPlantableInPeriod(growthMode, periodIndex)
-- growthMode  : g_currentMission.missionInfo.growthMode  (GrowthMode table value)
-- periodIndex : integer 1–12
-- return      : boolean
```

La fonction accepte **n'importe quel entier 1–12** comme `periodIndex`, pas uniquement `currentPeriod`.  
→ On peut interroger n'importe quelle période future sans hack.

### 6.5 GrowthMode

`GrowthMode` est une table globale prouvée dans le data dump (`globalTables.lua:583`).  
Ses **valeurs de constantes (SEASONAL, MANUAL, etc.) ne sont pas prouvées** dans les sources disponibles.

Pour une utilisation sûre, on passe simplement `g_currentMission.missionInfo.growthMode` comme valeur opaque — on ne teste pas ses valeurs, on la transmet.

---

## 7. INFORMATIONS NON PROUVÉES

| Aspect | Statut |
|---|---|
| Corps de `FruitTypeDesc:loadGrowth()` | NON PROUVÉ DANS LES SOURCES FOURNIES |
| Corps de `FruitTypeDesc:getIsPlantableInPeriod()` | NON PROUVÉ DANS LES SOURCES FOURNIES |
| Constantes de `GrowthMode` (SEASONAL, MANUAL, etc.) | NON PROUVÉ DANS LES SOURCES FOURNIES |
| Comportement avec GrowthMode=MANUAL (sans saisons) | NON PROUVÉ DANS LES SOURCES FOURNIES |
| Compatibilité avec maps modded ayant des calendriers personnalisés | NON PROUVÉ (mais `getIsPlantableInPeriod` délègue à la map → safe) |

---

## 8. FAISABILITÉ TECHNIQUE

### Ce qui est possible

1. **Stocker une période cible par slot** : ajout trivial dans `FieldRotationRepository`.
2. **Interroger la plantabilité** : `fruitTypeDesc:getIsPlantableInPeriod(growthMode, targetPeriod)` est prouvée, public, appelable depuis n'importe quel script de mod.
3. **Construire la liste filtrable** : itération sur `g_fruitTypeManager.fruitTypes` est déjà faite dans `buildPlanCropList()`.
4. **Afficher un avertissement** : le bandeau en haut est déjà câblé dans le Frame.

### Risques identifiés

| Risque | Impact | Mitigation |
|---|---|---|
| **Breaking save** : ajout de `period` au XML → version bump obligatoire | Moyen (migration nécessaire) | Bump `SAVE_VERSION` à 2, lire avec default=0 si absent |
| **Breaking MP stream** : ajout de `period` dans `FRPlanUpdateEvent` et `FRHistoryResponseEvent` | Élevé (incompatibilité client/server de versions mixtes) | Bump de version du protocole événement ou stream conditionnel |
| **GrowthMode opaque** : si `growthMode = MANUAL`, `getIsPlantableInPeriod` renvoie peut-être toujours `true` | Bas (safe) | On affiche l'avertissement seulement si la fonction retourne `false` |
| **Maps modded** : calendriers de semis différents de vanilla | Bas | La fonction délègue à `FruitTypeDesc` de la map active → automatiquement correct |
| **Pas de période définie** (slot=0) | Bas | Pas d'avertissement si aucune période choisie |

---

## 9. PROPOSITIONS UX

Le bandeau supérieur existe et affiche la saison courante (`fr_season_*`). Trois alternatives UX sont explorées ci-dessous.

---

### Alternative A — Filtrage silencieux (hard block)

**Comportement** : quand un slot a une période cible définie, le sélecteur de culture ne liste QUE les cultures dont `getIsPlantableInPeriod(mode, targetPeriod) == true`.

**Avantages** :
- Interface propre, pas de bruit visuel.
- Impossible de faire un mauvais choix.

**Inconvénients** :
- Déroutant : l'utilisateur voit des cultures disparaître sans comprendre pourquoi.
- S'il n'a pas défini de période, il voit la liste complète → comportement incohérent.
- Impossible de planifier "par anticipation" une culture hors-saison pour une future année.

**Verdict** : Non recommandé — trop opaque pour un planificateur prospectif.

---

### Alternative B — Avertissement dans le bandeau supérieur (soft warning)

**Comportement** : quand l'utilisateur choisit une culture incompatible avec la période cible du slot, le bandeau supérieur affiche un message temporaire, e.g. :

> ⚠ BLEU — Hors fenêtre de semis pour le Slot 1

Le bandeau retrouve son contenu normal (saison) quelques secondes après.

**Avantages** :
- N'utilise pas d'espace UI supplémentaire.
- Non bloquant : l'utilisateur peut quand même faire son choix.
- Pattern similaire aux warnings HUD du jeu vanilla.

**Inconvénients** :
- Éphémère : le message disparaît, l'utilisateur peut le manquer.
- Un seul warning à la fois — si 2 slots sont problématiques, seul le dernier modifié est visible.
- Le bandeau est actuellement implémenté pour la saison ; il faudrait gérer la coexistence des deux messages.

**Verdict** : Acceptable comme complément, insuffisant seul.

---

### Alternative C — Badge inline "Hors saison" par slot (RECOMMANDÉE)

**Comportement** : chaque slot plan dispose d'un label/badge discret en dessous du sélecteur de culture. Ce badge est :
- **invisible** si pas de période définie OU culture compatible.
- **visible** (texte court, ex. : `⚠ Hors saison`) si la culture choisie n'est pas semable dans la période cible du slot.

Pas de blocage, pas de liste réduite. L'utilisateur voit le problème directement à côté du contrôle problématique.

**Avantages** :
- Feedback persistant (visible tant que la combinaison est invalide).
- Un badge par slot → 4 slots indépendants visibles simultanément.
- Non bloquant : l'utilisateur décide en connaissance de cause.
- Simple à implémenter : 4 `Text` éléments cachés/affichés dynamiquement.

**Inconvénients** :
- Nécessite un ajout UI dans `FieldRotationFrame.xml` (4 nouveaux éléments `<Text>`).
- Texe court → nécessite une clé l10n par langue.

**Verdict** : **RECOMMANDÉE** — feedback clair, non destructif, contextuel.

---

### Combinaison suggérée

**Alternative C** (badge inline) comme source de vérité visuelle + **Alternative B** (bandeau) comme confirmation au moment de la sélection.

---

## 10. PLAN D'IMPLÉMENTATION PAR ÉTAPES

> Prérequis : audit validé par l'utilisateur. Zéro code avant validation.

### Étape 1 — Modèle de données (FieldRotationRepository)

- Ajouter `self.planPeriods = {}` : `planPeriods[farmlandId] = {p1, p2, p3, p4}` (entier 1–12 ou 0 = non défini).
- Ajouter `setPlanPeriod(farmlandId, yearIdx, period)` et `getPlanPeriods(farmlandId)`.
- **Ne pas modifier** `plans` (backward compat).

### Étape 2 — Persistance XML (Save/Load)

- Bump `SAVE_VERSION` : 1 → 2.
- `saveToXML` : écrire `<plan(0) year1="X" year2="X" ... period1="3" period2="7" .../>`.
- `loadFromXML` : lire `period1..period4` avec default=0 si absent (compatibilité SAVE_VERSION=1).

### Étape 3 — Sync MP (Events)

- `FRPlanUpdateEvent` : ajouter `period` (int 1–12 ou 0) dans `writeStream`/`readStream`.
  - `streamWriteInt8(streamId, tonumber(self.period) or 0)` — 1 octet supplémentaire.
- `FRHistoryResponseEvent` : sérialiser `planPeriods` dans la même boucle que `plans`.

### Étape 4 — UI : sélecteur de période par slot

- Ajouter dans `FieldRotationFrame.xml` 4 sélecteurs de période (`MultiTextOption`) liés aux slots plan.
- Peupler avec les 12 noms de période localisés (nouvelles clés l10n).
- Câbler dans `FieldRotationFrame.lua` : `onPlanPeriodChanged(slotIdx, periodIndex)` → `FRPlanUpdateEvent`.

### Étape 5 — Validation de compatibilité culture/période

- Dans `FieldRotationFrame.lua`, à chaque changement de culture ou de période :
  ```lua
  local fruitType = g_fruitTypeManager:getFruitTypeByName(cropName)
  if fruitType ~= nil and targetPeriod ~= nil and targetPeriod > 0 then
      local ok = fruitType:getIsPlantableInPeriod(
          g_currentMission.missionInfo.growthMode, targetPeriod)
      self:setSlotSeasonWarning(slotIdx, not ok)
  end
  ```
- `setSlotSeasonWarning(slotIdx, visible)` : affiche/cache le badge inline.

### Étape 6 — UX : badge inline + bandeau

- Ajouter 4 `<Text>` dans `FieldRotationFrame.xml` (`slotWarning[1..4]`), cachés par défaut.
- Mettre à jour `updatePlanSlotVisualsFromSelectors()` pour gérer leur visibilité.
- Bandeau : optionnel, en complément.

### Étape 7 — L10n

- 12 clés pour les noms de période (`fr_period_early_spring`, etc.) dans les 25 fichiers `l10n_*.xml`.
- 1 clé pour le badge warning (`fr_plan_warning_out_of_season`).

---

## 11. FICHIERS CONCERNÉS (RÉSUMÉ)

| Fichier | Modification nécessaire |
|---|---|
| `scripts/FieldRotationRepository.lua` | Ajout `planPeriods`, API, save/load, bump SAVE_VERSION |
| `scripts/FieldRotationManager.lua` | Exposer `setPlanPeriod`, `getPlanPeriods` |
| `events/FRPlanUpdateEvent.lua` | Ajouter champ `period` dans le stream |
| `events/FRHistoryResponseEvent.lua` | Sérialiser `planPeriods` |
| `gui/FieldRotationFrame.lua` | Sélecteurs période, validation, badges warning |
| `gui/FieldRotationFrame.xml` | 4 sélecteurs période + 4 textes warning |
| `l10n/l10n_*.xml` | 13 clés nouvelles × 25 fichiers |

---

## 12. APIS UTILISABLES (PROUVÉES)

| API | Source | Usage |
|---|---|---|
| `g_fruitTypeManager:getFruitTypeByName(name)` | `FruitTypeManager.lua:330` | Résoudre un FruitTypeDesc par nom |
| `g_fruitTypeManager:getFruitTypeByIndex(idx)` | `FruitTypeManager.lua:305` | Résoudre un FruitTypeDesc par index |
| `g_fruitTypeManager.fruitTypes` | `FruitTypeManager.lua:60` | Itérer toutes les cultures |
| `fruitTypeDesc:getIsPlantableInPeriod(mode, period)` | `SowingMachine.lua:857,1016` | Vérifier la semabilité |
| `g_currentMission.missionInfo.growthMode` | `SowingMachine.lua:857` | Mode de croissance actuel |
| `g_currentMission.environment.currentPeriod` | `FieldRotationService.lua:89` | Période courante (1–12) |

## 13. APIS NON PROUVÉES

| API prétendue | Statut |
|---|---|
| `GrowthMode.SEASONAL`, `GrowthMode.MANUAL` | NON PROUVÉ DANS LES SOURCES FOURNIES |
| `g_growthManager` (global) | NON PROUVÉ DANS LES SOURCES FOURNIES |
| `FruitTypeDesc.plantPeriods` (field direct) | NON PROUVÉ DANS LES SOURCES FOURNIES |
| `FruitTypeDesc.seasonal` (field direct) | NON PROUVÉ DANS LES SOURCES FOURNIES |

---

*Audit terminé. Aucun patch appliqué. En attente de validation.*
