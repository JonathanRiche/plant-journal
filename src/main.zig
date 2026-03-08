//! plant-journal is a small SQLite-backed CLI for tracking plant watering.
const std = @import("std");
const zqlite = @import("zqlite");
const c = @cImport({
    @cInclude("time.h");
});

const log = std.log.scoped(.plant_journal);

const epoch = std.time.epoch;

const AppError = error{
    InvalidArguments,
    InvalidDate,
    InvalidInterval,
    MissingHome,
    MissingValue,
    PlantNotFound,
    UnsupportedDate,
    UnknownCommand,
};

const AddCommand = struct {
    name: []const u8,
    species: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    interval_days: i64,
    last_watered_day: ?i64 = null,
};

const WaterCommand = struct {
    name: []const u8,
    notes: ?[]const u8 = null,
    interval_days: ?i64 = null,
    watered_on: ?i64 = null,
};

const Plant = struct {
    id: i64,
    name: []const u8,
    species: ?[]const u8,
    notes: ?[]const u8,
    interval_days: i64,
    last_watered_day: ?i64,
    next_watering_day: ?i64,
};

const Database = struct {
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,
    path: []const u8,

    fn init(allocator: std.mem.Allocator) !Database {
        const db_path = try resolveDatabasePath(allocator);
        const db_path_z = try allocator.dupeZ(u8, db_path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(db_path_z, flags);
        errdefer conn.close();

        try conn.busyTimeout(5_000);
        try conn.execNoArgs("pragma foreign_keys = on;");
        try conn.execNoArgs("pragma journal_mode = wal;");
        try ensureSchema(conn);

        return .{
            .allocator = allocator,
            .conn = conn,
            .path = db_path,
        };
    }

    fn deinit(self: Database) void {
        self.conn.close();
    }

    fn ensureSchema(conn: zqlite.Conn) !void {
        try conn.execNoArgs(
            \\create table if not exists plants (
            \\    id integer primary key,
            \\    name text not null unique,
            \\    species text,
            \\    notes text,
            \\    watering_interval_days integer not null check (watering_interval_days > 0),
            \\    created_at integer not null,
            \\    updated_at integer not null,
            \\    last_watered_on integer,
            \\    next_watering_on integer
            \\);
            \\create table if not exists watering_events (
            \\    id integer primary key,
            \\    plant_id integer not null references plants(id) on delete cascade,
            \\    watered_on integer not null,
            \\    notes text,
            \\    created_at integer not null
            \\);
            \\create index if not exists idx_watering_events_plant_day
            \\    on watering_events (plant_id, watered_on desc, id desc);
        );
    }

    fn addPlant(self: Database, command: AddCommand) !void {
        std.debug.assert(command.interval_days > 0);

        const now = std.time.timestamp();
        const next_watering_day = if (command.last_watered_day) |day|
            day + command.interval_days
        else
            null;

        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.exec(
            "insert into plants (name, species, notes, watering_interval_days, created_at, updated_at, last_watered_on, next_watering_on) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            .{
                command.name,
                command.species,
                command.notes,
                command.interval_days,
                now,
                now,
                command.last_watered_day,
                next_watering_day,
            },
        );

        if (command.last_watered_day) |day| {
            try self.conn.exec(
                "insert into watering_events (plant_id, watered_on, notes, created_at) values (?1, ?2, ?3, ?4)",
                .{ self.conn.lastInsertedRowId(), day, "Initial watering record", now },
            );
        }

        try self.conn.commit();
    }

    fn waterPlant(self: Database, command: WaterCommand) !void {
        const watered_on = command.watered_on orelse try todayLocalDay();
        const plant = try self.getPlant(command.name);
        const interval_days = command.interval_days orelse plant.interval_days;

        if (interval_days <= 0) {
            return AppError.InvalidInterval;
        }

        const next_watering_day = watered_on + interval_days;
        const now = std.time.timestamp();

        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.exec(
            "update plants set watering_interval_days = ?1, last_watered_on = ?2, next_watering_on = ?3, updated_at = ?4 where id = ?5",
            .{ interval_days, watered_on, next_watering_day, now, plant.id },
        );
        try self.conn.exec(
            "insert into watering_events (plant_id, watered_on, notes, created_at) values (?1, ?2, ?3, ?4)",
            .{ plant.id, watered_on, command.notes, now },
        );

        try self.conn.commit();
    }

    fn getPlant(self: Database, name: []const u8) !Plant {
        const row = try self.conn.row(
            "select id, name, species, notes, watering_interval_days, last_watered_on, next_watering_on from plants where name = ?1",
            .{name},
        );
        if (row == null) {
            return AppError.PlantNotFound;
        }

        const plant_row = row.?;
        defer plant_row.deinit();

        return .{
            .id = plant_row.int(0),
            .name = try self.allocator.dupe(u8, plant_row.text(1)),
            .species = try duplicateOptionalText(self.allocator, plant_row.nullableText(2)),
            .notes = try duplicateOptionalText(self.allocator, plant_row.nullableText(3)),
            .interval_days = plant_row.int(4),
            .last_watered_day = plant_row.nullableInt(5),
            .next_watering_day = plant_row.nullableInt(6),
        };
    }
};

