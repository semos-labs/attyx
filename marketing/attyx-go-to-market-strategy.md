# Attyx — Go-to-Market Strategy

*Repositioning: "just a terminal" → "the terminal for agentic workflows." Twitter/YouTube-first. Revised June 2026.*

---

## The bet, in one paragraph

The repositioning is already done where it counts — the README, `attyx.sh`, and the meta/OG tags all lead with "Terminal for agentic workflows," built around the real differentiators (per-pane agent status dots, IPC/CLI/MCP control, daemon-backed sessions, a <5 MB Zig binary). So this is a distribution problem, not a messaging rewrite. Given what's already happened — a Show HN that didn't land under the old positioning, and Reddit pushback on AI-written code — we're **not** going back to those wells. The spine is the two channels that fit a visual product and that you can actually sustain: **X/Twitter** (validated) and **your YouTube channel** (~2k subs, owned, warm). Everything else is a low-hostility amplifier. The hook is visual — dots flipping across an agent swarm is the entire pitch in 15 seconds — and both spine channels are built to carry exactly that.

---

## 1. Where Attyx sits (and the one line that wins)

The "agentic terminal" space is crowded now, so the positioning has to be sharp.

**Warp** is the gorilla — rebranded from "AI terminal" to "the agentic development environment," went open source in May 2026, and pairs local Agent Mode + MCP with a cloud agent orchestrator. Its bet: the terminal should *become* the agent. Warp brings its own AI, account, and cloud.

**Ghostty / Kitty / WezTerm / Alacritty** are the pure-terminal benchmark (Ghostty ~53k stars in ~18 months). Excellent terminals, zero agent-awareness — that's the gap.

**cmux / agent-deck / amux / CodeAgentSwarm** are the orchestration niche — TUIs and desktop apps that wrap agents into panes/boards. Mostly macOS-only, desktop-app-shaped, or bolt-on.

**Attyx's wedge: agent-agnostic mission control.** Attyx doesn't bring its own AI, account, or cloud. It makes *whatever agents you already run* — Claude Code, Codex, opencode — observable (status dots), drivable (stable pane IDs over IPC/CLI/MCP), and persistent (daemon sessions), in a real GPU terminal that's a single <5 MB binary. That's the one line none of the competitors can say, and every asset ladders back to it:

> **Warp wants to be your agent. Attyx is mission control for any agent you already use.**

---

## 2. Messaging — and how we handle the AI-code question

**Positioning one-liner** (what you say in the video cold-open and the lead tweet):

> **A GPU terminal that knows what your AI agents are doing — and lets any agent drive any pane.**

Punchier variant: **"`htop` for your agent swarm, built into the terminal."**

**Three proof pillars** (lead with the visual one):

1. **See the swarm** — a colored dot on every pane (working / waiting on you / idle), live across all sessions, plus `attyx dashboard`. The visual hook; the easiest thing to clip.
2. **Drive the swarm** — stable pane IDs over a Unix socket; one agent spawns, reads, and nudges others via the `attyx` CLI and MCP.
3. **Real terminal underneath** — daemon sessions, splits/tabs/popups, command palette, VT-correct engine, 22 themes, <5 MB, no Electron. The credibility hook.

**On the "it's AI-written code" objection — don't foreground authorship; let rigor speak.** This was the right call. The narrative is engineering quality and that you *daily-drive it and it's solid*: the deterministic VT engine, the mandatory testing discipline, the daemon-engine work that made session switching 10–40× faster, no per-character allocations, single tiny binary. Authorship simply isn't part of the story. If someone asks directly, answer matter-of-factly and move on — never defensively, never as a headline. On X and YouTube this is easy because nobody interrogates a commit history when the screen recording shows the thing working. The rigor *is* the rebuttal; you just never have to say the word.

**Per-audience lead fact:**
- **X / dev-Twitter:** lead with the visual. The swarm clip is the pitch.
- **YouTube:** lead with the *workflow* — "here's how I run four coding agents at once without losing track." Solve a problem the viewer already has.
- **Agentic-AI ecosystem (Claude Code / Codex / opencode / MCP crowd):** lead with the integration — "your agents now have a status light and a remote control," `attyx skill install`, the Claude Desktop MCP bridge.

---

## 3. Channel plan

### Spine — the two channels that carry the launch and the cadence

**X / Twitter (validated).** Your hook is visual and X rewards that. Two modes:
- *Launch moment:* a pinned thread led by the 15–20s swarm clip, unpacking the three pillars with a GIF each. (Full thread in the assets file.)
- *Sustained engine:* this is where the real compounding happens. You already ship releases fast (v0.4.12 and climbing) — every meaningful release becomes a short clip + GIF, plus build-in-public posts about the hard engineering (the daemon-engine move, VT-correctness war stories, why Zig). One good clip a week beats one big launch.

**YouTube (~2k subs, owned — your best durable asset).** This is the channel I'd lean into hardest, because:
- It's the only channel here with **search longevity** — a "how to run multiple Claude Code agents" video ranks and pays out for months, reaching the exact high-intent audience long after launch day. X clips die in 48 hours; a YouTube video accrues.
- Your 2k subs are a warm first-hour audience that guarantees initial watch-time signal, which is what the algorithm needs to start recommending it.
- The product is *demo-shaped* — agent swarms in motion are inherently watchable.

