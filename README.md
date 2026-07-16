# FS25_RealisticCropRotation

Crop rotation planning and disease simulation for Farming Simulator 25.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_RealisticCropRotation/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
[![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)](#)
[![Languages](https://img.shields.io/badge/languages-27-blue.svg)](#)

Track every field's crop history, plan your rotation on a repeating 4-year calendar from a dedicated in-game tab, and get a rotation grade based on real agronomy. Bring a host crop back too soon and nine realistic soil- and weather-driven diseases can take hold and spread. Available in singleplayer and multiplayer, with or without Precision Farming.

## Features

- **Crop history & flexible planning**: track each field's last 4 crops and plan up to 4 years ahead from a dedicated "Crop Rotation" tab in the in-game menu (a 2-crop alternation works just as well as a full 4-crop sequence, only the filled year slots count toward the grade)
- **Field monitoring**: current crop, growth stage, required soil work, weeds, nitrogen and pH for every field (Precision Farming's real maps when installed, vanilla fallback otherwise)
- **Rotation grade (0-100)**: family and disease-specific return intervals, legume-to-cereal nitrogen handoff, crop diversity and planned nitrogen residue all weigh in; a monoculture is capped at "poor", a plan with no nitrogen-fixing crop can't reach "excellent". Bands: 0-19 bad, 20-39 poor, 40-59 fair, 60-79 good, 80-100 excellent
- **Tailored advice**: a status card prioritizes an active outbreak on the field, then evaluates your planned next crop against family/disease spacing, then falls back to generic per-family guidance
- **Rotation overview**: fields sharing an identical plan are grouped into one card with combined area, grade and residue
- **Nitrogen residue**: legumes destroyed by tillage (not simple harvest) return real nitrogen (Precision Farming's nitrogen map when installed, one vanilla fertilizer level otherwise), split between the next crop and the rotation after; 2 usable cover crops (oilseed radish, flowering catch crop) add an estimated +25 kg N/ha each in the planner; see the full reference table below
- **9 realistic diseases** (sclerotinia, phoma, take-all, septoria, rust, fusarium head blight, late blight, beet cyst nematode, clubroot), each tied to specific host crops
- **Rotation-driven infection risk and speed**: a host crop returning before its disease's configured interval builds soil inoculum, raising infection odds and, once a field is infected, how fast the disease progresses
- **Weather & temperature**: rain and temperature drive infection odds and daily spread for the 7 fungal diseases, each with its own favourable temperature window; the beet cyst nematode and clubroot ignore rain, but every new infection still incubates faster in warm weather and slower in cold weather
- **Organic, progressive destruction**: an infected crop is destroyed in an irregular patch that spreads over the following days, with a scattered, speckled transition edge
- **Season-length aware**: disease progression speed automatically scales with the save's days-per-period setting, so pacing is consistent on short or long seasons
- **Sprayer treatment**: buyable fungicide (AMISTAR, Syngenta) and nematicide (VELUM PRIME, Bayer) stop an active infection from destroying more of the sprayed area and shield that ground against future damage from any disease in the same treatment family; take-all and clubroot have no chemical treatment and must be managed agronomically
- **Disease map**: 3 toggle-able views added to the existing in-game map (infected fields, a predictive pressure forecast, and treated-ground coverage), all colour-blind safe
- **On-foot HUD**: the field-info box shows rotation history and active disease under your feet, plus a treatment line when standing on protected ground
- **Weather forecast card**: the in-game menu header shows the next relevant weather event so you can time your spraying
- **Full multiplayer sync**: server-authoritative history, plans and disease state; debounced broadcast, full sync on menu open/join, server-side validation of client plan edits, savegame persistence
- **27 languages** supported

## Nitrogen Residue Reference

Legumes destroyed by tillage (disc harrow / cultivator, not simple harvest) return nitrogen in two shares: the first to the next crop, the second carried over to the rotation after.

| Crop | First share | Second share |
|---|---|---|
| Alfalfa | 80 kg N/ha | 50 kg N/ha |
| Vetch-rye | 60 kg N/ha | 20 kg N/ha |
| Clover | 50 kg N/ha | 20 kg N/ha |
| Soybean | 40 kg N/ha | 10 kg N/ha |
| Pea | 40 kg N/ha | 10 kg N/ha |
| Green bean | 20 kg N/ha | 5 kg N/ha |

Cover crops (oilseed radish, flowering catch crop) add an estimated flat +25 kg N/ha instead, reflected as an estimate in the planner. With Precision Farming, the residue is added directly to the nitrogen map; without it, the mod adds one vanilla fertilizer level regardless of the crop.

## Installation

### From ModHub
Search for "Realistic Crop Rotation" on the official [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

### Manual
1. Place the downloaded `FS25_RealisticCropRotation.zip` file into your FS25 `mods/` directory (do not extract)
2. Activate the mod in mod selection
3. Access via the dedicated "Crop Rotation" tab in the InGame Menu (ESC)

## Usage

### Planning a Rotation
1. InGame Menu (ESC) > **Crop Rotation** tab > **Planning**
2. Select a field in the sidebar to see its plan and rotation grade
3. Pick a year slot and assign a crop (and optionally a cover crop) from the calendar
4. Follow the per-field advice to avoid family and disease return-interval penalties

### Managing Disease Risk
1. Open the in-game Map and switch to the **Diseases** view to check infected fields and the pressure forecast
2. Space host crops far enough apart in your rotation plan to keep soil inoculum low
3. Treat active fungal infections with a fungicide sprayer (AMISTAR), or the beet cyst nematode with a nematicide sprayer (VELUM PRIME)
4. For take-all and clubroot, rely on a non-host crop, a resistant variety, liming and a long enough rotation
5. Harvest what remains after an infection and avoid returning a susceptible host until rotation decay lowers soil pressure

## Console Commands

Testing/admin tools registered by the mod (server/host only):

| Command | Description |
|---|---|
| `rcrDisease [farmlandId]` | Prints the current disease state |
| `rcrDiseaseInfect <farmlandId> <group> [severity]` | Forces an infection |
| `rcrDiseaseTick [farmlandId]` | Runs one disease update step |
| `rcrDiseaseClear [farmlandId]` | Clears disease state |

Valid `<group>` values: `SCLEROTINIA`, `PHOMA`, `TAKEALL`, `SEPTORIA`, `RUST`, `FUSARIUM`, `LATEBLIGHT`, `BCN`, `CLUBROOT`.

## Changelog

### v1.0.0.0
- Initial release

## Support

- **Issues & suggestions**: [GitHub Issues](https://github.com/Squallqt/FS25_RealisticCropRotation/issues)

## License

All Rights Reserved © 2026 Squallqt. Not affiliated with or endorsed by GIANTS Software GmbH.
