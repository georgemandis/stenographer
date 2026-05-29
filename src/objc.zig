// Objective-C runtime bindings for Zig.

const std = @import("std");

pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const NSUInteger = usize;
pub const NSInteger = isize;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

pub fn msgSendFn(comptime ReturnType: type, comptime ArgTypes: type) MsgSendFnType(ReturnType, ArgTypes) {
    return @ptrCast(&objc_msgSend);
}

fn MsgSendFnType(comptime ReturnType: type, comptime ArgTypes: type) type {
    const args_info = @typeInfo(ArgTypes);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) ReturnType,
        1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
        4 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) ReturnType,
        else => @compileError("msgSendFn: too many arguments, add more cases"),
    };
}

pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func = msgSendFn(ReturnType, ArgsType);

    const args_info = @typeInfo(ArgsType);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => func(target_as_id, selector),
        1 => func(target_as_id, selector, args[0]),
        2 => func(target_as_id, selector, args[0], args[1]),
        3 => func(target_as_id, selector, args[0], args[1], args[2]),
        4 => func(target_as_id, selector, args[0], args[1], args[2], args[3]),
        else => @compileError("msgSend: too many arguments"),
    };
}

// ---------------------------------------------------------------------------
// NSString helpers
// ---------------------------------------------------------------------------

pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

pub fn nsStringFromSlice(bytes: [*]const u8, len: NSUInteger) ?id {
    const NSString = getClass("NSString") orelse return null;
    const alloc_str = msgSend(id, NSString, sel("alloc"), .{});
    return msgSend(?id, alloc_str, sel("initWithBytes:length:encoding:"), .{
        bytes,
        len,
        @as(NSUInteger, 4),
    });
}

pub fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel("UTF8String"), .{});
}

pub fn nsStringLength(nsstr: id) NSUInteger {
    return msgSend(NSUInteger, nsstr, sel("length"), .{});
}

// ---------------------------------------------------------------------------
// NSArray helpers
// ---------------------------------------------------------------------------

pub fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel("count"), .{});
}

pub fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel("objectAtIndex:"), .{index});
}

// ---------------------------------------------------------------------------
// Autorelease pool
// ---------------------------------------------------------------------------

pub fn autoreleasePoolPush() id {
    const NSAutoreleasePool = getClass("NSAutoreleasePool") orelse unreachable;
    const pool = msgSend(id, NSAutoreleasePool, sel("alloc"), .{});
    return msgSend(id, pool, sel("init"), .{});
}

pub fn autoreleasePoolPop(pool: id) void {
    msgSend(void, pool, sel("drain"), .{});
}
