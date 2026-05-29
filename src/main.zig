const std = @import("std");
const builtin = @import("builtin");
const speech = @import("speech");

const version = "0.2.0";

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print(
        \\Usage: stenographer <command> [options]
        \\
        \\Speech-to-text CLI powered by native macOS Speech Recognition.
        \\Transcribe audio files or live microphone input, on-device.
        \\Version {s} ({s})
        \\
        \\Commands:
        \\  transcribe <file>  Transcribe an audio file
        \\  listen             Transcribe from the microphone (Enter/Esc to stop)
        \\  locales            List supported languages
        \\  help               Show this help message
        \\
        \\Options:
        \\  --locale=CODE      Language locale (default: en-US)
        \\  --on-device        Force on-device recognition (no network)
        \\  --duration=MS      Max listen duration in ms (0=unlimited, default: 0)
        \\  --silence=MS       Stop after this many ms of silence (default: 3000, 0=disabled)
        \\  --no-stream        Don't print partial results while listening
        \\  --verbose          Show debug info on stderr
        \\  --json             Output as JSON
        \\  --help, -h         Show this help message
        \\  --version, -v      Show version
        \\
        \\Examples:
        \\  stenographer transcribe meeting.wav
        \\  stenographer transcribe interview.mp3 --locale=fr-FR --json
        \\  stenographer transcribe podcast.m4a --on-device
        \\  stenographer listen
        \\  stenographer listen --duration=30000
        \\  stenographer listen --silence=5000
        \\  stenographer listen --no-stream
        \\  stenographer locales
        \\
        \\Created by George Mandis <george@mand.is>
        \\
    , .{ version, @tagName(builtin.os.tag) });
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

// ---------------------------------------------------------------------------
// Streaming output callback
// ---------------------------------------------------------------------------

// Module-level state for callbacks (accessed from function pointers)
var stream_writer: ?*std.Io.Writer = null;
var log_writer: ?*std.Io.Writer = null;

fn onLogMessage(msg: []const u8) void {
    const writer = log_writer orelse return;
    writer.print("{s}\n", .{msg}) catch return;
    writer.flush() catch return;
}

// Track how many lines we last printed so we can erase and rewrite
var stream_last_line_count: usize = 0;
var stream_term_width: usize = 80;

fn countDisplayLines(text: []const u8, width: usize) usize {
    if (text.len == 0) return 0;
    var lines: usize = 0;
    var col: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            lines += 1;
            col = 0;
        } else {
            col += 1;
            if (col >= width) {
                lines += 1;
                col = 0;
            }
        }
    }
    // The last partial line counts too
    if (col > 0) lines += 1;
    return lines;
}

fn onPartialResult(text: []const u8) void {
    const writer = stream_writer orelse return;

    // Move cursor up to erase previous output
    if (stream_last_line_count > 0) {
        // Move to start of our output: up N lines, then to column 1
        writer.print("\x1b[{d}A\r", .{stream_last_line_count}) catch return;
    } else {
        // First time — just go to start of current line
        writer.print("\r", .{}) catch return;
    }
    // Clear from cursor to end of screen
    writer.print("\x1b[J", .{}) catch return;
    // Print the full text
    writer.print("{s}", .{text}) catch return;
    writer.flush() catch return;

    stream_last_line_count = countDisplayLines(text, stream_term_width);
    // Subtract 1 because cursor is already on the last line
    if (stream_last_line_count > 0) stream_last_line_count -= 1;
}

