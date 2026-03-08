//! plant-journal is a SQLite-backed CLI for tracking plant care over time.
const std = @import("std");
const zqlite = @import("zqlite");
const c = @cImport({
    @cInclude("time.h");
});

const log = std.log.scoped(.plant_journal);
const epoch = std.time.epoch;

const CURRENT_SCHEMA_VERSION = 2;

const AppError = error{
    AmbiguousPlant,
    InvalidArguments,
    InvalidDate,
    InvalidEventType,
    InvalidInterval,
    InvalidLimit,
    InvalidStatus,
    MissingEvent,
    MissingHome,
    MissingValue,
    NoChangeRequested,
    PlantNotFound,
    UnsupportedDate,
    UnknownCommand,
};

const OutputMode = enum {
    plain,
    json,
};

const PlantStatus = enum {
    active,
    archived,
    gifted,
    dead,

    fn parse(value: []const u8) !PlantStatus {
        if (std.ascii.eqlIgnoreCase(value, "active")) return .active;
        if (std.ascii.eqlIgnoreCase(value, "archived")) return .archived;
        if (std.ascii.eqlIgnoreCase(value, "gifted")) return .gifted;
        if (std.ascii.eqlIgnoreCase(value, "dead")) return .dead;
        return AppError.InvalidStatus;
    }

    fn text(self: PlantStatus) []const u8 {
        return @tagName(self);
    }
};

const TextUpdate = union(enum) {
    keep,
    set: []const u8,
    clear,
};

const IntUpdate = union(enum) {
    keep,
    set: i64,
};

const DateUpdate = union(enum) {
    keep,
    set: i64,
    clear,
};

const StatusUpdate = union(enum) {
    keep,
    set: PlantStatus,
};

const GlobalOptions = struct {
    db_override: ?[]const u8 = null,
    output_mode: OutputMode = .plain,
    command_index: usize,
};

const AddCommand = struct {
    name: []const u8,
    common_name: ?[]const u8 = null,
    species: ?[]const u8 = null,
    location: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    interval_days: i64,
    acquired_on: ?i64 = null,
    last_watered_day: ?i64 = null,
};

const EditCommand = struct {
    query: []const u8,
    name: TextUpdate = .keep,
    common_name: TextUpdate = .keep,
    species: TextUpdate = .keep,
    location: TextUpdate = .keep,
    notes: TextUpdate = .keep,
    interval_days: IntUpdate = .keep,
    acquired_on: DateUpdate = .keep,
    status: StatusUpdate = .keep,
};

const WaterCommand = struct {
    query: []const u8,
    notes: ?[]const u8 = null,
    interval_days: ?i64 = null,
    watered_on: ?i64 = null,
};

const SkipCommand = struct {
    query: []const u8,
    notes: ?[]const u8 = null,
    days: ?i64 = null,
    to_day: ?i64 = null,
};

const ArchiveCommand = struct {
    query: []const u8,
    status: PlantStatus = .archived,
};

const RenameCommand = struct {
    query: []const u8,
    new_name: []const u8,
};

const DeleteCommand = struct {
    query: []const u8,
};

const ShowCommand = struct {
    query: []const u8,
};

const ListCommand = struct {
    include_all: bool = false,
    status: ?PlantStatus = null,
};

const DueCommand = struct {
    include_future: bool = false,
    include_all_statuses: bool = false,
};

const HistoryCommand = struct {
    query: ?[]const u8 = null,
    limit: usize = 20,
};

const EventCommand = struct {
    query: []const u8,
    event_type: []const u8,
    happened_on: ?i64 = null,
    notes: ?[]const u8 = null,
};

const UnwaterCommand = struct {
    query: []const u8,
    event_id: ?i64 = null,
    day: ?i64 = null,
};

const ImportCommand = struct {
    path: []const u8,
};

const ExportCommand = struct {
    path: ?[]const u8 = null,
};

const BackupCommand = struct {
    path: []const u8,
};

const DoctorReport = struct {
    database_path: []const u8,
    schema_version: i64,
    plant_count: i64,
    active_count: i64,
    event_count: i64,
};

const Plant = struct {
    id: i64,
    name: []const u8,
    common_name: ?[]const u8,
    species: ?[]const u8,
    location: ?[]const u8,
    notes: ?[]const u8,
    interval_days: i64,
    acquired_on: ?i64,
    status: PlantStatus,
    last_watered_day: ?i64,
    next_watering_day: ?i64,
};

const PlantSummary = struct {
    name: []const u8,
    common_name: ?[]const u8,
    species: ?[]const u8,
    location: ?[]const u8,
    notes: ?[]const u8,
    interval_days: i64,
    acquired_on: ?[]const u8,
    status: []const u8,
    last_watered_on: ?[]const u8,
    next_watering_on: ?[]const u8,
    due_status: ?[]const u8,
};

const EventRecord = struct {
    id: i64,
    plant_id: i64,
    plant_name: []const u8,
    event_type: []const u8,
    happened_on: i64,
    happened_on_text: []const u8,
    notes: ?[]const u8,
    metadata_json: ?[]const u8,
};

const MutationResponse = struct {
    ok: bool,
    message: []const u8,
};

const ExportPlant = struct {
    name: []const u8,
    common_name: ?[]const u8,
    species: ?[]const u8,
    location: ?[]const u8,
    notes: ?[]const u8,
    interval_days: i64,
    acquired_on: ?[]const u8,
    status: []const u8,
};

const ExportEvent = struct {
    plant_name: []const u8,
    event_type: []const u8,
    happened_on: []const u8,
    notes: ?[]const u8,
    metadata_json: ?[]const u8,
};

const SkipMetadata = struct {
    from: i64,
    to: i64,
};

const ExportDocument = struct {
    schema_version: i64,
    exported_at: i64,
    plants: []ExportPlant,
    events: []ExportEvent,
};

const ImportDocument = struct {
    schema_version: i64 = CURRENT_SCHEMA_VERSION,
    plants: []const ImportPlant,
    events: []const ImportEvent = &.{},
};

const ImportPlant = struct {
    name: []const u8,
    common_name: ?[]const u8 = null,
    species: ?[]const u8 = null,
    location: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    interval_days: i64,
    acquired_on: ?[]const u8 = null,
    status: []const u8 = "active",
};

const ImportEvent = struct {
    plant_name: []const u8,
    event_type: []const u8,
    happened_on: []const u8,
    notes: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
};

