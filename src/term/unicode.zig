/// Unicode helpers for the terminal engine: combining mark detection and
/// East Asian Width classification. Extracted from state.zig so that both
/// the engine core and app layer can reuse them.

/// Returns true for Unicode combining / nonspacing marks. Covers all major
/// BMP ranges including Latin combining diacriticals, Cyrillic, Hebrew,
/// Arabic, Thai, Lao, Devanagari, and other Indic/SEA scripts.
pub fn isCombiningMark(cp: u21) bool {
    if (cp < 0x0300 or cp > 0xFE2F) return false;
    return (cp <= 0x036F) // Combining Diacritical Marks
        or (cp >= 0x0483 and cp <= 0x0489) // Cyrillic
        or (cp >= 0x0591 and cp <= 0x05C7) // Hebrew
        or (cp >= 0x0610 and cp <= 0x061A) or (cp >= 0x064B and cp <= 0x065F) // Arabic
        or cp == 0x0670 or (cp >= 0x06D6 and cp <= 0x06ED) or cp == 0x0711
        or (cp >= 0x0730 and cp <= 0x074A) // Syriac
        or (cp >= 0x07A6 and cp <= 0x07B0) or (cp >= 0x07EB and cp <= 0x07F3) // Thaana/NKo
        or (cp >= 0x0816 and cp <= 0x082D) or (cp >= 0x0859 and cp <= 0x085B) // Samaritan
        or (cp >= 0x0898 and cp <= 0x08E1) or (cp >= 0x08E3 and cp <= 0x0963) // Arabic Ext/Indic
    // Devanagari
        or (cp >= 0x0901 and cp <= 0x0903) or (cp >= 0x093A and cp <= 0x094F)
        or (cp >= 0x0951 and cp <= 0x0957) or (cp >= 0x0962 and cp <= 0x0963)
    // Bengali
        or (cp >= 0x0981 and cp <= 0x0983) or (cp >= 0x09BC and cp <= 0x09CD)
        or cp == 0x09D7 or (cp >= 0x09E2 and cp <= 0x09E3)
        or (cp >= 0x0A01 and cp <= 0x0A75) // Gurmukhi
        or (cp >= 0x0A81 and cp <= 0x0AFF) // Gujarati + extensions
    // Tamil
        or cp == 0x0B82 or (cp >= 0x0BBE and cp <= 0x0BC8)
        or (cp >= 0x0BCA and cp <= 0x0BCD) or cp == 0x0BD7
    // Telugu
        or (cp >= 0x0C00 and cp <= 0x0C04) or (cp >= 0x0C3E and cp <= 0x0C56)
        or (cp >= 0x0C62 and cp <= 0x0C63)
    // Kannada
        or (cp >= 0x0C81 and cp <= 0x0C83) or (cp >= 0x0CBC and cp <= 0x0CD6)
        or (cp >= 0x0CE2 and cp <= 0x0CE3)
    // Malayalam
        or (cp >= 0x0D00 and cp <= 0x0D03) or (cp >= 0x0D3B and cp <= 0x0D4E)
        or cp == 0x0D57 or (cp >= 0x0D62 and cp <= 0x0D63)
    // Sinhala
        or (cp >= 0x0DCA and cp <= 0x0DDF) or (cp >= 0x0DF2 and cp <= 0x0DF3)
    // Thai
        or cp == 0x0E31 or (cp >= 0x0E34 and cp <= 0x0E3A)
        or (cp >= 0x0E47 and cp <= 0x0E4E)
    // Lao
        or cp == 0x0EB1 or (cp >= 0x0EB4 and cp <= 0x0EB9)
        or (cp >= 0x0EBB and cp <= 0x0EBC) or (cp >= 0x0EC8 and cp <= 0x0ECD)
    // Tibetan
        or (cp >= 0x0F18 and cp <= 0x0F19) or cp == 0x0F35 or cp == 0x0F37 or cp == 0x0F39
        or (cp >= 0x0F71 and cp <= 0x0F84) or (cp >= 0x0F86 and cp <= 0x0FBC)
    // Myanmar
        or (cp >= 0x102B and cp <= 0x103E) or (cp >= 0x1056 and cp <= 0x1059)
        or (cp >= 0x105E and cp <= 0x1060) or (cp >= 0x1062 and cp <= 0x106D)
    // Extended ranges
        or (cp >= 0x1AB0 and cp <= 0x1ACE) // Combining Diacritical Marks Extended
        or (cp >= 0x1DC0 and cp <= 0x1DFF) // Combining Diacritical Marks Supplement
        or (cp >= 0x20D0 and cp <= 0x20F0) // Combining Marks for Symbols
        or (cp >= 0xFE20 and cp <= 0xFE2F); // Combining Half Marks
}

/// Returns true for zero-width characters that should be absorbed without
/// occupying a cell: ZWJ, variation selectors, skin-tone modifiers, etc.
pub fn isZeroWidth(cp: u21) bool {
    if (cp == 0xFE0F) return true; // VS16 — emoji presentation selector
    if (cp == 0x200D) return true; // ZWJ — zero width joiner
    if (cp == 0x20E3) return true; // combining enclosing keycap
    if (cp >= 0xFE00 and cp <= 0xFE0E) return true; // VS1-15 variation selectors
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true; // Fitzpatrick skin-tone modifiers
    return false;
}

