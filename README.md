# FS25_RealisticCropRotation

Crop rotation planning and disease simulation for Farming Simulator 25.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_RealisticCropRotation/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)
![Languages](https://img.shields.io/badge/languages-27-blue.svg)

Every field remembers its last 4 crops. Bring a host crop back too soon and the disease builds up in the soil, until the right weather triggers an infection that eats away part of the field. Plan your rotation on a repeating 4-year calendar from a dedicated in-game tab, get a grade based on real agronomy, and see the consequences before you sow.

Singleplayer and multiplayer, with or without Precision Farming.

## Planning

- **Crop history**: the last 4 crops of every field, recorded automatically
- **4-year rotation calendar**: plan with 2, 3 or 4 crops, plus an optional cover crop per year
- **Rotation grade (0-100)**: family and disease-specific return intervals, the nitrogen a legume hands to the next cereal, crop diversity and planned nitrogen residue all weigh in
- **Diversity pays**: a 2-crop plan tops out at 50 ("fair"), you need 3 crops or more to reach "good" (60), and nitrogen returned by a legume or a cover crop to reach "excellent" (80). A single-family plan is capped at 30 ("poor")
- **Grade bands**: 0-19 bad, 20-39 poor, 40-59 fair, 60-79 good, 80-100 excellent
- **Tailored advice**: an active outbreak takes priority, then the planned next crop is checked against family and disease spacing, then generic per-family guidance
- **Rotation overview**: fields sharing an identical plan are grouped into one card with combined area, grade and residue

## Diseases

Nine diseases, each tied to specific host crops: sclerotinia, phoma, take-all, septoria, rust, fusarium head blight, late blight, beet cyst nematode, clubroot.

### Two families that behave differently

| | Diseases | Behaviour |
| --- | --- | --- |
| **Soil diseases** | take-all, clubroot, beet cyst nematode, sclerotinia, phoma | They survive in the ground between crops. A long enough rotation clears them completely. This is what rotation rewards you for. |
| **Wind-carried diseases** | rust, septoria, late blight, fusarium | Spores drift in from the whole region. They can strike even a perfect rotation, and the weather decides, not your plan. |

Each disease carries an `ambient` value in `cropConfig.xml`: the baseline the wind keeps supplying, which no rotation can clear. It is `0.00` for the soil group, so a clean rotation still wipes those out entirely.

### How an infection runs

1. **Soil pressure builds**: a host crop leaves its own disease behind and multiplies whatever the soil still carries, so the shorter the return interval, the higher the peak. Host-free years decay it toward zero.
2. **The roll**: once per period, while the crop is inside its disease growth window, soil pressure and the current weather decide whether an infection starts. You get an in-game notification naming the disease and the field.
3. **Incubation**: a latent period that burns down faster in warm weather and slower in cold, for every disease.
4. **Spread and destruction**: severity climbs daily and, past a per-disease threshold, destroys the crop in an irregular organic patch with a scattered, speckled edge. Severity only climbs while a living host carries it.

Rain and temperature drive both the onset and the daily spread of the seven fungal diseases, each with its own favourable temperature window. The nematode and clubroot ignore rain. Pacing scales automatically with your save's season length.

## Treatments

Buyable fungicide (AMISTAR, Syngenta) and nematicide (VELUM PRIME, Bayer), sprayed with any compatible sprayer.

**Both are preventive.** They save the yield on sprayed ground by excluding those cells from destruction. They do not stop an infection from starting, do not reduce severity and do not push an established infection back. Spray before, not after.

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
- **Field monitoring**: current crop, growth stage, required soil work, weeds, active disease with its treatment, nitrogen and pH (Precision Farming's real maps when installed, vanilla fallback otherwise)
- **Disease map**: 3 toggle-able views on the existing in-game map (infected fields, disease pressure forecast, treated-ground coverage), all colour-blind safe
- **On-foot HUD**: rotation history and active disease under your feet, plus a treatment line when standing on protected ground
- **Weather forecast card**: the menu header shows the next relevant weather event so you can time your spraying
- **Full multiplayer sync**: server-authoritative history, plans and disease state; debounced broadcast, full sync on menu open or join, server-side validation of client plan edits, savegame persistence
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
2. Select a field in the sidebar to see its plan and rotation grade
3. Pick a year slot and assign a crop, and optionally a cover crop, from the calendar
4. Follow the per-field advice to avoid family and disease return-interval penalties

### Managing disease risk

1. Open the in-game Map and switch to the **Diseases** view to check infected fields and the pressure forecast
2. Space host crops far enough apart to keep soil pressure low. This works fully against the soil group
3. Accept that rust, septoria, late blight and fusarium can still appear on a clean rotation. Watch the weather rather than the rotation for those
4. Spray preventively on crops you want to protect. Treating after the destruction has started saves only what is still standing
5. Harvesting or mowing removes fungicide protection from the cut area; nematicide stays in the soil for three months and a new application renews it
6. For take-all and clubroot, only a non-host crop and a long enough rotation help

## Console Commands

Testing and admin tools registered by the mod. They run on the server; typed on a client they are relayed to the server, and only a master user is accepted.

| Command | Description |
| --- | --- |
| `rcrDisease [farmlandId]` | Prints the full disease state: soil load, map pressure, band, active infections and treatment coverage |
| `rcrDiseaseInfect <farmlandId> <group> [severity]` | Forces an infection |
| `rcrDiseaseTick [farmlandId]` | Runs one cycle: infection roll, then progression |
| `rcrDiseaseClear [farmlandId]` | Clears disease state |

Valid `<group>` values: `SCLEROTINIA`, `PHOMA`, `TAKEALL`, `SEPTORIA`, `RUST`, `FUSARIUM`, `LATEBLIGHT`, `BCN`, `CLUBROOT`.

## Configuration

`cropConfig.xml` drives the whole model without any Lua editing. Add a `<crop>` line to register a new crop, or tune a `<diseaseGroup>` to change a disease's return interval, infection window, weather sensitivity, ambient floor and destruction curve.

## Changelog

### v1.0.0.0

- Initial release

## Support

- **Issues & suggestions**: [GitHub Issues](https://github.com/Squallqt/FS25_RealisticCropRotation/issues)

## License

All Rights Reserved © 2026 Squallqt. Not affiliated with or endorsed by GIANTS Software GmbH.
