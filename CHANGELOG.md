# Changelog

## 0.4.0.2 (Beta):
- Fixed sell negotiation exploit where inflated listing prices bypassed NPC market value cap
- Added listing price validation: cannot exceed twice the market value
- Clamped NPC opening bid to market-value ceiling in negotiation engine

## 0.4.0.1 (Beta):
- Fixed keyboard navigation not reaching Farmland Market settings in Game Settings
- Fixed negotiation toggle (BinaryOption) visual glitch where slider was misaligned

## 0.4.0.0 (Beta)
- Added dedicated negotiation dialog with offer history, field details, and action buttons
- Added seller names in negotiation messages for clearer context
- Improved cooldown messages to show remaining time in months
- Promoted from Alpha to Beta

## 0.3.0.0 (Alpha)
- Added negotiation system - buy and sell farmland through multi-round offers and counter-offers
- Added "Make offer" and "Negotiate sale" buttons replacing instant buy/sell
- Added negotiation cooldown per field to prevent repeated attempts
- Added negotiation toggle in Game Settings
- Added context box showing list price for listed fields and market value for owned fields
- Added multiplayer locking to prevent simultaneous negotiations on the same field
- Fixed farmland price leaking through "Not for sale" when Precision Farming is active

## 0.2.0.0 (Alpha)
- Added field availability system - not all fields are for sale at all times
- Added five difficulty presets: Easy, Normal, Hard, Harder, Realistic (or off)
- Added seasonal market variation - more fields listed Nov-Mar
- Added map color coding for available and unavailable fields
- Added farmland legend showing For Sale, Not For Sale, and My Farm
- Added base price multiplier setting (replaces fixed base price)
- Added settings to Game Settings menu (availability preset and price multiplier)
- Added multiplayer sync for all settings and availability state
- Price multiplier tooltip now shows the map's base price per hectare

## 0.1.0.0 (Alpha)
- Initial release
- Farmland prices now include estimated crop value
- Configurable base price per hectare
