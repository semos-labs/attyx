# Attyx — Launch Assets

Twitter/YouTube-first. **Edit everything into your own voice before posting** — it reads better and it's yours.

Guiding principle baked into every asset: **lead with the visual and the workflow; let the engineering rigor carry credibility; never foreground that the code is AI-assisted.** If anyone asks, answer matter-of-factly and move on.

Contents: X launch thread · standalone X hooks · flagship YouTube video (script + title/thumbnail/description/tags) · Shorts shot list · newsletter/creator outreach · ecosystem/awesome-list blurbs · optional Product Hunt.

---

## 1. X / Twitter launch thread

**Tweet 1 (the hook — attach the 15–20s swarm clip). The clip does the work; keep words minimal.**

> I kept losing track of which of my AI coding agents were working, which were stuck waiting on me, and which were done.
>
> So I built a terminal that shows you — and lets any agent drive any pane.
>
> Meet Attyx. GPU-rendered, written in Zig, under 5 MB. 🧵

**Tweet 2 (pillar 1 — dots GIF):**

> A colored dot on every pane, straight from each agent's own lifecycle:
>
> 🟠 working  🟣 waiting on you  🟢 idle
>
> Run Claude Code, Codex, and opencode side by side and tell at a glance who needs you. No more alt-tabbing to check.

**Tweet 3 (pillar 2 — CLI/orchestration GIF):**

> Every pane has a stable ID, and the whole terminal is scriptable over a Unix socket — CLI and MCP.
>
> One agent can spawn, watch, nudge, and clean up others:
>
> ```
> id=$(attyx split v --cmd "claude -p 'run tests'")
> attyx get-text -p $id
> attyx send-keys -p $id "yes{Enter}"
> ```

**Tweet 4 (pillar 3 — palette/themes GIF):**

> A real terminal underneath, not a wrapper:
>
> • daemon sessions — reopen tomorrow, every pane intact
> • splits, tabs, floating popups
> • command palette, 22 themes
> • VT-correct GPU engine, no Electron
>
> Single native binary, under 5 MB.

**Tweet 5 (the differentiator):**

> Attyx is deliberately agent-agnostic. No built-in AI, no account, no telemetry, loopback-only MCP, MIT.
>
> It's not trying to be the agent. It's mission control for whatever agents you already run.

**Tweet 6 (CTA — link the YouTube video here):**

> macOS (Apple Silicon + Intel) and Linux (x64 + ARM64):
>
> brew tap semos-labs/tap
> brew install attyx
>
> Full walkthrough (video), docs, and source:
> [YouTube link] · https://attyx.sh · github.com/semos-labs/attyx
>
> Built it solo, daily-driving it. Tell me what breaks.

