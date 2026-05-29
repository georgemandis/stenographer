const std = @import("std");
const builtin = @import("builtin");
const speech = @import("speech");

const version = "0.1.0";

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
        \\  listen             Transcribe from the microphone
        \\  locales            List supported languages
        \\  help               Show this help message
        \\
        \\Options:
        \\  --locale=CODE      Language locale (default: en-US)
        \\  --on-device        Force on-device recognition (no network)
        \\  --duration=MS      Listen duration in ms (default: 10000)
        \\  --json             Output as JSON
        \\  --help, -h         Show this help message
        \\  --version, -v      Show version
        \\
        \\Examples:
        \\  stenographer transcribe meeting.wav
        \\  stenographer transcribe interview.mp3 --locale=fr-FR --json
        \\  stenographer transcribe podcast.m4a --on-device
        \\  stenographer listen
        \\  stenographer listen --duration=5000
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
    var duration_ms: u32 = 10000;
    var file_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--on-device")) {
            on_device = true;
        } else if (std.mem.startsWith(u8, arg, "--locale=")) {
            locale = arg["--locale=".len..];
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            duration_ms = std.fmt.parseInt(u32, arg["--duration=".len..], 10) catch {
                try stderr.interface.print("Error: invalid --duration value\n", .{});
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
        try cmdListen(&stdout.interface, &stderr.interface, allocator, locale, duration_ms, on_device, json_mode);
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

fn cmdListen(writer: *std.Io.Writer, stderr: *std.Io.Writer, allocator: std.mem.Allocator, locale: []const u8, duration_ms: u32, on_device: bool, json_mode: bool) !void {
    if (!json_mode) {
        try stderr.print("Listening for {d:.1}s...\n", .{@as(f64, @floatFromInt(duration_ms)) / 1000.0});
        try stderr.flush();
    }

    const result = speech.listen(allocator, locale, duration_ms, on_device) catch |err| {
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
