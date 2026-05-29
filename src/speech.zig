// Cross-platform dispatch layer for speech recognition.
// macOS: Speech.framework (SFSpeechRecognizer)
// Future: whisper.cpp for Windows/Linux

const std = @import("std");

const platform = switch (@import("builtin").os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("stenographer: unsupported platform (macOS only, whisper.cpp support planned)"),
};

pub const SpeechError = error{
    FrameworkUnavailable,
    RecognitionFailed,
    PermissionDenied,
    FileNotFound,
    MicrophoneUnavailable,
    Timeout,
    OutOfMemory,
};

pub const TranscriptionResult = struct {
    text: []const u8,
};

pub const Locale = struct {
    identifier: []const u8,
};

/// Transcribe an audio file.
pub fn transcribeFile(allocator: std.mem.Allocator, path: []const u8, locale: []const u8, on_device: bool) SpeechError!TranscriptionResult {
    return platform.transcribeFile(allocator, path, locale, on_device);
}

/// Listen to the microphone and transcribe in real-time.
pub fn listen(allocator: std.mem.Allocator, locale: []const u8, duration_ms: u32, on_device: bool) SpeechError!TranscriptionResult {
    return platform.listen(allocator, locale, duration_ms, on_device);
}

/// List available locales for speech recognition.
pub fn listLocales(allocator: std.mem.Allocator) SpeechError![]Locale {
    return platform.listLocales(allocator);
}

pub fn freeTranscription(allocator: std.mem.Allocator, result: TranscriptionResult) void {
    allocator.free(result.text);
}

pub fn freeLocales(allocator: std.mem.Allocator, locales: []Locale) void {
    for (locales) |l| allocator.free(l.identifier);
    allocator.free(locales);
}