fn duplicateOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| {
        const copy = try allocator.dupe(u8, text);
        return copy;
    }
    return null;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    run(allocator) catch |err| switch (err) {
        AppError.InvalidArguments,
        AppError.InvalidDate,
        AppError.InvalidInterval,
        AppError.MissingHome,
        AppError.MissingValue,
        AppError.PlantNotFound,
        AppError.UnsupportedDate,
        AppError.UnknownCommand,
        error.ConstraintUnique,
        => {
            reportUserError(err) catch {};
            std.process.exit(1);
        },
        else => {
            log.err("unexpected failure: {s}", .{@errorName(err)});
            return err;
        },
    };
}

fn run(allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var arg_iter = try std.process.argsWithAllocator(arena);
    defer arg_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(arena);

    while (arg_iter.next()) |arg| {
        try args.append(arena, arg);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (args.items.len <= 1) {
        try writeHelp(&stdout_writer.interface);
        return;
    }

    const command = args.items[1];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        try writeHelp(&stdout_writer.interface);
        return;
    }

    var database = try Database.init(arena);
    defer database.deinit();

    if (std.mem.eql(u8, command, "add")) {
        const add_command = try parseAddCommand(args.items[2..]);
        try database.addPlant(add_command);
        try writeAddResult(&stdout_writer.interface, add_command);
        return;
    }

    if (std.mem.eql(u8, command, "water")) {
        const water_command = try parseWaterCommand(args.items[2..]);
        try database.waterPlant(water_command);
        const plant = try database.getPlant(water_command.name);
        try writeWaterResult(&stdout_writer.interface, plant);
        return;
    }

    if (std.mem.eql(u8, command, "list")) {
        try writePlantList(database, &stdout_writer.interface);
        return;
    }

    if (std.mem.eql(u8, command, "show")) {
        if (args.items.len != 3) {
            return AppError.InvalidArguments;
        }
        try writePlantDetails(database, args.items[2], &stdout_writer.interface);
        return;
    }

    return AppError.UnknownCommand;
}

fn parseAddCommand(args: []const []const u8) !AddCommand {
    if (args.len == 0) {
        return AppError.InvalidArguments;
    }

    var command: AddCommand = .{
        .name = args[0],
        .interval_days = 0,
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--species")) {
            command.species = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-days")) {
            command.interval_days = try parseInterval(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--last-watered")) {
            command.last_watered_day = try parseDateArgument(try optionValue(args, &index));
            continue;
        }

        return AppError.InvalidArguments;
    }

    if (command.interval_days <= 0) {
        return AppError.InvalidInterval;
    }

    return command;
}