const Database = struct {
    allocator: std.mem.Allocator,
    conn: zqlite.Conn,
    path: []const u8,

    fn init(allocator: std.mem.Allocator, db_override: ?[]const u8) !Database {
        const db_path = try resolveDatabasePath(allocator, db_override);
        const db_path_z = try allocator.dupeZ(u8, db_path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(db_path_z, flags);
        errdefer conn.close();

        try conn.busyTimeout(5_000);
        try conn.execNoArgs("pragma foreign_keys = on;");
        try conn.execNoArgs("pragma journal_mode = wal;");

        const db: Database = .{
            .allocator = allocator,
            .conn = conn,
            .path = db_path,
        };
        try db.ensureSchema();
        return db;
    }

    fn deinit(self: Database) void {
        self.conn.close();
    }

    fn ensureSchema(self: Database) !void {
        try self.conn.execNoArgs(
            \\create table if not exists app_meta (
            \\    key text primary key,
            \\    value text not null
            \\);
            \\create table if not exists plants (
            \\    id integer primary key,
            \\    name text not null unique,
            \\    common_name text,
            \\    species text,
            \\    location text,
            \\    notes text,
            \\    watering_interval_days integer not null check (watering_interval_days > 0),
            \\    acquired_on integer,
            \\    status text not null default 'active',
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
            \\create table if not exists plant_events (
            \\    id integer primary key,
            \\    plant_id integer not null references plants(id) on delete cascade,
            \\    event_type text not null,
            \\    happened_on integer not null,
            \\    notes text,
            \\    metadata_json text,
            \\    created_at integer not null
            \\);
            \\create index if not exists idx_plants_name on plants(name);
            \\create index if not exists idx_plants_status_next on plants(status, next_watering_on, name);
            \\create index if not exists idx_plant_events_lookup on plant_events(plant_id, event_type, happened_on desc, id desc);
        );

        try self.ensurePlantColumn("common_name", "text");
        try self.ensurePlantColumn("location", "text");
        try self.ensurePlantColumn("acquired_on", "integer");
        try self.ensurePlantColumn("status", "text not null default 'active'");
        try self.migrateLegacyWateringEvents();
        try self.setMetaValue("schema_version", "2");
    }

    fn ensurePlantColumn(self: Database, column_name: []const u8, definition: []const u8) !void {
        if (try self.tableHasColumn("plants", column_name)) {
            return;
        }

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "alter table plants add column {s} {s}",
            .{ column_name, definition },
        );
        try self.conn.execNoArgs(try self.allocator.dupeZ(u8, sql));
    }

    fn tableHasColumn(self: Database, table_name: []const u8, column_name: []const u8) !bool {
        const sql = try std.fmt.allocPrint(self.allocator, "pragma table_info({s})", .{table_name});
        var rows = try self.conn.rows(sql, .{});
        defer rows.deinit();

        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.text(1), column_name)) {
                return true;
            }
        }

        if (rows.err) |err| return err;
        return false;
    }

    fn migrateLegacyWateringEvents(self: Database) !void {
        try self.conn.execNoArgs(
            \\insert into plant_events (plant_id, event_type, happened_on, notes, metadata_json, created_at)
            \\select we.plant_id, 'water', we.watered_on, we.notes, null, we.created_at
            \\from watering_events we
            \\where not exists (
            \\    select 1
            \\    from plant_events pe
            \\    where pe.plant_id = we.plant_id
            \\      and pe.event_type = 'water'
            \\      and pe.happened_on = we.watered_on
            \\      and coalesce(pe.notes, '') = coalesce(we.notes, '')
            \\);
        );
    }

    fn setMetaValue(self: Database, key: []const u8, value: []const u8) !void {
        try self.conn.exec(
            "insert into app_meta (key, value) values (?1, ?2) on conflict(key) do update set value = excluded.value",
            .{ key, value },
        );
    }

    fn getSchemaVersion(self: Database) !i64 {
        const row = try self.conn.row("select value from app_meta where key = 'schema_version'", .{});
        if (row == null) return 0;
        defer row.?.deinit();
        return std.fmt.parseInt(i64, row.?.text(0), 10) catch 0;
    }

    fn addPlant(self: Database, command: AddCommand) !Plant {
        std.debug.assert(command.interval_days > 0);

        try self.conn.transaction();
        errdefer self.conn.rollback();

        const plant_id = try self.insertPlantRecord(command, .active);

        try self.conn.commit();
        return self.getPlantById(plant_id);
    }

    fn insertPlantRecord(self: Database, command: AddCommand, status: PlantStatus) !i64 {
        const now = std.time.timestamp();
        const next_watering_day = if (command.last_watered_day) |day|
            day + command.interval_days
        else
            null;

        try self.conn.exec(
            "insert into plants (name, common_name, species, location, notes, watering_interval_days, acquired_on, status, created_at, updated_at, last_watered_on, next_watering_on) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            .{
                command.name,
                command.common_name,
                command.species,
                command.location,
                command.notes,
                command.interval_days,
                command.acquired_on,
                status.text(),
                now,
                now,
                command.last_watered_day,
                next_watering_day,
            },
        );

        const plant_id = self.conn.lastInsertedRowId();
        if (command.last_watered_day) |day| {
            try self.insertEvent(plant_id, "water", day, "Initial watering record", null);
        }
        return plant_id;
    }

    fn editPlant(self: Database, command: EditCommand) !Plant {
        const plant = try self.getPlant(command.query);
        var changed = false;
        const now = std.time.timestamp();

        const new_name = try applyTextUpdate(self.allocator, plant.name, command.name, &changed);
        const new_common_name = try applyTextUpdateOptional(self.allocator, plant.common_name, command.common_name, &changed);
        const new_species = try applyTextUpdateOptional(self.allocator, plant.species, command.species, &changed);
        const new_location = try applyTextUpdateOptional(self.allocator, plant.location, command.location, &changed);
        const new_notes = try applyTextUpdateOptional(self.allocator, plant.notes, command.notes, &changed);
        const new_interval = applyIntUpdate(plant.interval_days, command.interval_days, &changed);
        const new_acquired_on = applyDateUpdate(plant.acquired_on, command.acquired_on, &changed);
        const new_status = applyStatusUpdate(plant.status, command.status, &changed);

        if (changed == false) return AppError.NoChangeRequested;

        const interval_changed = new_interval != plant.interval_days;
        const next_watering_day = if (interval_changed)
            if (plant.last_watered_day) |day| day + new_interval else plant.next_watering_day
        else
            plant.next_watering_day;

        try self.conn.exec(
            "update plants set name = ?1, common_name = ?2, species = ?3, location = ?4, notes = ?5, watering_interval_days = ?6, acquired_on = ?7, status = ?8, next_watering_on = ?9, updated_at = ?10 where id = ?11",
            .{
                new_name,
                new_common_name,
                new_species,
                new_location,
                new_notes,
                new_interval,
                new_acquired_on,
                new_status.text(),
                next_watering_day,
                now,
                plant.id,
            },
        );

        return self.getPlantById(plant.id);
    }

    fn renamePlant(self: Database, command: RenameCommand) !Plant {
        const edit_command: EditCommand = .{
            .query = command.query,
            .name = .{ .set = command.new_name },
        };
        return self.editPlant(edit_command);
    }

    fn setPlantStatus(self: Database, query: []const u8, status: PlantStatus) !Plant {
        const edit_command: EditCommand = .{
            .query = query,
            .status = .{ .set = status },
        };
        return self.editPlant(edit_command);
    }

    fn deletePlant(self: Database, query: []const u8) !Plant {
        const plant = try self.getPlant(query);
        try self.conn.exec("delete from plants where id = ?1", .{plant.id});
        return plant;
    }

    fn waterPlant(self: Database, command: WaterCommand) !Plant {
        const watered_on = command.watered_on orelse try todayLocalDay();
        const plant = try self.getPlant(command.query);
        const interval_days = command.interval_days orelse plant.interval_days;
        if (interval_days <= 0) return AppError.InvalidInterval;

        const next_watering_day = watered_on + interval_days;
        const now = std.time.timestamp();

        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.exec(
            "update plants set watering_interval_days = ?1, last_watered_on = ?2, next_watering_on = ?3, updated_at = ?4 where id = ?5",
            .{ interval_days, watered_on, next_watering_day, now, plant.id },
        );
        try self.insertEvent(plant.id, "water", watered_on, command.notes, null);

        try self.conn.commit();
        return self.getPlantById(plant.id);
    }

    fn skipPlant(self: Database, command: SkipCommand) !Plant {
        const plant = try self.getPlant(command.query);
        const current_next = plant.next_watering_day orelse (try todayLocalDay());

        if (command.days != null and command.to_day != null) {
            return AppError.InvalidArguments;
        }

        const new_next = if (command.to_day) |day|
            day
        else if (command.days) |days|
            current_next + days
        else
            return AppError.InvalidArguments;

        const metadata = try std.fmt.allocPrint(
            self.allocator,
            "{{\"from\":{d},\"to\":{d}}}",
            .{ current_next, new_next },
        );

        try self.conn.transaction();
        errdefer self.conn.rollback();

        try self.conn.exec(
            "update plants set next_watering_on = ?1, updated_at = ?2 where id = ?3",
            .{ new_next, std.time.timestamp(), plant.id },
        );
        try self.insertEvent(plant.id, "skip", new_next, command.notes, metadata);

        try self.conn.commit();
        return self.getPlantById(plant.id);
    }

    fn addGenericEvent(self: Database, command: EventCommand) !Plant {
        const plant = try self.getPlant(command.query);
        const happened_on = command.happened_on orelse try todayLocalDay();

        try self.insertEvent(plant.id, command.event_type, happened_on, command.notes, null);
        try self.conn.exec(
            "update plants set updated_at = ?1 where id = ?2",
            .{ std.time.timestamp(), plant.id },
        );
        return self.getPlantById(plant.id);
    }

    fn unwaterPlant(self: Database, command: UnwaterCommand) !Plant {
        const plant = try self.getPlant(command.query);
        const event = try self.findWaterEvent(plant.id, command.event_id, command.day);
        try self.conn.exec("delete from plant_events where id = ?1", .{event.id});
        try self.recomputeWateringSummary(plant.id);
        return self.getPlantById(plant.id);
    }

    fn insertEvent(
        self: Database,
        plant_id: i64,
        event_type: []const u8,
        happened_on: i64,
        notes: ?[]const u8,
        metadata_json: ?[]const u8,
    ) !void {
        try self.conn.exec(
            "insert into plant_events (plant_id, event_type, happened_on, notes, metadata_json, created_at) values (?1, ?2, ?3, ?4, ?5, ?6)",
            .{ plant_id, event_type, happened_on, notes, metadata_json, std.time.timestamp() },
        );
    }

    fn recomputeWateringSummary(self: Database, plant_id: i64) !void {
        const plant = try self.getPlantById(plant_id);
        const water_row = try self.conn.row(
            "select happened_on, id from plant_events where plant_id = ?1 and event_type = 'water' order by happened_on desc, id desc limit 1",
            .{plant_id},
        );
        defer if (water_row) |row| row.deinit();

        var last_watered_on: ?i64 = null;
        var next_watering_on: ?i64 = null;
        var last_water_event_id: ?i64 = null;

        if (water_row) |row| {
            const day = row.int(0);
            last_watered_on = day;
            next_watering_on = day + plant.interval_days;
            last_water_event_id = row.int(1);
        }

        const skip_row = try self.conn.row(
            "select metadata_json, id from plant_events where plant_id = ?1 and event_type = 'skip' and metadata_json is not null order by id desc limit 1",
            .{plant_id},
        );
        defer if (skip_row) |row| row.deinit();

        if (skip_row) |row| {
            const skip_event_id = row.int(1);
            if (last_water_event_id == null or skip_event_id > last_water_event_id.?) {
                const metadata_json = row.text(0);
                const parsed = try std.json.parseFromSlice(SkipMetadata, self.allocator, metadata_json, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                next_watering_on = parsed.value.to;
            }
        }

        try self.conn.exec(
            "update plants set last_watered_on = ?1, next_watering_on = ?2, updated_at = ?3 where id = ?4",
            .{ last_watered_on, next_watering_on, std.time.timestamp(), plant_id },
        );
    }

    fn getPlant(self: Database, query: []const u8) !Plant {
        if (try self.findPlantByExactMatch(query)) |plant| return plant;
        if (try self.findPlantByPartialMatch(query)) |plant| return plant;
        return AppError.PlantNotFound;
    }

    fn findPlantByExactMatch(self: Database, query: []const u8) !?Plant {
        return self.findUniquePlant(
            "select id, name, common_name, species, location, notes, watering_interval_days, acquired_on, status, last_watered_on, next_watering_on from plants where name = ?1 collate nocase or coalesce(common_name, '') = ?1 collate nocase order by case when name = ?1 collate nocase then 0 else 1 end, name",
            query,
        );
    }

    fn findPlantByPartialMatch(self: Database, query: []const u8) !?Plant {
        return self.findUniquePlant(
            "select id, name, common_name, species, location, notes, watering_interval_days, acquired_on, status, last_watered_on, next_watering_on from plants where name like '%' || ?1 || '%' collate nocase or coalesce(common_name, '') like '%' || ?1 || '%' collate nocase order by name",
            query,
        );
    }

    fn findUniquePlant(self: Database, sql: []const u8, query: []const u8) !?Plant {
        var rows = try self.conn.rows(sql, .{query});
        defer rows.deinit();

        var count: usize = 0;
        var first: ?Plant = null;
        while (rows.next()) |row| {
            count += 1;
            if (count == 1) {
                first = try plantFromRow(self.allocator, row);
                continue;
            }
            return AppError.AmbiguousPlant;
        }

        if (rows.err) |err| return err;
        return first;
    }

    fn getPlantById(self: Database, id: i64) !Plant {
        const row = try self.conn.row(
            "select id, name, common_name, species, location, notes, watering_interval_days, acquired_on, status, last_watered_on, next_watering_on from plants where id = ?1",
            .{id},
        );
        if (row == null) return AppError.PlantNotFound;
        defer row.?.deinit();
        return plantFromRow(self.allocator, row.?);
    }

    fn listPlants(self: Database, command: ListCommand) ![]Plant {
        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "select id, name, common_name, species, location, notes, watering_interval_days, acquired_on, status, last_watered_on, next_watering_on from plants");
        if (command.include_all == false and command.status == null) {
            try sql.appendSlice(self.allocator, " where status = 'active'");
        } else if (command.status) |status| {
            try sql.appendSlice(self.allocator, " where status = '");
            try sql.appendSlice(self.allocator, status.text());
            try sql.appendSlice(self.allocator, "'");
        }
        try sql.appendSlice(self.allocator, " order by coalesce(next_watering_on, 9223372036854775807), name");

        var rows = try self.conn.rows(sql.items, .{});
        defer rows.deinit();

        var plants: std.ArrayList(Plant) = .empty;
        defer plants.deinit(self.allocator);

        while (rows.next()) |row| {
            try plants.append(self.allocator, try plantFromRow(self.allocator, row));
        }

        if (rows.err) |err| return err;
        return plants.toOwnedSlice(self.allocator);
    }

    fn duePlants(self: Database, command: DueCommand) ![]Plant {
        const today = try todayLocalDay();
        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);

        try sql.appendSlice(self.allocator, "select id, name, common_name, species, location, notes, watering_interval_days, acquired_on, status, last_watered_on, next_watering_on from plants where next_watering_on is not null");
        if (command.include_all_statuses == false) {
            try sql.appendSlice(self.allocator, " and status = 'active'");
        }
        if (command.include_future == false) {
            try sql.appendSlice(self.allocator, " and next_watering_on <= ");
            try sql.writer(self.allocator).print("{d}", .{today});
        }
        try sql.appendSlice(self.allocator, " order by next_watering_on, name");

        var rows = try self.conn.rows(sql.items, .{});
        defer rows.deinit();

        var plants: std.ArrayList(Plant) = .empty;
        defer plants.deinit(self.allocator);

        while (rows.next()) |row| {
            try plants.append(self.allocator, try plantFromRow(self.allocator, row));
        }

        if (rows.err) |err| return err;
        return plants.toOwnedSlice(self.allocator);
    }

    fn history(self: Database, command: HistoryCommand) ![]EventRecord {
        var rows = if (command.query) |query| blk: {
            const plant = try self.getPlant(query);
            break :blk try self.conn.rows(
                "select pe.id, pe.plant_id, p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id where pe.plant_id = ?1 order by pe.happened_on desc, pe.id desc limit ?2",
                .{ plant.id, @as(i64, @intCast(command.limit)) },
            );
        } else try self.conn.rows(
            "select pe.id, pe.plant_id, p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id order by pe.happened_on desc, pe.id desc limit ?1",
            .{@as(i64, @intCast(command.limit))},
        );
        defer rows.deinit();

        var list: std.ArrayList(EventRecord) = .empty;
        defer list.deinit(self.allocator);

        while (rows.next()) |row| {
            try list.append(self.allocator, try eventFromRow(self.allocator, row));
        }

        if (rows.err) |err| return err;
        return list.toOwnedSlice(self.allocator);
    }

    fn doctor(self: Database) !DoctorReport {
        const plant_count = try self.scalar("select count(*) from plants", .{});
        const active_count = try self.scalar("select count(*) from plants where status = 'active'", .{});
        const event_count = try self.scalar("select count(*) from plant_events", .{});
        return .{
            .database_path = self.path,
            .schema_version = try self.getSchemaVersion(),
            .plant_count = plant_count,
            .active_count = active_count,
            .event_count = event_count,
        };
    }

    fn exportData(self: Database) !ExportDocument {
        var plants_rows = try self.conn.rows(
            "select name, common_name, species, location, notes, watering_interval_days, acquired_on, status from plants order by name",
            .{},
        );
        defer plants_rows.deinit();

        var plants: std.ArrayList(ExportPlant) = .empty;
        defer plants.deinit(self.allocator);

        while (plants_rows.next()) |row| {
            var acquired_buffer: [16]u8 = undefined;
            const acquired_on = row.nullableInt(6);

            try plants.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, row.text(0)),
                .common_name = try duplicateOptionalText(self.allocator, row.nullableText(1)),
                .species = try duplicateOptionalText(self.allocator, row.nullableText(2)),
                .location = try duplicateOptionalText(self.allocator, row.nullableText(3)),
                .notes = try duplicateOptionalText(self.allocator, row.nullableText(4)),
                .interval_days = row.int(5),
                .acquired_on = if (acquired_on) |day| try self.allocator.dupe(u8, try formatDay(day, &acquired_buffer)) else null,
                .status = try self.allocator.dupe(u8, row.text(7)),
            });
        }
        if (plants_rows.err) |err| return err;

        var event_rows = try self.conn.rows(
            "select p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id order by pe.happened_on, pe.id",
            .{},
        );
        defer event_rows.deinit();

        var events: std.ArrayList(ExportEvent) = .empty;
        defer events.deinit(self.allocator);

        while (event_rows.next()) |row| {
            var date_buffer: [16]u8 = undefined;
            try events.append(self.allocator, .{
                .plant_name = try self.allocator.dupe(u8, row.text(0)),
                .event_type = try self.allocator.dupe(u8, row.text(1)),
                .happened_on = try self.allocator.dupe(u8, try formatDay(row.int(2), &date_buffer)),
                .notes = try duplicateOptionalText(self.allocator, row.nullableText(3)),
                .metadata_json = try duplicateOptionalText(self.allocator, row.nullableText(4)),
            });
        }
        if (event_rows.err) |err| return err;

        return .{
            .schema_version = try self.getSchemaVersion(),
            .exported_at = std.time.timestamp(),
            .plants = try plants.toOwnedSlice(self.allocator),
            .events = try events.toOwnedSlice(self.allocator),
        };
    }

    fn importData(self: Database, document: ImportDocument) !void {
        _ = document.schema_version;

        try self.conn.transaction();
        errdefer self.conn.rollback();

        for (document.plants) |plant| {
            try self.upsertImportedPlant(plant);
        }

        for (document.events) |event| {
            try self.importEvent(event);
        }

        try self.conn.commit();
    }

    fn upsertImportedPlant(self: Database, plant: ImportPlant) !void {
        const acquired_on = if (plant.acquired_on) |text| try parseDateArgument(text) else null;
        const status = try PlantStatus.parse(plant.status);
        const existing = self.findPlantByExactMatch(plant.name) catch null;

        if (existing) |current| {
            try self.conn.exec(
                "update plants set common_name = ?1, species = ?2, location = ?3, notes = ?4, watering_interval_days = ?5, acquired_on = ?6, status = ?7, updated_at = ?8 where id = ?9",
                .{
                    plant.common_name,
                    plant.species,
                    plant.location,
                    plant.notes,
                    plant.interval_days,
                    acquired_on,
                    status.text(),
                    std.time.timestamp(),
                    current.id,
                },
            );
            try self.recomputeWateringSummary(current.id);
            return;
        }

        _ = try self.insertPlantRecord(.{
            .name = plant.name,
            .common_name = plant.common_name,
            .species = plant.species,
            .location = plant.location,
            .notes = plant.notes,
            .interval_days = plant.interval_days,
            .acquired_on = acquired_on,
        }, .active);

        if (status != .active) {
            _ = try self.setPlantStatus(plant.name, status);
        }
    }

    fn importEvent(self: Database, event: ImportEvent) !void {
        const plant = try self.getPlant(event.plant_name);
        const happened_on = try parseDateArgument(event.happened_on);

        const existing = try self.conn.row(
            "select id from plant_events where plant_id = ?1 and event_type = ?2 and happened_on = ?3 and coalesce(notes, '') = coalesce(?4, '') and coalesce(metadata_json, '') = coalesce(?5, '') limit 1",
            .{ plant.id, event.event_type, happened_on, event.notes, event.metadata_json },
        );
        if (existing) |row| {
            row.deinit();
            return;
        }

        try self.insertEvent(plant.id, event.event_type, happened_on, event.notes, event.metadata_json);
        if (std.mem.eql(u8, event.event_type, "water") or std.mem.eql(u8, event.event_type, "skip")) {
            try self.recomputeWateringSummary(plant.id);
        }
    }

    fn findWaterEvent(self: Database, plant_id: i64, event_id: ?i64, day: ?i64) !EventRecord {
        const row = if (event_id) |id| blk: {
            break :blk try self.conn.row(
                "select pe.id, pe.plant_id, p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id where pe.id = ?1 and pe.plant_id = ?2 and pe.event_type = 'water'",
                .{ id, plant_id },
            );
        } else if (day) |event_day| blk: {
            break :blk try self.conn.row(
                "select pe.id, pe.plant_id, p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id where pe.plant_id = ?1 and pe.event_type = 'water' and pe.happened_on = ?2 order by pe.id desc limit 1",
                .{ plant_id, event_day },
            );
        } else try self.conn.row(
            "select pe.id, pe.plant_id, p.name, pe.event_type, pe.happened_on, pe.notes, pe.metadata_json from plant_events pe join plants p on p.id = pe.plant_id where pe.plant_id = ?1 and pe.event_type = 'water' order by pe.happened_on desc, pe.id desc limit 1",
            .{plant_id},
        );

        if (row == null) return AppError.MissingEvent;
        defer row.?.deinit();
        return eventFromRow(self.allocator, row.?);
    }

    fn scalar(self: Database, sql: []const u8, values: anytype) !i64 {
        const row = try self.conn.row(sql, values);
        if (row == null) return 0;
        defer row.?.deinit();
        return row.?.int(0);
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    run(allocator) catch |err| switch (err) {
        AppError.AmbiguousPlant,
        AppError.InvalidArguments,
        AppError.InvalidDate,
        AppError.InvalidEventType,
        AppError.InvalidInterval,
        AppError.InvalidLimit,
        AppError.InvalidStatus,
        AppError.MissingEvent,
        AppError.MissingHome,
        AppError.MissingValue,
        AppError.NoChangeRequested,
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

    const args = try collectArgs(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    defer stdout_writer.interface.flush() catch {};

    if (args.len <= 1) {
        try writeHelp(&stdout_writer.interface, null);
        return;
    }

    const global = try parseGlobalOptions(args[1..]);
    const command = args[global.command_index];

    if (isHelpCommand(command)) {
        const help_target = if (args.len > global.command_index + 1) args[global.command_index + 1] else null;
        try writeHelp(&stdout_writer.interface, help_target);
        return;
    }

    var database = try Database.init(arena, global.db_override);
    defer database.deinit();

    if (std.mem.eql(u8, command, "add")) {
        const add_command = try parseAddCommand(args[(global.command_index + 1)..]);
        const plant = try database.addPlant(add_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Added plant.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "edit")) {
        const edit_command = try parseEditCommand(args[(global.command_index + 1)..]);
        const plant = try database.editPlant(edit_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Updated plant.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "rename")) {
        const rename_command = try parseRenameCommand(args[(global.command_index + 1)..]);
        const plant = try database.renamePlant(rename_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Renamed plant.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "archive")) {
        const archive_command = try parseArchiveCommand(args[(global.command_index + 1)..]);
        const plant = try database.setPlantStatus(archive_command.query, archive_command.status);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Updated plant status.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "delete")) {
        const delete_command = try parseDeleteCommand(args[(global.command_index + 1)..]);
        const plant = try database.deletePlant(delete_command.query);
        if (global.output_mode == .json) {
            try writeJson(&stdout_writer.interface, MutationResponse{ .ok = true, .message = plant.name });
        } else {
            try stdout_writer.interface.print("Deleted {s}.\n", .{plant.name});
        }
        return;
    }

    if (std.mem.eql(u8, command, "water")) {
        const water_command = try parseWaterCommand(args[(global.command_index + 1)..]);
        const plant = try database.waterPlant(water_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Recorded watering.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "skip") or std.mem.eql(u8, command, "snooze")) {
        const skip_command = try parseSkipCommand(args[(global.command_index + 1)..]);
        const plant = try database.skipPlant(skip_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Updated next watering.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "unwater")) {
        const unwater_command = try parseUnwaterCommand(args[(global.command_index + 1)..]);
        const plant = try database.unwaterPlant(unwater_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Removed watering event.", plant);
        return;
    }

    if (isGenericEventCommand(command)) {
        const event_command = try parseEventCommand(command, args[(global.command_index + 1)..]);
        const plant = try database.addGenericEvent(event_command);
        try writePlantMutationResult(global.output_mode, &stdout_writer.interface, "Recorded plant event.", plant);
        return;
    }

    if (std.mem.eql(u8, command, "list")) {
        const list_command = try parseListCommand(args[(global.command_index + 1)..]);
        const plants = try database.listPlants(list_command);
        try writePlantList(global.output_mode, &stdout_writer.interface, plants);
        return;
    }

    if (std.mem.eql(u8, command, "due")) {
        const due_command = try parseDueCommand(args[(global.command_index + 1)..]);
        const plants = try database.duePlants(due_command);
        try writePlantList(global.output_mode, &stdout_writer.interface, plants);
        return;
    }

    if (std.mem.eql(u8, command, "show")) {
        const show_command = try parseShowCommand(args[(global.command_index + 1)..]);
        const plant = try database.getPlant(show_command.query);
        try writePlantDetails(global.output_mode, &stdout_writer.interface, plant, database.path, try database.history(.{ .query = show_command.query, .limit = 20 }));
        return;
    }

    if (std.mem.eql(u8, command, "history")) {
        const history_command = try parseHistoryCommand(args[(global.command_index + 1)..]);
        const events = try database.history(history_command);
        try writeHistory(global.output_mode, &stdout_writer.interface, events);
        return;
    }

    if (std.mem.eql(u8, command, "doctor")) {
        if (args.len != global.command_index + 1) return AppError.InvalidArguments;
        try writeDoctor(global.output_mode, &stdout_writer.interface, try database.doctor());
        return;
    }

    if (std.mem.eql(u8, command, "export")) {
        const export_command = try parseExportCommand(args[(global.command_index + 1)..]);
        const document = try database.exportData();
        try writeExportDocument(&stdout_writer.interface, export_command, document);
        return;
    }

    if (std.mem.eql(u8, command, "import")) {
        const import_command = try parseImportCommand(args[(global.command_index + 1)..]);
        try importDocument(arena, database, import_command.path);
        if (global.output_mode == .json) {
            try writeJson(&stdout_writer.interface, MutationResponse{ .ok = true, .message = "Imported data." });
        } else {
            try stdout_writer.interface.writeAll("Imported data.\n");
        }
        return;
    }

    if (std.mem.eql(u8, command, "backup")) {
        const backup_command = try parseBackupCommand(args[(global.command_index + 1)..]);
        try backupDatabase(database.path, backup_command.path);
        if (global.output_mode == .json) {
            try writeJson(&stdout_writer.interface, MutationResponse{ .ok = true, .message = backup_command.path });
        } else {
            try stdout_writer.interface.print("Backed up database to {s}.\n", .{backup_command.path});
        }
        return;
    }

    return AppError.UnknownCommand;
}

fn collectArgs(allocator: std.mem.Allocator) ![]const []const u8 {
    var arg_iter = try std.process.argsWithAllocator(allocator);
    defer arg_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    while (arg_iter.next()) |arg| {
        try args.append(allocator, arg);
    }

    return args.toOwnedSlice(allocator);
}

fn parseGlobalOptions(args: []const []const u8) !GlobalOptions {
    var result: GlobalOptions = .{ .command_index = 1 };
    var offset: usize = 0;

    while (offset < args.len) {
        const arg = args[offset];
        if (isHelpCommand(arg) or isSubcommand(arg)) {
            result.command_index = offset + 1;
            return result;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            result.output_mode = .json;
            offset += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--db")) {
            offset += 1;
            if (offset >= args.len) return AppError.MissingValue;
            result.db_override = args[offset];
            offset += 1;
            continue;
        }
        return AppError.InvalidArguments;
    }

    result.command_index = args.len + 1;
    return result;
}

fn isHelpCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn isSubcommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "add") or
        std.mem.eql(u8, arg, "edit") or
        std.mem.eql(u8, arg, "rename") or
        std.mem.eql(u8, arg, "archive") or
        std.mem.eql(u8, arg, "delete") or
        std.mem.eql(u8, arg, "water") or
        std.mem.eql(u8, arg, "list") or
        std.mem.eql(u8, arg, "show") or
        std.mem.eql(u8, arg, "due") or
        std.mem.eql(u8, arg, "history") or
        std.mem.eql(u8, arg, "skip") or
        std.mem.eql(u8, arg, "snooze") or
        std.mem.eql(u8, arg, "unwater") or
        std.mem.eql(u8, arg, "doctor") or
        std.mem.eql(u8, arg, "export") or
        std.mem.eql(u8, arg, "import") or
        std.mem.eql(u8, arg, "backup") or
        isGenericEventCommand(arg);
}

