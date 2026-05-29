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
var recognition_text: ?[]const u8 = null; // used by transcribeFile
var recognition_text_changed: bool = false; // used by transcribeFile
var recognition_error: bool = false;
var auth_completed: bool = false;
var auth_status: objc.NSInteger = 0;
var current_run_loop: ?*anyopaque = null;
var log_callback: ?*const fn (msg: []const u8) void = null;
// When true, the callback ignores all events (used during task restart drain)
var ignore_callbacks: bool = false;
// Audio tap counter: incremented every time the mic tap fires
var audio_tap_count: u64 = 0;

// --- Simple captured text ---
// captured_buf holds: [text from previous tasks] + \n + [current task's text]
// On every callback, we replace the current task's portion with Apple's latest.
// The streaming callback only advances when total length grows.
var captured_buf: [32768]u8 = undefined;
var captured_len: usize = 0;
// Where the current utterance's text region starts
var captured_base_len: usize = 0;
var captured_changed: bool = false;
// Length of Apple's text in the previous callback (to detect new utterances)
var prev_apple_text_len: usize = 0;

// For live mic: the audio buffer recognition request and task
var live_recognition_request: ?objc.id = null;
var live_recognition_task: ?objc.id = null;
// Static blocks for mic capture (must survive across threads)
var static_tap_block: TapBlockLiteral = undefined;
var static_recognition_block: RecognitionBlockLiteral = undefined;

fn log(msg: []const u8) void {
    if (log_callback) |cb| cb(msg);
}

// ---------------------------------------------------------------------------
// Block callbacks
// ---------------------------------------------------------------------------

