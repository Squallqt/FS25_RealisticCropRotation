# FS25_RealisticCropRotation

Crop rotation planning and disease simulation for Farming Simulator 25.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_RealisticCropRotation/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)
![Languages](https://img.shields.io/badge/languages-27-blue.svg)
[![License](https://img.shields.io/badge/license-proprietary-red.svg)](LICENSE)

Every field remembers its last 4 crops. Some outbreaks leave inoculum behind on that field, while seasonal diseases arrive from the surrounding region; favourable weather can then turn that background pressure into an infection that eats away part of the crop. Plan a repeating 2-, 3- or 4-year rotation from a dedicated in-game tab, get a grade based on real agronomy, and see the consequences before you sow.

Singleplayer and multiplayer, with or without Precision Farming.

## Planning

- **Crop history**: the last 4 crops of every field, recorded automatically
- **2- to 4-year rotation calendar**: plan with 2, 3 or 4 crops, plus an optional cover crop per year; the selected slots form the real repeating cycle, including the return from its last crop to its first
- **Rotation grade (0-100)**: family and disease-specific return intervals, winter/spring sowing alternation, the nitrogen a legume hands to the next cereal and planned nitrogen residue all weigh in
- **Diversity pays**: a 2-crop plan tops out at 75 ("good"), you need 3 crops or more to reach "excellent" (80). A single-family plan is capped at 30 ("poor")
- **Grade bands**: 0-19 bad, 20-39 poor, 40-59 fair, 60-79 good, 80-100 excellent
- **Tailored advice**: an active outbreak takes priority, then the planned next crop is checked against family and disease spacing, then generic per-family guidance
- **Rotation overview**: fields sharing an identical plan are grouped into one card with combined area, grade and residue

## Diseases

Nine generic disease groups, each tied to specific host crops: sclerotinia, phoma, take-all, septoria, rust, fusarium, late blight, beet cyst nematode, clubroot.

### Field reservoirs and seasonal exposure

| Source | Diseases | Behaviour |
| --- | --- | --- |
| **Field reservoir** | phoma, take-all, fusarium; secondarily septoria; persistent beet cyst nematode and clubroot | A completed outbreak can leave inoculum on that field in proportion to its final severity. Recent-residue reservoirs fade over calendar years; cyst nematode and clubroot persist much longer and rotation lowers their pressure without ever erasing it completely. |
| **Seasonal / regional exposure** | rust and late blight; primarily septoria | A host can be exposed even after a clean rotation. These groups receive no disease-specific spacing penalty in the planner; weather controls the immediate infection risk. |
| **Mixed** | sclerotinia | Both a field reservoir and regional exposure contribute. |

The planner still applies crop-family spacing independently. A cover crop carries no generic disease-break credit because its sanitary effect would depend on its actual species and the disease concerned.

### How an infection runs

1. **Background pressure**: the pressure map combines the field's stored inoculum with any seasonal or regional exposure while a host is standing. It is a background indicator before the current weather is applied, not the instantaneous probability of infection.
2. **The roll**: once per period, while the crop is inside its disease growth window, background pressure and the current weather decide whether an infection starts. You get an in-game notification naming the disease and the field.
3. **Incubation**: a latent period that burns down faster in warm weather and slower in cold, for every disease.
4. **Spread and destruction**: severity climbs daily and, past a per-disease threshold, destroys the crop in an irregular organic patch with a scattered, speckled edge. Severity only climbs while a living host carries it.
5. **After the crop**: reservoir-forming diseases leave a deposit based on their final severity. Stored pressure then decays by calendar year according to the disease; a non-host year reduces it but does not guarantee eradication.

Rain and the shared temperature response drive the weather-sensitive groups while each infection remains limited to its configured crop-growth window. Temperature also paces the initial incubation of every infection; soil-driven groups do not all react to rain. Pacing scales automatically with your save's season length.

## Treatments

Buyable fungicide (AMISTAR, Syngenta) and nematicide (VELUM PRIME, Bayer), sprayed with any compatible sprayer.

**Coverage matters for both products, and neither restores lost crop.** Fungicide lowers the field-wide chance of a fungal outbreak and slows an established infection in proportion to coverage; sprayed cells are also excluded from destruction. For reservoir-forming diseases, that lower final severity also means a smaller future deposit, but fungicide never erases inoculum already stored in the field. Nematicide protects treated cells from nematode destruction only: it does not reduce field-level severity or the cyst reservoir. Spray before, not after.

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
- **Disease map**: 3 toggle-able views on the existing in-game map (infected fields, background disease pressure before weather, treated-ground coverage), all colour-blind safe
- **On-foot HUD**: rotation history and active disease under your feet, plus a treatment line when standing on protected ground
- **Weather forecast card**: the menu header shows the next relevant weather event so you can time your spraying
- **Full multiplayer sync**: server-authoritative history, plans, active disease and field reservoirs; debounced broadcast, full sync on menu open or join, server-side validation of client plan edits, savegame persistence
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
2. Use the planner's repeating 2-, 3- or 4-year cycle to space diseases that are actually controlled by crop return intervals. The last slot is checked against the first as part of the same cycle
3. Accept that rust and late blight, and primarily septoria, can still appear on a clean rotation. Their seasonal exposure is not scored as a disease-spacing conflict; watch the weather. Fusarium can also arrive regionally, but infected cereal and maize residue still matters
4. Spray fungicide early on the crops you want to protect: where you spray, the disease rarely appears, and if it does show up, treating keeps it from spreading further there. It never heals what is already damaged, so spray before an outbreak, not after
5. The Treatment gauge in the Crop Rotation tab shows how much of the field is sprayed, whether the disease is absent, active or under control, and how long protection lasts
6. Harvesting ends the outbreak on the field and clears the fungicide; reservoir-forming diseases can leave inoculum based on their final severity, so the next sensitive crop can still be at risk. Nematicide protects sprayed ground for three months and a new spray renews it, without reducing the cyst reservoir
7. For take-all and clubroot, only non-host time and a suitable rotation lower pressure. Clubroot and cyst nematode reservoirs are never guaranteed to reach zero

## Console Commands

Testing and admin tools registered by the mod. They run on the server; typed on a client they are relayed to the server, and only a master user is accepted.

| Command | Description |
| --- | --- |
| `rcrDisease [farmlandId]` | Prints the full disease state: field reservoir, effective load, map pressure, band, active infections and treatment coverage |
| `rcrDiseaseInfect <farmlandId> <group> [severity]` | Forces an infection |
| `rcrDiseaseTick [farmlandId]` | Runs one cycle: infection roll, then progression |
| `rcrDiseaseClear [farmlandId]` | Clears active disease and the stored field reservoir |

Valid `<group>` values: `SCLEROTINIA`, `PHOMA`, `TAKEALL`, `SEPTORIA`, `RUST`, `FUSARIUM`, `LATEBLIGHT`, `BCN`, `CLUBROOT`.

## Configuration

`cropConfig.xml` drives the whole model without any Lua editing. Add a `<crop>` line to register a new crop, or tune a `<diseaseGroup>` to change planner relevance and return interval, reservoir class and persistence, infection window, weather response, regional exposure and destruction curve.

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