fn isGenericEventCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "fertilize") or
        std.mem.eql(u8, command, "repot") or
        std.mem.eql(u8, command, "prune") or
        std.mem.eql(u8, command, "rotate") or
        std.mem.eql(u8, command, "treat");
}

fn parseAddCommand(args: []const []const u8) !AddCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: AddCommand = .{
        .name = args[0],
        .interval_days = 0,
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--common-name")) {
            command.common_name = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--species")) {
            command.species = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--location")) {
            command.location = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-days")) {
            command.interval_days = try parsePositiveInt(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--acquired")) {
            command.acquired_on = try parseDateArgument(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--last-watered")) {
            command.last_watered_day = try parseDateArgument(try optionValue(args, &index));
            continue;
        }
        return AppError.InvalidArguments;
    }

    if (command.interval_days <= 0) return AppError.InvalidInterval;
    return command;
}

fn parseEditCommand(args: []const []const u8) !EditCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: EditCommand = .{ .query = args[0] };
    var index: usize = 1;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--name")) {
            command.name = .{ .set = try optionValue(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--common-name")) {
            command.common_name = .{ .set = try optionValue(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-common-name")) {
            command.common_name = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--species")) {
            command.species = .{ .set = try optionValue(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-species")) {
            command.species = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--location")) {
            command.location = .{ .set = try optionValue(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-location")) {
            command.location = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = .{ .set = try optionValue(args, &index) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-notes")) {
            command.notes = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-days")) {
            command.interval_days = .{ .set = try parsePositiveInt(try optionValue(args, &index)) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--acquired")) {
            command.acquired_on = .{ .set = try parseDateArgument(try optionValue(args, &index)) };
            continue;
        }
        if (std.mem.eql(u8, arg, "--clear-acquired")) {
            command.acquired_on = .clear;
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            command.status = .{ .set = try PlantStatus.parse(try optionValue(args, &index)) };
            continue;
        }
        return AppError.InvalidArguments;
    }

    return command;
}

fn parseRenameCommand(args: []const []const u8) !RenameCommand {
    if (args.len != 2) return AppError.InvalidArguments;
    return .{ .query = args[0], .new_name = args[1] };
}

fn parseArchiveCommand(args: []const []const u8) !ArchiveCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: ArchiveCommand = .{ .query = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--status")) {
            command.status = try PlantStatus.parse(try optionValue(args, &index));
            continue;
        }
        return AppError.InvalidArguments;
    }

    if (command.status == .active) return AppError.InvalidStatus;
    return command;
}

fn parseDeleteCommand(args: []const []const u8) !DeleteCommand {
    if (args.len != 1) return AppError.InvalidArguments;
    return .{ .query = args[0] };
}

fn parseWaterCommand(args: []const []const u8) !WaterCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: WaterCommand = .{ .query = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--interval-days")) {
            command.interval_days = try parsePositiveInt(try optionValue(args, &index));
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

fn parseSkipCommand(args: []const []const u8) !SkipCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: SkipCommand = .{ .query = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        if (std.mem.eql(u8, arg, "--days")) {
            command.days = try parsePositiveInt(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--to")) {
            command.to_day = try parseDateArgument(try optionValue(args, &index));
            continue;
        }
        return AppError.InvalidArguments;
    }
    return command;
}

fn parseUnwaterCommand(args: []const []const u8) !UnwaterCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: UnwaterCommand = .{ .query = args[0] };
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--event-id")) {
            command.event_id = try parsePositiveInt(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--date")) {
            command.day = try parseDateArgument(try optionValue(args, &index));
            continue;
        }
        return AppError.InvalidArguments;
    }
    return command;
}

fn parseListCommand(args: []const []const u8) !ListCommand {
    var command: ListCommand = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--all")) {
            command.include_all = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--status")) {
            command.status = try PlantStatus.parse(try optionValue(args, &index));
            continue;
        }
        return AppError.InvalidArguments;
    }
    return command;
}

fn parseDueCommand(args: []const []const u8) !DueCommand {
    var command: DueCommand = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--all")) {
            command.include_future = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all-statuses")) {
            command.include_all_statuses = true;
            continue;
        }
        return AppError.InvalidArguments;
    }
    return command;
}

