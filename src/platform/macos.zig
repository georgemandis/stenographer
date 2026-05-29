const std = @import("std");
const objc = @import("../objc.zig");
const speech = @import("../speech.zig");

// ---------------------------------------------------------------------------
// CoreFoundation run loop externs
// ---------------------------------------------------------------------------
extern "c" fn CFRunLoopGetCurrent() *anyopaque;
extern "c" fn CFRunLoopStop(rl: *anyopaque) void;
extern "c" fn CFRunLoopRunInMode(mode: objc.id, seconds: f64, returnAfterSourceHandled: bool) i32;
extern "c" var kCFRunLoopDefaultMode: objc.id;

// ---------------------------------------------------------------------------
// ObjC block ABI
// ---------------------------------------------------------------------------
extern var _NSConcreteStackBlock: [1]usize;
extern var _NSConcreteGlobalBlock: [1]usize;

const BlockDescriptor = extern struct {
    reserved: c_ulong,
    size: c_ulong,
};

// Block for recognitionTask(with:resultHandler:)
// Signature: (SFSpeechRecognitionResult?, NSError?) -> Void
const RecognitionBlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*RecognitionBlockLiteral, ?objc.id, ?objc.id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

const recognition_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(RecognitionBlockLiteral),
};

// Block for requestAuthorization: callback
// Signature: (SFSpeechRecognizerAuthorizationStatus) -> Void
const AuthBlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*AuthBlockLiteral, objc.NSInteger) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

const auth_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(AuthBlockLiteral),
};

// Block for AVAudioEngine installTap
const TapBlockLiteral = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*TapBlockLiteral, objc.id, objc.id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

const tap_block_descriptor = BlockDescriptor{
    .reserved = 0,
    .size = @sizeOf(TapBlockLiteral),
};

// ---------------------------------------------------------------------------
// Module-level state
// ---------------------------------------------------------------------------
var recognition_done: bool = false;
var recognition_text: ?[]const u8 = null;
var recognition_error: bool = false;
var auth_completed: bool = false;
var auth_status: objc.NSInteger = 0;
var current_run_loop: ?*anyopaque = null;

// For live mic: the audio buffer recognition request
var live_recognition_request: ?objc.id = null;
// Static blocks for mic capture (must survive across threads)
var static_tap_block: TapBlockLiteral = undefined;
var static_recognition_block: RecognitionBlockLiteral = undefined;

// ---------------------------------------------------------------------------
// Block callbacks
// ---------------------------------------------------------------------------

fn recognitionBlockInvoke(block: *RecognitionBlockLiteral, result: ?objc.id, err: ?objc.id) callconv(.c) void {
    _ = block;

    if (err != null) {
        // If we already have partial text, keep it and mark done
        recognition_error = recognition_text == null;
        recognition_done = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    }

    if (result) |res| {
        // Check if this is the final result
        const is_final = objc.msgSend(bool, res, objc.sel("isFinal"), .{});

        // Get bestTranscription.formattedString
        const transcription = objc.msgSend(objc.id, res, objc.sel("bestTranscription"), .{});
        const formatted = objc.msgSend(objc.id, transcription, objc.sel("formattedString"), .{});
        const cstr = objc.fromNSString(formatted) orelse {
            if (is_final) {
                recognition_done = true;
                if (current_run_loop) |rl| CFRunLoopStop(rl);
            }
            return;
        };

        const slice = std.mem.sliceTo(cstr, 0);

        // Free previous partial result
        if (recognition_text) |prev| {
            std.heap.c_allocator.free(@constCast(prev));
        }

        recognition_text = std.heap.c_allocator.dupe(u8, slice) catch {
            if (is_final) {
                recognition_done = true;
                if (current_run_loop) |rl| CFRunLoopStop(rl);
            }
            return;
        };

        if (is_final) {
            recognition_done = true;
            if (current_run_loop) |rl| CFRunLoopStop(rl);
        }
    }
}

