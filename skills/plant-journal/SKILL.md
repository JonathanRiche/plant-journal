---
name: plant-journal
description: Build, run, and extend the plant-journal Zig CLI for tracking plant watering in SQLite. Use when working on this repository, adding plant care features, debugging the SQLite schema or XDG data path logic, or using the CLI to record watering history.
---

# Plant Journal

This skill covers the `plant-journal` Zig CLI in this repository.

## When to Use This Skill

Use this skill when:

- You need to run or modify the `plant-journal` CLI.
- You are adding plant-tracking features such as watering, schedules, notes, or care metadata.
- You need to debug the SQLite schema, persisted data, or per-user data directory behavior.
- You want to verify command behavior with `zig build run -- ...`.

## Repository Layout

- `src/main.zig`: Main CLI, argument parsing, schema creation, date handling, and command output.
- `build.zig`: Zig build configuration, including the `zqlite` dependency and `sqlite3` linkage.
- `build.zig.zon`: Zig package manifest.

## Current CLI Surface

The current commands are:

```bash
zig build run -- help
zig build run -- add <name> --interval-days <days> [--species <text>] [--notes <text>] [--last-watered <YYYY-MM-DD|today>]
zig build run -- water <name> [--date <YYYY-MM-DD|today>] [--interval-days <days>] [--notes <text>]
zig build run -- list
zig build run -- show <name>
```

After `zig build`, the installed binary is:

```bash
./zig-out/bin/plant-journal
```

## Data Storage

The CLI stores data in SQLite and resolves the database path in this order:

1. `$PLANT_JOURNAL_DB`
2. `$XDG_DATA_HOME/plant-journal/plant-journal.sqlite3`
3. `$HOME/.local/share/plant-journal/plant-journal.sqlite3`

Use a temporary database path for smoke tests:

```bash
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- list
```

## Current Schema

The tool currently manages:

- `plants`: name, species, notes, watering interval, last watered date, next watering date, timestamps
- `watering_events`: one row per watering event, linked to a plant

Dates are stored as whole day offsets from `1970-01-01`. User input accepts `YYYY-MM-DD` and `today`.

## Development Workflow

1. Read `src/main.zig` before changing behavior; command parsing, database writes, and date logic are all there.
2. Use `zigdoc` for Zig stdlib and dependency APIs instead of guessing.
3. Run formatting and tests after edits:

```bash
zig fmt src/main.zig build.zig
zig build test
```

4. Smoke-test with a temporary database:

```bash
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- add pothos --interval-days 7 --last-watered today
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- water pothos --notes "top soil dry"
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- list
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- show pothos
```

## Implementation Notes

- The project uses `zqlite` as a thin SQLite wrapper and links against system `sqlite3`.
- Keep schema changes backward-compatible when possible; the database is initialized in `ensureSchema`.
- If you return text from SQLite rows, copy it before the row is finalized.
- Follow the repository Zig conventions from `AGENTS.md`: explicit allocators, concise functions, and `zigdoc` for API discovery.
