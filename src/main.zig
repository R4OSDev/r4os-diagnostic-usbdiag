const std = @import("std");
const r4os = @import("r4os");

const read_stress_default_passes: u32 = 8;
const read_stress_max_passes: u32 = 64;
const read_stress_chunk_size: usize = 4096;
const read_stress_max_path: usize = 260;
const fnv1a_offset_basis: u64 = 14_695_981_039_346_656_037;
const fnv1a_prime: u64 = 1_099_511_628_211;

const ReadStressOptions = struct {
    path: []const u8,
    passes: u32,
};

const App = struct {
    app: *r4os.App2,
    files: r4os.Files,
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App2) ?App {
        return .{
            .app = r4_app,
            .files = r4_app.files() orelse return null,
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }

    fn run(self: *App) i32 {
        self.sys.println("USBDIAG");
        var ok = true;
        ok = self.checkApi() and ok;
        ok = self.checkRole("usb.hid_report") and ok;
        ok = self.checkRole("usb.hid_boot") and ok;
        ok = self.checkRole("usb.msc_bot") and ok;
        ok = self.checkRole("usb.scsi_block") and ok;
        ok = self.checkHidReport() and ok;
        ok = self.checkHidBoot() and ok;
        ok = self.checkMscBot() and ok;
        ok = self.checkScsiBlock() and ok;

        self.sys.write("USBDIAG result: ");
        self.sys.println(if (ok) "OK" else "FAILED");
        return if (ok) 0 else 1;
    }

    fn runReadStress(self: *App, options: ReadStressOptions) i32 {
        var path_buffer: [read_stress_max_path:0]u8 = .{0} ** read_stress_max_path;
        _ = copyZ(path_buffer[0..], options.path) orelse {
            self.sys.println("USBDIAG read-stress error: path-too-long");
            self.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        };

        const file_path = r4os.FilePath.parse(options.path) catch {
            self.sys.println("USBDIAG read-stress error: invalid-path");
            return 1;
        };
        const metadata = switch (self.files.metadata(file_path.asZ())) {
            .found => |value| value,
            .missing => {
                self.sys.println("USBDIAG read-stress error: file-not-found");
                return 1;
            },
            .failure => {
                self.sys.println("USBDIAG read-stress error: metadata-unavailable");
                return 1;
            },
        };
        if (metadata.flags & r4os.abi.file_metadata2_flag_directory != 0) {
            self.sys.println("USBDIAG read-stress error: path-is-directory");
            return 1;
        }
        const size = r4os.metadata2.fileSize(&metadata) orelse {
            self.sys.println("USBDIAG read-stress error: file-size-unavailable");
            return 1;
        };
        // The shared borrowed path reader has an explicit u32 offset range.
        // Keep the original limit; counters and the transfer offset stay u64.
        if (size > std.math.maxInt(u32) or size > std.math.maxInt(u64) / @as(u64, options.passes)) {
            self.sys.println("USBDIAG read-stress error: file-too-large-for-path-reader");
            return 1;
        }

        self.sys.write("USBDIAG read-stress start path=");
        self.sys.write(options.path);
        self.sys.write(" size=");
        self.sys.printU64(size);
        self.sys.write(" passes=");
        self.sys.printU64(options.passes);
        self.sys.write(" chunk=");
        self.sys.printU64(read_stress_chunk_size);
        self.sys.println("");

        var reference_checksum: ?u64 = null;
        var pass: u32 = 1;
        while (pass <= options.passes) : (pass += 1) {
            const result = self.readStressPass(file_path.asZ().ptr, size);
            const checksum_matches = if (reference_checksum) |expected| result.checksum == expected else true;
            const pass_ok = result.ok and checksum_matches;

            self.sys.write("USBDIAG read-stress pass=");
            self.sys.printU64(pass);
            self.sys.putc('/');
            self.sys.printU64(options.passes);
            self.sys.write(" bytes=");
            self.sys.printU64(result.bytes);
            self.sys.write(" checksum=");
            self.sys.printU64(result.checksum);
            self.sys.write(" result=");
            self.sys.println(if (pass_ok) "OK" else "FAILED");

            if (!pass_ok) {
                if (!result.ok) {
                    self.sys.write("USBDIAG read-stress error: read rc=");
                    self.sys.printI32(result.read_result);
                    self.sys.write(" expected=");
                    self.sys.printU64(result.expected);
                    self.sys.println("");
                } else {
                    self.sys.write("USBDIAG read-stress error: checksum-mismatch expected=");
                    self.sys.printU64(reference_checksum.?);
                    self.sys.println("");
                }
                self.sys.println("USBDIAG read-stress result: FAILED");
                return 1;
            }

            if (reference_checksum == null) reference_checksum = result.checksum;
        }

        self.sys.write("USBDIAG read-stress summary passes=");
        self.sys.printU64(options.passes);
        self.sys.write(" bytes=");
        self.sys.printU64(size * options.passes);
        self.sys.write(" checksum=");
        self.sys.printU64(reference_checksum orelse fnv1a_offset_basis);
        self.sys.println("");
        self.sys.println("USBDIAG read-stress result: OK");
        return 0;
    }

    const ReadStressPassResult = struct {
        ok: bool,
        bytes: u64,
        checksum: u64,
        read_result: i32,
        expected: usize,
    };

    fn readStressPass(self: *App, path: [*:0]const u8, size: u64) ReadStressPassResult {
        var buffer: [read_stress_chunk_size]u8 = undefined;
        var clock = self.app.clock() catch return .{ .ok = false, .bytes = 0, .checksum = fnv1a_offset_basis, .read_result = r4os.abi.err_no_fn, .expected = 0 };
        const budget = r4os.rpc_budget.Budget.fromTimeout(clock.read, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 30_000_000_000 }) catch return .{ .ok = false, .bytes = 0, .checksum = fnv1a_offset_basis, .read_result = r4os.abi.err_no_fn, .expected = 0 };
        var source = r4os.stream_transfer.adapters.FileRead.fromContext2(self.sys.base.generation2.?, path, 0) catch return .{ .ok = false, .bytes = 0, .checksum = fnv1a_offset_basis, .read_result = r4os.abi.err_no_fn, .expected = 0 };
        var transfer = r4os.stream_transfer.Transfer.initAbsolute(.read_exact, size, budget.deadline) catch unreachable;
        var checksum = fnv1a_offset_basis;
        while (true) {
            const progress = transfer.readStep(&buffer, read_stress_chunk_size, self.app.shouldClose(), r4os.stream_transfer.adapters.PlatformClock.sample, &clock, r4os.stream_transfer.adapters.FileRead.step, &source) catch return .{ .ok = false, .bytes = transfer.bytes, .checksum = checksum, .read_result = r4os.abi.file_stream_error_io, .expected = 0 };
            checksum = checksumUpdate(checksum, buffer[0..progress.last_bytes]);
            if (progress.flags & r4os.stream_transfer.core.terminal != 0) return .{
                .ok = progress.outcome == @intFromEnum(r4os.stream_transfer.Outcome.complete) and progress.bytes == size,
                .bytes = progress.bytes,
                .checksum = checksum,
                .read_result = progress.error_code,
                .expected = @intCast(@min(size - progress.bytes, buffer.len)),
            };
            if (progress.outcome == @intFromEnum(r4os.stream_transfer.Outcome.would_block)) self.sys.sleepTicks(1);
        }
    }

    fn checkApi(self: *App) bool {
        const ok = self.dev.hasFn("protocol_dispatch");
        self.printCheck("USBDIAG api protocol-dispatch", ok);
        return ok;
    }

    fn checkRole(self: *App, role: []const u8) bool {
        var status: r4os.abi.ProtocolStatus = .{};
        const rc = self.dev.protocolStatus(role, &status);
        const ok = rc == 0 and status.state == @intFromEnum(r4os.abi.ProtocolState.active) and (status.flags & ((1 << 1) | (1 << 2))) != 0;
        self.sys.write("USBDIAG role ");
        self.sys.write(role);
        self.sys.write(": ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" source=");
        self.sys.write(sourceName(status.flags));
        self.sys.write(" state=");
        self.sys.write(stateName(status.state));
        if (rc != 0) {
            self.sys.write(" rc=");
            self.sys.printI32(rc);
        }
        self.sys.println("");
        return ok;
    }

    fn checkHidReport(self: *App) bool {
        var op: r4os.abi.HidReportOp = .{};
        const rc = self.dispatch("usb.hid_report", r4os.abi.hid_report_op_self_test, r4os.abi.HidReportOp, &op);
        const ok = rc == r4os.abi.hid_report_result_ok and op.result == r4os.abi.hid_report_result_ok and op.summary.parsed != 0 and op.summary.malformed == 0;
        self.printDispatch("hid-report", ok, rc, op.result);
        return ok;
    }

    fn checkHidBoot(self: *App) bool {
        var op: r4os.abi.UsbHidBootOp = .{};
        const rc = self.dispatch("usb.hid_boot", r4os.abi.usb_hid_boot_op_self_test, r4os.abi.UsbHidBootOp, &op);
        const ok = rc == r4os.abi.usb_hid_boot_result_ok and op.result == r4os.abi.usb_hid_boot_result_ok;
        self.printDispatch("hid-boot", ok, rc, op.result);
        return ok;
    }

    fn checkMscBot(self: *App) bool {
        var op: r4os.abi.UsbMscBotOp = .{};
        const rc = self.dispatch("usb.msc_bot", r4os.abi.usb_msc_bot_op_self_test, r4os.abi.UsbMscBotOp, &op);
        const ok = rc == r4os.abi.usb_msc_bot_result_ok and op.result == r4os.abi.usb_msc_bot_result_ok;
        self.printDispatch("msc-bot", ok, rc, op.result);
        return ok;
    }

    fn checkScsiBlock(self: *App) bool {
        var op: r4os.abi.UsbScsiBlockOp = .{};
        const rc = self.dispatch("usb.scsi_block", r4os.abi.usb_scsi_op_self_test, r4os.abi.UsbScsiBlockOp, &op);
        var ok = rc == r4os.abi.usb_scsi_result_ok and op.result == r4os.abi.usb_scsi_result_ok;
        self.printDispatch("scsi-block", ok, rc, op.result);

        op = .{
            .lba64 = 0x0000_0001_2345_6789,
            .block_count = 4,
            .logical_block_size = 4096,
        };
        const read16_rc = self.dispatch("usb.scsi_block", r4os.abi.usb_scsi_op_build_read16, r4os.abi.UsbScsiBlockOp, &op);
        const read16_ok = read16_rc == 0 and op.result == 0 and op.cdb[0] == 0x88 and op.cdb_len == 16 and op.transfer_len == 16384;
        self.printDispatch("scsi-read16-4kn", read16_ok, read16_rc, op.result);
        ok = read16_ok and ok;

        op = .{
            .lba64 = 0x0000_0002_3456_789A,
            .block_count = 2,
            .logical_block_size = 4096,
        };
        const write16_rc = self.dispatch("usb.scsi_block", r4os.abi.usb_scsi_op_build_write16, r4os.abi.UsbScsiBlockOp, &op);
        const write16_ok = write16_rc == 0 and op.result == 0 and op.cdb[0] == 0x8A and op.cdb_len == 16 and op.transfer_len == 8192 and op.direction == r4os.abi.usb_scsi_dir_out;
        self.printDispatch("scsi-write16-4kn", write16_ok, write16_rc, op.result);
        ok = write16_ok and ok;

        op = .{ .allocation_len = 32 };
        writeBe64(op.data[0..8], 0x0000_0001_0000_0000);
        writeBe32(op.data[8..12], 4096);
        const capacity16_rc = self.dispatch("usb.scsi_block", r4os.abi.usb_scsi_op_parse_capacity16, r4os.abi.UsbScsiBlockOp, &op);
        const capacity16_ok = capacity16_rc == 0 and op.result == 0 and op.sector_count == 0x0000_0001_0000_0001 and op.sector_size == 4096 and op.capacity_format == 16;
        self.printDispatch("scsi-capacity16-4kn", capacity16_ok, capacity16_rc, op.result);
        ok = capacity16_ok and ok;
        return ok;
    }

    fn dispatch(self: *App, role: []const u8, opcode: u32, comptime T: type, op: *T) i32 {
        var in_buffer = r4os.abi.ProtocolBuffer{
            .data = op,
            .len = @sizeOf(T),
            .capacity = @sizeOf(T),
            .flags = 0,
            .reserved = 0,
        };
        var out_buffer: r4os.abi.ProtocolBuffer = .{};
        return self.dev.protocolDispatch(role, opcode, &in_buffer, &out_buffer);
    }

    fn printCheck(self: *App, label: []const u8, ok: bool) void {
        self.sys.write(label);
        self.sys.write(": ");
        self.sys.println(if (ok) "OK" else "FAILED");
    }

    fn printDispatch(self: *App, label: []const u8, ok: bool, rc: i32, result: i32) void {
        self.sys.write("USBDIAG selftest ");
        self.sys.write(label);
        self.sys.write(": ");
        self.sys.write(if (ok) "OK" else "FAILED");
        self.sys.write(" rc=");
        self.sys.printI32(rc);
        self.sys.write(" result=");
        self.sys.printI32(result);
        self.sys.println("");
    }
};

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const args = r4_app.args();
    var failure: r4os.arguments.Failure = .{};
    var cursor = r4_app.argCursor(.{ .quotes = 0, .max_bytes = 4096 }, &failure) catch return usage(&app);
    const command = cursor.next() catch return usage(&app);
    if (command) |token| {
        const options = parseReadStressOptions(&cursor, args, token) orelse return usage(&app);
        return app.runReadStress(options);
    }
    return app.run();
}

