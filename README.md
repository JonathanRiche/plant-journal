# plant-journal

`plant-journal` is a Zig CLI for tracking plant care in SQLite.

## Install

Build and install it to `~/.local/bin`:

```bash
zig build install -Doptimize=ReleaseFast --prefix "$HOME/.local"
```

If `~/.local/bin` is on your `PATH`, the CLI will then be available globally as:

```bash
plant-journal
```

## Build And Test

```bash
zig build
zig build test
```

## Usage

```bash
plant-journal help
plant-journal -h
plant-journal --db "$HOME/.local/share/plant-journal/demo.sqlite3" add monstera --interval-days 7 --common-name "Swiss cheese plant" --species deliciosa --location office --notes "Bright indirect light" --last-watered today
plant-journal water monstera --notes "Top soil dry"
plant-journal fertilize monstera --notes "Half strength feed"
plant-journal skip monstera --days 2 --notes "Still damp"
plant-journal list
plant-journal due
plant-journal history monstera --limit 20
plant-journal show monstera
plant-journal export plant-journal-export.json
plant-journal backup plant-journal-backup.sqlite
```

## Features

- Tracks plants with name, common name, species, location, notes, acquired date, status, and watering interval.
- Stores care events in SQLite, including watering, fertilizing, repotting, pruning, rotating, treatment, and schedule skips.
- Supports `edit`, `rename`, `archive`, `delete`, `due`, `history`, `doctor`, `export`, `import`, and `backup`.
- Supports case-insensitive and partial plant lookup for most commands.
- Supports `--json` output and `--db <path>` database overrides.

The database path resolves in this order:

1. `$PLANT_JOURNAL_DB`
2. `$XDG_DATA_HOME/plant-journal/plant-journal.sqlite3`
3. `$HOME/.local/share/plant-journal/plant-journal.sqlite3`

For testing, point the CLI at a temporary database:

```bash
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite plant-journal list
```

You can also override the database path directly:

```bash
plant-journal --db /tmp/plant-journal.sqlite list --all
```

## Common Commands

```bash
plant-journal add <name> --interval-days <days> [--common-name <text>] [--species <text>] [--location <text>] [--notes <text>] [--acquired <date>] [--last-watered <date>]
plant-journal edit <plant> [--name <text>] [--common-name <text>|--clear-common-name] [--species <text>|--clear-species] [--location <text>|--clear-location] [--notes <text>|--clear-notes] [--interval-days <days>] [--acquired <date>|--clear-acquired] [--status <active|archived|gifted|dead>]
plant-journal rename <plant> <new-name>
plant-journal archive <plant> [--status archived|gifted|dead]
plant-journal delete <plant>
plant-journal water <plant> [--date <date>] [--interval-days <days>] [--notes <text>]
plant-journal skip <plant> (--days <n> | --to <date>) [--notes <text>]
plant-journal unwater <plant> [--event-id <id> | --date <date>]
plant-journal fertilize|repot|prune|rotate|treat <plant> [--date <date>] [--notes <text>]
plant-journal list [--all] [--status <status>]
plant-journal due [--all] [--all-statuses]
plant-journal history [plant] [--limit <n>]
plant-journal doctor
plant-journal export [path]
plant-journal import <path>
plant-journal backup <path>
```

## Included Skill

This repo also includes an installable skill at `skills/plant-journal/SKILL.md`.

With `skills.sh`, install it from the repo with:

```bash
npx skills add https://github.com/JonathanRiche/plant-journal --skill plant-journal
```