fn recognitionBlockInvoke(block: *RecognitionBlockLiteral, result: ?objc.id, err: ?objc.id) callconv(.c) void {
    _ = block;

    // During task restart, we ignore all callbacks (they're from the old task)
    if (ignore_callbacks) {
        log("[verbose] ignoring callback from old task during restart");
        return;
    }

    if (err) |e| {
        if (log_callback != null) {
            const desc = objc.msgSend(objc.id, e, objc.sel("localizedDescription"), .{});
            const desc_cstr = objc.fromNSString(desc);
            if (desc_cstr) |cs| {
                const slice = std.mem.sliceTo(cs, 0);
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[verbose] recognition error: {s}", .{slice}) catch "[verbose] recognition error: (too long)";
                log(msg);
            }
        }
        recognition_error = captured_len == 0;
        recognition_done = true;
        if (current_run_loop) |rl| CFRunLoopStop(rl);
        return;
    }

    if (result) |res| {
        const is_final = objc.msgSend(bool, res, objc.sel("isFinal"), .{});

        const transcription = objc.msgSend(objc.id, res, objc.sel("bestTranscription"), .{});
        const formatted = objc.msgSend(objc.id, transcription, objc.sel("formattedString"), .{});
        const cstr = objc.fromNSString(formatted) orelse {
            if (is_final) {
                recognition_done = true;
                if (current_run_loop) |rl| CFRunLoopStop(rl);
            }
            return;
        };

        const apple_text = std.mem.sliceTo(cstr, 0);

        // Update recognition_text (used by transcribeFile for non-live mode)
        if (recognition_text) |prev| {
            std.heap.c_allocator.free(@constCast(prev));
        }
        recognition_text = std.heap.c_allocator.dupe(u8, apple_text) catch null;
        recognition_text_changed = true;

        // --- Simple capture: replace current utterance, advance base on new utterance ---
        // When Apple's text gets shorter, it means a new utterance started
        // (the iOS 18 regression bug, or a natural pause). Lock in what we had
        // and start the new utterance after it.
        if (apple_text.len < prev_apple_text_len and prev_apple_text_len > 0) {
            // New utterance — advance base to lock in previous text
            captured_base_len = captured_len;
        }
        prev_apple_text_len = apple_text.len;

        // Write current utterance after the base
        const sep_len: usize = if (captured_base_len > 0) 1 else 0;
        const write_start = captured_base_len + sep_len;
        const avail = if (write_start < captured_buf.len) captured_buf.len - write_start else 0;
        const copy_len = @min(apple_text.len, avail);
        if (sep_len > 0) {
            captured_buf[captured_base_len] = '\n';
        }
        @memcpy(captured_buf[write_start .. write_start + copy_len], apple_text[0..copy_len]);
        captured_len = write_start + copy_len;
        captured_changed = true;

        if (is_final) {
            log("[verbose] recognition callback: isFinal=true");
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

    audio_tap_count += 1;

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

fn startRecognitionTask(recognizer: objc.id, on_device: bool) ?objc.id {
    const SFSpeechAudioBufferRecognitionRequest = objc.getClass("SFSpeechAudioBufferRecognitionRequest") orelse
        return null;
    const request_alloc = objc.msgSend(objc.id, SFSpeechAudioBufferRecognitionRequest, objc.sel("alloc"), .{});
    const request = objc.msgSend(objc.id, request_alloc, objc.sel("init"), .{});

    if (on_device) {
        const supports_on_device = objc.msgSend(bool, recognizer, objc.sel("supportsOnDeviceRecognition"), .{});
        if (supports_on_device) {
            objc.msgSend(void, request, objc.sel("setRequiresOnDeviceRecognition:"), .{@as(bool, true)});
        }
    }

    objc.msgSend(void, request, objc.sel("setShouldReportPartialResults:"), .{@as(bool, true)});
    // Hint that this is dictation (value 1), not search — improves behavior for continuous speech
    objc.msgSend(void, request, objc.sel("setTaskHint:"), .{@as(objc.NSInteger, 1)});

    live_recognition_request = request;

    static_recognition_block = .{
        .isa = @ptrCast(&_NSConcreteGlobalBlock),
        .flags = 0,
        .reserved = 0,
        .invoke = &recognitionBlockInvoke,
        .descriptor = &recognition_block_descriptor,
    };

    const task = objc.msgSend(objc.id, recognizer, objc.sel("recognitionTaskWithRequest:resultHandler:"), .{
        request,
        @as(objc.id, @ptrCast(&static_recognition_block)),
    });
    live_recognition_task = task;

    return request;
}

/// Cancel the current recognition task and drain its pending callbacks.
/// The audio engine/tap stays running throughout.
fn cancelCurrentTask(request: objc.id) void {
    // Mute the callback so any belated invocations from the dying task are ignored
    ignore_callbacks = true;

    if (live_recognition_task) |task| {
        objc.msgSend(void, task, objc.sel("cancel"), .{});
        live_recognition_task = null;
    }
    objc.msgSend(void, request, objc.sel("endAudio"), .{});
    live_recognition_request = null;

    // Drain: pump the run loop so any pending callbacks fire (and get ignored)
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);

    // Reset all state for the next task
    recognition_done = false;
    recognition_error = false;
    recognition_text_changed = false;

    // Unmute
    ignore_callbacks = false;
}

/// Build a complete audio pipeline from scratch: engine + tap + recognizer + task.
/// Returns null on failure.
const AudioPipeline = struct {
    engine: objc.id,
    input_node: objc.id,
    recognizer: objc.id,
    request: objc.id,
};

fn buildPipeline(opts: speech.ListenOptions) ?AudioPipeline {
    const AVAudioEngine = objc.getClass("AVAudioEngine") orelse return null;
    const engine = objc.msgSend(objc.id, objc.msgSend(objc.id, AVAudioEngine, objc.sel("alloc"), .{}), objc.sel("init"), .{});
    const input_node = objc.msgSend(objc.id, engine, objc.sel("inputNode"), .{});
    const format = objc.msgSend(objc.id, input_node, objc.sel("outputFormatForBus:"), .{@as(objc.NSUInteger, 0)});

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

    const recognizer = createRecognizer(opts.locale) orelse return null;
    const is_available = objc.msgSend(bool, recognizer, objc.sel("isAvailable"), .{});
    if (!is_available) return null;

    const request = startRecognitionTask(recognizer, opts.on_device) orelse return null;

    var start_err: ?objc.id = null;
    if (!objc.msgSend(bool, engine, objc.sel("startAndReturnError:"), .{&start_err})) {
        return null;
    }

    return .{
        .engine = engine,
        .input_node = input_node,
        .recognizer = recognizer,
        .request = request,
    };
}

/// Tear down an entire audio pipeline (engine, tap, task, request).
fn teardownPipeline(p: AudioPipeline) void {
    ignore_callbacks = true;

    if (live_recognition_task) |task| {
        objc.msgSend(void, task, objc.sel("cancel"), .{});
        live_recognition_task = null;
    }
    objc.msgSend(void, p.request, objc.sel("endAudio"), .{});
    live_recognition_request = null;

    objc.msgSend(void, p.input_node, objc.sel("removeTapOnBus:"), .{@as(objc.NSUInteger, 0)});
    objc.msgSend(void, p.engine, objc.sel("stop"), .{});

    // Drain any pending callbacks (all ignored)
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);

    recognition_done = false;
    recognition_error = false;
    recognition_text_changed = false;
    ignore_callbacks = false;
}

pub fn listen(allocator: std.mem.Allocator, opts: speech.ListenOptions) speech.SpeechError!speech.TranscriptionResult {
    const pool = objc.autoreleasePoolPush();
    defer objc.autoreleasePoolPop(pool);

    log_callback = opts.on_log;
    try ensureAuthorized();

    // Reset all global state
    recognition_done = false;
    recognition_error = false;
    captured_len = 0;
    captured_base_len = 0;
    captured_changed = false;
    audio_tap_count = 0;

    current_run_loop = CFRunLoopGetCurrent();

    var pipeline = buildPipeline(opts) orelse
        return speech.SpeechError.FrameworkUnavailable;
    log("[verbose] recognition task started");

    // --- Poll loop ---
    const poll_interval: f64 = 0.2;
    const silence_timeout_s: f64 = @as(f64, @floatFromInt(opts.silence_timeout_ms)) / 1000.0;
    const has_hard_duration = opts.duration_ms > 0;
    const hard_duration_s: f64 = if (has_hard_duration)
        @as(f64, @floatFromInt(opts.duration_ms)) / 1000.0
    else
        0;

    var elapsed: f64 = 0;
    var silence_elapsed: f64 = 0;
    var time_since_last_capture: f64 = 0;
    var prev_captured_len: usize = 0;
    var last_status_time: f64 = 0;
    var prev_tap_count: u64 = 0;

    while (true) {
        _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, poll_interval, false);
        elapsed += poll_interval;

        if (captured_changed) {
            captured_changed = false;
            // Any callback = activity, even revisions that shrink text
            time_since_last_capture = 0;

            if (captured_len > prev_captured_len) {
                // Text grew — stream the new content
                if (opts.on_partial) |cb| {
                    cb(captured_buf[0..captured_len]);
                }
                silence_elapsed = 0;
            }
            prev_captured_len = captured_len;
        } else {
            time_since_last_capture += poll_interval;
            if (captured_len > 0) {
                silence_elapsed += poll_interval;
            }
        }

        // --- Periodic status log (every 2s) ---
        if (elapsed - last_status_time >= 2.0) {
            const tap_delta = audio_tap_count - prev_tap_count;
            var buf: [256]u8 = undefined;
            const status_msg = std.fmt.bufPrint(&buf, "[verbose] status: mic={d}/2s, captured={d}, base={d}, silence={d:.1}s, stall={d:.1}s", .{
                tap_delta,
                captured_len,
                captured_base_len,
                silence_elapsed,
                time_since_last_capture,
            }) catch "[verbose] status: (fmt error)";
            log(status_msg);
            prev_tap_count = audio_tap_count;
            last_status_time = elapsed;
        }

        // --- Need to restart? (task ended or stalled) ---
        const needs_restart = recognition_done or
            (time_since_last_capture >= 5.0 and captured_len > 0);

        if (needs_restart) {
            if (recognition_done) {
                log("[verbose] recognition task ended");
            } else {
                log("[verbose] recognizer stalled (no callbacks for 5s)");
            }

            if (recognition_error and captured_len == 0) {
                log("[verbose] error before any text, stopping");
                break;
            }

            // Nuclear restart
            log("[verbose] rebuilding pipeline...");
            teardownPipeline(pipeline);
            _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);

            // Advance base so new task's text appends after what we have
            captured_base_len = captured_len;
            time_since_last_capture = 0;

            pipeline = buildPipeline(opts) orelse {
                log("[verbose] failed to rebuild pipeline");
                break;
            };
            log("[verbose] pipeline rebuilt, recognition resumed");
            continue;
        }

        // --- User requested stop ---
        if (opts.stop_flag) |flag| {
            if (flag.*) {
                log("[verbose] stop requested");
                break;
            }
        }

        // --- Silence timeout (user-facing, 0 = disabled) ---
        if (silence_timeout_s > 0 and captured_len > 0 and silence_elapsed >= silence_timeout_s) {
            log("[verbose] silence timeout reached");
            break;
        }

        // --- Hard duration limit ---
        if (has_hard_duration and elapsed >= hard_duration_s) {
            log("[verbose] duration limit reached");
            break;
        }
    }

    // --- Cleanup ---
    teardownPipeline(pipeline);
    current_run_loop = null;
    log_callback = null;

    if (captured_len == 0) {
        return speech.SpeechError.RecognitionFailed;
    }

    const final_text = allocator.dupe(u8, captured_buf[0..captured_len]) catch return speech.SpeechError.OutOfMemory;
    return .{ .text = final_text };
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