*(Pin Tweet 1. Post a YouTube community post the same day so your subs boost the video's first-hour watch-time.)*

---

## 2. Standalone X hooks (the ongoing cadence — this is what compounds)

One per meaningful release or whenever you have a good clip. Each pairs with a GIF/clip.

- "htop, but for your AI agents." [dashboard clip] — `attyx dashboard` shows every agent across every session: state, tokens, cost, context. One screen.
- "I just dragged an image into a Claude Code pane from the command line." [send_image clip] — `attyx send_image screenshot.png`
- "Heavy TUI session switching went from ~200ms to single-digit milliseconds. Here's the daemon-engine trick." [before/after clip + short thread]
- "Your terminal should know when an agent is waiting on you. Mine does now." [dot flips purple → native notification fires]
- "22 themes, live-previewed in the command palette." [theme cycling clip]
- "Why I wrote a terminal in Zig — and what it taught me about how terminals actually work." [build-in-public thread, engineering-forward]
- "One agent, four panes, zero focus changes: watch it orchestrate the others over a socket." [orchestration clip]

---

## 3. Flagship YouTube video

Your single best durable asset. Problem-first, workflow-led, search-optimized. Footage recorded once; the X clips and Shorts are cut from the same session.

**Title** (problem-first beats brand-first for search — pick one):
- `How I run 4 AI coding agents at once without losing track`
- `I built a terminal that shows what every AI agent is doing`
- `Managing multiple Claude Code agents: the terminal I built to fix it`

**Thumbnail:** the four-pane swarm with the colored dots clearly visible (orange/purple/green), one bold word like "SWARM" or "4 AGENTS." High contrast, readable at phone size. Your face in the corner if that's your channel's style — familiar faces lift CTR for an existing subscriber base.

**Length:** 6–10 minutes. Hook in the first 15 seconds (show the dots flipping before any intro).

**Script outline:**

1. **(0–0:20) Cold open — the pain, shown not told.** Four agents running, you narrating: "I run a few coding agents at once, and the real problem was never the agents — it was knowing which one needed me." Dots visible and changing.
2. **(0:20–2:00) Pillar 1 — see the swarm.** Walk through the status dots from each agent's lifecycle, the native notification when one needs input, click-to-jump. This is the emotional payoff — dwell here.
3. **(2:00–4:30) Pillar 2 — drive the swarm.** Live-type the orchestration sequence (`split` → `get-text` → `send-keys` → `close`). Explain stable pane IDs and the socket. Show the MCP angle: `attyx skill install`, Claude Desktop driving the terminal.
4. **(4:30–6:30) Pillar 3 — it's a real terminal.** Command palette, splits/tabs/popups, a daemon session reopening intact, theme switching. Mention <5 MB, Zig, GPU, no Electron — briefly; this is the credibility beat, not the focus.
5. **(6:30–end) Philosophy + CTA.** "No built-in AI, no account, no telemetry, MIT — mission control for the agents you already use." Install command on screen, links in description, ask for a sub.

**Description (paste-ready, edit links):**

> Attyx is a GPU-accelerated terminal built for running AI coding agents. It puts a live status dot on every pane — working, waiting on you, or idle — straight from each agent's lifecycle (Claude Code, Codex, opencode), and exposes the whole terminal over a CLI and MCP so one agent can spawn, read, and drive others by stable pane ID. Daemon-backed sessions, splits/tabs, command palette, 22 themes. Single native binary under 5 MB, written in Zig, GPU-rendered on Metal and OpenGL. No account, no telemetry, MIT.
>
> Install (macOS + Linux):
> brew tap semos-labs/tap
> brew install attyx
>
> Site: https://attyx.sh
> Docs: https://attyx.sh/docs/
> Source: https://github.com/semos-labs/attyx
>
> Chapters:
> 0:00 The problem with running multiple agents
> 0:20 Live agent status on every pane
> 2:00 Driving panes from the CLI and MCP
> 4:30 The terminal underneath
> 6:30 Why agent-agnostic + how to install

**Tags / search terms to weave into title, description, first comment:** multiple Claude Code agents, AI coding agents, agent orchestration, Claude Code workflow, Codex CLI, opencode, terminal for AI agents, MCP terminal, tmux alternative for agents, Zig terminal, GPU terminal.

---

## 4. Shorts / GIF shot list

Cut from the flagship footage. ≤6s loops for Shorts (vertical) and X (landscape). Same clips serve both.

- Dots flipping orange→purple→green across the tab bar (the money shot).
- `attyx split / get-text / send-keys` driving a pane with no focus change.
- Command palette fuzzy-searching and running an action.
- Theme cycling with live preview.
- Native notification firing when an agent needs input → click → jump to pane.
- (When it ships) `attyx dashboard` populating with live agents.

Each Short gets a one-line problem-first caption ("Telling which AI agent needs you, at a glance 👇").

---

## 5. Newsletter / creator outreach

Short, no fluff. Attach the OG image, link the flagship video. Target: TLDR, Console.dev, Changelog, Pointer, agentic-AI newsletters, and devtools/AI-coding YouTubers whose audience would actually use this.

> Subject: Attyx — a tiny GPU terminal that's aware of your AI agents (open source)
>
> Hi [name],
>
> I built Attyx, a GPU-accelerated terminal (Zig, single binary under 5 MB) for people running multiple AI coding agents. It puts a live status dot on each pane straight from the agent's lifecycle — working / waiting on you / idle — and exposes the whole terminal over a CLI and MCP, so one agent can spawn, read, and drive others by stable pane ID. Works with Claude Code, Codex, and opencode. Fully local — no account, no telemetry — and MIT.
>
> It's the opposite bet from Warp: not trying to be the agent, just mission control for the agents you already use.
>
> Short demo: [YouTube link] · Repo: github.com/semos-labs/attyx
>
> Happy to answer anything. Thanks for taking a look.
>
> [Nick]

**For YouTubers specifically**, add: "If it'd be useful to your audience I'm glad to hop on a call or set you up — no strings." A 30-second mention in someone's "my AI coding setup" video outperforms anything you post yourself.

---

## 6. Ecosystem / awesome-list / registry blurbs

For PRs to `awesome-cli-coding-agents`, `awesome-agent-orchestrators`, awesome-zig, terminal lists, and MCP server directories. Match each list's format.

> **Attyx** — GPU-accelerated terminal (Zig, <5 MB) that tracks AI-agent lifecycle state per pane (Claude Code, Codex, opencode) and exposes the full terminal over CLI/IPC/MCP so agents and scripts can drive panes by stable ID. Daemon-backed sessions, splits/tabs, command palette, 22 themes. macOS + Linux, MIT.

**MCP directory one-liner:**

> Attyx MCP — drive a real GPU terminal from any MCP client: list/create panes and tabs, send keystrokes, read pane output, manage sessions, check agent status. Loopback-only, POSIX.

---

## 7. Product Hunt (optional, one shot)

If you run it, keep it light and drive your X/YouTube audience to it on launch day.

> **Tagline:** Mission control for your AI coding agents — in the terminal.
>
> **Description:** Attyx is a GPU-accelerated terminal (Zig, <5 MB) that shows a live status dot on every pane — working, waiting on you, idle — from each agent's lifecycle, and lets any agent or script drive any pane over a CLI and MCP. Works with Claude Code, Codex, and opencode. Daemon sessions, splits/tabs, command palette, 22 themes. Local-only, no account, MIT. macOS + Linux.
>
> **First comment:** Built this because I run several coding agents at once and couldn't tell which needed me. It's agent-agnostic on purpose — no built-in AI, no cloud, just a fast terminal that knows what your agents are doing and lets them drive each other. Happy to answer anything.