fn parseWaterCommand(args: []const []const u8) !WaterCommand {
    if (args.len == 0) {
        return AppError.InvalidArguments;
    }

    var command: WaterCommand = .{
        .name = args[0],
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-days")) {
            command.interval_days = try parseInterval(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--date")) {
            command.watered_on = try parseDateArgument(try optionValue(args, &index));
            continue;
        }

        return AppError.InvalidArguments;
    }

    return command;
}

fn optionValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        return AppError.MissingValue;
    }
    return args[index.*];
}

fn parseInterval(value: []const u8) !i64 {
    const interval = std.fmt.parseInt(i64, value, 10) catch return AppError.InvalidInterval;
    if (interval <= 0) {
        return AppError.InvalidInterval;
    }
    return interval;
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\plant-journal tracks plant watering in SQLite.
        \\
        \\Usage:
        \\  plant-journal add <name> --interval-days <days> [--species <text>] [--notes <text>] [--last-watered <YYYY-MM-DD|today>]
        \\  plant-journal water <name> [--date <YYYY-MM-DD|today>] [--interval-days <days>] [--notes <text>]
        \\  plant-journal list
        \\  plant-journal show <name>
        \\  plant-journal help
        \\  plant-journal -h
        \\  plant-journal --help
        \\
        \\Data location:
        \\  Uses $PLANT_JOURNAL_DB when set.
        \\  Otherwise uses $XDG_DATA_HOME/plant-journal/plant-journal.sqlite3
        \\  or $HOME/.local/share/plant-journal/plant-journal.sqlite3.
        \\
    );
}

fn writeAddResult(writer: *std.Io.Writer, command: AddCommand) !void {
    if (command.last_watered_day) |day| {
        var last_buffer: [16]u8 = undefined;
        var next_buffer: [16]u8 = undefined;
        try writer.print(
            "Added {s}. Last watered {s}; next watering {s}.\n",
            .{
                command.name,
                try formatDay(day, &last_buffer),
                try formatDay(day + command.interval_days, &next_buffer),
            },
        );
        return;
    }

    try writer.print(
        "Added {s}. Water every {d} day{s}. No watering date recorded yet.\n",
        .{ command.name, command.interval_days, pluralSuffix(command.interval_days) },
    );
}

fn writeWaterResult(writer: *std.Io.Writer, plant: Plant) !void {
    var last_buffer: [16]u8 = undefined;
    var next_buffer: [16]u8 = undefined;

    try writer.print(
        "Recorded watering for {s}. Last watered {s}; next watering {s}.\n",
        .{
            plant.name,
            try formatOptionalDay(plant.last_watered_day, &last_buffer),
            try formatOptionalDay(plant.next_watering_day, &next_buffer),
        },
    );
}

fn writePlantList(database: Database, writer: *std.Io.Writer) !void {
    const today = try todayLocalDay();
    var rows = try database.conn.rows(
        "select name, species, notes, watering_interval_days, last_watered_on, next_watering_on from plants order by coalesce(next_watering_on, 9223372036854775807), name",
        .{},
    );
    defer rows.deinit();

    var found_any = false;
    while (rows.next()) |row| {
        found_any = true;

        const name = row.text(0);
        const species = row.nullableText(1);
        const notes = row.nullableText(2);
        const interval_days = row.int(3);
        const last_watered_day = row.nullableInt(4);
        const next_watering_day = row.nullableInt(5);

        var last_buffer: [16]u8 = undefined;
        var next_buffer: [16]u8 = undefined;
        var status_buffer: [32]u8 = undefined;

        try writer.print(
            "{s} | every {d} day{s} | last {s} | next {s}",
            .{
                name,
                interval_days,
                pluralSuffix(interval_days),
                try formatOptionalDay(last_watered_day, &last_buffer),
                try formatOptionalDay(next_watering_day, &next_buffer),
            },
        );

        if (next_watering_day) |day| {
            try writer.print(" | {s}", .{try formatDueStatus(day, today, &status_buffer)});
        }

        try writer.writeAll("\n");

        if (species) |value| {
            try writer.print("  species: {s}\n", .{value});
        }
        if (notes) |value| {
            try writer.print("  notes: {s}\n", .{value});
        }
    }

    if (rows.err) |err| {
        return err;
    }

    if (found_any == false) {
        try writer.writeAll("No plants yet. Add one with `plant-journal add`.\n");
    }
}

