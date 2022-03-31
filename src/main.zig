const std = @import("std");

// TYPES

// header and pixel are packed so that they can be casted to and from [*]u8 correctly
// because the fields will always be in the correct order and the correct size

const QoiHeader = packed struct {
    magic: [4]u8 = "qoif", // magic bytes
    width: u32,
    height: u32,
    channels: u8, // purely informational
    colorpace: u8, // see above
};

const Pixel = packed struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 255 };

const BinaryList = std.ArrayList(u8);

// END TYPES

// UTIL FUNCTIONS

inline fn pixelsEq(a: Pixel, b: Pixel) bool {
    return (a.r == b.r) and (a.g == b.g) and (a.b == b.b) and (a.a == b.a);
}

inline fn hash(pix: Pixel) u8 {
    return @intCast(u8, (@intCast(u16, pix.r) * 3 +
        @intCast(u16, pix.g) * 5 +
        @intCast(u16, pix.b) * 7 +
        @intCast(u16, pix.a) * 11) % 64);
}

// END UTIL FUNCTIONS

// EMITTER FUNCTIONS

// same alpha value as the previous
inline fn emitRGB(prevAlpha: u8, pix: Pixel) ?[4]u8 {
    if (prevAlpha == pix.a)
        return [4]u8{ 0xFE, pix.r, pix.g, pix.b };
    return null;
}

inline fn emitRGBA(pix: Pixel) [5]u8 {
    return [5]u8{ 0xFF, pix.r, pix.g, pix.b, pix.a };
}

// small diff fits into 6 bits + a 2 bit tag
inline fn emitDiff(prev: Pixel, curr: Pixel) ?u8 {
    if (prev.a != curr.a) return null;

    // % operators allow wrapping in zig
    const dr = (curr.r -% prev.r) +% 2; // bias of 2
    const dg = (curr.g -% prev.g) +% 2;
    const db = (curr.b -% prev.b) +% 2;

    // <= 3 so it fits into just two bits (00 01 10 11)
    if (dr <= 3 and dg <= 3 and db <= 3)
        return (1 << 6) | (dr << 4) | (dg << 2) | db;

    return null;
}

// large diff over two bytes
inline fn emitLuma(prev: Pixel, curr: Pixel) ?[2]u8 {
    const dgRaw = (curr.g -% prev.g);
    const dg = dgRaw +% 32; // bias of 32
    if (dg >= (1 << 7)) return null;

    const dr = (curr.r -% prev.r) -% dgRaw +% 8; // bias of 8
    const db = (curr.b -% prev.b) -% dgRaw +% 8;

    if (dr >= (1 << 4) or db >= (1 << 4)) return null;

    return [2]u8{ 1 << 7 | dg, dr << 4 | db };
}

inline fn emitRun(length: u8) ?u8 {
    const biased = length -% 1;
    if (biased < 63)
        return 0b11 << 6 | biased;

    return null;
}

// if same as at hash in prevSeen
inline fn emitIndex(table: [64]Pixel, pix: Pixel) ?u8 {
    const hashed = hash(pix);
    const prev = table[hashed];
    if (pixelsEq(prev, pix))
        return hashed;
    return null;
}

inline fn tryEmitBestRaw(lastA: u8, pix: Pixel) []u8 {
    if (emitRGB(lastA, pix)) |rgb|
        return rgb;
    return emitRGBA(pix);
}

// END EMITTER FUNCTIONS

// the image may have at most ~4.29 billion pixels
pub fn enc(allocator: std.mem.Allocator, input: []Pixel, length: u32) []Pixel {
    const output = BinaryList.init(allocator);
    const hashTable: [64]?Pixel = undefined;

    var previousPixel = Pixel{};
    var preRunLengthA: u8 = 255;
    var runLength: u8 = 0;
    var index: u32 = 0;

    while (index < length) : ({
        index += 1;
        if (runLength == 1)
            preRunLengthA = previousPixel.a;
        previousPixel = input[index - 1];
    }) {
        const currentPixel = input[index];

        // keep the hash table up-to-date
        const hashed = hash(currentPixel);
        if (hashTable[hashed] == null)
            hashTable[hashed] = currentPixel;

        if (pixelsEq(previousPixel, currentPixel)) {
            runLength += 1;
            continue;
        }

        if (runLength != 0) {
            // run length has ended, emit it and continue with the next pixel
            while (runLength > 0) : (runLength -= 1) {
                if (emitRun(runLength)) |byte| {
                    output.append(byte);
                    break;
                }
                output.appendSlice(tryEmitBestRaw(preRunLengthA, previousPixel));
            }
            runLength = 0;
        }

        // order of preference: run (already covered), index, diff, luma, raw
        if (emitIndex(hashTable, currentPixel)) |byte| {
            output.append(byte);
        } else if (emitDiff(previousPixel, currentPixel)) |byte| {
            output.append(byte);
        } else if (emitLuma(previousPixel, currentPixel)) |bytes| {
            output.appendSlice(bytes);
        } else {
            output.appendSlice(tryEmitBestRaw(previousPixel.a, currentPixel));
        }
    }

    return output.items;
}

fn hashIfNeeded(table: [64]?Pixel, pix: Pixel) void {
    const hashed = hash(pix);
    if (table[hashed] == null)
        table[hashed] = pix;
}

pub fn dec(allocator: std.mem.Allocator, input: []Pixel, length: u32) []Pixel {
    const output = BinaryList.init(allocator);
    const hashTable: [64]?Pixel = undefined;

    var previousPixel = Pixel{};

    var index: u32 = 0;

    while (index < length) : ({
        index += 1;
        previousPixel = output.items[output.items.len - 1];
        hashIfNeeded(hashTable, previousPixel);
    }) {
        const current = input[index];

        if (current == 0xFE) {
            index += 1;
            const red = input[index];
            index += 1;
            const blue = input[index];
            index += 1;
            const green = input[index];
            output.append(Pixel{ .r = red, .g = green, .b = blue });
        }

        else if (current == 0xFF) {
            index += 1;
            const red = input[index];
            index += 1;
            const blue = input[index];
            index += 1;
            const green = input[index];
            index += 1;
            const alpha = input[index];
        }

        if ((current & 0b11000000) == 0) {
            // index
            const index = current & 0b00111111;
            output.append(table[index]);
        }

        else if ((current & 0b11000000) == (1 << 6)) {
            // diff
            const dr = (current & 0b00110000) >> 4 +% 2; // remove bias
            const dg = (current & 0b00001100) >> 2 +% 2;
            const db = (current & 0b00000011) +% 2;
            output.append(Pixel{
                .r = previousPixel.r + dr,
                .g = previousPixel.g + dg,
                .b = previousPixel.b + db,
            });
        }

        else if ((current & 0b11000000) == (1 << 7)) {
            // luma
            const dg = (current & 0b00111111) -% 32;
            
            index += 1;
            const next = input[index];

            const dr = (next & 0b11110000) >> 4 -% 8 +% dg;
            const db = (next & 0b00001111) -% 8 +% dg;
            output.append(Pixel{
                .r = previousPixel.r + dr,
                .g = previousPixel.g + dg,
                .b = previousPixel.b + db,
            });
        }

        else if ((current & 0b11000000) == (0b11 << 6)) {
            // run
            var length = current & 0b00111111;
            while (length > 0) : (length -= 1) {
                output.append(previousPixel);
            }
        }
    }

    return output.items;
}