fn parseShowCommand(args: []const []const u8) !ShowCommand {
    if (args.len != 1) return AppError.InvalidArguments;
    return .{ .query = args[0] };
}

fn parseHistoryCommand(args: []const []const u8) !HistoryCommand {
    var command: HistoryCommand = .{};
    var index: usize = 0;
    if (index < args.len and std.mem.startsWith(u8, args[index], "--") == false) {
        command.query = args[index];
        index += 1;
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--limit")) {
            const limit = try parsePositiveInt(try optionValue(args, &index));
            command.limit = @intCast(limit);
            continue;
        }
        return AppError.InvalidArguments;
    }

    return command;
}

fn parseEventCommand(event_type: []const u8, args: []const []const u8) !EventCommand {
    if (args.len == 0) return AppError.InvalidArguments;
    var command: EventCommand = .{
        .query = args[0],
        .event_type = event_type,
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--date")) {
            command.happened_on = try parseDateArgument(try optionValue(args, &index));
            continue;
        }
        if (std.mem.eql(u8, arg, "--notes")) {
            command.notes = try optionValue(args, &index);
            continue;
        }
        return AppError.InvalidArguments;
    }
    return command;
}

fn parseImportCommand(args: []const []const u8) !ImportCommand {
    if (args.len != 1) return AppError.InvalidArguments;
    return .{ .path = args[0] };
}