fn writePlantDetails(database: Database, name: []const u8, writer: *std.Io.Writer) !void {
    const plant = try database.getPlant(name);

    var last_buffer: [16]u8 = undefined;
    var next_buffer: [16]u8 = undefined;

    try writer.print("{s}\n", .{plant.name});
    try writer.print("  database: {s}\n", .{database.path});
    try writer.print("  interval: {d} day{s}\n", .{ plant.interval_days, pluralSuffix(plant.interval_days) });
    try writer.print("  last watered: {s}\n", .{try formatOptionalDay(plant.last_watered_day, &last_buffer)});
    try writer.print("  next watering: {s}\n", .{try formatOptionalDay(plant.next_watering_day, &next_buffer)});

    if (plant.species) |species| {
        try writer.print("  species: {s}\n", .{species});
    }
    if (plant.notes) |notes| {
        try writer.print("  notes: {s}\n", .{notes});
    }

    try writer.writeAll("  watering history:\n");

    var rows = try database.conn.rows(
        "select watered_on, notes from watering_events where plant_id = ?1 order by watered_on desc, id desc limit 10",
        .{plant.id},
    );
    defer rows.deinit();

    var found_any = false;
    while (rows.next()) |row| {
        found_any = true;

        var day_buffer: [16]u8 = undefined;
        const watered_on = row.int(0);
        const notes = row.nullableText(1);

        if (notes) |value| {
            try writer.print("    {s} | {s}\n", .{ try formatDay(watered_on, &day_buffer), value });
        } else {
            try writer.print("    {s}\n", .{try formatDay(watered_on, &day_buffer)});
        }
    }

    if (rows.err) |err| {
        return err;
    }

    if (found_any == false) {
        try writer.writeAll("    no watering events yet\n");
    }
}

fn reportUserError(err: anyerror) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};

    switch (err) {
        AppError.InvalidArguments,
        AppError.MissingValue,
        AppError.UnknownCommand,
        => try stderr_writer.interface.writeAll("Invalid arguments. Run `plant-journal help` for usage.\n"),
        AppError.InvalidDate => try stderr_writer.interface.writeAll("Invalid date. Use YYYY-MM-DD or `today`.\n"),
        AppError.InvalidInterval => try stderr_writer.interface.writeAll("Invalid interval. Use a positive whole number of days.\n"),
        AppError.MissingHome => try stderr_writer.interface.writeAll("Could not resolve a per-user data directory. Set $HOME, $XDG_DATA_HOME, or $PLANT_JOURNAL_DB.\n"),
        AppError.PlantNotFound => try stderr_writer.interface.writeAll("Plant not found.\n"),
        AppError.UnsupportedDate => try stderr_writer.interface.writeAll("Only dates on or after 1970-01-01 are supported.\n"),
        error.ConstraintUnique => try stderr_writer.interface.writeAll("A plant with that name already exists.\n"),
        else => try stderr_writer.interface.print("Error: {s}\n", .{@errorName(err)}),
    }
}

fn resolveDatabasePath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("PLANT_JOURNAL_DB")) |override| {
        const path: []const u8 = override;
        if (std.fs.path.dirname(path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }
        return allocator.dupe(u8, path);
    }

    var owned_base: ?[]u8 = null;
    defer if (owned_base) |base| allocator.free(base);

    const base: []const u8 = if (std.posix.getenv("XDG_DATA_HOME")) |xdg|
        xdg
    else if (std.posix.getenv("HOME")) |home| blk: {
        const default_base = try std.fs.path.join(allocator, &.{ home, ".local", "share" });
        owned_base = default_base;
        break :blk default_base;
    } else return AppError.MissingHome;

    const data_dir = try std.fs.path.join(allocator, &.{ base, "plant-journal" });
    try std.fs.cwd().makePath(data_dir);
    return std.fs.path.join(allocator, &.{ data_dir, "plant-journal.sqlite3" });
}

