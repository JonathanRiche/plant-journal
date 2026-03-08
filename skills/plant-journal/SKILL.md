---
name: plant-journal
description: Build, run, and extend the plant-journal Zig CLI for tracking plant care in SQLite. Use when working on this repository, adding plant metadata or care-event features, debugging schema or import/export behavior, or using the CLI to record watering and other plant maintenance history.
---

# Plant Journal

This skill covers the `plant-journal` Zig CLI in this repository.

## When to Use This Skill

Use this skill when:

- You need to run or modify the `plant-journal` CLI.
- You are adding plant-tracking features such as watering, fertilizing, repotting, schedules, notes, archive states, or care metadata.
- You need to debug the SQLite schema, migrations, import/export behavior, or per-user data directory behavior.
- You want to verify command behavior with `zig build run -- ...`.

## Repository Layout

- `src/main.zig`: Main CLI, argument parsing, schema creation, date handling, and command output.
- `build.zig`: Zig build configuration, including the `zqlite` dependency and `sqlite3` linkage.
- `build.zig.zon`: Zig package manifest.

## Current CLI Surface

The current commands are:

```bash
zig build run -- help
zig build run -- help edit
zig build run -- --json doctor
zig build run -- add <name> --interval-days <days> [--common-name <text>] [--species <text>] [--location <text>] [--notes <text>] [--acquired <YYYY-MM-DD|today>] [--last-watered <YYYY-MM-DD|today>]
zig build run -- edit <plant> [--name <text>] [--common-name <text>|--clear-common-name] [--species <text>|--clear-species] [--location <text>|--clear-location] [--notes <text>|--clear-notes] [--interval-days <days>] [--acquired <YYYY-MM-DD|today>|--clear-acquired] [--status <active|archived|gifted|dead>]
zig build run -- rename <plant> <new-name>
zig build run -- archive <plant> [--status archived|gifted|dead]
zig build run -- delete <plant>
zig build run -- water <plant> [--date <YYYY-MM-DD|today>] [--interval-days <days>] [--notes <text>]
zig build run -- skip <plant> (--days <n> | --to <YYYY-MM-DD|today>) [--notes <text>]
zig build run -- unwater <plant> [--event-id <id> | --date <YYYY-MM-DD|today>]
zig build run -- fertilize|repot|prune|rotate|treat <plant> [--date <YYYY-MM-DD|today>] [--notes <text>]
zig build run -- list [--all] [--status <status>]
zig build run -- due [--all] [--all-statuses]
zig build run -- history [plant] [--limit <n>]
zig build run -- show <plant>
zig build run -- export [path]
zig build run -- import <path>
zig build run -- backup <path>
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

- `plants`: name, common name, species, location, notes, acquired date, status, watering interval, last watered date, next watering date, timestamps
- `plant_events`: generic care history rows such as `water`, `skip`, `fertilize`, `repot`, `prune`, `rotate`, and `treat`
- `watering_events`: legacy table retained for migration compatibility

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
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- add pothos --interval-days 7 --location office --last-watered today
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- water pothos --notes "top soil dry"
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- fertilize poth --notes "half strength"
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- skip pothos --days 2
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- history pothos
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite zig build run -- --json list --all
```

## Implementation Notes

- The project uses `zqlite` as a thin SQLite wrapper and links against system `sqlite3`.
- Keep schema changes backward-compatible when possible; the database is initialized and migrated in `ensureSchema`.
- If you return text from SQLite rows, copy it before the row is finalized.
- `skip` and `unwater` interact through recomputation logic, so changes there need regression testing.
- Follow the repository Zig conventions from `AGENTS.md`: explicit allocators, concise functions, and `zigdoc` for API discovery.