fn parseExportCommand(args: []const []const u8) !ExportCommand {
    if (args.len > 1) return AppError.InvalidArguments;
    return .{ .path = if (args.len == 1) args[0] else null };
}

fn parseBackupCommand(args: []const []const u8) !BackupCommand {
    if (args.len != 1) return AppError.InvalidArguments;
    return .{ .path = args[0] };
}

fn optionValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return AppError.MissingValue;
    return args[index.*];
}

fn parsePositiveInt(value: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch return AppError.InvalidInterval;
    if (parsed <= 0) return AppError.InvalidInterval;
    return parsed;
}

fn writeHelp(writer: *std.Io.Writer, subcommand: ?[]const u8) !void {
    if (subcommand) |name| {
        if (std.mem.eql(u8, name, "add")) {
            try writer.writeAll(
                \\Usage: plant-journal add <name> --interval-days <days> [options]
                \\  --common-name <text>
                \\  --species <text>
                \\  --location <text>
                \\  --notes <text>
                \\  --acquired <YYYY-MM-DD|today>
                \\  --last-watered <YYYY-MM-DD|today>
                \\
            );
            return;
        }
        if (std.mem.eql(u8, name, "edit")) {
            try writer.writeAll(
                \\Usage: plant-journal edit <plant> [options]
                \\  --name <text>
                \\  --common-name <text> | --clear-common-name
                \\  --species <text> | --clear-species
                \\  --location <text> | --clear-location
                \\  --notes <text> | --clear-notes
                \\  --interval-days <days>
                \\  --acquired <YYYY-MM-DD|today> | --clear-acquired
                \\  --status <active|archived|gifted|dead>
                \\
            );
            return;
        }
        if (std.mem.eql(u8, name, "history")) {
            try writer.writeAll(
                \\Usage: plant-journal history [plant] [--limit <n>]
                \\
            );
            return;
        }
        if (std.mem.eql(u8, name, "due")) {
            try writer.writeAll(
                \\Usage: plant-journal due [--all] [--all-statuses]
                \\
            );
            return;
        }
    }

    try writer.writeAll(
        \\plant-journal tracks watering and other care events in SQLite.
        \\
        \\Global options:
        \\  --db <path>     Use a specific SQLite file.
        \\  --json          Emit structured JSON where supported.
        \\
        \\Commands:
        \\  plant-journal add <name> --interval-days <days> [--common-name <text>] [--species <text>] [--location <text>] [--notes <text>] [--acquired <date>] [--last-watered <date>]
        \\  plant-journal edit <plant> [flags]
        \\  plant-journal rename <plant> <new-name>
        \\  plant-journal archive <plant> [--status archived|gifted|dead]
        \\  plant-journal delete <plant>
        \\  plant-journal water <plant> [--date <date>] [--interval-days <days>] [--notes <text>]
        \\  plant-journal skip <plant> (--days <n> | --to <date>) [--notes <text>]
        \\  plant-journal unwater <plant> [--event-id <id> | --date <date>]
        \\  plant-journal fertilize|repot|prune|rotate|treat <plant> [--date <date>] [--notes <text>]
        \\  plant-journal list [--all] [--status <status>]
        \\  plant-journal due [--all] [--all-statuses]
        \\  plant-journal history [plant] [--limit <n>]
        \\  plant-journal show <plant>
        \\  plant-journal doctor
        \\  plant-journal export [path]
        \\  plant-journal import <path>
        \\  plant-journal backup <path>
        \\  plant-journal help [command]
        \\  plant-journal -h
        \\  plant-journal --help
        \\
        \\Data location:
        \\  Uses --db first, then $PLANT_JOURNAL_DB.
        \\  Otherwise uses $XDG_DATA_HOME/plant-journal/plant-journal.sqlite3
        \\  or $HOME/.local/share/plant-journal/plant-journal.sqlite3.
        \\
    );
}