fn todayLocalDay() !i64 {
    const now = c.time(null);
    if (now < 0) {
        return AppError.UnsupportedDate;
    }

    var local_time: c.struct_tm = undefined;
    if (c.localtime_r(&now, &local_time) == null) {
        return AppError.UnsupportedDate;
    }

    const year: u16 = @intCast(local_time.tm_year + 1900);
    const month: u8 = @intCast(local_time.tm_mon + 1);
    const day: u8 = @intCast(local_time.tm_mday);
    return ymdToEpochDay(year, month, day);
}

fn parseDateArgument(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "today")) {
        return todayLocalDay();
    }
    return parseIsoDay(value);
}

fn parseIsoDay(value: []const u8) !i64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') {
        return AppError.InvalidDate;
    }

    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return AppError.InvalidDate;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return AppError.InvalidDate;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return AppError.InvalidDate;

    return ymdToEpochDay(year, month, day);
}

fn ymdToEpochDay(year: u16, month_number: u8, day_number: u8) !i64 {
    if (year < epoch.epoch_year) {
        return AppError.UnsupportedDate;
    }

    const month = monthFromNumber(month_number) catch return AppError.InvalidDate;
    const days_in_month = epoch.getDaysInMonth(year, month);
    if (day_number == 0 or day_number > days_in_month) {
        return AppError.InvalidDate;
    }

    var total_days: i64 = 0;

    var current_year: u16 = epoch.epoch_year;
    while (current_year < year) : (current_year += 1) {
        total_days += epoch.getDaysInYear(current_year);
    }

    var current_month_number: u8 = 1;
    while (current_month_number < month_number) : (current_month_number += 1) {
        total_days += epoch.getDaysInMonth(year, try monthFromNumber(current_month_number));
    }

    total_days += day_number - 1;
    return total_days;
}

fn monthFromNumber(month_number: u8) !epoch.Month {
    return switch (month_number) {
        1 => .jan,
        2 => .feb,
        3 => .mar,
        4 => .apr,
        5 => .may,
        6 => .jun,
        7 => .jul,
        8 => .aug,
        9 => .sep,
        10 => .oct,
        11 => .nov,
        12 => .dec,
        else => AppError.InvalidDate,
    };
}

fn formatOptionalDay(day: ?i64, buffer: *[16]u8) ![]const u8 {
    if (day) |value| {
        return formatDay(value, buffer);
    }
    return "n/a";
}

fn formatDay(day: i64, buffer: *[16]u8) ![]const u8 {
    if (day < 0) {
        return AppError.UnsupportedDate;
    }

    const epoch_day: epoch.EpochDay = .{ .day = @intCast(day) };
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_of_month: u8 = month_day.day_index + 1;

    return std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, month_day.month.numeric(), day_of_month },
    );
}

fn formatDueStatus(next_watering_day: i64, today: i64, buffer: *[32]u8) ![]const u8 {
    const delta = next_watering_day - today;
    if (delta < 0) {
        const overdue = -delta;
        return std.fmt.bufPrint(buffer, "overdue by {d} day{s}", .{ overdue, pluralSuffix(overdue) });
    }
    if (delta == 0) {
        return "due today";
    }
    return std.fmt.bufPrint(buffer, "due in {d} day{s}", .{ delta, pluralSuffix(delta) });
}

fn pluralSuffix(value: i64) []const u8 {
    return if (value == 1) "" else "s";
}

test "date parsing round trips through formatting" {
    const day = try parseIsoDay("2026-03-08");
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2026-03-08", try formatDay(day, &buffer));
}

test "date parsing rejects invalid calendar dates" {
    try std.testing.expectError(AppError.InvalidDate, parseIsoDay("2026-02-29"));
}

test "due status labels today and overdue plants" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("due today", try formatDueStatus(10, 10, &buffer));
    try std.testing.expectEqualStrings("overdue by 2 days", try formatDueStatus(8, 10, &buffer));
}

test {
    std.testing.refAllDecls(@This());
}
