# Guild router

A "set and forget," high-performance, lightweight World of Warcraft addon that routes guild chat, joins/leaves, member achievements, and roster changes into a single, dedicated chat tab.

## Why use this?

Stop losing track of your guild's activity in a flood of trade chat, raid alerts, and world messages. **GuildRouter** intercepts system messages that usually vanish beneath the flood and organizes them into a clean, readable stream.

While you can move standard guild chat to a new tab using default Blizzard settings, you lose the context of important events like achievements and roster changes. By default, these are mixed into your main chat frame where they rapidly get buried, especially on busy realms or during intense gaming.

## Key features

- **dedicated routing:** automatically creates and manages a "Guild" chat tab
- **intelligent class colouring:** all player names in join/leave, roster changes, and achievements are class-coloured
- **interactive links:** player names are fully clickable for whispering, inviting, or inspecting
- **roster change tracking:** captures promotions, demotions, and note changes (officer & public)
- **MOTD integration:** routes the guild message of the day to the tab upon login and update
- **anti-spam engine:** uses monotonic game-time tracking to de-duplicate rapid-fire system messages
- **performance:** built with localized globals and memory-efficient string escaping to ensure zero impact on your FPS
- **efficiency:** consumes ~80KB for a 1,000 player guild and only fires on system events

## Installation

1. move/copy the `GuildRouter` folder to your `_retail_/Interface/AddOns/` or `_classic_/Interface/AddOns/` directory
2. restart World of Warcraft or logout and login

## Configuration

The addon works out of the box. Upon loading, it will check for a chat tab named **"Guild"**. if it doesn't find one, it will create it and lock it automatically.

## Technical details

- **system messages:** intercepts, formats and routes guild and related `system` messages
- **monotonic timing:** uses `GetTime()` instead of system clock to ensure anti-spam reliability during clock syncs or DST changes
- **pattern robustness:** uses `gsub` realm-stripping to ensure compatibility with hyphenated names on international realms
- **deterministic logic:** sequential pattern matching to ensure complex roster changes (like note updates) are captured with 100% accuracy
- **lookups:** caches the Guild roster for performance

---

_created by Arc Nineohnine_