fn authBlockInvoke(block: *AuthBlockLiteral, status: objc.NSInteger) callconv(.c) void {
    _ = block;
    auth_status = status;
    auth_completed = true;
    if (current_run_loop) |rl| CFRunLoopStop(rl);
}

fn tapBlockInvoke(block: *TapBlockLiteral, buffer: objc.id, when: objc.id) callconv(.c) void {
    _ = block;
    _ = when;

    // Feed audio buffer to the recognition request
    if (live_recognition_request) |request| {
        objc.msgSend(void, request, objc.sel("appendAudioPCMBuffer:"), .{buffer});
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ensureAuthorized() speech.SpeechError!void {
    const SFSpeechRecognizer = objc.getClass("SFSpeechRecognizer") orelse
        return speech.SpeechError.FrameworkUnavailable;

    // Check current status: 0=notDetermined, 1=denied, 2=restricted, 3=authorized
    const status = objc.msgSend(objc.NSInteger, SFSpeechRecognizer, objc.sel("authorizationStatus"), .{});

    if (status == 3) return; // already authorized

    if (status == 1 or status == 2) return speech.SpeechError.PermissionDenied;

    // Not determined — request authorization
    auth_completed = false;
    auth_status = 0;

    var auth_block = AuthBlockLiteral{
        .isa = @ptrCast(&_NSConcreteStackBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &authBlockInvoke,
        .descriptor = &auth_block_descriptor,
    };

    current_run_loop = CFRunLoopGetCurrent();
    objc.msgSend(void, SFSpeechRecognizer, objc.sel("requestAuthorization:"), .{@as(objc.id, @ptrCast(&auth_block))});

    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 30.0, false);

    if (!auth_completed or auth_status != 3) {
        current_run_loop = null;
        return speech.SpeechError.PermissionDenied;
    }
}

fn createRecognizer(locale: []const u8) ?objc.id {
    const SFSpeechRecognizer = objc.getClass("SFSpeechRecognizer") orelse return null;
    const NSLocale = objc.getClass("NSLocale") orelse return null;

    // Create NSLocale
    const locale_str = objc.nsStringFromSlice(locale.ptr, locale.len) orelse return null;
    const ns_locale_alloc = objc.msgSend(objc.id, NSLocale, objc.sel("alloc"), .{});
    const ns_locale = objc.msgSend(objc.id, ns_locale_alloc, objc.sel("initWithLocaleIdentifier:"), .{locale_str});

    // Create SFSpeechRecognizer with locale
    const recognizer_alloc = objc.msgSend(objc.id, SFSpeechRecognizer, objc.sel("alloc"), .{});
    return objc.msgSend(?objc.id, recognizer_alloc, objc.sel("initWithLocale:"), .{ns_locale});
}

// ---------------------------------------------------------------------------
// Public API: transcribe file
// ---------------------------------------------------------------------------

pub fn transcribeFile(allocator: std.mem.Allocator, path: []const u8, locale: []const u8, on_device: bool) speech.SpeechError!speech.TranscriptionResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    try ensureAuthorized();

    // Reset state
    recognition_done = false;
    recognition_text = null;
    recognition_error = false;

    // Create recognizer
    const recognizer = createRecognizer(locale) orelse
        return speech.SpeechError.FrameworkUnavailable;

    // Check availability
    const is_available = objc.msgSend(bool, recognizer, objc.sel("isAvailable"), .{});
    if (!is_available) return speech.SpeechError.FrameworkUnavailable;

    // Create NSURL from file path
    const ns_path = objc.nsStringFromSlice(path.ptr, path.len) orelse
        return speech.SpeechError.FileNotFound;
    const NSURL = objc.getClass("NSURL") orelse return speech.SpeechError.FrameworkUnavailable;
    const file_url = objc.msgSend(objc.id, NSURL, objc.sel("fileURLWithPath:"), .{ns_path});

    // Create SFSpeechURLRecognitionRequest
    const SFSpeechURLRecognitionRequest = objc.getClass("SFSpeechURLRecognitionRequest") orelse
        return speech.SpeechError.FrameworkUnavailable;
    const request_alloc = objc.msgSend(objc.id, SFSpeechURLRecognitionRequest, objc.sel("alloc"), .{});
    const request = objc.msgSend(objc.id, request_alloc, objc.sel("initWithURL:"), .{file_url});

    // Set on-device if requested
    if (on_device) {
        const supports_on_device = objc.msgSend(bool, recognizer, objc.sel("supportsOnDeviceRecognition"), .{});
        if (supports_on_device) {
            objc.msgSend(void, request, objc.sel("setRequiresOnDeviceRecognition:"), .{@as(bool, true)});
        }
    }

    // Create recognition block
    var block = RecognitionBlockLiteral{
        .isa = @ptrCast(&_NSConcreteStackBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &recognitionBlockInvoke,
        .descriptor = &recognition_block_descriptor,
    };

    // Start recognition task
    current_run_loop = CFRunLoopGetCurrent();
    _ = objc.msgSend(objc.id, recognizer, objc.sel("recognitionTaskWithRequest:resultHandler:"), .{
        request,
        @as(objc.id, @ptrCast(&block)),
    });

    // Pump run loop until done (timeout: 120s for long files)
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 120.0, false);
    current_run_loop = null;

    if (recognition_text == null) {
        return speech.SpeechError.RecognitionFailed;
    }

    const text_c = recognition_text.?;
    const text = allocator.dupe(u8, text_c) catch return speech.SpeechError.OutOfMemory;
    std.heap.c_allocator.free(@constCast(text_c));
    recognition_text = null;

    return .{ .text = text };
}

// ---------------------------------------------------------------------------
// Public API: listen (live mic)
// ---------------------------------------------------------------------------

pub fn listen(allocator: std.mem.Allocator, locale: []const u8, duration_ms: u32, on_device: bool) speech.SpeechError!speech.TranscriptionResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    try ensureAuthorized();

    // Reset state
    recognition_done = false;
    recognition_text = null;
    recognition_error = false;

    // Create recognizer
    const recognizer = createRecognizer(locale) orelse
        return speech.SpeechError.FrameworkUnavailable;

    const is_available = objc.msgSend(bool, recognizer, objc.sel("isAvailable"), .{});
    if (!is_available) return speech.SpeechError.FrameworkUnavailable;

    // Create AVAudioEngine
    const AVAudioEngine = objc.getClass("AVAudioEngine") orelse
        return speech.SpeechError.FrameworkUnavailable;
    const engine_alloc = objc.msgSend(objc.id, AVAudioEngine, objc.sel("alloc"), .{});
    const engine = objc.msgSend(objc.id, engine_alloc, objc.sel("init"), .{});

    // Get input node and format
    const input_node = objc.msgSend(objc.id, engine, objc.sel("inputNode"), .{});
    const format = objc.msgSend(objc.id, input_node, objc.sel("outputFormatForBus:"), .{@as(objc.NSUInteger, 0)});

    // Create SFSpeechAudioBufferRecognitionRequest
    const SFSpeechAudioBufferRecognitionRequest = objc.getClass("SFSpeechAudioBufferRecognitionRequest") orelse
        return speech.SpeechError.FrameworkUnavailable;
    const request_alloc = objc.msgSend(objc.id, SFSpeechAudioBufferRecognitionRequest, objc.sel("alloc"), .{});
    const request = objc.msgSend(objc.id, request_alloc, objc.sel("init"), .{});
    live_recognition_request = request;

    // Set on-device if requested
    if (on_device) {
        const supports_on_device = objc.msgSend(bool, recognizer, objc.sel("supportsOnDeviceRecognition"), .{});
        if (supports_on_device) {
            objc.msgSend(void, request, objc.sel("setRequiresOnDeviceRecognition:"), .{@as(bool, true)});
        }
    }

    // Enable partial results for streaming
    objc.msgSend(void, request, objc.sel("setShouldReportPartialResults:"), .{@as(bool, true)});

    // Install tap on audio input (GlobalBlock since it's module-level static)
    static_tap_block = .{
        .isa = @ptrCast(&_NSConcreteGlobalBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &tapBlockInvoke,
        .descriptor = &tap_block_descriptor,
    };

    objc.msgSend(void, input_node, objc.sel("installTapOnBus:bufferSize:format:block:"), .{
        @as(objc.NSUInteger, 0),
        @as(u32, 1024),
        format,
        @as(objc.id, @ptrCast(&static_tap_block)),
    });

    // Use static recognition block with GlobalBlock ISA (must survive across callback threads)
    static_recognition_block = .{
        .isa = @ptrCast(&_NSConcreteGlobalBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &recognitionBlockInvoke,
        .descriptor = &recognition_block_descriptor,
    };

    // Start recognition task BEFORE starting audio engine
    current_run_loop = CFRunLoopGetCurrent();
    _ = objc.msgSend(objc.id, recognizer, objc.sel("recognitionTaskWithRequest:resultHandler:"), .{
        request,
        @as(objc.id, @ptrCast(&static_recognition_block)),
    });

    // Start audio engine
    var start_err: ?objc.id = null;
    const started = objc.msgSend(bool, engine, objc.sel("startAndReturnError:"), .{&start_err});
    if (!started) {
        live_recognition_request = null;
        current_run_loop = null;
        return speech.SpeechError.MicrophoneUnavailable;
    }

    // Listen for specified duration, pumping run loop for recognition callbacks
    const duration_seconds: f64 = if (duration_ms > 0)
        @as(f64, @floatFromInt(duration_ms)) / 1000.0
    else
        10.0;

    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, duration_seconds, false);

    // Stop audio capture
    objc.msgSend(void, input_node, objc.sel("removeTapOnBus:"), .{@as(objc.NSUInteger, 0)});
    objc.msgSend(void, engine, objc.sel("stop"), .{});

    // Signal end of audio to the recognition request
    objc.msgSend(void, request, objc.sel("endAudio"), .{});
    live_recognition_request = null;

    // Wait for final result (pump run loop for callbacks to fire)
    if (!recognition_done) {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10.0, false);
    }
    current_run_loop = null;

    // Accept partial results even if not final
    if (recognition_text == null) {
        return speech.SpeechError.RecognitionFailed;
    }

    const text_c = recognition_text.?;
    const text = allocator.dupe(u8, text_c) catch return speech.SpeechError.OutOfMemory;
    std.heap.c_allocator.free(@constCast(text_c));
    recognition_text = null;

    return .{ .text = text };
}