fn writePlantMutationResult(
    mode: OutputMode,
    writer: *std.Io.Writer,
    message: []const u8,
    plant: Plant,
) !void {
    if (mode == .json) {
        const summary = try buildPlantSummary(std.heap.page_allocator, plant);
        defer freePlantSummary(std.heap.page_allocator, summary);
        try writeJson(writer, summary);
        return;
    }

    var last_buffer: [16]u8 = undefined;
    var next_buffer: [16]u8 = undefined;
    try writer.print(
        "{s} {s} | last {s} | next {s}\n",
        .{
            message,
            plant.name,
            try formatOptionalDay(plant.last_watered_day, &last_buffer),
            try formatOptionalDay(plant.next_watering_day, &next_buffer),
        },
    );
}

fn writePlantList(mode: OutputMode, writer: *std.Io.Writer, plants: []Plant) !void {
    if (mode == .json) {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var summaries: std.ArrayList(PlantSummary) = .empty;
        defer summaries.deinit(arena);

        for (plants) |plant| {
            try summaries.append(arena, try buildPlantSummary(arena, plant));
        }
        try writeJson(writer, summaries.items);
        return;
    }

    if (plants.len == 0) {
        try writer.writeAll("No matching plants.\n");
        return;
    }

    for (plants) |plant| {
        var last_buffer: [16]u8 = undefined;
        var next_buffer: [16]u8 = undefined;
        var status_buffer: [32]u8 = undefined;
        try writer.print(
            "{s} | status {s} | every {d} day{s} | last {s} | next {s}",
            .{
                plant.name,
                plant.status.text(),
                plant.interval_days,
                pluralSuffix(plant.interval_days),
                try formatOptionalDay(plant.last_watered_day, &last_buffer),
                try formatOptionalDay(plant.next_watering_day, &next_buffer),
            },
        );

        if (plant.next_watering_day) |day| {
            try writer.print(" | {s}", .{try formatDueStatus(day, try todayLocalDay(), &status_buffer)});
        }
        try writer.writeAll("\n");

        if (plant.common_name) |value| try writer.print("  common name: {s}\n", .{value});
        if (plant.species) |value| try writer.print("  species: {s}\n", .{value});
        if (plant.location) |value| try writer.print("  location: {s}\n", .{value});
        if (plant.notes) |value| try writer.print("  notes: {s}\n", .{value});
    }
}

