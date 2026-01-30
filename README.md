# Guild router

A "set and forget," high-performance, lightweight World of Warcraft addon that routes guild chat, joins/leaves, member achievements, and roster changes into a single, dedicated chat tab.

## Why use this?

**TL;DR** - be better connected with your guild.

Stop losing track of your guild's activity in a flood of trade chat, raid alerts, and world messages. **GuildRouter** intercepts system messages that usually vanish beneath the flood and organises them into a clean, readable stream.

While you can move standard guild chat to a new tab using default Blizzard settings, you lose the context of important events like achievements and roster changes. By default, these are mixed into your main chat frame where they rapidly get buried, especially on busy realms or during intense gaming.

## Key features

- **set and forget:** install as with any other addon but **no** configuration is required
- **Dedicated routing:** automatically creates and manages a "Guild" chat tab
- **Intelligent class colouring:** all player names in join/leave, roster changes, and achievements are class-coloured
- **Interactive links:** player names are fully clickable for whispering, inviting, or inspecting
- **Roster change tracking:** captures promotions, demotions, and note changes (officer & public)
- **MOTD integration:** routes the guild message of the day to the tab upon login and update
- **Anti-spam engine:** uses monotonic game-time tracking to de-duplicate rapid-fire system messages
- **Performance:** built with active name caching, localized globals, and inlined pattern escaping to ensure zero impact on your FPS
- **Efficiency:** consumes trivial memory (~230KB with a 750 player guild), only fires on system events
- **Privacy:** all routed messages respect the data source, you can't see more than allowed e.g. officer chat restricted per Guild config

## Installation

1. Move/copy the `GuildRouter` folder to your `_retail_/Interface/AddOns/` or `_classic_/Interface/AddOns/` directory
2. Restart World of Warcraft or logout and login

## Configuration

This addon works out of the box. Upon loading, it will check for a chat tab named **"Guild"**. If it doesn't find one, it will be created and populated with Guild, Officer, Guild announcement, and Blizzard system channels.

If you are using ElvUi, you may need to drag the ‘Guild’ tab once to your preferred position. After that, if you ever delete or need to reset the tab, you can use /grreset and it should retain the previous ordering sequence.

## Command Line Options

GuildRouter provides several slash commands to manage the Guild tab, control presence announcements, and test events. None are required for normal operation.

`/grhelp` Displays available GuildRouter commands.

`/grpresence [mode]` Controls login/logout announcements. Modes: `guild-only` (default), `all`, `off`, or `trace` (debug).

`/grstatus [full]` Display status (compact by default, full for detailed info).

`/grreset` Recreates the Guild tab with correct configuration and docking.

`/grdelete` Deletes the Guild tab (no confirmation).

`/grfix` Repairs the Guild tab's configuration and docking.

`/grdock` Forces the Guild tab to dock.

`/grsources` Displays message groups assigned to the Guild tab.

`/grtest [event]` Simulates guild events: `join`, `leave`, `promote`, `demote`, `note`, `ach`.

`/grforceroster` Force guild roster acquisition.

`/grnames` Display cached player→realm mappings.

`/grdbg` Display cache statistics.

### SavedVariables

GuildRouter stores presence settings in `GuildRouterDB`. The following values persist across sessions:

`presenceMode` — `guild-only`, `all`, or `off`

`presenceTrace` — `true` or `false`

Defaults on first install:

- presenceMode = "guild-only"
- presenceTrace = false

Don't edit the SavedVariables file, this is updated/read by the addon.

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

Please ensure your changes maintain compatibility with existing variable formats and follows Lua best practices.

## <a name='Support'></a>Support

This tool is unsupported and may cause objects in mirrors to be closer than they appear etc. Batteries not included.

## <a name='License'></a>License

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses>.

Copyright (C) 2026 ArcNineOhNine