/// Returns 2 for Unicode characters with East Asian Width W or F (wide),
/// 1 for everything else. Mirrors the canBeWide() logic in the glyph caches.
pub fn charDisplayWidth(char: u21) u2 {
    const cp: u32 = char;
    if (cp < 0x1100) return 1;
    if (cp <= 0x115F) return 2; // Hangul Jamo
    if (cp == 0x2329 or cp == 0x232A) return 2;
    if (cp >= 0x2E80 and cp <= 0x303E) return 2;
    if (cp >= 0x3041 and cp <= 0x33FF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0xA000 and cp <= 0xA4CF) return 2;
    if (cp >= 0xA960 and cp <= 0xA97F) return 2;
    if (cp >= 0xAC00 and cp <= 0xD7AF) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0xFE10 and cp <= 0xFE6F) return 2;
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    if (cp >= 0x1B000 and cp <= 0x1B2FF) return 2;
    if (cp >= 0x1F300 and cp <= 0x1F64F) return 2;
    if (cp >= 0x1F680 and cp <= 0x1F6FF) return 2; // Transport & Map Symbols
    if (cp >= 0x1F7E0 and cp <= 0x1F7FF) return 2; // Coloured circles/squares
    if (cp >= 0x1F900 and cp <= 0x1FAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x2FFFD) return 2;
    if (cp >= 0x30000 and cp <= 0x3FFFD) return 2;
    // Common emoji with Emoji_Presentation that are unambiguously 2-cell:
    if (cp == 0x231A or cp == 0x231B) return 2;
    if (cp >= 0x23E9 and cp <= 0x23F3) return 2;
    if (cp >= 0x25FD and cp <= 0x25FE) return 2;
    if (cp == 0x2614 or cp == 0x2615) return 2;
    if (cp >= 0x2648 and cp <= 0x2653) return 2;
    if (cp == 0x267F or cp == 0x2693 or cp == 0x26A1) return 2;
    if (cp == 0x26CE or cp == 0x26D4 or cp == 0x26EA) return 2;
    if (cp == 0x26F2 or cp == 0x26F3 or cp == 0x26F5) return 2;
    if (cp == 0x26FA or cp == 0x26FD) return 2;
    if (cp == 0x2702 or cp == 0x2705) return 2;
    if (cp == 0x2708) return 2; // airplane
    if (cp >= 0x270A and cp <= 0x270B) return 2; // fists
    if (cp == 0x270D) return 2; // writing hand
    if (cp == 0x2728) return 2;
    if (cp == 0x2744 or cp == 0x2747) return 2;
    if (cp == 0x274C or cp == 0x274E) return 2;
    if (cp >= 0x2753 and cp <= 0x2755) return 2;
    if (cp == 0x2757) return 2;
    if (cp == 0x2763 or cp == 0x2764) return 2;
    if (cp >= 0x2795 and cp <= 0x2797) return 2;
    if (cp == 0x27A1 or cp == 0x27B0 or cp == 0x27BF) return 2;
    if (cp == 0x2934 or cp == 0x2935) return 2;
    if (cp >= 0x2B05 and cp <= 0x2B07) return 2;
    if (cp == 0x2B1B or cp == 0x2B1C or cp == 0x2B50 or cp == 0x2B55) return 2;
    return 1;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "Thai combining marks detected" {
    // Mai han akat (above vowel)
    try testing.expect(isCombiningMark(0x0E31));
    // Sara i
    try testing.expect(isCombiningMark(0x0E34));
    // Mai ek (tone mark)
    try testing.expect(isCombiningMark(0x0E48));
}

test "Latin combining diacriticals detected" {
    // Combining acute accent
    try testing.expect(isCombiningMark(0x0301));
    // Combining diaeresis
    try testing.expect(isCombiningMark(0x0308));
    // Combining ring above
    try testing.expect(isCombiningMark(0x030A));
}

test "Non-combining codepoints rejected" {
    try testing.expect(!isCombiningMark('a'));
    try testing.expect(!isCombiningMark(0x0E01)); // Thai ko kai (base consonant)
    try testing.expect(!isCombiningMark(' '));
}

test "Zero-width characters detected" {
    try testing.expect(isZeroWidth(0x200D)); // ZWJ
    try testing.expect(isZeroWidth(0xFE0F)); // VS16
    try testing.expect(isZeroWidth(0xFE00)); // VS1
    try testing.expect(!isZeroWidth('a'));
}

test "CJK wide characters" {
    try testing.expectEqual(@as(u2, 2), charDisplayWidth(0x4E00)); // CJK unified
    try testing.expectEqual(@as(u2, 1), charDisplayWidth('a'));
    try testing.expectEqual(@as(u2, 2), charDisplayWidth(0xAC00)); // Hangul
}
