# Guild router

A "set and forget," high-performance, lightweight World of Warcraft addon that routes guild chat, joins/leaves, member achievements, and roster changes into a single, dedicated chat tab.

## Why use this?

Stop losing track of your guild's activity in a flood of trade chat, raid alerts, and world messages. **GuildRouter** intercepts system messages that usually vanish beneath the flood and organizes them into a clean, readable stream.

While you can move standard guild chat to a new tab using default Blizzard settings, you lose the context of important events like achievements and roster changes. By default, these are mixed into your main chat frame where they rapidly get buried, especially on busy realms or during intense gaming.

## Key features

- **Dedicated routing:** automatically creates and manages a "Guild" chat tab
- **Intelligent class colouring:** all player names in join/leave, roster changes, and achievements are class-coloured
- **Interactive links:** player names are fully clickable for whispering, inviting, or inspecting
- **Roster change tracking:** captures promotions, demotions, and note changes (officer & public)
- **MOTD integration:** routes the guild message of the day to the tab upon login and update
- **Anti-spam engine:** uses monotonic game-time tracking to de-duplicate rapid-fire system messages
- **Performance:** built with localized globals and memory-efficient string escaping to ensure zero impact on your FPS
- **Efficiency:** consumes ~80KB for a 1,000 player guild and only fires on system events

## Installation

1. Move/copy the `GuildRouter` folder to your `_retail_/Interface/AddOns/` or `_classic_/Interface/AddOns/` directory
2. Restart World of Warcraft or logout and login

## Configuration

This addon works out of the box. Upon loading, it will check for a chat tab named **"Guild"**. If it doesn't find one, it will be created and populated with Guild, Officer, Guild announcement, and Blizzard system channels.

### Debug

Debug mode can be anabled by typing `/grdebug` into your console (chat message box), repeat to disable. When enabled any unhandled CHAT_MSG_SYSTEM message (eg Blizzard adds a new Guild message event) will be printed to your main chat frame e.g.:

```text
[GR Debug] Unhandled system message: Arcette has sold the guild and moved to Far North Queensland.
```

## Technical details

- **System messages:** intercepts, formats and routes guild and related `system` messages
- **Monotonic timing:** uses `GetTime()` instead of system clock to ensure anti-spam reliability during clock syncs or DST changes
- **Pattern robustness:** uses `gsub` realm-stripping to ensure compatibility with hyphenated names on international realms
- **Deterministic logic:** sequential pattern matching to ensure complex roster changes (like note updates) are captured with 100% accuracy
- **Lookups:** caches the Guild roster for performance

## <a name='Contributing'></a>Contributing

Contributions to improve this tool are welcome! To contribute:

1. Fork the repository
2. Create a feature branch
3. Make your changes to the source code or documentation
4. Test with sample data and various input scenarios
5. Submit a pull request with a clear description of the improvements

Please ensure your changes maintain compatibility with existing variable formats and follow Lua best practices.

## <a name='Support'></a>Support

This tool is unsupported and may cause objects in mirrors to be closer than they appear etc. Batteries not included.

## <a name='License'></a>License

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses>.

Copyright (C) 2026 Arc NineOhNine
