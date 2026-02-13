# Farmland Market

> [!WARNING] 
> **EARLY ALPHA - USE AT YOUR OWN RISK.** This mod is under active development and may contain bugs, cause unexpected behavior, or corrupt save data. Do not use on a savegame you care about. Back up your save before installing.

Makes farmland acquisition more realistic and strategic. Field prices reflect their actual crop value, and not all fields are always available for purchase.

In vanilla FS25, all unowned farmlands are always available at a static price - even fields with harvest-ready crops that can be immediately sold for profit. Farmland Market adds dynamic pricing based on crop value, limits which fields are for sale at any given time, and color-codes the map so you can see availability at a glance.

## Features

- **Crop-value adjusted pricing** - field price includes estimated harvest value based on current growth state, crop type, and market prices
- **Limited field availability** - only a subset of fields are for sale at any time, rotating daily with seasonal variation (more listings Nov-Mar)
- **Five difficulty presets** - Easy, Normal, Hard, Harder, and Realistic - or turn availability off entirely
- **Base price multiplier** - adjust the map's base farmland price per hectare from the settings
- **Map color coding** - for-sale and not-for-sale fields are color-coded on the farmland map with a matching legend
- **Game Settings integration** - all settings accessible from the in-game settings menu

## Installation

### From GitHub Releases
1. Download the latest release ZIP
2. Place the ZIP in your mods folder:
   - **Windows**: `Documents/My Games/FarmingSimulator2025/mods/`
   - **macOS**: `~/Library/Application Support/FarmingSimulator2025/mods/`
3. Enable the mod in-game

### Manual Installation
1. Clone this repository
2. Copy the folder to your mods folder
3. Enable the mod in-game

## Usage

- Farmland prices automatically adjust to include crop value - fields with harvest-ready crops cost more than empty fields
- Open **Game Settings** to configure the availability preset and base price multiplier
- Check the **farmland map** to see which fields are currently for sale (green) or not for sale (red)


## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported
- **Platform**: PC (Windows/macOS)
- **Maps**: Works with any map

## Changelog

### 0.2.0.0 (Alpha):
- Added field availability system - not all fields are for sale at all times
- Added five difficulty presets: Easy, Normal, Hard, Harder, Realistic (or off)
- Added seasonal market variation - more fields listed Nov-Mar
- Added map color coding for available and unavailable fields
- Added farmland legend showing For Sale, Not For Sale, and My Farm
- Added base price multiplier setting (replaces fixed base price)
- Added settings to Game Settings menu (availability preset and price multiplier)
- Added multiplayer sync for all settings and availability state
- Price multiplier tooltip now shows the map's base price per hectare

### 0.1.0.0 (Alpha):
- Initial release
- Farmland prices now include estimated crop value
- Configurable base price per hectare

## License

This mod is provided as-is for personal use.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

[Open an issue](https://github.com/rittermod/FS25_FarmlandMarket/issues)
