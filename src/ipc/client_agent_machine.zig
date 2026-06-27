// Attyx — agent turn detector (pure state machine for `attyx agent send/await`)
//
// Split out from client_agent.zig: this is the pure function over watch-stream
// status frames that decides when a driven turn has resolved. It has no IO, so it
// is unit-tested without a real agent or socket. The orchestration that feeds it
// lives in client_agent.zig.

const std = @import("std");

/// Agent run-state as reported on the watch stream.
pub const State = enum {
    idle,
    working,
    input,
    none,

    pub fn fromStr(s: []const u8) State {
        if (std.mem.eql(u8, s, "working")) return .working;
        if (std.mem.eql(u8, s, "input")) return .input;
        if (std.mem.eql(u8, s, "idle")) return .idle;
        return .none;
    }
};

/// The result of a driven turn. Exit codes let scripts branch:
/// `attyx agent send -p 3 "run tests" --wait && deploy`.
pub const Outcome = enum {
    done, // working → idle: the agent finished its turn
    needs_input, // working → input: paused for permission/a question
    timeout, // still working past --timeout (we stop waiting; agent untouched)
    no_turn, // the agent never started working (wrong pane, modal, ignored input)
    ended, // the agent exited mid-wait (state none)

    pub fn exitCode(self: Outcome) u8 {
        return switch (self) {
            .done => 0,
            .needs_input => 2,
            .timeout => 3,
            .no_turn, .ended => 4,
        };
    }
    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .done => "done",
            .needs_input => "needs_input",
            .timeout => "timeout",
            .no_turn => "no_turn",
            .ended => "ended",
        };
    }
};

/// Pure turn detector. The watch stream emits the pane's current state on
/// connect (a snapshot) then a frame per transition. We open it before sending,
/// so we must not mistake the pre-submit snapshot for completion: feed every
/// frame to `feed`, and clock checks to `tick`.
///
/// `initial` is the pane's state at submit time (from the precondition snapshot).
/// Until we observe `working`, frames equal to `initial` are the snapshot and are
/// ignored; a transition to `working` starts the turn; a transition to a
/// *different* terminal state (fast turn with no observed `working`) resolves it.
pub const Machine = struct {
    initial: State,
    submit_ms: i64,
    start_grace_ms: i64,
    timeout_ms: i64,
    saw_working: bool = false,

    /// Apply one status frame. Returns an Outcome when the turn resolves, else
    /// null to keep waiting.
    pub fn feed(self: *Machine, state: State) ?Outcome {
        if (state == .none) return .ended;
        if (self.saw_working) {
            return switch (state) {
                .idle => .done,
                .input => .needs_input,
                .working => null,
                .none => .ended,
            };
        }
        switch (state) {
            .working => {
                self.saw_working = true;
                return null;
            },
            // A change away from the pre-submit state without an observed
            // `working` = an instant turn; same state = the connect snapshot.
            .idle => return if (state != self.initial) .done else null,
            .input => return if (state != self.initial) .needs_input else null,
            .none => return .ended,
        }
    }

    /// Apply a clock check (called on poll timeouts). `no_turn` before the turn
    /// starts, `timeout` after.
    pub fn tick(self: *const Machine, now_ms: i64) ?Outcome {
        if (!self.saw_working) {
            if (now_ms - self.submit_ms >= self.start_grace_ms) return .no_turn;
        } else {
            if (now_ms - self.submit_ms >= self.timeout_ms) return .timeout;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests — the state machine, no socket/agent required.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn machine(initial: State) Machine {
    return .{ .initial = initial, .submit_ms = 0, .start_grace_ms = 3000, .timeout_ms = 600_000 };
}

test "working then idle = done; working then input = needs_input" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, null), a.feed(.working));
    try testing.expectEqual(@as(?Outcome, .done), a.feed(.idle));

    var b = machine(.idle);
    _ = b.feed(.working);
    try testing.expectEqual(@as(?Outcome, .needs_input), b.feed(.input));
}

test "pre-submit snapshot of the same state does not false-fire" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, null), a.feed(.idle)); // connect snapshot
    try testing.expectEqual(@as(?Outcome, null), a.feed(.working)); // turn starts
    try testing.expectEqual(@as(?Outcome, .done), a.feed(.idle)); // turn ends
}

test "no working within start grace = no_turn" {
    var a = machine(.idle);
    _ = a.feed(.idle); // snapshot only
    try testing.expectEqual(@as(?Outcome, null), a.tick(2999));
    try testing.expectEqual(@as(?Outcome, .no_turn), a.tick(3000));
}

test "working then silence past deadline = timeout" {
    var a = machine(.idle);
    _ = a.feed(.working);
    try testing.expectEqual(@as(?Outcome, null), a.tick(599_999));
    try testing.expectEqual(@as(?Outcome, .timeout), a.tick(600_000));
}

test "agent exits mid-turn = ended" {
    var a = machine(.idle);
    _ = a.feed(.working);
    try testing.expectEqual(@as(?Outcome, .ended), a.feed(.none));
}

test "instant turn (input straight after submit, no observed working)" {
    var a = machine(.idle);
    try testing.expectEqual(@as(?Outcome, .needs_input), a.feed(.input));

    var b = machine(.input); // answering a paused agent
    try testing.expectEqual(@as(?Outcome, null), b.feed(.input)); // snapshot (==initial)
    _ = b.feed(.working);
    try testing.expectEqual(@as(?Outcome, .done), b.feed(.idle));
}

test "outcome exit codes" {
    try testing.expectEqual(@as(u8, 0), Outcome.done.exitCode());
    try testing.expectEqual(@as(u8, 2), Outcome.needs_input.exitCode());
    try testing.expectEqual(@as(u8, 3), Outcome.timeout.exitCode());
    try testing.expectEqual(@as(u8, 4), Outcome.no_turn.exitCode());
    try testing.expectEqual(@as(u8, 4), Outcome.ended.exitCode());
}
