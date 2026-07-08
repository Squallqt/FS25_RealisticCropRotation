# FS25_RealisticCropRotation

Crop rotation planning and disease simulation for Farming Simulator 25.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_RealisticCropRotation/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
[![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)](#)
[![Languages](https://img.shields.io/badge/languages-27-blue.svg)](#)

Track every field's crop history, plan the next four crops from a dedicated in-game tab, and get a rotation grade based on real agronomy. Bring a host crop back too soon and nine realistic soil- and weather-driven diseases can take hold and spread. Available in singleplayer and multiplayer.

## Features

- **Crop history tracking** per field, with a 4-crop rotation planning tab in the in-game menu
- **Field monitoring**: current crop, growth stage, soil condition, weeds, nitrogen and pH for every field
- **Rotation quality grading**: family return intervals, disease-specific return intervals, legume nitrogen handoff and crop diversity, with a tailored recommendation per field
- **Nitrogen residue**: a legume destroyed by tillage returns nitrogen in two shares, the first to the next crop and the second to the rotation after
- **9 realistic diseases** (sclerotinia, phoma, take-all, septoria, rust, fusarium head blight, late blight, beet cyst nematode, clubroot), each tied to specific host crops
- **Rotation-driven infection risk and speed**: heavier soil inoculum from a poor rotation raises the odds of infection and, once a field is infected, how fast the disease spreads
- **Weather-driven risk**: rain and temperature both modulate fungal disease pressure, each disease with its own favourable temperature window
- **Temperature-paced incubation**: a new infection stays latent before doing damage, shorter in warm weather and longer in cold weather
- **Organic, progressive destruction**: an infected crop is destroyed in an irregular patch that spreads over the following days, with a scattered, speckled transition edge
- **Season-length aware**: disease progression speed automatically scales with the save's days-per-period setting, so pacing is consistent on short or long seasons
- **Sprayer treatment**: buyable fungicide (AMISTAR) and nematicide (VELUM PRIME) products cure active infections and shield treated ground from future ones; take-all and clubroot have no chemical treatment and must be managed agronomically
- **Disease pressure map**: infected fields and pressure level shown on the in-game map and field advice
- **Full multiplayer sync**: server-authoritative disease state and destruction, savegame persistence
- **27 languages** supported

## Installation

### From ModHub
Search for "Realistic Crop Rotation" on the official [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

### Manual
1. Place the downloaded `FS25_RealisticCropRotation.zip` file into your FS25 `mods/` directory (do not extract)
2. Activate the mod in mod selection
3. Access via the dedicated tab in the InGame Menu (ESC)

## Usage

### Planning a Rotation
1. InGame Menu (ESC) > Realistic Crop Rotation tab
2. Select a field to see its crop history and current grade
3. Plan the next four crops from the calendar view
4. Follow the per-field recommendation to avoid family and disease return-interval penalties

### Managing Disease Risk
1. Check the disease pressure map for infected or at-risk fields
2. Space host crops far enough apart in your rotation plan to keep soil inoculum low
3. Treat active fungal infections with a fungicide sprayer (AMISTAR), or the beet cyst nematode with a nematicide sprayer (VELUM PRIME)
4. For take-all and clubroot, rely on a non-host crop, a resistant variety, liming and a long enough rotation
5. Harvest what remains after an infection and avoid returning a susceptible host until rotation decay lowers soil pressure

## Changelog

### v1.0.0.0
- Initial release

## Support

- **Issues & suggestions**: [GitHub Issues](https://github.com/Squallqt/FS25_RealisticCropRotation/issues)

## License

All Rights Reserved © 2026 Squallqt. Not affiliated with or endorsed by GIANTS Software GmbH.