pub fn main(init: std.process.Init) !void {
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = stdout_file.writerStreaming(init.io, &stdout_buf);

    const stderr_file = std.Io.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr = stderr_file.writerStreaming(init.io, &stderr_buf);

    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip program name

    // Get command
    const command = args_iter.next() orelse {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "help")) {
        try printUsage(&stdout.interface);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        try stdout.interface.print("stenographer " ++ version ++ " (" ++ @tagName(builtin.os.tag) ++ ")\n", .{});
        try stdout.interface.flush();
        return;
    }

    // Parse flags
    var json_mode = false;
    var locale: []const u8 = "en-US";
    var on_device = false;
    var duration_ms: u32 = 0;
    var silence_ms: u32 = 3000;
    var no_stream = false;
    var verbose = false;
    var file_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--on-device")) {
            on_device = true;
        } else if (std.mem.eql(u8, arg, "--no-stream")) {
            no_stream = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--locale=")) {
            locale = arg["--locale=".len..];
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_ms = std.fmt.parseInt(u32, arg["--duration=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --duration value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--silence=")) {
            silence_ms = std.fmt.parseInt(u32, arg["--silence=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --silence value\n", .{});
                try stderr.interface.flush();
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.interface.print("Error: unknown flag: {s}\n", .{arg});
            try stderr.interface.flush();
            std.process.exit(2);
        } else {
            if (file_path == null) {
                file_path = arg;
            }
        }
    }

    // Dispatch commands
    if (std.mem.eql(u8, command, "locales")) {
        try cmdLocales(&stdout.interface, allocator, json_mode);
    } else if (std.mem.eql(u8, command, "transcribe")) {
        const path = file_path orelse {
            try stderr.interface.print("Error: no file path provided\n", .{});
            try stderr.interface.flush();
            std.process.exit(1);
        };
        try cmdTranscribe(&stdout.interface, allocator, path, locale, on_device, json_mode);
    } else if (std.mem.eql(u8, command, "listen")) {
        const is_tty = stdout_file.isTty(init.io) catch false;
        const streaming = !no_stream and !json_mode and is_tty;
        try cmdListen(&stdout.interface, &stderr.interface, allocator, .{
            .locale = locale,
            .duration_ms = duration_ms,
            .on_device = on_device,
            .silence_ms = silence_ms,
            .json_mode = json_mode,
            .streaming = streaming,
            .verbose = verbose,
        });
    } else {
        try stderr.interface.print("Error: unknown command '{s}'\n\n", .{command});
        try printUsage(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(2);
    }

    try stdout.interface.flush();
}

fn cmdLocales(writer: *std.Io.Writer, allocator: std.mem.Allocator, json_mode: bool) !void {
    const locales = speech.listLocales(allocator) catch |err| {
        return printSpeechError(writer, err);
    };
    defer speech.freeLocales(allocator, locales);

    // Sort alphabetically
    std.mem.sort(speech.Locale, locales, {}, struct {
        fn lessThan(_: void, a: speech.Locale, b: speech.Locale) bool {
            return std.mem.lessThan(u8, a.identifier, b.identifier);
        }
    }.lessThan);

    if (json_mode) {
        try writer.print("[", .{});
        for (locales, 0..) |l, i| {
            if (i > 0) try writer.print(",", .{});
            try writer.print("\"", .{});
            try writeJsonString(writer, l.identifier);
            try writer.print("\"", .{});
        }
        try writer.print("]\n", .{});
    } else {
        for (locales) |l| {
            try writer.print("{s}\n", .{l.identifier});
        }
    }
}

fn cmdTranscribe(writer: *std.Io.Writer, allocator: std.mem.Allocator, path: []const u8, locale: []const u8, on_device: bool, json_mode: bool) !void {
    const result = speech.transcribeFile(allocator, path, locale, on_device) catch |err| {
        return printSpeechError(writer, err);
    };
    defer speech.freeTranscription(allocator, result);

    if (json_mode) {
        try writer.print("{{\"text\":\"", .{});
        try writeJsonString(writer, result.text);
        try writer.print("\"}}\n", .{});
    } else {
        try writer.print("{s}\n", .{result.text});
    }
}

const ListenCmdOpts = struct {
    locale: []const u8,
    duration_ms: u32,
    on_device: bool,
    silence_ms: u32,
    json_mode: bool,
    streaming: bool,
    verbose: bool,
};

// Thread that reads stdin for stop key (Enter/Escape) and sets a flag
var listen_stop_flag: bool = false;

fn stdinWatchThread() void {
    const stdin_fd = std.posix.STDIN_FILENO;
    var buf: [1]u8 = undefined;
    while (!listen_stop_flag) {
        const n = std.posix.read(stdin_fd, &buf) catch break;
        if (n == 0) break;
        // Enter (0x0A or 0x0D) or Escape (0x1B)
        if (buf[0] == '\n' or buf[0] == '\r' or buf[0] == 0x1B) {
            listen_stop_flag = true;
            break;
        }
    }
}

fn cmdListen(writer: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, opts: ListenCmdOpts) !void {
    if (opts.verbose) {
        if (opts.duration_ms > 0 and opts.silence_ms > 0) {
            try stderr.print("Listening for {d:.1}s (silence timeout: {d:.1}s)...\n", .{
                @as(f64, @floatFromInt(opts.duration_ms)) / 1000.0,
                @as(f64, @floatFromInt(opts.silence_ms)) / 1000.0,
            });
        } else if (opts.duration_ms > 0) {
            try stderr.print("Listening for {d:.1}s...\n", .{
                @as(f64, @floatFromInt(opts.duration_ms)) / 1000.0,
            });
        } else if (opts.silence_ms > 0) {
            try stderr.print("Listening (silence timeout: {d:.1}s)...\n", .{
                @as(f64, @floatFromInt(opts.silence_ms)) / 1000.0,
            });
        } else {
            try stderr.print("Listening...\n", .{});
        }
        try stderr.flush();
    }

    // Set up streaming callback
    if (opts.streaming) {
        stream_writer = writer;
        stream_last_line_count = 0;
        // Get terminal width via ioctl
        stream_term_width = blk: {
            var ws: std.posix.winsize = undefined;
            const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
            break :blk if (rc == 0 and ws.col > 0) @as(usize, ws.col) else 80;
        };
    } else {
        stream_writer = null;
    }

    // Set up verbose logging
    if (opts.verbose) {
        log_writer = stderr;
    } else {
        log_writer = null;
    }

    // Set up stdin keypress listener (Enter/Escape to stop) when interactive
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdin_is_tty = std.posix.system.isatty(stdin_fd) != 0;
    var orig_termios: std.posix.termios = undefined;
    var stdin_thread: ?std.Thread = null;

    if (stdin_is_tty) {
        listen_stop_flag = false;
        // Put stdin into raw mode so keypresses arrive immediately
        orig_termios = std.posix.tcgetattr(stdin_fd) catch blk: {
            break :blk undefined;
        };
        var raw = orig_termios;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(stdin_fd, .NOW, raw) catch {};

        stdin_thread = std.Thread.spawn(.{}, stdinWatchThread, .{}) catch null;
    }

    defer {
        if (stdin_is_tty) {
            listen_stop_flag = true;
            // Restore terminal
            std.posix.tcsetattr(stdin_fd, .NOW, orig_termios) catch {};
            if (stdin_thread) |t| t.join();
        }
    }

    const result = speech.listen(allocator, .{
        .locale = opts.locale,
        .duration_ms = opts.duration_ms,
        .on_device = opts.on_device,
        .silence_timeout_ms = opts.silence_ms,
        .on_partial = if (opts.streaming) &onPartialResult else null,
        .on_log = if (opts.verbose) &onLogMessage else null,
        .stop_flag = if (stdin_is_tty) &listen_stop_flag else null,
    }) catch |err| {
        stream_writer = null;
        log_writer = null;
        return printSpeechError(writer, err);
    };
    defer speech.freeTranscription(allocator, result);

    // Clean up callback state
    stream_writer = null;
    log_writer = null;

    if (opts.streaming) {
        // Final rewrite: erase streaming output and print clean result
        if (stream_last_line_count > 0) {
            try writer.print("\x1b[{d}A\r", .{stream_last_line_count});
        } else {
            try writer.print("\r", .{});
        }
        try writer.print("\x1b[J{s}\n", .{result.text});
    } else if (opts.json_mode) {
        try writer.print("{{\"text\":\"", .{});
        try writeJsonString(writer, result.text);
        try writer.print("\"}}\n", .{});
    } else {
        try writer.print("{s}\n", .{result.text});
    }
}

fn printSpeechError(writer: *std.Io.Writer, err: speech.SpeechError) !void {
    const msg: []const u8 = switch (err) {
        speech.SpeechError.FrameworkUnavailable => "Speech framework not available",
        speech.SpeechError.RecognitionFailed => "Speech recognition failed",
        speech.SpeechError.PermissionDenied => "Speech recognition permission denied",
        speech.SpeechError.FileNotFound => "Audio file not found or unsupported format",
        speech.SpeechError.MicrophoneUnavailable => "Microphone not available or access denied",
        speech.SpeechError.Timeout => "Recognition timed out",
        speech.SpeechError.OutOfMemory => "Out of memory",
    };
    try writer.print("Error: {s}\n", .{msg});
}
