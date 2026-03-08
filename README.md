# plant-journal

`plant-journal` is a Zig CLI for tracking plant watering in SQLite.

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
plant-journal add monstera --interval-days 7 --species deliciosa --notes "Bright indirect light" --last-watered today
plant-journal water monstera --notes "Top soil dry"
plant-journal list
plant-journal show monstera
```

The database path resolves in this order:

1. `$PLANT_JOURNAL_DB`
2. `$XDG_DATA_HOME/plant-journal/plant-journal.sqlite3`
3. `$HOME/.local/share/plant-journal/plant-journal.sqlite3`

For testing, point the CLI at a temporary database:

```bash
PLANT_JOURNAL_DB=/tmp/plant-journal.sqlite plant-journal list
```

## Included Skill

This repo also includes an installable skill at `skills/plant-journal/SKILL.md`.

With `skills.sh`, install it from the repo with:

```bash
npx skills add <repo-url> --skill plant-journal
```