fn usage(app: *App) i32 {
    app.sys.println("Usage: USBDIAG.R4X /READSTRESS PATH [PASSES]");
    app.sys.println("       PASSES must be between 1 and 64 (default 8).");
    app.sys.println("USBDIAG read-stress result: FAILED");
    return 1;
}

fn parseReadStressOptions(cursor: *r4os.arguments.ArgCursor, args: []const u8, command: r4os.arguments.Token) ?ReadStressOptions {
    if (!equalsIgnoreCase(command.bytes(args) catch return null, "/READSTRESS")) return null;
    const path = (cursor.next() catch return null) orelse return null;
    const path_bytes = path.bytes(args) catch return null;
    const count_token = (cursor.next() catch return null) orelse return .{ .path = path_bytes, .passes = read_stress_default_passes };
    const count = parsePasses(count_token.bytes(args) catch return null) orelse return null;
    if ((cursor.next() catch return null) != null) return null;
    return .{ .path = path_bytes, .passes = count };
}

fn parsePasses(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var result: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        result = result * 10 + @as(u32, ch - '0');
        if (result > read_stress_max_passes) return null;
    }
    if (result == 0) return null;
    return result;
}

fn checksumUpdate(seed: u64, bytes: []const u8) u64 {
    var checksum = seed;
    for (bytes) |byte| {
        checksum ^= byte;
        checksum *%= fnv1a_prime;
    }
    return checksum;
}

fn writeBe32(out: []u8, value: u32) void {
    out[0] = @truncate(value >> 24);
    out[1] = @truncate(value >> 16);
    out[2] = @truncate(value >> 8);
    out[3] = @truncate(value);
}

fn writeBe64(out: []u8, value: u64) void {
    writeBe32(out[0..4], @truncate(value >> 32));
    writeBe32(out[4..8], @truncate(value));
}

fn copyZ(out: [:0]u8, value: []const u8) ?[*:0]const u8 {
    if (value.len >= out.len) return null;
    @memcpy(out[0..value.len], value);
    out[value.len] = 0;
    return @ptrCast(out.ptr);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}

fn sourceName(flags: u32) []const u8 {
    if ((flags & (1 << 2)) != 0) return "preload";
    if ((flags & (1 << 1)) != 0) return "r4p";
    if ((flags & (1 << 0)) != 0) return "builtin";
    return "none";
}

fn stateName(state: u32) []const u8 {
    return switch (state) {
        1 => "loaded",
        2 => "active",
        3 => "fallback",
        4 => "blocked",
        5 => "error",
        6 => "disabled",
        else => "missing",
    };
}
