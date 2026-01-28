# Guild Router

A "set and forget," high-performance, lightweight World of Warcraft addon that routes guild chat, joins/leaves, member achievements, and roster changes into a single, dedicated chat tab.

## Why use this?

Stop losing track of your guild's activity in a flood of trade chat, raid alerts, and world messages.

While you can move standard guild chat to a new tab using default Blizzard settings, you lose the context of important entries like achievements and roster changes. By default, these are mixed into your main chat frame where they rapidly get buried—especially on busy realms or during intense raiding. Guild Router keeps your guild's history in one place, formatted, colored, and easy to read.

## Overview

**Guild Router** intercepts system messages that usually vanish in the sea of trade chat or combat logs and organizes them into a clean, readable stream. It focuses on roster transparency, making it easy to see who is joining, leaving, or being promoted at a glance.

## Key Features

- **Dedicated Routing:** Automatically creates and manages a "Guild" chat tab.
- **Intelligent Class Coloring:** All player names in join/leave, roster changes, and achievements are class-colored based on the current guild roster.
- **Interactive Links:** Player names are fully clickable for whispering, inviting, or inspecting.
- **Roster Change Tracking:** Captures promotions, demotions, and note changes (Officer & Public).
- **MOTD Integration:** Routes the Guild Message of the Day to the tab upon login and update.
- **Anti-Spam Engine:** Uses monotonic game-time tracking to de-duplicate rapid-fire system messages.
- **Performance:** Built with localized globals and memory-efficient string escaping to ensure zero impact on your FPS
- **Efficiency:** Consumes ~80KB for a 1,000 player guild and only fires on system events

## Technical Details

Unlike generic chat filters, GuildRouter uses:

- **Monotonic Timing:** Uses `GetTime()` instead of system clock to ensure anti-spam reliability during clock syncs or DST changes.
- **Pattern Robustness:** Uses `gsub` realm-stripping to ensure compatibility with hyphenated names on international realms.
- **Deterministic Logic:** Sequential pattern matching to ensure complex roster changes (like note updates) are captured with 100% accuracy.

## Installation

1. Download the `GuildRouter` folder.
2. Move/copy it to your `_retail_/Interface/AddOns/` or `_classic_/Interface/AddOns/` directory.
3. Restart World of Warcraft or logout and login.

## Configuration

The addon works out of the box. Upon loading, it will check for a chat tab named **"Guild"**. If it doesn't find one, it will create it and lock it automatically.

---

_Developed by Arc NineOhNine_