// ---------------------------------------------------------------------------
// Public API: list locales
// ---------------------------------------------------------------------------

pub fn listLocales(allocator: std.mem.Allocator) speech.SpeechError![]speech.Locale {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    const SFSpeechRecognizer = objc.getClass("SFSpeechRecognizer") orelse
        return speech.SpeechError.FrameworkUnavailable;

    // supportedLocales returns NSSet<NSLocale>
    const locales_set = objc.msgSend(objc.id, SFSpeechRecognizer, objc.sel("supportedLocales"), .{});
    const locales_array = objc.msgSend(objc.id, locales_set, objc.sel("allObjects"), .{});
    const count = objc.nsArrayCount(locales_array);

    var results = allocator.alloc(speech.Locale, count) catch return speech.SpeechError.OutOfMemory;
    var valid: usize = 0;

    for (0..count) |i| {
        const ns_locale = objc.nsArrayObjectAtIndex(locales_array, i);
        const identifier = objc.msgSend(objc.id, ns_locale, objc.sel("localeIdentifier"), .{});
        const cstr = objc.fromNSString(identifier) orelse continue;
        const slice = std.mem.sliceTo(cstr, 0);

        results[valid] = .{
            .identifier = allocator.dupe(u8, slice) catch return speech.SpeechError.OutOfMemory,
        };
        valid += 1;
    }

    return allocator.realloc(results, valid) catch results[0..valid];
}
