//! Static, offline price table for estimating agent cost when the agent doesn't
//! report it. Today only **Codex** needs this — Claude, opencode, and Pi all
//! report cost directly — so the table covers the GPT-5 family Codex runs.
//!
//! Rates are USD per 1,000,000 tokens and are deliberately a small, hand-
//! maintained subset (not a network dependency, mirroring what ccusage pulls
//! from LiteLLM but offline). They are APPROXIMATE and go stale — costs derived
//! here are marked `cost_is_estimate` and shown with a `~` in the UI. Bump them
//! against the vendor's pricing page when they drift:
//!   OpenAI: https://openai.com/api/pricing/
//!
//! Unknown model → no estimate (null), so the UI shows `—` rather than a guess.
const std = @import("std");
const AgentUsage = @import("attyx").actions.AgentUsage;

pub const Rates = struct {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
};

const Entry = struct { prefix: []const u8, rates: Rates };

// GPT-5 family rates (USD per 1M tokens, approximate — verify before trusting
// the dollar figures). Cached input reads bill ~10× cheaper; Codex doesn't
// report cache *writes*, so that rate is only a fallback. Ordered specific →
// general: startsWith returns the first hit, so "gpt-5-mini" and "gpt-5.5" must
// precede the broad "gpt-5".
const table = [_]Entry{
    .{ .prefix = "gpt-5-mini", .rates = .{ .input = 0.25, .output = 2.0, .cache_read = 0.025, .cache_write = 0.25 } },
    .{ .prefix = "gpt-5.5", .rates = .{ .input = 1.25, .output = 10.0, .cache_read = 0.125, .cache_write = 1.25 } },
    .{ .prefix = "gpt-5-codex", .rates = .{ .input = 1.25, .output = 10.0, .cache_read = 0.125, .cache_write = 1.25 } },
    .{ .prefix = "gpt-5", .rates = .{ .input = 1.25, .output = 10.0, .cache_read = 0.125, .cache_write = 1.25 } },
};

/// Per-million rates for a model id (prefix match), or null if not in the table.
pub fn rates(model: []const u8) ?Rates {
    for (table) |e| if (std.mem.startsWith(u8, model, e.prefix)) return e.rates;
    return null;
}

/// Estimated USD for these token counts under `model`, or null when the model
/// isn't priced. Absent counts are treated as 0.
pub fn estimate(model: []const u8, input: ?u64, output: ?u64, cache_read: ?u64, cache_write: ?u64) ?f64 {
    const r = rates(model) orelse return null;
    const n = struct {
        fn f(v: ?u64) f64 {
            return @floatFromInt(v orelse 0);
        }
    }.f;
    return (n(input) * r.input + n(output) * r.output +
        n(cache_read) * r.cache_read + n(cache_write) * r.cache_write) / 1_000_000.0;
}

/// `u` with `cost_usd` filled from the table when it's absent and the model is
/// known (flagged `cost_is_estimate`). An agent-reported cost is left untouched.
pub fn withEstimate(u: AgentUsage) AgentUsage {
    if (u.cost_usd != null) return u;
    const model = u.model orelse return u;
    const c = estimate(model, u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens) orelse return u;
    var out = u;
    out.cost_usd = c;
    out.cost_is_estimate = true;
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "estimate computes from per-million rates incl. cache" {
    // gpt-5.5: in 1.25, out 10, cache_read 0.125 per 1M.
    // 1_000_000 in + 100_000 out + 800_000 cache_read =
    //   1.25 + 1.0 + 0.1 = 2.35
    const c = estimate("gpt-5.5", 1_000_000, 100_000, 800_000, null).?;
    try testing.expectApproxEqAbs(@as(f64, 2.35), c, 1e-9);
}

test "prefix match handles dated/suffixed model ids and mini ordering" {
    try testing.expect(rates("gpt-5.5-2026-01-01") != null);
    // gpt-5-mini must not be shadowed by gpt-5.
    try testing.expectEqual(@as(f64, 0.25), rates("gpt-5-mini").?.input);
    try testing.expectEqual(@as(f64, 1.25), rates("gpt-5-codex").?.input);
}

test "unknown model yields no estimate" {
    try testing.expect(rates("claude-opus-4-8") == null);
    try testing.expect(estimate("some-llama", 100, 100, 0, 0) == null);
}

test "withEstimate fills only when cost is absent and model is priced" {
    // Reported cost is preserved untouched.
    const reported = withEstimate(.{ .cost_usd = 1.23, .model = "gpt-5.5", .input_tokens = 1_000_000 });
    try testing.expectEqual(@as(?f64, 1.23), reported.cost_usd);
    try testing.expect(!reported.cost_is_estimate);

    // Missing cost + priced model → estimate, flagged.
    const est = withEstimate(.{ .model = "gpt-5.5", .input_tokens = 1_000_000 });
    try testing.expectApproxEqAbs(@as(f64, 1.25), est.cost_usd.?, 1e-9);
    try testing.expect(est.cost_is_estimate);

    // Missing cost + unknown model → still null.
    const unknown = withEstimate(.{ .model = "mystery", .input_tokens = 1_000_000 });
    try testing.expect(unknown.cost_usd == null);
}
