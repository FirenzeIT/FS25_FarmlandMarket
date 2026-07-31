# Farmland Market

Makes farmland acquisition more realistic and strategic. Field prices reflect their actual crop value, and not all fields are always available for purchase.

In vanilla FS25, all unowned farmlands are always available at a static price - even fields with harvest-ready crops that can be immediately sold for profit. Farmland Market adds dynamic pricing based on crop value, limits which fields are for sale at any given time, introduces multi-round negotiation for buying and selling, and color-codes the map so you can see availability at a glance.

## Features

- **Negotiation system** - buy and sell farmland through multi-round offers and counter-offers instead of instant transactions, with independent toggles for purchases, sales, and unlisted offers
- **Crop-value adjusted pricing** - field price includes estimated harvest value based on current growth state, crop type, and market prices
- **Limited field availability** - only a subset of fields are for sale at any time, rotating daily with seasonal variation (more listings Nov-Mar)
- **Five difficulty presets** - Easy, Normal, Hard, Harder, and Realistic - or turn availability off entirely
- **Adjustable base price per hectare** - set a custom base farmland price per hectare from the settings
- **Watchlist** - track farmlands you are interested in and get notified when a watched farmland goes up for sale or its negotiation cooldown ends; persists across save/load and isolates per-farm in multiplayer
- **Map color coding** - for-sale and not-for-sale fields are color-coded on the farmland map with a matching legend, with a color-blind palette that activates when the game's color-blind mode is enabled
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
- Open **Game Settings** to configure the availability preset, base price per hectare, and negotiation settings (purchases, sales, and unlisted offers can be toggled independently)
- To buy a field, select it on the map and click **"Make offer"** to start negotiating
- To sell a field you own, select it and click **"Negotiate sale"** to receive offers
- Check the **farmland map** to see which fields are currently for sale (green) or not for sale (red)
- Open the **Watchlist** from the Farmlands subcategory on the map; toggle entries with **"Add to watchlist"** / **"Remove from watchlist"** in the farmland action menu


## Compatibility

- **Game Version**: Farming Simulator 25
- **Multiplayer**: Supported
- **Platform**: PC (Windows/macOS)
- **Maps**: Any map

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full changelog.

## License

This mod is provided as-is for personal use.

## Credits

- **Author**: [Ritter](https://github.com/rittermod)

## Support

[Open an issue](https://github.com/rittermod/FS25_FarmlandMarket/issues)