fn writePlantDetails(
    mode: OutputMode,
    writer: *std.Io.Writer,
    plant: Plant,
    database_path: []const u8,
    events: []EventRecord,
) !void {
    if (mode == .json) {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const summary = try buildPlantSummary(arena, plant);
        try writeJson(writer, .{
            .plant = summary,
            .database_path = database_path,
            .history = events,
        });
        return;
    }

    var acquired_buffer: [16]u8 = undefined;
    var last_buffer: [16]u8 = undefined;
    var next_buffer: [16]u8 = undefined;

    try writer.print("{s}\n", .{plant.name});
    try writer.print("  database: {s}\n", .{database_path});
    try writer.print("  status: {s}\n", .{plant.status.text()});
    try writer.print("  interval: {d} day{s}\n", .{ plant.interval_days, pluralSuffix(plant.interval_days) });
    try writer.print("  acquired: {s}\n", .{try formatOptionalDay(plant.acquired_on, &acquired_buffer)});
    try writer.print("  last watered: {s}\n", .{try formatOptionalDay(plant.last_watered_day, &last_buffer)});
    try writer.print("  next watering: {s}\n", .{try formatOptionalDay(plant.next_watering_day, &next_buffer)});
    if (plant.common_name) |value| try writer.print("  common name: {s}\n", .{value});
    if (plant.species) |value| try writer.print("  species: {s}\n", .{value});
    if (plant.location) |value| try writer.print("  location: {s}\n", .{value});
    if (plant.notes) |value| try writer.print("  notes: {s}\n", .{value});

    try writer.writeAll("  history:\n");
    if (events.len == 0) {
        try writer.writeAll("    no events yet\n");
        return;
    }

    for (events) |event| {
        if (event.notes) |notes| {
            try writer.print("    #{d} {s} {s} | {s}\n", .{ event.id, event.happened_on_text, event.event_type, notes });
        } else {
            try writer.print("    #{d} {s} {s}\n", .{ event.id, event.happened_on_text, event.event_type });
        }
    }
}

fn writeHistory(mode: OutputMode, writer: *std.Io.Writer, events: []EventRecord) !void {
    if (mode == .json) {
        try writeJson(writer, events);
        return;
    }

    if (events.len == 0) {
        try writer.writeAll("No events found.\n");
        return;
    }

    for (events) |event| {
        if (event.notes) |notes| {
            try writer.print("#{d} {s} {s} {s} | {s}\n", .{ event.id, event.plant_name, event.happened_on_text, event.event_type, notes });
        } else {
            try writer.print("#{d} {s} {s} {s}\n", .{ event.id, event.plant_name, event.happened_on_text, event.event_type });
        }
    }
}

fn writeDoctor(mode: OutputMode, writer: *std.Io.Writer, report: DoctorReport) !void {
    if (mode == .json) {
        try writeJson(writer, report);
        return;
    }

    try writer.print("database: {s}\n", .{report.database_path});
    try writer.print("schema_version: {d}\n", .{report.schema_version});
    try writer.print("plants: {d}\n", .{report.plant_count});
    try writer.print("active: {d}\n", .{report.active_count});
    try writer.print("events: {d}\n", .{report.event_count});
}

fn writeExportDocument(
    writer: *std.Io.Writer,
    command: ExportCommand,
    document: ExportDocument,
) !void {
    if (command.path) |path| {
        const json = try jsonStringifyAlloc(std.heap.page_allocator, document);
        defer std.heap.page_allocator.free(json);
        try writeFileAtPath(path, json);
        try writer.print("Exported data to {s}.\n", .{path});
        return;
    }

    try writeJson(writer, document);
}

fn buildPlantSummary(allocator: std.mem.Allocator, plant: Plant) !PlantSummary {
    var acquired_buffer: [16]u8 = undefined;
    var last_buffer: [16]u8 = undefined;
    var next_buffer: [16]u8 = undefined;
    var due_buffer: [32]u8 = undefined;

    return .{
        .name = try allocator.dupe(u8, plant.name),
        .common_name = try duplicateOptionalText(allocator, plant.common_name),
        .species = try duplicateOptionalText(allocator, plant.species),
        .location = try duplicateOptionalText(allocator, plant.location),
        .notes = try duplicateOptionalText(allocator, plant.notes),
        .interval_days = plant.interval_days,
        .acquired_on = if (plant.acquired_on) |day| try allocator.dupe(u8, try formatDay(day, &acquired_buffer)) else null,
        .status = try allocator.dupe(u8, plant.status.text()),
        .last_watered_on = if (plant.last_watered_day) |day| try allocator.dupe(u8, try formatDay(day, &last_buffer)) else null,
        .next_watering_on = if (plant.next_watering_day) |day| try allocator.dupe(u8, try formatDay(day, &next_buffer)) else null,
        .due_status = if (plant.next_watering_day) |day|
            try allocator.dupe(u8, try formatDueStatus(day, try todayLocalDay(), &due_buffer))
        else
            null,
    };
}

fn freePlantSummary(allocator: std.mem.Allocator, summary: PlantSummary) void {
    allocator.free(summary.name);
    if (summary.common_name) |value| allocator.free(value);
    if (summary.species) |value| allocator.free(value);
    if (summary.location) |value| allocator.free(value);
    if (summary.notes) |value| allocator.free(value);
    if (summary.acquired_on) |value| allocator.free(value);
    allocator.free(summary.status);
    if (summary.last_watered_on) |value| allocator.free(value);
    if (summary.next_watering_on) |value| allocator.free(value);
    if (summary.due_status) |value| allocator.free(value);
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    var jw: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try jw.write(value);
    try writer.writeAll("\n");
}

fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(value);
    return json_writer.toOwnedSlice();
}

fn importDocument(allocator: std.mem.Allocator, database: Database, path: []const u8) !void {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(ImportDocument, allocator, contents, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try database.importData(parsed.value);
}

fn backupDatabase(source_path: []const u8, dest_path: []const u8) !void {
    if (std.fs.path.dirname(dest_path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    try std.fs.cwd().copyFile(source_path, std.fs.cwd(), dest_path, .{});
}

fn writeFileAtPath(path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.fs.cwd().makePath(parent);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = contents,
    });
}

fn reportUserError(err: anyerror) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stderr_writer.interface.flush() catch {};

    switch (err) {
        AppError.AmbiguousPlant => try stderr_writer.interface.writeAll("Plant query matched more than one plant. Use a more specific name.\n"),
        AppError.InvalidArguments,
        AppError.MissingValue,
        AppError.UnknownCommand,
        => try stderr_writer.interface.writeAll("Invalid arguments. Run `plant-journal help` for usage.\n"),
        AppError.InvalidDate => try stderr_writer.interface.writeAll("Invalid date. Use YYYY-MM-DD or `today`.\n"),
        AppError.InvalidEventType => try stderr_writer.interface.writeAll("Invalid event type.\n"),
        AppError.InvalidInterval => try stderr_writer.interface.writeAll("Invalid interval. Use a positive whole number of days.\n"),
        AppError.InvalidLimit => try stderr_writer.interface.writeAll("Invalid limit. Use a positive whole number.\n"),
        AppError.InvalidStatus => try stderr_writer.interface.writeAll("Invalid status. Use active, archived, gifted, or dead.\n"),
        AppError.MissingEvent => try stderr_writer.interface.writeAll("No matching watering event was found.\n"),
        AppError.MissingHome => try stderr_writer.interface.writeAll("Could not resolve a per-user data directory. Set --db, $HOME, $XDG_DATA_HOME, or $PLANT_JOURNAL_DB.\n"),
        AppError.NoChangeRequested => try stderr_writer.interface.writeAll("No changes were requested.\n"),
        AppError.PlantNotFound => try stderr_writer.interface.writeAll("Plant not found.\n"),
        AppError.UnsupportedDate => try stderr_writer.interface.writeAll("Only dates on or after 1970-01-01 are supported.\n"),
        error.ConstraintUnique => try stderr_writer.interface.writeAll("A plant with that name already exists.\n"),
        else => try stderr_writer.interface.print("Error: {s}\n", .{@errorName(err)}),
    }
}

fn resolveDatabasePath(allocator: std.mem.Allocator, db_override: ?[]const u8) ![]const u8 {
    if (db_override) |path| {
        if (std.fs.path.dirname(path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }
        return allocator.dupe(u8, path);
    }

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

fn plantFromRow(allocator: std.mem.Allocator, row: zqlite.Row) !Plant {
    return .{
        .id = row.int(0),
        .name = try allocator.dupe(u8, row.text(1)),
        .common_name = try duplicateOptionalText(allocator, row.nullableText(2)),
        .species = try duplicateOptionalText(allocator, row.nullableText(3)),
        .location = try duplicateOptionalText(allocator, row.nullableText(4)),
        .notes = try duplicateOptionalText(allocator, row.nullableText(5)),
        .interval_days = row.int(6),
        .acquired_on = row.nullableInt(7),
        .status = try PlantStatus.parse(row.text(8)),
        .last_watered_day = row.nullableInt(9),
        .next_watering_day = row.nullableInt(10),
    };
}

fn eventFromRow(allocator: std.mem.Allocator, row: zqlite.Row) !EventRecord {
    var date_buffer: [16]u8 = undefined;
    return .{
        .id = row.int(0),
        .plant_id = row.int(1),
        .plant_name = try allocator.dupe(u8, row.text(2)),
        .event_type = try allocator.dupe(u8, row.text(3)),
        .happened_on = row.int(4),
        .happened_on_text = try allocator.dupe(u8, try formatDay(row.int(4), &date_buffer)),
        .notes = try duplicateOptionalText(allocator, row.nullableText(5)),
        .metadata_json = try duplicateOptionalText(allocator, row.nullableText(6)),
    };
}

fn duplicateOptionalText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| {
        const copy = try allocator.dupe(u8, text);
        return copy;
    }
    return null;
}

fn applyTextUpdate(
    allocator: std.mem.Allocator,
    current: []const u8,
    update: TextUpdate,
    changed: *bool,
) ![]const u8 {
    return switch (update) {
        .keep => try allocator.dupe(u8, current),
        .set => |value| blk: {
            changed.* = true;
            break :blk try allocator.dupe(u8, value);
        },
        .clear => current,
    };
}

fn applyTextUpdateOptional(
    allocator: std.mem.Allocator,
    current: ?[]const u8,
    update: TextUpdate,
    changed: *bool,
) !?[]const u8 {
    return switch (update) {
        .keep => try duplicateOptionalText(allocator, current),
        .set => |value| blk: {
            changed.* = true;
            break :blk try allocator.dupe(u8, value);
        },
        .clear => blk: {
            changed.* = true;
            break :blk null;
        },
    };
}

fn applyIntUpdate(current: i64, update: IntUpdate, changed: *bool) i64 {
    return switch (update) {
        .keep => current,
        .set => |value| blk: {
            changed.* = true;
            break :blk value;
        },
    };
}

fn applyDateUpdate(current: ?i64, update: DateUpdate, changed: *bool) ?i64 {
    return switch (update) {
        .keep => current,
        .set => |value| blk: {
            changed.* = true;
            break :blk value;
        },
        .clear => blk: {
            changed.* = true;
            break :blk null;
        },
    };
}

fn applyStatusUpdate(current: PlantStatus, update: StatusUpdate, changed: *bool) PlantStatus {
    return switch (update) {
        .keep => current,
        .set => |value| blk: {
            if (value != current) changed.* = true;
            break :blk value;
        },
    };
}

fn todayLocalDay() !i64 {
    const now = c.time(null);
    if (now < 0) return AppError.UnsupportedDate;

    var local_time: c.struct_tm = undefined;
    if (c.localtime_r(&now, &local_time) == null) return AppError.UnsupportedDate;

    const year: u16 = @intCast(local_time.tm_year + 1900);
    const month: u8 = @intCast(local_time.tm_mon + 1);
    const day: u8 = @intCast(local_time.tm_mday);
    return ymdToEpochDay(year, month, day);
}

fn parseDateArgument(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "today")) return todayLocalDay();
    return parseIsoDay(value);
}

fn parseIsoDay(value: []const u8) !i64 {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return AppError.InvalidDate;

    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return AppError.InvalidDate;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return AppError.InvalidDate;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return AppError.InvalidDate;

    return ymdToEpochDay(year, month, day);
}

fn ymdToEpochDay(year: u16, month_number: u8, day_number: u8) !i64 {
    if (year < epoch.epoch_year) return AppError.UnsupportedDate;

    const month = monthFromNumber(month_number) catch return AppError.InvalidDate;
    const days_in_month = epoch.getDaysInMonth(year, month);
    if (day_number == 0 or day_number > days_in_month) return AppError.InvalidDate;

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
    if (day) |value| return formatDay(value, buffer);
    return "n/a";
}

fn formatDay(day: i64, buffer: *[16]u8) ![]const u8 {
    if (day < 0) return AppError.UnsupportedDate;

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
    if (delta == 0) return "due today";
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

test "parse status values" {
    try std.testing.expectEqual(PlantStatus.gifted, try PlantStatus.parse("gifted"));
    try std.testing.expectError(AppError.InvalidStatus, PlantStatus.parse("sleepy"));
}

test {
    std.testing.refAllDecls(@This());
}
