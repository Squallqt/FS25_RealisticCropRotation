# FS25_RealisticCropRotation

Crop rotation planning and disease simulation for Farming Simulator 25.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_RealisticCropRotation/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)
![Languages](https://img.shields.io/badge/languages-27-blue.svg)
[![License](https://img.shields.io/badge/license-proprietary-red.svg)](LICENSE)

Every field remembers its last 4 rotation entries, whether crops or fallow years. Plan a repeating 2-, 3- or 4-year rotation, watch the disease risk, and protect a sensitive crop before an outbreak destroys part of it.

Singleplayer and multiplayer, with or without Precision Farming.

## Planning

- **Rotation history**: the last 4 rotation entries of every field, crops or fallow years, recorded automatically
- **2- to 4-year rotation calendar**: fill 2, 3 or 4 yearly slots with crops or fallow, plus an optional cover crop per year; the selected slots form the real repeating cycle, including the return from its last slot to its first
- **Planned fallow**: a fallow slot adds a full year of spacing before the next sensitive crop; it does not instantly clear the field or guarantee that every disease has disappeared
- **Rotation quality**: the planner gives a clear rating based on crop spacing, disease risk, sowing seasons and nitrogen benefits
- **Diversity pays**: a 2-crop plan can be rated good, but reaching excellent requires at least 3 crops. A plan using only one crop family remains poor
- **Tailored advice**: a detected outbreak takes priority, then the planner warns when the next crop returns too soon, before showing general advice for its crop family
- **Rotation overview**: fields sharing an identical plan are grouped into one card with combined area, rotation quality and residue

## Diseases

Nine diseases affect specific crops: sclerotinia, phoma, take-all, septoria, rust, fusarium, late blight, beet cyst nematode and clubroot.

### The rules

- **Only sensitive crops can be affected**: each disease has its own list of crops. A crop that is never infected adds no new disease to the field.
- **A first outbreak can happen on a clean field**: favourable weather raises the chance for weather-sensitive diseases. Rust and late blight never remain in the field after the crop.
- **A real outbreak can affect future crops**: after harvest, sclerotinia, phoma, take-all, septoria, fusarium, beet cyst nematode or clubroot can remain in the field. The more advanced the outbreak, the greater the risk when a sensitive crop returns.
- **The risk falls with time**: it drops once per calendar year. Beet cyst nematode and clubroot can become very weak, but they may remain in the field indefinitely.
- **Rotation reduces risk**: spacing sensitive crops gives the disease time to decline. The planner warns when a crop returns too soon. Crop-family diversity remains a separate rule, and cover crops receive no automatic disease bonus.

### From risk to damage

1. The Disease Risk map highlights fields where the current crop is more likely to become infected. Current weather can raise that chance further.
2. Once per period, the mod checks whether an outbreak starts while the crop is at a vulnerable growth stage.
3. A new infection starts at a low attack level and progresses each day. It remains hidden until it begins to damage the crop; before then, only the Disease Risk map and preventive advice can warn you that conditions are favourable.
4. Fungicide can prevent or slow supported diseases and protect sprayed crop, but it never restores destroyed crop or cleans a field that is already affected.
5. Harvest ends the active outbreak. A crop that was never infected adds nothing new to the field; even an infection harvested before visible damage may leave a low future risk.

## Treatments

Buyable fungicide (AMISTAR, Syngenta) and nematicide (VELUM PRIME, Bayer), sprayed with any compatible sprayer.

**Coverage matters for both products, and neither restores lost crop.** Fungicide lowers the chance of a supported outbreak and slows an active disease in proportion to coverage; sprayed crop is also protected from destruction. A smaller outbreak leaves less disease behind for future crops, but fungicide never cleans a field that is already affected. Nematicide protects sprayed crop from nematode damage but does not remove nematodes from the field. Spray early whenever possible. If a disease that uses fungicide is already active, fungicide can still slow it and protect the sprayed crop.

- **Fungicide**: consumed only on the ground actually harvested or mown, and cleared when the field is replanted or rotated
- **Nematicide**: three months in the soil per field, surviving harvest; reapplying renews the full duration
- **Take-all and clubroot have no product at all.** Only rotation keeps them in check

## Nitrogen Residue

Legumes destroyed by tillage (disc harrow / cultivator, not simple harvest) return nitrogen in two shares: the first to the next crop, the second carried over to the rotation after.

| Crop | First share | Second share |
| --- | --- | --- |
| Alfalfa | 80 kg N/ha | 50 kg N/ha |
| Vetch-rye | 60 kg N/ha | 20 kg N/ha |
| Clover | 50 kg N/ha | 20 kg N/ha |
| Soybean | 40 kg N/ha | 10 kg N/ha |
| Pea | 40 kg N/ha | 10 kg N/ha |
| Green bean | 20 kg N/ha | 5 kg N/ha |

Cover crops (oilseed radish, flowering catch crop) add an estimated flat +25 kg N/ha instead, reflected as an estimate in the planner. With Precision Farming, the residue is added directly to the nitrogen map; without it, the mod adds one vanilla fertilizer level regardless of the crop.

## Interface

- **Crop Rotation tab** in the InGame Menu (ESC), with Agronomy and Planning views
- **Field monitoring**: current crop, growth stage, required soil work, weeds, detected disease with its treatment, nitrogen and pH (Precision Farming's real maps when installed, vanilla fallback otherwise)
- **Disease map**: 3 toggle-able views on the existing in-game map (infected fields, disease risk, treated-ground coverage). The infected-fields view follows the game's colour-blind setting
- **On-foot HUD**: rotation history and detected disease under your feet, plus a treatment line when standing on protected ground
- **Weather forecast card**: the menu header shows the next relevant weather event so you can time your spraying
- **Full multiplayer sync**: server-authoritative history, plans, detected disease and remaining field risk; debounced broadcast, full sync on menu open or join, server-side validation of client plan edits, savegame persistence
- **27 languages**

## Installation

### From ModHub

Search for "Realistic Crop Rotation" on the official [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

### Manual

1. Place the downloaded `FS25_RealisticCropRotation.zip` file into your FS25 `mods/` directory (do not extract)
2. Activate the mod in mod selection
3. Access via the dedicated "Crop Rotation" tab in the InGame Menu (ESC)

## Usage

### Planning a rotation

1. InGame Menu (ESC) > **Crop Rotation** tab > **Planning**
2. Select a field in the sidebar to see its plan and rotation quality
3. Pick a year slot and assign a crop or fallow year, and optionally a cover crop, from the calendar
4. Follow the per-field advice to avoid family and disease return-interval penalties

### Managing disease risk

1. Open the **Diseases** map to distinguish detected outbreaks from fields where the current crop is at risk
2. Use the planner's complete repeating cycle to keep sensitive crops apart; its last slot is always checked against its first
3. Watch the weather because some diseases can still start on a field that has never been affected
4. Spray early: treatment can prevent or slow damage, but it never repairs destroyed crop or cleans an already affected field
5. After harvest, wait before bringing a sensitive crop back so any disease left in the field has time to decline

## Console Commands

Testing and admin tools registered by the mod. They run on the server; typed on a client they are relayed to the server, and only a master user is accepted.

| Command | Description |
| --- | --- |
| `rcrDisease [farmlandId]` | Prints active disease, remaining field risk and treatment coverage |
| `rcrDiseaseInfect <farmlandId> <group> [attackLevel]` | Forces an infection |
| `rcrDiseaseTick [farmlandId]` | Runs one cycle: infection roll, then progression |
| `rcrDiseaseClear [farmlandId]` | Clears active disease and any remaining field risk |

Valid `<group>` values: `SCLEROTINIA`, `PHOMA`, `TAKEALL`, `SEPTORIA`, `RUST`, `FUSARIUM`, `LATEBLIGHT`, `BCN`, `CLUBROOT`.

## Changelog

### v1.0.0.0

- Initial release

## Support

* [GitHub Issues](https://github.com/Squallqt/FS25_RealisticCropRotation/issues)
* [GitHub Discussions](https://github.com/Squallqt/FS25_RealisticCropRotation/discussions)

## License

Copyright © 2026 Squallqt. All rights reserved.

This project is proprietary software and is not distributed under an
open-source license.

Downloading an official release for private use with Farming Simulator 25 is
permitted. Copying, modifying, converting, redistributing, reuploading,
commercializing, or reusing any part of this project requires prior written
authorization.

See the [LICENSE](LICENSE) file for the complete terms.
