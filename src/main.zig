const std = @import("std");
const qoi = @import("qoi.zig");

fn strEq(str1: []const u8, str2: []const u8) bool {
    return str1.len == str2.len and std.mem.eql(u8, str1, str2);
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdout = std.io.getStdOut().writer();

    var args = try std.process.argsWithAllocator(allocator);
    if (!args.skip())
        unreachable; // ignore argv[0], crash if for some reason argv has 0 length

    if (args.next(allocator)) |firstArg| {
        const encMode = strEq((try firstArg)[0..], "enc");
        // true = enc, false = dec
        if (encMode or strEq((try firstArg)[0..], "dec")) {
            if (args.next(allocator)) |sourceRaw| {
                if (args.next(allocator)) |destRaw| {
                    const realSource = try std.fs.realpathAlloc(allocator, (try sourceRaw)[0..]);
                    const realDest = try std.fs.realpathAlloc(allocator, (try destRaw)[0..]);

                    const source = try std.fs.openFileAbsolute(realSource, std.fs.File.OpenFlags{ .read = true, .write = false });
                    const dest = try std.fs.createFileAbsolute(realDest, std.fs.File.CreateFlags{
                        .read = false,
                        .truncate = false, // do not append
                        .exclusive = false,
                    });

                    _ = source;
                    _ = dest;
                    _ = encMode;
                    return;
                }
            }

            try stdout.print("You must supply two args that are paths", .{});
            return;
        }
    }

    try stdout.print("You must supply enc or dec as an arg", .{});
}
