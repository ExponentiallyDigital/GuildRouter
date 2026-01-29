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
- **Performance:** built with localised globals and memory-efficient string escaping to ensure zero impact on your FPS
- **Efficiency:** consumes ~80KB for a 1,000 player guild, listens and only fires on system events
- **Privacy:** all routed messages respect the data source, you can't see more than allowed eg officer chat restricted per Blizzard config

## Installation

1. Move/copy the `GuildRouter` folder to your `_retail_/Interface/AddOns/` or `_classic_/Interface/AddOns/` directory
2. Restart World of Warcraft or logout and login

## Configuration

This addon works out of the box. Upon loading, it will check for a chat tab named **"Guild"**. If it doesn't find one, it will be created and populated with Guild, Officer, Guild announcement, and Blizzard system channels.

If you are using ElvUi, you may need to drag the ‘Guild’ tab once to your preferred position. After that, if you ever delete or need to reset the tab, you can use /grreset and it should retain the previous ordering sequence.

## Command Line Options

GuildRouter provides several slash commands to manage the Guild tab, debug routing, test events, and control presence announcements. None are needed for installation or operation.

`/grhelp` Displays a list of all available GuildRouter commands.

`/grstatus short | full` Display detailed status information, defaults to short unless `full` specified.

`/grreset` Recreates the existing Guild chat tab with the correct message groups and safe docking. Use this if the tab disappears, becomes undocked, or is misconfigured.

`/grdelete` Deletes the existing Guild chat tab (if present). NB there is NO confirmation, it just gets deleted.

`/grfix` Repairs the Guild tab’s message groups and re‑docks it safely. This does not delete the tab, it simply restores the correct configuration.

`/grdock` Forces the Guild tab to dock to the main chat frame using the safe ElvUI‑compatible docking method. Use this if the tab is floating, hidden, or not visible.

`/grsources` Display the message groups currently assigned to the Guild tab. This uses Blizzard’s official API and works correctly under both Blizzard UI and ElvUI.

`/grnames` Display the name cache pairs.

`/grdebug` Toggles debug mode. When enabled, GuildRouter prints any system messages it did not handle to your main chat frame. This can be useful for identifying new message patterns, and helps diagnose routing issues e.g.:

```text
[GR Debug] Unhandled system message: LeeroyJenkins has sold the guild and moved to Blackrock Mountain.
```

`/grtest` Simulates guild‑related events for testing.

Examples:

```text
/grtest join
/grtest leave
/grtest promote
/grtest demote
/grtest note
/grtest ach
```

These allow you to verify formatting, clickable names, class colours, and routing without needing real guild activity.

`/grpresence` Controls login/logout announcements routed to the Guild tab. GuildRouter supports four presence modes:

- `/grpresence guild-only` (Default) Only guild members’ login/logout messages are routed to the Guild tab. Everyone else (friends, party members, strangers) is ignored.

- `/grpresence all` Routes all login/logout announcements to the Guild tab, regardless of guild membership.

- `/grpresence off` Disables presence announcements entirely.

- `/grpresence trace` Toggles presence trace mode. When enabled, GuildRouter prints detailed trace output showing whether a presence event was routed or ignored, why it was ignored (e.g., not a guild member, mode=off), and the exact message Blizzard fired which is useful for debugging presence behaviour.

### SavedVariables

GuildRouter stores presence settings in `GuildRouterDB`. The following values persist across sessions:

`presenceMode` — `guild-only`, `all`, or `off`

`presenceTrace` — `true` or `false`

Defaults on first install:

- presenceMode = "guild-only"
- presenceTrace = false

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