Plan: one **flagship 6–10 min video** (the workflow film — script in assets), plus **Shorts** cut from the same footage and cross-posted to X. Then a per-feature video cadence (the dashboard alone is worth its own video). Target search-friendly, problem-first titles, not brand-first ones.

### Amplifiers — low-hostility, high-intent, low effort

- **Agentic-AI ecosystem placement.** Submit to MCP server directories/registries, the Claude Code / opencode community spaces (Discord/X), and the agent-tool awesome-lists (`awesome-cli-coding-agents`, `awesome-agent-orchestrators`, awesome-zig, terminal lists). These reach people who already run agents and want better tooling — the opposite of an AI-skeptical crowd. Low effort, durable referral traffic.
- **Newsletters.** Pitch agentic-AI and devtools newsletters (TLDR, Console.dev, Changelog, Pointer). One paragraph + the OG image + the flagship video link. (Template in assets.)
- **Product Hunt (optional, one shot).** Visual-friendly, not engineering-snobby, decent awareness bump. Worth a single coordinated launch with the same clip and your X/YouTube audience driving it. Don't over-invest — it's an awareness play, not a star machine.
- **Creator/peer amplification.** You have a YouTube presence — trade shout-outs or get the tool in front of other devtools/AI-coding YouTubers who'd find it genuinely useful. A 30-second mention in someone else's "my AI coding setup" video is worth more than any post you write yourself.

### Explicitly not doing

Hacker News and Reddit are off the table for this push. HN didn't land under the old positioning and the AI-code hostility there and on Reddit isn't worth fighting. *If* you ever revisit HN, do it only when `attyx dashboard` ships — a concrete new feature is legitimate news and a cleaner pretext than relaunching — and treat it as optional upside, not a plan.

---

## 4. Launch sequence

**T-minus 2 weeks — prep (don't launch without these):**
- Record the hero footage once, cut everything from it: the flagship YouTube video (6–10 min), a 60–90s condensed cut, a 15–20s silent loop for the X lead, and 3–4 Shorts/GIFs (dots flipping, CLI driving a pane, command palette, theme switching).
- Confirm the OG image (`attyx.sh/images/attyx-og.png`) unfurls cleanly on X/Slack/Discord — it's what most people see first.
- Write and queue the X thread, the YouTube title/description/thumbnail, the newsletter pitches, the awesome-list PRs.
- **Fix the install-command inconsistency** (see §6) and test `brew install` cold on a clean machine. Broken install = dead launch.

**Launch week:**
- Publish the flagship YouTube video first (it needs a head start to gather watch-time).
- Same day: fire the pinned X thread led by the swarm clip, and link the video in tweet 6. Notify your YouTube subs (community post) so the first-hour signal is strong.
- Drop the awesome-list PRs and ecosystem/registry submissions.
- 24–72h later: newsletter pitches go out, referencing the video.

**Ongoing (the part that actually compounds):**
- Per-release X clips + a per-feature YouTube cadence.
- Build-in-public posts on the engineering.
- Hold the `attyx dashboard` launch as the second flagship video — "htop for agents" is a strong enough standalone story.

---

## 5. Assets (companion file)

All ready-to-post copy is in **`attyx-launch-assets.md`**: the X launch thread, standalone X hooks for the cadence, the flagship YouTube video script + title/thumbnail/description/tags + Shorts shot list, the newsletter/creator outreach template, awesome-list/registry blurbs, and an optional Product Hunt blurb. Written in your first-person voice — edit into your own words before posting.

---

## 6. Metrics, targets & things to get right

**Track the funnel, not the spike:**

| Metric | What good looks like | What it tells you |
|---|---|---|
| YouTube views / watch-time / subs gained | flagship video outperforms your channel baseline; retention >50% | whether the workflow story lands + durable reach |
| X impressions / clip views / profile-link clicks | lead clip outperforms your usual posts | whether the visual hook works |
| GitHub stars run-rate | 2–3× your pre-launch weekly baseline, *sustained* | mindshare / durability (more meaningful than a one-day spike) |
| Homebrew installs | upward trend on `git:downloads` | real usage — the metric that matters |
| Issues/PRs | steady inflow, fast responses | community health + contributor funnel |

The leading indicator to watch all month is **stars-and-installs run-rate after the launch settles.** A push that durably 2–3×'s your baseline is the win; a one-week blip that returns to baseline means the cadence (the weekly clips + YouTube SEO) is where the work really is. For a solo dev, the compounding cadence beats any single launch — plan accordingly.

**Things to get right:**
- **Install friction kills launches.** The README says `brew install semos-labs/tap/attyx --cask`; `attyx.sh` shows `brew tap semos-labs/tap` then `brew install attyx`. Pick one canonical form, make both surfaces match, and test it cold. This is the first thing every curious viewer does.
- **Have the Warp answer tight** — agent-agnostic, local, no account/cloud, 5 MB, MIT. Concede they're good; draw the line on philosophy.
- **Don't oversell the agent layer** — name the limits (POSIX-only HTTP MCP, Windows caveats, dashboard not shipped yet). Accuracy is cheaper than a correction.
- **Trust is a feature** — no telemetry, no account, loopback-only MCP, MIT. Against a funded competitor that wants your cloud and data, "tiny, local, open" is a real differentiator. Lean on it.

---

*Sources for the landscape data are in the chat response accompanying this document.*
