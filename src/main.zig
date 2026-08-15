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
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
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
        const path = copyZ(path_buffer[0..], options.path) orelse {
            self.sys.println("USBDIAG read-stress error: path-too-long");
            self.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        };

        const info = self.sys.fileInfo(path) orelse {
            self.sys.println("USBDIAG read-stress error: file-not-found");
            self.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        };
        if (info.is_dir != 0) {
            self.sys.println("USBDIAG read-stress error: path-is-directory");
            self.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        }
        if (info.size > 0xffff_ffff) {
            self.sys.println("USBDIAG read-stress error: file-too-large-for-fileReadAt");
            self.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        }

        self.sys.write("USBDIAG read-stress start path=");
        self.sys.write(options.path);
        self.sys.write(" size=");
        self.sys.printU64(info.size);
        self.sys.write(" passes=");
        self.sys.printU64(options.passes);
        self.sys.write(" chunk=");
        self.sys.printU64(read_stress_chunk_size);
        self.sys.println("");

        var reference_checksum: ?u64 = null;
        var pass: u32 = 1;
        while (pass <= options.passes) : (pass += 1) {
            const result = self.readStressPass(path, info.size);
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
        self.sys.printU64(info.size * options.passes);
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
        var offset: u64 = 0;
        var checksum = fnv1a_offset_basis;

        while (offset < size) {
            const want: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
            const read = self.sys.fileReadAt(path, @intCast(offset), buffer[0..want]);
            if (read <= 0 or read > @as(i32, @intCast(want))) {
                return .{
                    .ok = false,
                    .bytes = offset,
                    .checksum = checksum,
                    .read_result = read,
                    .expected = want,
                };
            }
            const read_len: usize = @intCast(read);
            checksum = checksumUpdate(checksum, buffer[0..read_len]);
            offset += read_len;
        }

        return .{
            .ok = true,
            .bytes = offset,
            .checksum = checksum,
            .read_result = 0,
            .expected = 0,
        };
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
        const ok = rc == r4os.abi.usb_scsi_result_ok and op.result == r4os.abi.usb_scsi_result_ok;
        self.printDispatch("scsi-block", ok, rc, op.result);
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

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const args = trim(r4_app.args());
    if (args.len != 0) {
        const options = parseReadStressOptions(args) orelse {
            app.sys.println("Usage: USBDIAG.R4X /READSTRESS PATH [PASSES]");
            app.sys.println("       PASSES must be between 1 and 64 (default 8).");
            app.sys.println("USBDIAG read-stress result: FAILED");
            return 1;
        };
        return app.runReadStress(options);
    }
    return app.run();
}

fn parseReadStressOptions(args: []const u8) ?ReadStressOptions {
    const command = takeToken(args) orelse return null;
    if (!equalsIgnoreCase(command.token, "/READSTRESS")) return null;

    const path = takeToken(command.rest) orelse return null;
    if (path.rest.len == 0) {
        return .{ .path = path.token, .passes = read_stress_default_passes };
    }

    const passes = takeToken(path.rest) orelse return null;
    if (passes.rest.len != 0) return null;
    const count = parsePasses(passes.token) orelse return null;
    return .{ .path = path.token, .passes = count };
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

fn takeToken(value: []const u8) ?Token {
    const trimmed = trim(value);
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and !isSpace(trimmed[end])) : (end += 1) {}
    return .{
        .token = trimmed[0..end],
        .rest = if (end >= trimmed.len) "" else trim(trimmed[end..]),
    };
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

fn copyZ(out: [:0]u8, value: []const u8) ?[*:0]const u8 {
    if (value.len >= out.len) return null;
    @memcpy(out[0..value.len], value);
    out[value.len] = 0;
    return @ptrCast(out.ptr);
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
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
