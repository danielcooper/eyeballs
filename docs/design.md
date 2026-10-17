# Eyeballs design

- **Purpose:** Build Eyeballs from this design. Eyeballs is a native macOS app where you review a coding agent's stack of PRs layer by layer, and the agent replies and fixes.
- **For:** the agents that build PRs 1 to 15 from it, and the people who review those PRs.
- **Date:** 2026-10-16.
- **Status:** approved. PR 0, the diff pane spike, is done. PRs 1 to 8 are built and connected on the `mvp` branch: the whole loop works from a terminal. PR 9, the plugin, is next.
- **Words used here:**
  - **"You"** means the reviewer: the person who reads the stack in Eyeballs and comments on it.
  - **"The agent"** means the coding agent that submits the stack and replies.
  - **"Fix N"** points to the numbered list in [Changes after design review](#changes-after-design-review).
  - **"Assumption"** marks anything not yet confirmed. Each one names the PR that checks it.
- **Examples:** the reviewer's `git config user.name` is Alex, and the repo is at `/Users/alex/src/shop`.

## Contents

- [Why Eyeballs exists](#why-eyeballs-exists)
- [Overview](#overview)
- [Decisions and reasons](#decisions-and-reasons)
- [A. Architecture: the app is the only writer](#a-architecture-the-app-is-the-only-writer)
- [B. Data model: every comment lasts for months](#b-data-model-every-comment-lasts-for-months)
- [C. Agent contract: the CLI is the agent's only interface](#c-agent-contract-the-cli-is-the-agents-only-interface)
- [D. Review window: a GitHub-style review, one layer at a time](#d-review-window-a-github-style-review-one-layer-at-a-time)
- [E. Anchoring and porting: threads follow the code or say they are outdated](#e-anchoring-and-porting-threads-follow-the-code-or-say-they-are-outdated)
- [F. Build and release: copy wreckingball, then add targets in stages](#f-build-and-release-copy-wreckingball-then-add-targets-in-stages)
- [G. Delivery plan: small PRs, one at a time](#g-delivery-plan-small-prs-one-at-a-time)
- [H. Risks, assumptions and open questions](#h-risks-assumptions-and-open-questions)
- [Diff pane spike results (PR 0)](#diff-pane-spike-results-pr-0)
- [Changes after design review](#changes-after-design-review)

---

## Why Eyeballs exists

You want to review what an agent built before it goes out wider. VS Code shows the code, but it gives you no way to leave comments for the agent and get replies.

Research on 2026-10-16 found many tools that do part of this. The closest, [Crit](https://github.com/tomasz-tomczyk/crit), does most of it in a browser. No tool found offers these three things together:

- **Per-layer review of a local `gh stack`** before anything is pushed.
- **Threads that stay attached** when the agent rebases or amends the stack.
- **A native Mac window** with two-way threads.

So the project makes three choices:

- **Build it stack-first.** Per-layer review of local gh-stack stacks and rebase-proof threads are the core. A general diff viewer is not the goal.
- **Use a fully native diff pane.** That rules out a web view and a localhost UI.
- **Use [wreckingball](https://github.com/danielcooper/wreckingball)'s build system:** XcodeGen, Swift 6, macOS 15, and GitHub Actions with ad hoc signing.

---

## Overview

- **`Eyeballs.app` is the only process that writes state.** It owns one SQLite database, runs git and serves a Unix socket. Only one copy runs at a time.
- **The `eyeballs` command-line interface (CLI) is how the agent talks to the app.** It is a thin client inside the app bundle. Commands print compact text, and every command takes `--json`. There is no Model Context Protocol (MCP) server in version 1.
- **The agent's loop:**
  1. **Submit:** The agent runs `eyeballs review`, then `eyeballs wait` in the background.
  2. **Review:** You comment and press Submit review.
  3. **Wake:** The wait exits, and the agent runs `eyeballs inbox`.
  4. **Fix and reply:** The agent fixes the code, runs `eyeballs reply`, then runs `eyeballs review` again.
- **Comments reach the agent only through `inbox` and `show`.** Every wake-up tells the agent to run `eyeballs inbox`. `inbox` always returns every thread that waits on the agent, so an interrupted read loses nothing.
- **One driver per stack.** The session that last ran `eyeballs review` or `eyeballs attach` gets that stack's wake-ups. Subagents share the parent's session ID, so they act for the driver. A dead driver hands the role to the next session that asks.
- **The agent wakes in layers:**
  - **Background wait:** `eyeballs wait` in the background is the main path.
  - **Monitor:** a plugin monitor running `eyeballs watch` catches events while the agent is busy. It starts only after the skill runs.
  - **Stop hook:** a safety net at the end of each turn.
  - **SessionStart context:** recovery after a restart, `/clear` or compaction.
- **Only you resolve, submit, approve or push.** No command does any of these.
- **Stacks come from `.git/gh-stack`.** That is gh-stack's own JSON file. Eyeballs reads it directly and never runs `gh stack view`, because that command calls GitHub and rewrites the file.
- **Reviewed commits are pinned** under `refs/eyeballs/…`, so old revisions survive rebases and `git gc`.
- **An outdated thread beats a wrong one.** The app checks every ported thread against the new file text. If the check fails, the thread shows as outdated, with its original code. A simple porter ships first.
- **Guards against data loss:**
  - **Sync mode:** `synchronous=FULL`
  - **Backups:** daily and before each migration
  - **Drafts:** autosave and soft deletes
  - **Enums:** no `CHECK` lists
  - **Pins:** named by commit SHA
  - **Debug:** a separate store
- **The diff pane is fully native.** It is a view-based `NSTableView` with row-height estimation turned off. The PR 0 spike proved this shape.
- **The build is wreckingball's shape.** A local package with no dependencies holds the core logic, so `swift test` runs in seconds. Every remote package stays in `project.yml`.
- **The MVP is PRs 0 to 9.** You can read a real stack after PR 4. The full loop works from a terminal after PR 8, and inside Claude Code after PR 9.

---

## Decisions and reasons

Each item gives the choice, then the reason. Sections A to H hold the detail.

### Architecture and transport

1. **Who writes state:** the app only, over a Unix socket, not a shared database. Reason: one writer removes cross-process locking, version skew and change signals, and the app must run for you to review anyway.
2. **One app at a time:** the app takes an exclusive `flock` on `run/app.lock` before it opens the database or the socket. Reason: Xcode's Profile action, a second downloaded copy or an old CLI link could otherwise start a second writer, and wake-ups would split between the two (fix 1).
3. **Socket token:** no token. Use a 0700 folder, a 0600 socket and a `getpeereid` UID check. Reason: a process that can read a 0600 token can already open a 0600 socket in a 0700 folder.
4. **App lifetime:** the app keeps running after its last window closes, and it offers Open at Login. Reason: hooks and `watch` never start the app, so it should usually be running.
5. **Process API:** Foundation `Process`, not swift-subprocess. Reason: swift-subprocess 1.0.2 was published on 2026-10-16, the day this design was written ([swift-subprocess releases](https://github.com/swiftlang/swift-subprocess/releases)).
6. **MCP:** none in version 1. Reason: the CLI already serves the agent, and a second interface would need its own tests and versioning.
7. **URL scheme:** integer IDs only, never paths. Reason: a web page can fire the URL. Paths arrive over the socket instead.

### Agent contract

8. **Output format:** text for commands the agent reads, with `--json` on every command. Reason: code inside JSON strings costs escapes and reads worse, while scripts and hooks still get JSON.
9. **Delivery path:** every wake-up says "run `eyeballs inbox`". Only `inbox` and `show` hand comment text to the agent, and `review` never prints the review. Reason: a finished background task's notice carries the output file path and exit code but not the output. One delivery command also means one delivery state.
10. **What `inbox` returns:** every thread that waits on the agent, with the ones shown before labelled. `delivered_at` only stops repeat wake-ups. Reason: an interrupted `inbox`, or one run by a subagent, would otherwise hide threads for good (fix 11).
11. **Submit then wait:** `review` runs in the foreground and `wait` runs in the background. Reason: the agent sees errors at once, and the CLI tells it which wake-up path to use.
12. **Ownership:** one driver per stack, set by `review` or `attach`, with no thread claims. When the driver's session has ended or its process is gone, the role moves to the caller. Reason: the driver rule already gives one owner, subagents share the parent's session ID, and a dead driver must not strand a review (fix 11).
13. **Replies from other sessions:** saved with a `not_driver` warning, never refused. Reason: agent text is never lost (fix 11).
14. **Wake-up routing:** the app sends each event to every live `wait` and `watch` connection of the driver's Claude process. It keys connections by `CLAUDE_PID` plus that process's start time. Reason: a subagent's background `wait` wakes the subagent, not the main conversation, and both share one session ID. A duplicate wake-up costs one extra `inbox` call (fix 10).
15. **Monitor:** starts only after the review skill runs, through a `when` value on the monitor. Reason: a monitor in every session blocks backgrounding and keeps idle sessions alive. SessionStart context still tells a resumed session that a review is waiting (fix 12).
16. **Main wake-up path:** background `eyeballs wait`, until PR 9 confirms that a monitor line wakes an idle session. Reason: the Claude Code docs say a finished background task wakes Claude, but they only say a monitor lets Claude "interject".
17. **Stop hook:** blocks once per reason, recorded in `stop_block`, with no early exit on `stop_hook_active`. Reason: that flag stays true for the whole continuation, so an early exit would skip the unreplied-threads check (fix 12).
18. **Exit codes:** the sysexits family 0, 64, 65, 69, 70, 75, 77 and 78. A wrapper around `main` maps every error, with 70 as the default. Reason: swift-argument-parser already exits 64 for usage errors, and without the wrapper it exits 1 for any unmapped error (fix 6).
19. **Reply input:** `## t41 addressed` text blocks, with `--json-file PATH|-` as an option. Reason: reply bodies hold quotes, backticks and code, which break JSON typed into a heredoc.
20. **Reply statuses:** `addressed`, `declined` and `question`. Reason: they cover every case, and "declined" is more neutral than "rejected".
21. **Reply to a resolved thread:** saved, with a `thread_resolved` warning. Reason: agent text is never lost, and you can reopen the thread.
22. **Unreplied threads at resubmit:** `review` refuses with `unreplied` unless the agent passes `--force`. The check covers the whole stack. Reason: every round should answer every thread, whichever session read it (fix 11).
23. **Hook output:** counts and commands only, never comment bodies. Reason: comment text reaches the agent only through `inbox` and `show`.
24. **JSON versioning:** every JSON object carries `"schema":"eyeballs.<kind>/1"` and `"ok"`. Reason: scripts can detect shape changes, and fields are only ever added within a version.
25. **Names in shipped text:** packets, hook messages and the skill name the reviewer from `git config user.name`, or say "the reviewer" when it is unset. Reason: the repo is public, and anyone may run Eyeballs.

### Data and storage

26. **IDs:** integers shown as `s3`, `t41`, `r4`, `c210` and `review 7`, with no UUID columns. Reason: short IDs save tokens, and since pins name commit SHAs, nothing outside the database refers to a row.
27. **Pin names:** `refs/eyeballs/<install-id>/<sha>`. Reason: writing a pin twice is harmless, a Debug store cannot collide with Release, and retention asks one question per SHA.
28. **Repo identity:** the git common directory, then root commits plus the remote. Eyeballs writes nothing to `.git/config`. Reason: pins stay the only thing Eyeballs writes into a repo.
29. **Durability:**
    - **Sync mode:** `synchronous=FULL`
    - **Backups:** `VACUUM INTO`, daily and before each migration
    - **Integrity:** `PRAGMA quick_check` at launch
    - **Migrations:** a hash lock
    - **Drafts:** autosave
    - **Deletes:** soft deletes
    - **Edits:** `comment_edit` history

    Reason: these are cheap, and comments must last for months.
30. **Enum columns:** no `CHECK` lists. Swift decodes unknown values. Reason: SQLite cannot change a `CHECK` constraint without rebuilding the table, and the lists will grow.
31. **Timestamps:** integer milliseconds, UTC. JSON shows ISO 8601. Reason: cheap to compare and sort.
32. **Event table:** none in version 1. Reason: delivery fields on reviews and comments answer "what is waiting", and the app pushes events to live connections.
33. **Anchor key:** at most one ported anchor per thread per revision, plus any number of `human` anchors, using partial indexes. Reason: "the anchor at rN" is a direct lookup, and "Move here" stays append-only.
34. **Layer position:** 1 is the bottom layer. Reason: it matches the "layer 1" you see.
35. **Base rules:** `parent_tip`, then `recorded_base`, then `fork_point`, then `merge_base`. Reason: `fork_point` costs one git call, and gh-stack itself uses fork-point.
36. **Stack sources in version 1:** gh-stack, a single branch, and an explicit `--branches` list. Inferred plain-git chains wait in the backlog. Reason: the core use is gh-stack.
37. **Refusing during an operation:** Eyeballs refuses a snapshot only during a real operation. That means a `gh stack modify` in its `applying` or `conflict` phase, or a paused rebase that touches a stack branch. Reason: gh-stack keeps its modify file in `pending_submit` until someone pushes, and the skill forbids pushing, so a stricter rule stalls the loop (fix 9).

### Porting

38. **Porting:** check every result, and mark the thread outdated if the check fails. The full chain ships in PR 10, and a simple porter ships first in PR 7. Reason: correct threads without delaying the loop.
39. **Deleted lines and far moves:** when the commented lines are deleted, the thread becomes outdated, with "was near line N" as a hint only, unless a content search finds the same lines elsewhere. A thread placed by any search needs one side of its context to match, or it shows "Check placement". Reason: an outdated thread beats a wrong one (fix 14).
40. **Send now ports:** a Send now comment is a submit with one comment. Reason: otherwise its packet gives old line numbers while the branch is at a newer revision (fix 13).

### UI

41. **Windows:** one main window, not a Reviews window plus one window per stack. Reason: fewer windows to manage. A stack can pop out later.
42. **Sidebar order:** top layer first and trunk last, like `gh stack view`. Layer 1 is selected by default. Reason: it matches the order you already read in the terminal.
43. **Window focus:** the window comes to the front without taking keyboard focus, and `--focus` overrides that. Reason: an agent can run `review` while you are typing.
44. **Esc in a composer:** closes it and keeps the draft. There is no keep-or-discard prompt. Reason: nothing is lost, and no modal dialog interrupts.
45. **Shortcuts:**
    - **Threads:** `r` replies and `e` resolves.
    - **Layers:** `⌘1` to `⌘9` jump to layers.
    - **Composer:** `⌘↩` adds the comment and `⌥⌘↩` sends it now.
    - **Submit:** `⇧⌘↩` submits the review.
    - **Focus guard:** single-letter shortcuts fire only when the table itself has keyboard focus.

    Reason: no key combination means two things, and a stray letter must never resolve a thread while you type (fix 2).
46. **Send now:** included. Reason: an answer to an agent's question should not wait for a whole review.
47. **Diff pane:** a view-based `NSTableView` with row-height estimation off. Reason: the PR 0 spike passed every check this way, apart from a warm-up hitch on the first scroll, and with estimation on, a row's position was about 14,000 points off.

### Build and agents

48. **Core packaging:** a local package with no dependencies holds the git runner, diff parser, porting and wire types. The GRDB store is a static target in `project.yml`. Reason: every remote package stays in `project.yml`, and `swift test` still runs the core in seconds.
49. **Targets arrive in stages:** PR 1 has only the app, the CLI and the core package. The store, GRDB and `doctor` arrive in PR 5, and the plugin checks in PR 9. Reason: XcodeGen fails when a target's source folder is missing, and CI cannot check files that do not exist yet (fix 4).
50. **Package pins:** `exactVersion`, not wreckingball's `from:`. Reason: `Package.resolved` lives inside the gitignored `.xcodeproj`, so only exact pins make CI builds repeatable.
51. **Debug isolation:** a separate folder, socket, bundle ID, URL scheme, install ID and CLI link (`eyeballs-debug`). Xcode's Profile action also points at the Debug folder. Reason: a Debug build or a profiling run must never touch real data (fixes 1 and 8).
52. **Plugin wrapper:** ship `bin/eyeballs`, not PATH only. Reason: hooks and monitors need a path that fails softly when the app is missing. claude.ai and Cowork refuse a plugin with a top-level `bin/`, but Eyeballs targets Claude Code in the terminal.
53. **Licence:** GPL-3.0-or-later, for the app and the plugin. Reason: wreckingball's README says "either version 3 of the License, or (at your option) any later version".
54. **Codex:** not in version 1. It waits in the backlog. Reason: Codex support was an assumption, not a stated need.

---

## A. Architecture: the app is the only writer

### Components

| Component | Kind | Job |
|---|---|---|
| `Eyeballs.app` | SwiftUI app with an AppKit diff pane | Owns the database. Runs git, writes pins, ports threads, renders text packets, serves the socket, shows the window, takes backups. |
| `eyeballs` | XcodeGen `tool` target at `Eyeballs.app/Contents/Helpers/eyeballs` | Reads the agent's environment, sends one request, prints the reply. Never opens the database. Links only `EyeballsKit` and swift-argument-parser. |
| `EyeballsCore` | Product of the local package `Packages/EyeballsCore`, no dependencies | Git runner with one serial `cat-file` queue, gh-stack catalog reader, stack discovery, base rules, unified-diff parser, porting, interdiff. |
| `EyeballsKit` | Product of the same package, no dependencies | Socket protocol types (`Codable`, `Sendable`) and the socket client. |
| `EyeballsStore` | Static library target in `project.yml`, from PR 5 | GRDB schema, migrations, records, backups. |
| `plugin/` | Plain files, from PR 9 | Claude Code plugin: skill, monitor, hooks and a `bin/eyeballs` wrapper. |

### How a request flows

1. **Find the app.** The CLI resolves its real path with `_NSGetExecutablePath` and `realpath`, then walks up from `Contents/Helpers` to the `.app`. This works through the `~/.local/bin` symlink and through the plugin wrapper.
2. **Connect.** It connects to `~/Library/Application Support/Eyeballs/run/eyeballs.sock`.
3. **Start the app if needed.** Only commands marked "Starts the app" in the [command reference](#command-reference) do this. They run `/usr/bin/open -g -a <app path>`, then retry every 100 ms for up to 10 s. Because the path is explicit, a Debug build never answers for Release.
4. **Send one JSON line:** `{"v":1,"id":7,"op":"inbox","client":{"agent":"claude","session":"…","pid":4242,"pid_start":1760620000,"ancestors":[…],"cwd":"…"},"args":{…}}`. The `client` block carries `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` and that process's start time.
5. **The app replies with one JSON line:** `{"id":7,"ok":true,"result":{…},"text":"…"}`, or `{"id":7,"ok":false,"error":{"code":"…","message":"…","hint":"…"}}`. The CLI prints `text` by default and `result` with `--json`.
6. **Streams stay open.** A `wait` connection gets one event and then closes. A `watch` connection streams events until it disconnects.
7. **The app checks the version.** It answers an unknown `v` with `version_mismatch`, and the CLI exits 78.

**Assumption:** Network.framework's `NWListener` does not expose the peer's credentials. So the server is a plain BSD socket on a dispatch source, which lets it call `getpeereid`. PR 5 checks this.

### Where state lives

| What | Where |
|---|---|
| Database | `~/Library/Application Support/Eyeballs/eyeballs.sqlite` (folder 0700, file 0600) |
| Backups | `~/Library/Application Support/Eyeballs/Backups/`: 14 daily backups, plus one before each migration |
| Socket | `~/Library/Application Support/Eyeballs/run/eyeballs.sock` (folder 0700, socket 0600) |
| Instance lock | `~/Library/Application Support/Eyeballs/run/app.lock` |
| Unsent drafts | `~/Library/Application Support/Eyeballs/drafts.json` (file 0600): composer text you have not added or sent, by stack, layer and composer. Schema 1 has no table for it. |
| Caches | `~/Library/Caches/coops.eyeballs/`: blob-pair diffs and highlight runs. Safe to delete. |
| Pins | `refs/eyeballs/<install-id>/<head-sha>` in each repo |
| Logs | `os.Logger`, subsystem `coops.eyeballs`. A `Log` enum with categories `app`, `server`, `git`, `store`, `port`, `ui`, after [wreckingball's Logger.swift](https://github.com/danielcooper/wreckingball/blob/main/Wreckingball/Utilities/Logger.swift). |
| Settings | `UserDefaults`, domain `coops.eyeballs` |
| Debug builds | Folder `Eyeballs-Debug/`, bundle ID `coops.eyeballs.debug`, URL scheme `eyeballs-debug`, CLI link `~/.local/bin/eyeballs-debug`, their own install ID |
| Profiling | Xcode's Profile action builds Release, so it sets `EYEBALLS_HOME` to the Debug folder (fix 1) |
| Tests | `$EYEBALLS_HOME`, pointing at a short temporary folder such as one under `/tmp` |

**Socket path length:** macOS limits a socket path to 103 bytes plus a terminating zero (`sun_path`). The Release path is 62 bytes plus the length of your user name, so it fits names up to 41 characters. Keep test homes short for the same reason, because `$TMPDIR` alone is about 50 bytes.

### Security rules

- **No network listener.** There is only the Unix socket. Unauthenticated localhost WebSockets in similar tools have led to remote code execution bugs.
- **Same user only.** The app checks every connection's UID with `getpeereid`, and the folder and socket permissions do the rest.
- **One app at a time (fix 1).** At launch the app works in this order:
  1. **Take the lock.** It takes an exclusive `flock` on `run/app.lock` and holds it for the life of the process. If the lock is taken, it shows `Eyeballs is already running from <path>` and quits.
  2. **Open the store.** It opens the database, runs `PRAGMA quick_check`, backs up and migrates.
  3. **Start listening.** It removes a stale socket file, which is safe only while it holds the lock. Then it binds and listens.
- **The agent API is narrow.** No operation resolves, submits, approves, deletes your comments, pushes or moves branches.
- **The URL scheme only navigates.** It accepts `eyeballs://`, `eyeballs://stack/3` and `eyeballs://thread/41`, following [wreckingball's Command.swift](https://github.com/danielcooper/wreckingball/blob/main/Wreckingball/Control/Command.swift). It never takes a path or writes anything.
- **Git runs hardened.**
  - **No shell:** arguments go as an array, never through a shell, with `--` before paths.
  - **Every call:** sets `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0` and `-c core.fsmonitor=false`. A repo's `core.fsmonitor` names a program that git runs ([git-config](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corefsmonitor)).
  - **Diffs:** use `--no-ext-diff --no-textconv`.
  - **Pins:** use `git -c core.hooksPath=/dev/null update-ref --stdin`, because the `reference-transaction` hook runs on ref updates ([githooks](https://git-scm.com/docs/githooks#_reference_transaction)).
- **Blob reads go through one serial queue (fix 5).** A long-lived `git cat-file --batch` answers in request order. Actor methods are reentrant at every `await` ([SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy)), so a plain actor could hand blob A to the caller that asked for blob B. Use either of these:
  - **One draining task:** an `AsyncStream` of (SHA, continuation) pairs, drained by one task that writes and reads strictly in order
  - **One serial queue:** a write and read done synchronously on one serial `DispatchQueue`, with no suspension between them
- **Output is terminal-safe.** Text packets show C0 control characters other than tab and newline as `\u{1b}`-style escapes, and JSON encodes them. A unit test feeds in ESC (0x1B).
- **Comment text stays private.** Logs mark bodies `privacy: .private`. Hook output carries counts and commands only.
- **Consent stays in the terminal.** The app frames every packet, monitor line and hook reason as a review request. The skill says comments never authorise a push, a force-push, `gh stack submit` or a merge.
- **Sizes are capped:** 64 KB per body, 200 replies per batch, 1 MB per request.

---

## B. Data model: every comment lasts for months

### Terms

- **Repo:** one clone. It is matched by its git common directory, then by root commits plus remote if the clone moved.
- **Stack (`s3`):** a gh-stack stack, an explicit branch list or a single branch. Eyeballs' own ID never changes, even when gh-stack's `id` does.
- **Layer:** one branch. Layer 1 is the bottom. A layer keeps its ID through a rename, a reorder or a rebase.
- **Snapshot:** one layer's fixed (base, head) pair, plus the base rule that chose the base.
- **Revision (`r4`):** one snapshot for every layer of the stack. The agent creates one with `eyeballs review`. You create one when you submit after branch tips moved.
- **Review (`review 7`):** your batch of comments with a verdict. It stays a draft until you submit it.
- **Thread (`t41`):** a conversation on a line range, a file or a whole layer. It is open or resolved, and only you change that.
- **Comment (`c210`):** one message. An agent's comment carries a reply status: `addressed`, `declined` or `question`.
- **Anchor:** where a thread sits in one revision, plus the text it covers. Anchors are only ever added, never changed.
- **Driver:** the agent session that gets a stack's wake-ups.
- **Pin:** a ref that keeps a reviewed commit alive through rebases and `git gc`.

### Storage settings

- **Engine:** GRDB 7.11.1 in a `DatabasePool` with WAL (write-ahead logging).
- **Pragmas:** `synchronous=FULL`, because WAL with `NORMAL` can lose the last commits on power loss ([SQLite synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)). Also `foreign_keys=ON`.
- **STRICT tables:** these need SQLite 3.37 or later, so the store asserts `sqlite_version() >= 3.37.0` when it opens.
- **Integrity:** `PRAGMA quick_check` runs at launch.
- **Backups:** `VACUUM INTO 'Backups/…'` runs daily and before each migration ([VACUUM INTO](https://www.sqlite.org/lang_vacuum.html#vacuuminto)).
- **Migrations:** `DatabaseMigrator`, adding things only. `Store/Migrations.lock` lists the SHA-256 of each shipped migration, and a test fails if one changes.
- **Units:** times are integer milliseconds UTC, and lines are 1-based and inclusive.
- **Deletes are soft.** Edits keep the old text in `comment_edit`. Drafts save themselves.
- **CHECK constraints:** kept only for structure (null pairs, line ranges) and for sets that can never grow (`human`/`agent`). Enum-like columns list their values in comments, and Swift decodes unknown values as `.unknown(raw)`.

### Schema version 1

```sql
CREATE TABLE store_info (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
-- keys: install_id, created_by_version

CREATE TABLE repo (
  id           INTEGER PRIMARY KEY,
  common_dir   TEXT NOT NULL UNIQUE,        -- last seen; updated when the clone moves
  root_commits TEXT NOT NULL,               -- sorted `git rev-list --max-parents=0 HEAD`
  remote_key   TEXT,                        -- gh-stack "repository" or normalised origin URL
  created_at   INTEGER NOT NULL
) STRICT;

CREATE TABLE agent_session (
  id          INTEGER PRIMARY KEY,
  agent       TEXT NOT NULL,                -- claude | other
  session_key TEXT NOT NULL,                -- CLAUDE_CODE_SESSION_ID
  pid         INTEGER,                      -- CLAUDE_PID; survives /clear
  pid_start   INTEGER,                      -- start time of pid, so a reused pid never looks alive
  cwd         TEXT NOT NULL,
  first_seen  INTEGER NOT NULL,
  last_seen   INTEGER NOT NULL,
  ended_at    INTEGER,
  UNIQUE (agent, session_key)
) STRICT;

CREATE TABLE stack (
  id              INTEGER PRIMARY KEY,      -- s<id>
  repo_id         INTEGER NOT NULL REFERENCES repo(id),
  name            TEXT NOT NULL,            -- top branch; the reviewer can rename it
  source          TEXT NOT NULL,            -- gh_stack | branch_list | single_branch; git_chain is kept for inferred chains (backlog)
  trunk_branch    TEXT NOT NULL,
  gh_stack_id     TEXT,                     -- last seen; changes after gh stack modify + submit
  gh_stack_number INTEGER,
  driver_session  INTEGER REFERENCES agent_session(id),
  state           TEXT NOT NULL DEFAULT 'active',   -- active | merged | archived
  created_at      INTEGER NOT NULL,
  ended_at        INTEGER
) STRICT;

CREATE TABLE layer (
  id          INTEGER PRIMARY KEY,
  stack_id    INTEGER NOT NULL REFERENCES stack(id),
  branch      TEXT NOT NULL,
  position    INTEGER NOT NULL,             -- 1 = bottom
  pr_number   INTEGER,
  pr_url      TEXT,
  state       TEXT NOT NULL DEFAULT 'active',   -- active | merged | dropped | folded
  folded_into INTEGER REFERENCES layer(id),
  created_at  INTEGER NOT NULL,
  ended_at    INTEGER
) STRICT;
CREATE UNIQUE INDEX layer_live_branch ON layer(stack_id, branch) WHERE state = 'active';

CREATE TABLE layer_name (
  layer_id   INTEGER NOT NULL REFERENCES layer(id),
  branch     TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  PRIMARY KEY (layer_id, branch)
) STRICT;

CREATE TABLE snapshot (
  id         INTEGER PRIMARY KEY,
  layer_id   INTEGER NOT NULL REFERENCES layer(id),
  base_sha   TEXT NOT NULL,
  head_sha   TEXT NOT NULL,
  base_tree  TEXT NOT NULL,
  head_tree  TEXT NOT NULL,
  base_rule  TEXT NOT NULL,                 -- parent_tip | recorded_base | fork_point | merge_base
  parent_ref TEXT NOT NULL,
  patch_id   TEXT,                          -- git patch-id --stable of base..head
  created_at INTEGER NOT NULL,
  UNIQUE (layer_id, base_sha, head_sha)
) STRICT;

CREATE TABLE snapshot_file (
  snapshot_id INTEGER NOT NULL REFERENCES snapshot(id),
  path        TEXT NOT NULL,
  old_path    TEXT,
  change      TEXT NOT NULL,                -- A | M | D | R | C | T
  base_blob   TEXT,
  head_blob   TEXT,
  file_patch  TEXT,                         -- hash of this file's diff without line numbers
  additions   INTEGER,                      -- NULL for binary
  deletions   INTEGER,
  PRIMARY KEY (snapshot_id, path)
) STRICT;

CREATE TABLE revision (
  id            INTEGER PRIMARY KEY,
  stack_id      INTEGER NOT NULL REFERENCES stack(id),
  number        INTEGER NOT NULL,           -- r<number>
  trigger       TEXT NOT NULL,              -- agent_submit | human_start
  content_hash  TEXT NOT NULL,              -- hash of sorted (layer, base, head); same hash = no new revision
  agent_session INTEGER REFERENCES agent_session(id),
  agent_note    TEXT,
  dirty_files   INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  UNIQUE (stack_id, number)
) STRICT;

CREATE TABLE revision_layer (
  revision_id INTEGER NOT NULL REFERENCES revision(id),
  layer_id    INTEGER NOT NULL REFERENCES layer(id),
  position    INTEGER NOT NULL,
  snapshot_id INTEGER NOT NULL REFERENCES snapshot(id),
  PRIMARY KEY (revision_id, layer_id)
) STRICT;

CREATE TABLE review (
  id           INTEGER PRIMARY KEY,         -- "review 7"
  stack_id     INTEGER NOT NULL REFERENCES stack(id),
  revision_id  INTEGER REFERENCES revision(id),     -- the revision the reviewer was looking at; set on submit
  status       TEXT NOT NULL,               -- draft | submitted | delivered | replied | discarded
  verdict      TEXT,                        -- comment | changes_requested | approved
  body         TEXT NOT NULL DEFAULT '',
  delivered_to INTEGER REFERENCES agent_session(id),
  created_at   INTEGER NOT NULL,
  submitted_at INTEGER,
  delivered_at INTEGER,
  replied_at   INTEGER
) STRICT;
CREATE UNIQUE INDEX review_one_draft ON review(stack_id) WHERE status = 'draft';

CREATE TABLE thread (
  id                   INTEGER PRIMARY KEY, -- t<id>
  stack_id             INTEGER NOT NULL REFERENCES stack(id),
  layer_id             INTEGER NOT NULL REFERENCES layer(id),   -- home layer
  subject              TEXT NOT NULL,       -- line | file | layer
  side                 TEXT,                -- base | head (GitHub LEFT | RIGHT)
  opened_by            TEXT NOT NULL DEFAULT 'human' CHECK (opened_by IN ('human','agent')),
  status               TEXT NOT NULL DEFAULT 'open',            -- open | resolved; only the UI changes it
  resolved_at          INTEGER,
  resolved_revision_id INTEGER REFERENCES revision(id),
  deleted_at           INTEGER,
  created_at           INTEGER NOT NULL
) STRICT;

CREATE TABLE anchor (
  id             INTEGER PRIMARY KEY,
  thread_id      INTEGER NOT NULL REFERENCES thread(id),
  revision_id    INTEGER NOT NULL REFERENCES revision(id),
  snapshot_id    INTEGER NOT NULL REFERENCES snapshot(id),
  layer_id       INTEGER NOT NULL REFERENCES layer(id),
  path           TEXT,                      -- NULL when gone or layer-level
  blob           TEXT,
  start_line     INTEGER,                   -- NULL = file or layer level, or outdated
  end_line       INTEGER,
  near_line      INTEGER,                   -- outdated only: "was near line N"; a hint, never a port source
  state          TEXT NOT NULL,             -- original | current | moved | whitespace | changed | relocated | outdated | gone
  method         TEXT NOT NULL,             -- created | same_blob | diff_shift | diff_ws | diff_interior | exact_search | fuzzy | journal | fallback | human
  confidence     REAL NOT NULL DEFAULT 1.0,
  verified       INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0,1)),
  in_diff        INTEGER NOT NULL CHECK (in_diff IN (0,1)),
  covered_text   TEXT,
  context_before TEXT,                      -- up to 3 lines
  context_after  TEXT,
  diff_hunk      TEXT,
  ported_from    INTEGER REFERENCES anchor(id),
  engine_version INTEGER NOT NULL,
  created_at     INTEGER NOT NULL,
  CHECK ((start_line IS NULL) = (end_line IS NULL)),
  CHECK (start_line IS NULL OR (start_line >= 1 AND end_line >= start_line))
) STRICT;
CREATE UNIQUE INDEX anchor_origin    ON anchor(thread_id) WHERE method = 'created';
CREATE UNIQUE INDEX anchor_port_once ON anchor(thread_id, revision_id) WHERE method NOT IN ('created','human');
CREATE INDEX anchor_by_thread ON anchor(thread_id, revision_id, id);

CREATE TABLE comment (
  id            INTEGER PRIMARY KEY,        -- c<id>
  thread_id     INTEGER NOT NULL REFERENCES thread(id),
  author        TEXT NOT NULL CHECK (author IN ('human','agent')),
  agent_session INTEGER REFERENCES agent_session(id),
  review_id     INTEGER REFERENCES review(id),        -- NULL for Send now and for agent replies
  reply_status  TEXT,                       -- addressed | declined | question (agent only)
  body          TEXT NOT NULL,
  at_ranges     TEXT,                       -- JSON [{"path","start","end"}] from `at:` lines
  revision_id   INTEGER NOT NULL REFERENCES revision(id),   -- newest revision when written
  fixed_in      INTEGER REFERENCES revision(id),            -- first revision after an addressed reply
  sent_at       INTEGER,                    -- NULL while in a draft review
  delivered_at  INTEGER,                    -- first shown by inbox; only stops repeat wake-ups
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  deleted_at    INTEGER,
  CHECK ((author = 'agent') = (reply_status IS NOT NULL)),
  CHECK (author = 'human' OR review_id IS NULL)
) STRICT;
CREATE INDEX comment_by_thread ON comment(thread_id, id);

CREATE TABLE comment_edit (
  id          INTEGER PRIMARY KEY,
  comment_id  INTEGER NOT NULL REFERENCES comment(id),
  old_body    TEXT NOT NULL,
  replaced_at INTEGER NOT NULL
) STRICT;

CREATE TABLE stop_block (                   -- the Stop hook blocks once per reason
  session_id INTEGER NOT NULL REFERENCES agent_session(id),
  reason_key TEXT NOT NULL,                 -- 'undelivered:7' | 'unreplied:7' | 'undelivered:c215' | 'unreplied:c215'
  blocked_at INTEGER NOT NULL,
  PRIMARY KEY (session_id, reason_key)
) STRICT;

CREATE TABLE pin (
  repo_id     INTEGER NOT NULL REFERENCES repo(id),
  sha         TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  released_at INTEGER,
  PRIMARY KEY (repo_id, sha)
) STRICT;
```

These tables come later, each as an added migration:

- **`viewed_file`:** keyed by layer, path and `file_patch` (PR 11).
- **`snapshot_commit`:** commit SHA, patch-id, Change-Id and subject, for range-diff labels and layer matching (PR 12).
- **`github_link` and `github_comment_link`:** for threads pushed to GitHub (backlog).

### Derived thread state

The app works out one state per thread. The first rule that matches wins, and the UI and the packets both use the result.

| Order | You see | Rule | Counts toward the Dock badge |
|---|---|---|---|
| 1 | Resolved | `status = resolved` | No |
| 2 | Draft | Every comment is in a draft review | No |
| 3 | Agent asks you | The last comment is an agent `question` | Yes |
| 4 | Check the fix | The last comment is an agent `addressed` reply | Yes |
| 5 | Agent declined | The last comment is an agent `declined` reply | Yes |
| 6 | Waiting on agent | The last comment is yours, and it has been sent | No |

A thread **waits on the agent** when it is open and not deleted, and its last comment is yours and has been sent. The agent sees each waiting thread with a kind:

- **`new`:** your first comment.
- **`follow-up`:** you replied after the agent's reply.
- **`answer`:** you answered the agent's question.
- **`reopened`:** you reopened a resolved thread.

A review moves through `draft`, then `submitted`, then `delivered` when `inbox` first returns it, then `replied` when every thread in it has a newer agent reply. You can also discard a draft, which sets `discarded`.

### How a stack is read

- **Read the catalog yourself.** Parse `<git-common-dir>/gh-stack` directly. It is a JSON file with `schemaVersion` 1. If it is missing, read the legacy `worktrees/<id>/gh-stack` files.
- **Never run `gh stack view --json`.** It calls the GitHub API and rewrites the catalog ([view.go L133–L134](https://github.com/github/gh-stack/blob/29a36d3/cmd/view.go#L133)).
- **Refuse newer schemas.** If `schemaVersion` is greater than 1, return `unsupported_catalog`.
- **Trust live refs.** Use `refs/heads/<branch>`, never the catalog's `head`. In a real gh-stack repository checked during design, every recorded head differed from the live branch tip.
- **Pick the base by rule.** Keep the first candidate that is an ancestor of the head: `parent_tip`, then `recorded_base`, then `fork_point`, then `merge_base`. Store which rule won. Any rule other than `parent_tip` shows "Needs restack".
- **Guard the base.** A candidate counts only if it contains the head's merge base with its parent and the head's merge base with the trunk. So a layer never shows commits that its parent or the trunk already has. When every candidate fails this check, the base is the trunk's merge base with the head, with rule `merge_base` and the trunk as the parent ref. Without the guard, the rules gave wrong layers on a real gh-stack repository. A stale recorded base put 66 commits into a layer that has 8. A parent squash-merged into the trunk made the merge-base rule show 33 commits instead of 2.
- **Choose the newer trunk.** For layer 1, compute against both `<trunk>` and `origin/<trunk>`, and use the newer result.
- **Handle plain branches too.** `--branch B` reviews a single branch, with the trunk from `--trunk`, else `origin/HEAD`, else `main`. `--branches a,b,c --trunk T` reviews an explicit stack.
- **Match layers in version 1** by the same branch, then by `renamed_branches` from a `pending_submit` modify file, then by the same PR number. Anything else becomes a new layer. A left-over old layer becomes `merged` if the catalog says so, otherwise `dropped`.
- **Match the stack** by any shared active branch, then by gh-stack `id` or `number`.

**Refuse only during a real operation (fix 9).** Check every worktree that `git worktree list --porcelain` reports, and skip the ones it marks `prunable`.

- **The modify file:** treat `<git-common-dir>/gh-stack-modify-state` as an operation in progress only in its `applying` or `conflict` phase. That is gh-stack's own rule ([state.go L213–L235](https://github.com/github/gh-stack/blob/29a36d3/internal/modify/state.go#L213-L235)).
- **The `pending_submit` phase:** take the snapshot as normal, and read `renamed_branches` to match layers. gh-stack keeps the file in this phase after every finished `gh stack modify` on a submitted stack that touches a PR ([apply.go L658](https://github.com/github/gh-stack/blob/29a36d3/internal/modify/apply.go#L658), [recovery.go L337–L352](https://github.com/github/gh-stack/blob/29a36d3/internal/modify/recovery.go#L337-L352)). It deletes the file only after `gh stack submit` pushes ([submit.go L770–L773](https://github.com/github/gh-stack/blob/29a36d3/cmd/submit.go#L770-L773)).
- **Paused git rebases** (`rebase-merge/` or `rebase-apply/`): refuse only when the rebase touches a branch in the stack. That means the branch in its `head-name` file, or the branch that worktree has checked out, is a stack branch.
- **`gh-stack-rebase-state`:** refuse only when a git rebase from the rule above is actually in progress. Otherwise warn that the file looks stale.

Without these rules, the loop stalls after any `gh stack modify` until someone pushes, and the skill forbids pushing. A leftover rebase in an abandoned worktree would also block every review in the repo.

---

## C. Agent contract: the CLI is the agent's only interface

### The loop

1. **The agent submits.** It commits its work and runs `eyeballs review --note "…"`.
2. **The app snapshots.** It pins each layer, records `r4`, ports open threads and shows the window. The CLI prints at most 6 lines, and the last one says what to do next.
3. **The agent waits.** It follows the `Next:` line: either it ends its turn, or it starts `eyeballs wait` in the background and then ends its turn.
4. **You review.** You comment and press Submit review.
5. **The agent wakes.** The wait exits, a monitor line arrives, or the Stop hook fires. The agent runs `eyeballs inbox`.
6. **The agent fixes.** It fixes the bottom layer first, committing each fix to the branch named in the thread, and restacks with gh-stack.
7. **The agent replies.** It sends every reply in one `eyeballs reply --file -` call, then goes back to step 1.

### Command reference

| Command | What it does | Starts the app |
|---|---|---|
| `eyeballs review [--stack sN \| --branch B \| --branches a,b,c --trunk T] [--note TEXT \| --note-file PATH\|-] [--focus] [--force] [--json]` | The driver submits a new revision and opens the window. `--stack` also takes the name of any branch in the stack. | Yes |
| `eyeballs wait [--stack sN] [--timeout DUR] [--json]` | The driver runs it in the background. It exits when something needs the agent. | No. It waits for the socket. |
| `eyeballs inbox [--stack sN] [--page N] [--peek] [--json]` | The driver prints every thread waiting on the agent. | Yes |
| `eyeballs show tN [--context N] [--json]` | The agent or a subagent prints one thread in full, with code and anchor history. | Yes |
| `eyeballs reply (--file PATH\|- \| --json-file PATH\|-) [--json]` | The agent or a subagent replies to many threads in one call, using `## t41 addressed` blocks. | Yes |
| `eyeballs reply tN addressed\|declined\|question (--body TEXT \| --body-file PATH\|-) [--at PATH:A-B]... [--json]` | The agent or a subagent replies to one thread. | Yes |
| `eyeballs threads [--open\|--all] [--stack sN] [--json]` | The agent prints one line per thread. | No |
| `eyeballs status [--brief] [--json]` | The agent, the skill and hooks get one status line. Always exits 0. | No |
| `eyeballs attach [--stack sN]` | A session takes over as driver. | Yes |
| `eyeballs watch` | For the plugin monitor only. Never exits. | No |
| `eyeballs hook session-start\|stop\|session-end` | For hooks only. Always exits 0. | No |
| `eyeballs open [PATH]` | Brings the window to the front. Without a path it shows the stack you are working on and never adds a stack; with one it opens that repo's stack. | Yes, in front |
| `eyeballs doctor [--strict] [--json]` | You and CI check the install and the store's invariants. It prints the permission line to add. It exits 0 when the app is not running, unless you pass `--strict`, which makes that exit 69 (fix 4). | No |
| `eyeballs --version` | Prints `eyeballs 0.1.0 (42) protocol 1`. | No |

**Rules every command follows:**

- **Durations:** `--timeout` accepts `90s`, `30m` or `2h`. With no timeout, a command waits forever.
- **Agent detection:** the CLI reads `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`. `--agent` and `--session` override them. It reads the start time of `CLAUDE_PID` with `proc_pidinfo` (`pbi_start_tvsec`, SDK `usr/include/sys/proc_info.h`).
- **IDs:** thread IDs are accepted as `t41` or `41`.
- **Which stack:** a command without `--stack` uses a stack the caller's session drives: the one holding the branch checked out in the caller's folder, if any, else the newest. Only when the session drives none does it fall back to the stack holding that branch. An agent working in another worktree, or on a branch the stack does not have, still gets its own stack.
- **Output:** stdout carries exactly one document, either text or JSON. Errors also print one human line on stderr.
- **App not running:** a command that does not start the app exits 69. The exceptions are `wait`, `watch`, `status`, `hook`, `doctor` and `--version`, which follow their own rules above.
- **Driver rule:** `review` and `attach` make the caller the driver. When the driver's session has ended, or its process and start time are no longer alive, the role moves to any session that calls `inbox`, `wait` or `reply` (fix 11). A live driver keeps the role: then `inbox` reports `not_driver` as its `status`, `wait` reports it as its `event`, and both exit 0. The app saves the `reply` with a `not_driver` warning.
- **Reviewer name:** wherever shipped text names the reviewer, the app uses `git config user.name` for that repo. When it is unset, the text says "the reviewer".

### `eyeballs review`, step by step

1. **Find the stack.** If a real operation is in progress, as defined in [How a stack is read](#how-a-stack-is-read), exit 75 with `mid_operation` (fix 9).
2. **Check for unreplied threads.** Look across the whole stack, whichever session read them. If an open thread that `inbox` already showed has no newer agent reply, exit 77 with `unreplied` and list it (fix 11). `--force` skips this check.
3. **Snapshot every layer.** Read all branch tips with one `git for-each-ref`. If a `pending_submit` modify file exists, use its `renamed_branches` to match layers.
4. **Skip unchanged stacks.** If the content hash equals the latest revision's, create no revision. Return `"created": false`, mark the agent's replies ready, and notify the reviewer once.
5. **Create the revision.** Otherwise pin new head SHAs first. Then write the revision rows, port the open threads, and set `fixed_in` on each `addressed` reply since the last revision.
6. **Take the driver role.** If another session was driver, its `wait` connections exit with `rebound`.
7. **Show the window.** It comes to the front without taking keyboard focus, unless the agent passes `--focus`.

What `eyeballs review` prints:

```text
Opened checkout-v2 (s3) r4 in Eyeballs: 3 layers, 14 files, +412 -88.
Threads carried over: 3 current, 1 moved, 1 outdated.
Warning: 3 uncommitted files are not in this revision.
Waiting on Alex: 5 threads. Waiting on you: 0.
Next: run `eyeballs wait` with run_in_background: true, then end your turn.
```

With a monitor connected and the idle wake confirmed in PR 9, the last line reads `Next: end your turn. An "eyeballs:" line will wake you.`

The same result with `--json`:

```json
{"schema":"eyeballs.review/1","ok":true,
 "stack":{"id":"s3","name":"checkout-v2","source":"gh_stack","trunk":"main","repo":"/Users/alex/src/shop"},
 "revision":4,"created":true,
 "layers":[{"position":1,"branch":"models","pr":811,"files":4,"additions":120,"deletions":8,
            "base_rule":"parent_tip","changed_since_last":true}],
 "ported":{"current":3,"moved":1,"whitespace":0,"changed":0,"relocated":0,"outdated":1,"gone":0},
 "warnings":[{"code":"dirty_worktree","message":"3 uncommitted files are not in this revision."}],
 "waiting_on_you":[],"waiting_on_reviewer":5,
 "listening":[],"next":"run_wait_in_background"}
```

- **`listening`** lists what the driver's process has connected: `wait`, `monitor`, both or neither.
- **`next`** is `run_wait_in_background`, `end_turn` or `run_inbox`.

### `eyeballs wait`

- **When it returns:** at once with `not_driver` if a live session other than the caller drives the stack. At once if the stack has a submitted review or a sent comment that `inbox` has not shown yet. Otherwise it blocks until one of these happens:
  - **Submit:** you submit a review
  - **Send now:** you send a comment with Send now
  - **Approve:** you approve the stack
  - **End Review:** you close the stack
  - **Takeover:** another session takes the driver role
  - **Timeout:** the timeout passes
- **Who gets the event:** every live `wait` and `watch` connection of the driver's Claude process, keyed by `CLAUDE_PID` plus its start time (fix 10). A subagent shares its parent's session ID and PID. So a `wait` that a subagent started and the main session's monitor both wake.
- **What it prints:** one line, the same as `watch`. With `--json` it prints `{"schema":"eyeballs.wait/1","ok":true,"event":"review.submitted","stack":"s3","review":7,"threads":5,"verdict":"changes_requested","next":"run_inbox"}`. The other `event` values are `comment.sent`, `review.approved`, `stack.closed`, `rebound`, `not_driver` and `timeout`.
- **Exit code:** always 0.
- **What the agent does next:** after any exit, the agent runs `eyeballs inbox`. A finished background task's notice carries the task ID, the output-file path, the status and the exit code, but not the output. A Claude Code session on 2026-10-16 showed this. So the agent never needs that file.
- **Unattended runs:** in `-p` and other unattended runs, background tasks default to a 30-minute limit. The skill there passes `--timeout 25m` and waits again on `timeout`.

### `eyeballs watch`

- **Line format:** at most 200 characters. For example: `eyeballs: Alex submitted review 7 on checkout-v2 (s3, r4): 5 threads, changes requested. Run: eyeballs inbox`
- **When it prints:** for every event routed to its Claude process, even when a `wait` is connected too (fix 10). `watch` merges events that arrive within 3 s into one line.
- **Never exits:** it reconnects with a backoff from 1 to 30 s, swallows errors, and never starts the app.
- **How it finds its Claude process:**
  1. **Environment:** It uses `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID` if the monitor's environment has them.
  2. **Ancestor PIDs:** Otherwise it sends its ancestor PIDs, and the app matches a registered `CLAUDE_PID`.

  **Assumption:** a plugin monitor's environment is undocumented. Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` into a monitor's `command`, but does not export it ([plugin components](https://code.claude.com/docs/en/plugins/components)). PR 9 checks what the monitor sees.

### `eyeballs inbox`: the text packet

`inbox` returns every thread that waits on the agent, ordered bottom layer first, then by path, then by line (fix 11).

- **Threads shown before are included,** and labelled `shown before`. An interrupted `inbox`, or one a subagent ran, therefore hides nothing. Stop does not fire after a user interrupt ([hooks: Stop](https://code.claude.com/docs/en/hooks#stop)), so this matters.
- **`delivered_at`:** `inbox` sets it on comments it shows for the first time, and sets `review.delivered_to`. It only stops repeat wake-ups and repeat Stop blocks. It never hides a thread.
- **`--peek`** changes nothing.
- **Pages:** at most 20,000 characters. A longer inbox ends with `4 more threads: run eyeballs inbox --page 2.`

~~~text
Eyeballs review 7 · checkout-v2 (s3) · r4 · changes requested
5 threads for you, bottom layer first. 1 was shown before. Reply to all of them in one `eyeballs reply --file -`.

Alex: Close. Mostly naming, plus one real bug in the retry path.

## t41 · new · layer 1 models (PR #811) · Sources/Models/Order.swift:12-14
   12 | struct Order: Codable {
   13 |   var id: String
   14 |   var total: Double
Alex: Use Decimal for money, not Double.

## t42 · new · shown before · layer 2 api-client (PR #812) · Sources/API/Client.swift:40-44
checkout: /Users/alex/src/shop-wt/api-client
   40 |   func get(_ path: String) async throws -> Data {
   41 |     var attempt = 0
   42 |     while attempt < 3 {
   43 |       do { return try await send(path) }
   44 |       catch { attempt += 1 }
Alex: This retries on 4xx too. Only retry 5xx and timeouts.

## t43 · follow-up · layer 2 api-client · Sources/API/Client.swift (file)
You (r3, declined): Keeping one file: Retry is 30 lines and only Client uses it.
Alex: Fine, but give Retry its own type so tests can drive it.

## t44 · answer · layer 3 web-ui (PR #814) · Web/Checkout.tsx:88
You (r3, question): Should the spinner block the whole form or just the button?
Alex: Just the button.

## t45 · new · layer 3 web-ui · Web/Checkout.tsx:120-121 · moved from 98-99 since r3
  120 |   const total = items.reduce((a, b) => a + b.price, 0)
  121 |   return <Total value={total} />
Alex: Recomputed on every keystroke.
~~~

**Packet rules:**

- **Header line:** thread ID, kind, `shown before` when it applies, layer position and branch, PR, `path:start-end`, and the anchor state when it is not `current`.
- **`checkout:` line:** only when the layer's branch is checked out in a different worktree from the agent's working directory.
- **Code:** only the covered lines, at most 12. Longer ranges end with `(… 30 more lines; run eyeballs show t45)`. `changed` and `outdated` anchors add the original lines under `Originally:`.
- **History:** older comments are cut to 300 characters each. The reviewer's newest comment is always shown in full.
- **Other results:**
  - **`approved`:** `Alex approved checkout-v2 r5. No changes needed. Tell Alex. Push or merge only if Alex asks you in the terminal.`
  - **`closed`:** `Alex closed checkout-v2 (s3). Stop.`
  - **`not_driver`:** `Another session now drives checkout-v2 (s3). Stop, or run eyeballs attach.`
  - **`nothing`:** `Nothing waiting on you. Next: run eyeballs wait with run_in_background: true, then end your turn.`

The same packet with `--json`:

```json
{"schema":"eyeballs.inbox/1","ok":true,"status":"threads",
 "stack":{"id":"s3","name":"checkout-v2","repo":"/Users/alex/src/shop","trunk":"main"},
 "revision":4,"reviewer":"Alex",
 "reviews":[{"id":7,"verdict":"changes_requested","body":"Close. Mostly naming…","submitted_at":"2026-10-16T14:02:11Z"}],
 "threads":[{"id":"t42","kind":"new","review":7,"shown_before":true,
   "layer":{"position":2,"branch":"api-client","pr":812,"checkout":"/Users/alex/src/shop-wt/api-client"},
   "subject":"line","side":"head","path":"Sources/API/Client.swift","start":40,"end":44,"commit":"9f2c1ab",
   "anchor":"current","commented_on":4,"code":["  func get(_ path: String) async throws -> Data {","…"],
   "original":null,"history":[],
   "comment":{"id":"c203","body":"This retries on 4xx too. Only retry 5xx and timeouts."}}],
 "more":false,"next_page":null,"next":"reply_then_review"}
```

`status` is one of `threads`, `approved`, `closed`, `not_driver` or `nothing`. `next_page` is an integer when more pages exist.

### `eyeballs reply`

The batch format:

```text
## t41 addressed
Money is Decimal now, and both callers are updated.

## t42 addressed
at: Sources/API/Client.swift:40-58
at: Sources/API/Retry.swift:1-30
Only 5xx and URLError.timedOut retry now. 4xx fails at once.

## t43 declined
Retry is its own type in Retry.swift, but I kept it internal. Tests use @testable import.

## t45 question
Should sum() live in a shared utils module, or stay local to Checkout?
```

- **Block header:** `## t<id> <status>` at column 0. To put a line starting with `## t` inside a body, indent it.
- **`at:` lines:** optional, directly under the header. They name where the fix is when it is not on the commented lines.
- **All or nothing:** an unknown thread or a bad status fails the whole batch with exit 65, and nothing is posted.
- **Sessions that are not the driver:** the app saves their replies, with the warning `not_driver` (fix 11). If the driver is dead, the caller takes the role first.
- **Resolved threads:** a reply to one is still saved, with the warning `thread_resolved`.
- **Visibility:** replies appear in the window at once. From PR 11, a `question` also sends you a notification at once.
- **The `--json-file -` alternative:** `[{"thread":"t42","status":"addressed","body":"…","at":["Sources/API/Client.swift:40-58"]}]`.

What `eyeballs reply` prints:

```text
Sent 4 replies on review 7: 2 addressed, 1 declined, 1 question.
Still waiting on you: t44 (answer). Next: fix t44, reply, then run `eyeballs review --note "…"`.
```

The same with `--json`: `{"schema":"eyeballs.reply/1","ok":true,"replied":[{"thread":"t41","status":"addressed","comment":"c210"}],"waiting_on_you":["t44"],"warnings":[],"next":"reply_remaining"}`. `warnings` can hold `not_driver` and `thread_resolved`.

When nothing waits on the agent, `next` depends on the batch. With an `addressed` reply the agent changed code, so it is `run_review`. With only `declined` and `question` replies nothing changed, so it is `run_wait_in_background`, and the text says so.

### Other commands

- **`eyeballs threads`** prints one line per thread, for example `t42  api-client  Sources/API/Client.swift:40-44  waiting on Alex (you: addressed)`.
- **`eyeballs status --brief`** prints one line, for example `Eyeballs: you drive checkout-v2 (s3) at r4. Review 7: 2 threads still need your reply (t44, t45). Listening: wait.` It may also print `Eyeballs: nothing open for this session.` or `Eyeballs: app not running.`
- **`eyeballs show t42`** prints the whole thread: every comment in full, and the code at the newest revision with 5 lines of context. It also prints the anchor history (`r3 40-44 original → r4 40-44 current`) and the `checkout:` path.

### Errors and exit codes

Every error with `--json` prints `{"schema":"eyeballs.error/1","ok":false,"error":{"code":"mid_operation","message":"A rebase of api-client is paused in /Users/alex/src/shop. Finish it, then run eyeballs review again.","hint":"…","retry_after_s":10}}`.

| Exit | Error codes | What the agent does |
|---|---|---|
| 0 | none: every expected outcome, including timeouts, "nothing waiting" and `not_driver` from `inbox` or `wait` | Act on `status` or `next` |
| 64 | none: usage error ([ArgumentParser Platform.swift](https://github.com/apple/swift-argument-parser/blob/main/Sources/ArgumentParser/Utilities/Platform.swift)) | Fix the command |
| 65 | `not_a_repo`, `no_stack`, `unknown_thread`, `bad_input`, `unsupported_catalog` | Read `message`, and ask the reviewer if it is unclear |
| 69 | `app_unavailable`, `sandbox_blocked` | Tell the reviewer, quoting the line |
| 70 | `internal`, the default for any error with no mapping | Tell the reviewer, quoting the line |
| 75 | `mid_operation` | Finish the rebase or modify, then retry |
| 77 | `unreplied` | Reply first, or pass `--force` |
| 78 | `version_mismatch` | Tell the reviewer to update the app or the plugin |

**Map every exit code (fix 6).** swift-argument-parser exits 1 (`EXIT_FAILURE`) for any error from `run()` that is not an `ExitCode` or a validation error ([Platform.swift L149–L163](https://github.com/apple/swift-argument-parser/blob/main/Sources/ArgumentParser/Utilities/Platform.swift)). So override `static func main()`, or wrap each `run()`, and map every error to this table, with 70 as the default. `hook` and `status` catch everything and exit 0, because a stray error there would show a hook error on every turn. A test injects an unknown error and checks the exit code.

Non-zero exits are kept for real errors, because Claude Code reports exit 1 as a failure.

### Token budgets

| Output | Limit |
|---|---|
| Monitor or wait line | 1 line, 200 characters or fewer |
| Stop hook reason | 300 characters or fewer |
| SessionStart context | 600 characters or fewer |
| `review` output | 6 lines or fewer |
| `reply` output | 3 lines or fewer |
| `inbox` page | 20,000 characters or fewer |
| Code per thread | Covered lines only, 12 or fewer |

Golden tests fail if a fixture packet grows past its budget. **Assumption:** at about 4 characters per token, a five-thread review costs about 1,000 tokens to receive.

### Waking the agent

| Mechanism | Works when | Role |
|---|---|---|
| Background `eyeballs wait` | Any Claude Code session. Unattended runs have a 30-minute default. | The main path. The Claude Code docs say a finished background task wakes an idle session. |
| Plugin monitor running `eyeballs watch` | Interactive Claude Code with the plugin at user scope, after the review skill has run once in the session (fix 12). Not with `-p`, Bedrock, Google Agent Platform or Foundry, not with `DISABLE_TELEMETRY` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` set, and not for project-scope plugins ([plugin components](https://code.claude.com/docs/en/plugins/components), [tools reference](https://code.claude.com/docs/en/tools-reference#monitor-tool)). | Catches events while the agent is busy. Becomes the main path if PR 9 confirms the idle wake. |
| Stop hook | Claude Code | A safety net. It blocks once per reason when a review is undelivered or threads are unreplied. |
| SessionStart context | Claude Code, after startup, resume, clear, compact or fork | Recovery after a restart, `/clear` or compaction |
| Copy prompt, in the app | Always | The fallback when no agent is listening |

How monitor output reaches Claude: each stdout line becomes a notification, and Claude Code batches lines that arrive within 200 ms into one. Claude Code stops a monitor that produces too many events. The [tools reference](https://code.claude.com/docs/en/tools-reference#monitor-tool) says only "You keep working in the same session and Claude interjects when an event arrives". That is why the idle wake is still an assumption.

### Sessions and the driver

- **Registration:** a session's first call creates its `agent_session` row. Later calls update `last_seen`, `pid` and `pid_start`, and clear `ended_at`.
- **`/clear`:** SessionStart arrives with source `clear`, a new session key and the same `CLAUDE_PID`. The app moves the driver role to the new key. Rebinding by PID happens only when the source is `clear`, so an in-process `/resume` of another conversation cannot take the role (fix 11).
- **Compaction:** the session key stays the same, so SessionStart only prints context. This is assumption 5, checked in PR 9.
- **Resume:** the key stays the same and the PID changes. The hook updates the PID and clears `ended_at`, so the session is live again and keeps the driver role.
- **Fork:** a fork never takes the driver role on its own. Its SessionStart context says to run `eyeballs attach`. Agent view's backgrounding also reports source `fork` and starts a new process ([hooks: SessionStart](https://code.claude.com/docs/en/hooks#sessionstart), [agent view](https://code.claude.com/docs/en/agent-view#what-carries-over-when-you-background)). The old process is then gone, so the dead-driver rule hands the role over at the next `inbox`, `wait` or `reply`.
- **Session end:** SessionEnd marks the session ended. The driver role stays with it. A resumed session keeps the role, unless a different session took it first by the dead-driver rule.
- **Subagents:** they get the parent's `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`, and no agent ID. So they act as the driver, and their wake-ups reach the main conversation too ([sub-agents](https://code.claude.com/docs/en/sub-agents#run-subagents-in-foreground-or-background)).

### Claude Code plugin

**Files:**

```text
.claude-plugin/marketplace.json
plugin/.claude-plugin/plugin.json
plugin/skills/review/SKILL.md        -> /eyeballs:review
plugin/monitors/monitors.json
plugin/hooks/hooks.json
plugin/bin/eyeballs
```

`.claude-plugin/marketplace.json`:

```json
{"name":"eyeballs","owner":{"name":"Daniel Cooper"},
 "plugins":[{"name":"eyeballs","source":"./plugin","description":"Review local stacks in Eyeballs and act on the comments."}]}
```

`plugin/.claude-plugin/plugin.json`:

```json
{"name":"eyeballs","displayName":"Eyeballs","version":"0.1.0",
 "description":"Open stacks in the Eyeballs review app and act on the reviewer's comments.",
 "author":{"name":"Daniel Cooper"},
 "homepage":"https://github.com/danielcooper/eyeballs",
 "repository":"https://github.com/danielcooper/eyeballs",
 "license":"GPL-3.0-or-later","keywords":["review","stack","gh-stack"]}
```

- **Version:** CI checks that `version` equals the tag on releases, because a pinned version holds users on it ([manifest reference](https://code.claude.com/docs/en/plugins/manifest-reference)).
- **Install:** run `claude plugin marketplace add danielcooper/eyeballs`, then `claude plugin install eyeballs@eyeballs`.

`plugin/monitors/monitors.json`. Keep exactly these keys, because an unknown key in a monitor entry stops the plugin from loading:

```json
[{"name":"eyeballs",
  "command":"\"${CLAUDE_PLUGIN_ROOT}/bin/eyeballs\" watch",
  "description":"Tells Claude when the reviewer submits an Eyeballs review or answers a question.",
  "when":"on-skill-invoke:review"}]
```

- **The `when` value (fix 12):** the monitor starts the first time the review skill runs, not at session start. The default, `"always"`, would run it in every session in every repo. In [agent view](https://code.claude.com/docs/en/agent-view#the-supervisor-process) a running monitor counts as background work, so in sessions that have nothing to do with Eyeballs:
  - **Backgrounding:** every backgrounding would show the "Background this session?" dialog
  - **Exit:** every exit would show the "Background work is running" dialog
  - **Idle sessions:** the supervisor would never end the session when it sits idle
- **Check the exact value against the docs in PR 9.** The docs' example uses the bare skill directory name, as in `on-skill-invoke:deploy` ([plugin components](https://code.claude.com/docs/en/plugins/components)).

`plugin/hooks/hooks.json`:

```json
{"hooks":{
  "SessionStart":[{"matcher":"startup|resume|clear|compact|fork",
    "hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/bin/eyeballs\" hook session-start","timeout":5}]}],
  "Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/bin/eyeballs\" hook stop","timeout":10}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/bin/eyeballs\" hook session-end","timeout":2}]}]
}}
```

**What each hook does:**

- **`hook stop`:** the CLI forwards the hook's stdin JSON to the app, and the app decides.
  1. **App check.** Exit 0 if the socket does not answer within 1 s.
  2. **Undelivered review or Send now comment.** Block once per review (`undelivered:7`), or once per Send now comment (`undelivered:c215`): `{"decision":"block","reason":"Eyeballs: Alex submitted review 7 (5 threads). Run eyeballs inbox."}`
  3. **Unreplied threads.** Block once per review (`unreplied:7`), and once per Send now comment that has no newer agent reply (`unreplied:c215`): `Eyeballs: t44 and t45 from review 7 have no reply. Reply with eyeballs reply, then run eyeballs review.`
  4. **Record the block.** Write `stop_block` so the same reason never blocks twice. Exit 0 on any error.

  There is no early exit on `stop_hook_active` (fix 12). That flag stays true for the whole continuation after any Stop block, so an early exit would skip step 3 after the agent replies to only some threads. The `stop_block` table already blocks once per reason. Claude Code also caps Stop continuations at 8 in a row, and the count resets on each tool call ([hooks: Stop input](https://code.claude.com/docs/en/hooks#stop-input)). There is also no "a wait is connected" shortcut (fix 10), because that wait may belong to a subagent.
- **`hook session-start`:** rebinds by `CLAUDE_PID` only when the source is `clear`. It prints `hookSpecificOutput.additionalContext` only when the session has state, in 600 characters or fewer. For example: `Eyeballs: you drive checkout-v2 (s3) at r4. t44 and t45 from review 7 have no reply. Run eyeballs inbox. Only Alex resolves threads.`
- **`hook session-end`:** sends one socket write and does not wait for an answer, to fit the 1.5 s SessionEnd budget.

`plugin/bin/eyeballs`:

```sh
#!/bin/sh
for candidate in \
  "${EYEBALLS_CLI:-}" \
  "$HOME/.local/bin/eyeballs" \
  "/Applications/Eyeballs.app/Contents/Helpers/eyeballs" \
  "$HOME/Applications/Eyeballs.app/Contents/Helpers/eyeballs"
do
  [ -n "$candidate" ] && [ -x "$candidate" ] && exec "$candidate" "$@"
done
case "$1" in
  hook) exit 0 ;;
  status) echo "Eyeballs: not installed."; exit 0 ;;
  # A monitor that exits sends Claude a notification, so sleep instead.
  watch) exec tail -f /dev/null ;;
esac
echo "eyeballs: Eyeballs.app isn't installed. Get it from https://github.com/danielcooper/eyeballs/releases" >&2
exit 69
```

`plugin/skills/review/SKILL.md`. It tells the agent to fix the bottom layer first, to restack with the gh-stack skill and to keep thread IDs out of commit messages. It names the reviewer from `git config user.name`.

````markdown
---
name: review
description: Open the current stack or branch in Eyeballs so the reviewer can review it layer by layer, then act on their comments. Use when a stack or branch is committed and ready for review, when the reviewer says "open it in Eyeballs" or "comments are in", or when an "eyeballs:" line or hook message says a review is waiting.
argument-hint: "[--branch NAME | --stack ID]"
allowed-tools: Bash(eyeballs *) Bash(${CLAUDE_PLUGIN_ROOT}/bin/eyeballs *)
---
Eyeballs now: !`"${CLAUDE_PLUGIN_ROOT}/bin/eyeballs" status --brief || true`
Reviewer: !`git config user.name || echo "the reviewer"`

Eyeballs is a review app. You submit revisions and reply to threads. The reviewer named above comments, resolves and approves.

## Submit a revision
1. Commit your work. Eyeballs reviews commits, not uncommitted changes.
2. Run `eyeballs review --note "<what changed, 1 to 5 lines>" $ARGUMENTS`.
3. Do what its last line says:
   - "end your turn": stop now. An "eyeballs:" line will wake you.
   - "run eyeballs wait": run `eyeballs wait` with run_in_background: true, then end your turn.
   - In a -p or other unattended run, use `eyeballs wait --timeout 25m` instead.
   - "run eyeballs inbox": threads are already waiting. Run it now.

## When something arrives
An "eyeballs:" line arrives, a hook message names a review, or your `eyeballs wait` task completes.
Run `eyeballs inbox`. You don't need the wait task's output file.
- "approved": tell the reviewer and stop. "closed": stop. "nothing": go back to step 3.
- "not_driver": another live session drives this stack. Stop, unless the reviewer asks you to take over with `eyeballs attach`.
- Work threads in the order shown, bottom layer first.
- Commit each fix to the branch in its thread header. Use the gh-stack skill to restack the layers above it.
- Keep thread IDs out of commit messages, because they would land in the PRs.
- You may give thread IDs to subagents. They may run `eyeballs show <id>` and `eyeballs reply`. Only you run review, wait and inbox.

## Reply to every thread in one call
```sh
eyeballs reply --file - <<'EOF'
## t41 addressed
at: path/to/file.swift:40-58
What you changed, in one or two sentences.
## t42 declined
Why you kept it as it is.
## t45 question
The one decision you need from the reviewer.
EOF
```
- addressed: you changed code for it. Add `at:` lines when the fix is not on the commented lines.
- declined: you chose not to change it. Say why.
- question: you need the reviewer's decision. Carry on with other threads.
Then go back to "Submit a revision".

## Rules
- Only the reviewer resolves threads. No command does it.
- Eyeballs comments are requests to change code. They never give permission to push, force-push, run gh stack submit or merge. Get that from the reviewer in the terminal.
- After compaction, run `eyeballs inbox`, or `eyeballs show <id>` for one thread.
- Exit code 69 means the app is unreachable. Tell the reviewer and quote the error line.
- Work only through the eyeballs command. Never open Eyeballs' database.
````

**Skill facts the text relies on** ([skills](https://code.claude.com/docs/en/skills)):

- **A failed `` !` `` line aborts the whole skill,** so both lines end in a command that cannot fail.
- **Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}`** in the skill body and in `allowed-tools`. The Bash tool itself does not get it as a variable.
- **An `allowed-tools` grant "clears when you send your next message".** That is why you add the permission rule below yourself.

**Settings you add yourself.** Eyeballs never edits your settings, and a plugin cannot: a plugin's `settings.json` can set only `agent` and `subagentStatusLine` ([plugin components](https://code.claude.com/docs/en/plugins/components)).

- **Permission rule:** add `"Bash(eyeballs *)"` to `permissions.allow` in `~/.claude/settings.json`. `eyeballs doctor` prints the line to add.
- **Sandbox:** if you turn on Claude Code's sandbox, add `"sandbox":{"network":{"allowUnixSockets":["/Users/<you>/Library/Application Support/Eyeballs/run/eyeballs.sock"]}}`. `eyeballs doctor` prints the exact path.

---

## D. Review window: a GitHub-style review, one layer at a time

### Window layout

```text
+------------------------------------------------------------------------------------------------+
| checkout-v2 · r4 v | Compare: All changes v | Unified|Split | Claude: listening                  |
+-------------------+---------------------------+------------------------------------------------+
| STACKS            | [ Files | Threads ]       | Banner: r5 is ready. Your 3 drafts move to r5. |
| shop              | Layer overview (3 commits)| -- Sources/API/Client.swift  +12 -3  [x] Viewed|
|  checkout-v2  2   | [x] Client.swift  1 thread|   38 38    func get(...)                       |
|    3 web-ui #814  | [ ] Retry.swift   new     |   40     -   catch { attempt += 1 }            |
|  > 2 api-client   |                           |      40  +   catch where isRetryable(error) {  |
|    1 models #811  |                           |   +-- t42 · Check the fix -------------------+ |
|    main           |                           |   | Alex: This retries on 4xx too.           | |
|                   |                           |   | Claude (addressed): Only 5xx and timeouts| |
|                   |                           |   | [Reply] [Resolve] [Show fix]             | |
+-------------------+---------------------------+------------------------------------------------+
| 4 pending comments · Summary... · ( ) Comment (o) Request changes ( ) Approve · [Submit review] |
+------------------------------------------------------------------------------------------------+
```

- **One main window.** A `NavigationSplitView` with three columns sits above a review bar.
- **Sidebar:** repos, then stacks, then layers from top to bottom with the trunk last, as in `gh stack view`. Each layer shows its PR number, open thread count and status in words: "Needs restack", "merged" or "empty". Layer 1 is selected by default.
- **Middle column:** switches between Files and Threads.
  - **Files:** Layer overview first, then each file with its counts, thread badge and Viewed box (from PR 11).
  - **Threads:** every thread, filtered by Needs you, Waiting on agent, Outdated or Resolved.
- **Diff pane:** on the right. [How the diff pane works](#how-the-diff-pane-works) gives its rules.
- **The view follows the agent.** When the agent submits a new revision of the stack on screen, the window moves to it, keeps your place, and says "Now showing revision 5". It stays put only while you have unsent text for a new comment on lines, because those line numbers belong to the revision on screen; then a banner offers "Show r5". If branch tips moved without a submit, a "Live changes" pill offers Take snapshot, which creates a `human_start` revision.

### How the diff pane works

The pane is a view-based `NSTableView` inside `NSViewControllerRepresentable`, with one row per display line. The PR 0 spike proved this shape, and these rules follow its lessons ([Diff pane spike results (PR 0)](#diff-pane-spike-results-pr-0)).

- **Rows:** code rows are drawn with CoreText in a custom `NSView`. File headers are floating group rows, so they stay pinned at the top as you scroll. Thread rows are `NSHostingView`s holding a SwiftUI card. The composer inside a thread is an AppKit `NSTextView`.
- **Height estimation is off.** Register `NSTableViewCanEstimateRowHeights` = `NO` as an app default before the table is created. With estimation on, `rect(ofRow: 1000)` was about 14,000 points from the row's true position, so the scroller and every jump would be wrong. With it off, the table asks for every row's height at reload, which costs tens of milliseconds for 50,000 rows.
- **Row heights come from the model,** never from measuring live views.
  - **Plain ASCII code lines:** work out the height by arithmetic, with tabs expanded to tab stops (fix 7).
  - **Every other code line:** measure its width once with `CTLine`, off the main thread, and cache the result by blob. Count wraps with `CTTypesetterSuggestLineBreak` only for lines wider than the column. Tabs, wide East Asian characters and fallback fonts make arithmetic wrong, so a line would wrap inside a one-line row and be clipped (fix 7).
  - **Thread rows:** measure with `NSHostingController(rootView:).sizeThatFits(in: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))` at the real column width. Cache the height by thread ID, content version and width (fix 3). Never use `fittingSize`: with no width set, it measures a wrapped comment as one long line.
- **Width changes recompute heights.** Heights depend on wrapping, so compute them only after the table has its real width. Recompute every row when a live resize ends and on any other width change, such as a sidebar collapse or a switch between split and unified. Keep the top row in place (fix 3).
- **Height changes do not animate.** Wrap `noteHeightOfRows` in an `NSAnimationContext` with a duration of 0. Then restore the top visible row and its offset. A row that grows above the viewport must not move the rows you are reading.
- **Find the top visible row with `rows(in: visibleRect)`,** and take its first row. Never use `row(at:)`, because it returns the floating file header that covers the top of the viewport.
- **Jumps land below the sticky header.** Offset every jump (`n`, `]`, `⌘1`, a thread link) by the header's height, so the target row is not hidden under it.
- **The sticky header takes clicks.** A click in the top strip of the viewport hits the header, not the code row under it.
- **Composer text lives in the model,** keyed by thread ID, never in view state. Reused rows then never show one thread's draft under another (fix 2).
- **Focus stays with the composer.** The table keeps the first-responder row alive off screen. So a composer you scroll away from keeps keyboard focus and keeps receiving your typing. Single-letter shortcuts fire only when the table itself is first responder (fix 2).
- **Expect a warm-up hitch** on the first scroll after launch. Pre-warming a hosting view at launch may remove it. That is not yet tested.
- **Defaults:** unified view first. Split view arrives in PR 13 and falls back to unified below 900 points wide. Files past 400 lines or 20 KB start collapsed ([GitHub limits](https://docs.github.com/en/repositories/creating-and-managing-repositories/repository-limits)). Binary files, submodules, symlinks and mode-only changes get one-line rows.

### What you do

- **Comment on lines.** Click a line number for one line. Drag down the gutter, or Shift-click, for a range on one side of one file. Ranges are stored as `side`, `start_line` and `end_line`, which map to GitHub's `side`, `start_line` and `line` ([REST review comments](https://docs.github.com/en/rest/pulls/comments)).
- **Comment on a file or layer.** Use the button in the file header or in Layer overview.
- **Drafts save themselves.** A composer writes its draft 300 ms after typing stops, on focus change and on quit. Esc closes the composer and keeps the draft. Delete is a soft delete with Undo.
- **Add, send now or submit.** `⌘↩` adds a comment to the pending review. `⌥⌘↩` sends it at once, which suits answering a question. `⇧⌘↩` opens the Submit sheet.
- **Send now is a submit with one comment (fix 13).** It runs Submit steps 2, 3 and 5 below for that one thread:
  1. **Pins first.** If branch tips moved past the revision you are viewing, it creates a `human_start` revision.
  2. **Ports the thread** to the newest revision.
  3. **Sends the event** to every live `wait` and `watch` connection of the driver's Claude process.

  So the agent never gets old line numbers while its branch is at a newer revision.
- **Resolve and reopen** take effect at once, and only you can do either. A resolved thread collapses to "Resolved · t42".
- **Edit after submit.** The old body is kept in `comment_edit`.
- **Copy.** Until PR 15, `⌘C` copies the selected lines without markers or line numbers.

### What Submit review does

1. **Asks for a verdict** in a sheet: Comment, Request changes or Approve, plus a summary.
2. **Pins first.** If branch tips moved past the revision you are viewing, it creates a `human_start` revision.
3. **Ports drafts** to the newest revision. The packet then says "commented on r4".
4. **Commits in one transaction.** It checks the draft is still `draft`, then sets `submitted`, `sent_at` and `revision_id`.
5. **Sends the event** to every live `wait` and `watch` connection of the driver's Claude process (fix 10).
6. **Shows delivery.** The bar shows "Delivered to Claude at 14:03" once `inbox` runs. If no agent is listening, it shows "No agent is listening" and Copy prompt.

**Approve sends a verdict and nothing else.** It never pushes or merges.

### How thread states appear

| Anchor state | Where the thread appears | Label |
|---|---|---|
| `current` | Same lines | none |
| `moved` | New lines | "Moved from line 98 (r3)" |
| `whitespace` | New lines | "Whitespace changed since this comment" |
| `changed` | Narrowed range | "Lines changed since this comment", with a Show original button |
| `relocated` | Where search found it | "Found by content search". In another layer it adds Keep here and Accept move buttons. |
| `outdated` | A card at the top of the file, with the original snippet | "Outdated: the lines this thread was on are gone". When they were deleted, it adds "was near line 45" (fix 14). |
| `gone` | Under "Detached threads" in the sidebar | "Gone: file deleted in r5", or "Gone: layer dropped" |
| `in_diff = 0` | A context row with 3 lines around it | "Not in this layer's diff" |
| `confidence < 0.6` | As its state shows | Adds "Check placement" |

- **Status chips use words.** Each thread's chip names its derived state, such as "Agent asks you", "Check the fix", "Moved from line 98 (r3)" or "Outdated". Colour never carries meaning on its own.
- **Dock badge:** counts threads that need you.
- **Agent status pill:** one of these:
  - **Listening:** "Claude: listening"
  - **Working:** "Claude: working, 3 of 5 replied". The pill keeps one width, so it leaves out the review number.
  - **Not listening:** "Claude: not listening. Copy prompt"

### Keyboard shortcuts

Single-letter shortcuts fire only when the table itself has keyboard focus, never while a composer has it (fix 2).

| Keys | Action |
|---|---|
| `j` / `k` | Next or previous line |
| `⇧J` / `⇧K` | Extend the line selection |
| `n` / `p` | Next or previous open thread |
| `a` | Next thread that needs you |
| `]` / `[` | Next or previous file |
| `⌘1` to `⌘9` | Go to layer 1 to 9 |
| `⇧⌘]` / `⇧⌘[` | Next or previous layer |
| `c` | Comment on the selected lines |
| `r` | Reply in the focused thread |
| `e` | Resolve or reopen the focused thread |
| `v` | Mark the file viewed (PR 11) |
| `s` | Split or unified (PR 13) |
| `u` | All changes or since your last review (PR 11) |
| `x` | Expand context (PR 13) |
| `⌘C` | Copy without markers or line numbers |
| `⌘F`, `⌘G` | Find, find next (PR 15) |
| `⌘↩` / `⌥⌘↩` | In a composer: add to review, or send now |
| `⇧⌘↩` | Submit review |
| `Esc` | Close the composer and keep the draft |

### Menus and notifications

- **Eyeballs menu:** Install Command Line Tool…, and Open at Login ([`SMAppService.mainApp`](https://developer.apple.com/documentation/servicemanagement/smappservice)).
- **File menu:** Open Repository… (`⌘O`).
- **Review menu:** Submit Review, End Review, Take Snapshot, Copy Agent Prompt. End Review archives the stack, and a waiting CLI gets `stack.closed`.
- **Notifications** use `UNUserNotificationCenter`, from PR 11:
  - **Question:** one notification at once per `reply` call that holds a question.
  - **Summary:** one when the agent has replied to every thread in a review, or when a new revision arrives.
  - **Nothing else.**

---

## E. Anchoring and porting: threads follow the code or say they are outdated

### What an anchor stores

Each anchor stores:

- **Position:** the revision, snapshot and layer
- **Range:** the path, side and 1-based line range
- **Blob:** the blob ID, from the `index` line of the `--full-index` diff
- **Text:** the covered lines, plus up to 3 context lines on each side, read from the blob
- **Port record:** the `diff_hunk`, a state, a method, a confidence score and `engine_version`
- **Outdated anchors:** no line range, and `near_line` when the lines were deleted

The `created` anchor is the origin, and its snippet is kept for good. Head-side anchors are the default, so a change of base rule never moves them.

### Porting rules

1. **When it runs:** when a revision is created, when you submit drafts, when you Send now (fix 13), and when you reopen a thread. The live view computes anchors in memory and saves nothing.
2. **Start from the last good anchor.** That is any state except `outdated` and `gone`, and `human` anchors count as good. A thread that went outdated can come back. A `near_line` hint is never a starting point.
3. **A port is a pure function.** Its inputs are the source anchor, the target snapshot and git objects that never change. The index `anchor_port_once` blocks duplicates.
4. **Check every result.** Re-read the target lines from the new blob. If they don't match the claimed state, the result becomes `outdated`.
5. **Never port a resolved thread.** This follows Gerrit ([ListPortedComments L59](https://github.com/GerritCodeReview/gerrit/blob/ecd8df1/java/com/google/gerrit/server/restapi/change/ListPortedComments.java#L59)). A reopened thread ports from its resolution revision.
6. **Base-side anchors port from base blob to base blob,** as Gerrit does ([CommentPorter L294](https://github.com/GerritCodeReview/gerrit/blob/ecd8df1/java/com/google/gerrit/server/restapi/change/CommentPorter.java#L294)).
7. **Ship in two stages.**
   - **PR 7 porter:** if the file is unchanged, the thread stays put. Otherwise it uses Gerrit's shift rule, and if that fails the thread becomes outdated.
   - **PR 10 porter:** adds these steps, in order:
     1. **A whitespace-blind retry**
     2. **Range narrowing**
     3. **A content search** within the file
     4. **A search elsewhere,** in other files and layers
     5. **A confidence score,** and a "Move here" button for you

     It also adds the stricter checks of fix 14.

### Algorithm

```swift
let good: Set<AnchorState> = [.original, .current, .moved, .whitespace, .changed, .relocated]

func portOpenThreads(of stack: Stack, to target: Revision) -> [Anchor] {
  stack.openThreads.compactMap { t in
    let from = t.anchors.last { good.contains($0.state) || $0.method == .human }!
    guard from.revisionID != target.id else { return nil }
    guard let s = target.snapshot(for: t.homeLayer) else {
      return from.fallback(to: target, .gone)                        // layer dropped or merged away
    }
    return port(t, from: from, to: s, in: target)                    // inserted; anchor_port_once blocks repeats
  }
}

func port(_ t: Thread, from a: Anchor, to s: Snapshot, in r: Revision) -> Anchor {
  if t.subject == .layer { return a.carried(to: s, r, path: nil, lines: nil, .current, .sameBlob) }
  // git diff -z --name-status -M60 --no-ext-diff <oldCommit> <newCommit>, cached by commit pair
  guard let path = git.followPath(a.path!, from: a.commit(t.side), to: s.commit(t.side)) else {
    guard let c = searchElsewhere(t, a, s, r).map({ placed($0, against: a) }),
          verify(c, against: a) else { return a.fallback(to: s, r, .gone) }
    return c.refreshed()
  }
  let blob = git.blob(s.commit(t.side), path)                       // git rev-parse <commit>:<path>
  if blob == a.blob || t.subject == .file {
    return a.carried(to: s, r, path: path, lines: a.lines, .current, .sameBlob)
  }
  let hunks = git.diffBlobs(a.blob!, blob, histogram: true, context: 0)   // cached forever by blob pair
  let candidate =
       shift(a.lines!, hunks).map {
         a.carried(to: s, r, path: path, lines: $0, $0 == a.lines ? .current : .moved, .diffShift) }
    ?? shift(a.lines!, git.diffBlobs(a.blob!, blob, histogram: true, context: 0, ignoreAllSpace: true)).map {
         a.carried(to: s, r, path: path, lines: $0, .whitespace, .diffWs) }
    ?? narrow(a.lines!, hunks, newLineCount: git.lineCount(blob)).map {
         a.carried(to: s, r, path: path, lines: $0, .changed, .diffInterior) }
    ?? searchFile(a, in: git.lines(blob)).map {                     // exact, then fuzzy >= 0.75 and >= 0.10 ahead
         placed(a.carried(to: s, r, path: path, lines: $0.lines, .relocated, $0.method, confidence: $0.score), against: a) }
    ?? searchElsewhere(t, a, s, r).map { placed($0, against: a) }   // other files, then other layers' added lines
  guard let c = candidate, verify(c, against: a) else {
    return a.fallback(to: s, r, path: path, .outdated,
                      nearLine: nearLine(a.lines!, hunks))           // shown as "was near line N"; never a port source
  }
  return c.refreshed()                                               // covered_text, context, in_diff, diff_hunk from the new blob
}

// Gerrit's shift rule on -U0 hunks, sorted by oldStart. 1-based, inclusive.
func shift(_ r: ClosedRange<Int>, _ hunks: [Hunk]) -> ClosedRange<Int>? {
  var delta = 0
  for h in hunks {
    if h.oldCount == 0 {                                             // insertion after old line h.oldStart
      if h.oldStart < r.lowerBound { delta += h.newCount; continue }
      if h.oldStart >= r.upperBound { break }
      return nil                                                     // inserted inside the range
    }
    let last = h.oldStart + h.oldCount - 1
    if last < r.lowerBound { delta += h.newCount - h.oldCount; continue }
    if h.oldStart > r.upperBound { break }
    return nil                                                       // the range itself changed
  }
  return (r.lowerBound + delta)...(r.upperBound + delta)
}

// crt-style narrowing: keep surviving ends, extend into replaced lines.
func narrow(_ old: ClosedRange<Int>, _ hunks: [Hunk], newLineCount n: Int) -> ClosedRange<Int>? {
  let map = unchangedLineMap(hunks)                                  // old line -> new line
  let start = map[old.lowerBound] ?? ((map.lastMapped(before: old.lowerBound) ?? 0) + 1)
  let end   = map[old.upperBound] ?? ((map.firstMapped(after: old.upperBound) ?? n + 1) - 1)
  guard start <= end else { return nil }                             // pure deletion: never guess a new home (fix 14)
  return (end - start + 1) <= max(2 * old.count, old.count + 10) ? start...end : nil
}

// Where deleted lines used to sit, for the "was near line N" hint only.
func nearLine(_ old: ClosedRange<Int>, _ hunks: [Hunk]) -> Int? {
  let map = unchangedLineMap(hunks)
  return map.firstMapped(after: old.upperBound) ?? map.lastMapped(before: old.lowerBound)
}

// A thread found by any content search needs one side of its context to match (fix 14).
func placed(_ c: Anchor, against a: Anchor) -> Anchor {
  let contextMatches = git.linesBefore(c, 3) == a.contextBefore || git.linesAfter(c, 3) == a.contextAfter
  return contextMatches ? c : c.withConfidence(min(c.confidence, 0.59))   // below 0.6 shows "Check placement"
}

func verify(_ c: Anchor, against a: Anchor) -> Bool {
  let text = git.lines(c.blob!, c.lines)
  switch c.state {
  case .current, .moved: return text == a.coveredText
  case .whitespace:      return text.removingWhitespace == a.coveredText.removingWhitespace
  case .changed:         return git.linesBefore(c, 3) == a.contextBefore || git.linesAfter(c, 3) == a.contextAfter
  case .relocated:       return similarity(text, a.coveredText) >= c.confidence
  default:               return true
  }
}
```

**Rules outside the code:**

- **Zero-count hunks:** a `-U0` hunk header with a count of 0 points at the line before the change. Fixture tests cover this.
- **Pure deletion (fix 14):** `narrow()` gives up, so only a content search can still place the thread. That covers code that moved, and the context rule below still applies. If no search finds it, the thread is `outdated`, with "was near line N" as a display hint. Before this fix, the range collapsed onto the next surviving line, the context check passed, and the thread followed unrelated code for good.
- **Any content search (fix 14):** `placed()` caps confidence below 0.6 unless the stored context matches on at least one side. This holds for a search in the same file and for one in other files or layers. So a short block such as `} catch {` / `return nil` / `}` found elsewhere shows "Check placement".
- **Trivial text:** covered text with fewer than 3 letters or digits, such as `}`, skips searching and relies on context.
- **Repeated code:** without a clear winner on context and distance, the thread becomes `outdated`.
- **Moving a thread to another layer:** the modify journal's folds do it automatically (PR 12). A move found by search waits for you to accept it.

### Check the fix

**Built now:** a thread in "Check the fix" whose newest agent reply has `at:` lines gets a **Show Fix** button. It unfolds the file and any gap hiding the first `at:` range, selects those lines and scrolls to them. Threads with more than 4 messages also fold their middle messages behind "Show N earlier messages", so a long conversation never buries the code under it.

The rest arrives in PR 11:

1. **Find the two revisions.** `rA` is the revision of the review that holds your comment. `rB` is the first revision after the agent's `addressed` reply. Set `fixed_in = rB`.
2. **Detect "no change".** If the anchor at `rB` is still `current`, the file's `file_patch` is unchanged and the reply has no `at:` lines, show "No change found where the comment was".
3. **Otherwise show the fix.** Show the `rA → rB` interdiff, limited to hunks that touch the anchor or the `at:` ranges.

### Since last review

This arrives in PR 11. For one layer moving from (B0, H0) to (B1, H1), it follows [mergegate's interdiff](https://github.com/damian-kolasinski/mergegate/blob/9ab0a03/crates/git/src/interdiff.rs):

1. **Rebased only:** if `patch_id(B0..H0) == patch_id(B1..H1)`, show "Rebased only, no changes".
2. **Same base:** if `B0 == B1`, diff `H0` against `H1`.
3. **Moved base:** run `git merge-tree --write-tree --name-only -z --merge-base=B0 B1 H0`, then diff that tree against `H1`. Conflicted paths show as "unseparated". This needs Git 2.40 or later. Apple's `/usr/bin/git` on macOS 26.3 is 2.50.1.
4. **Commit labels:** `git range-diff B0..H0 B1..H1` labels each commit in Layer overview.

### Pins

- **Name:** `refs/eyeballs/<install-id>/<head-sha>`. Every base rule picks an ancestor of the head, so pinning the head keeps the base too.
- **Write before record.** List the existing pins under `refs/eyeballs/<install-id>/`. Create the missing ones in one `git -c core.hooksPath=/dev/null update-ref --stdin` transaction. Only then write the rows. The pin sweeper deletes a pin that has no row after 24 hours.
- **Retention:** keep a pin while any of these holds:
  - **Recent revisions:** its SHA is in the last 2 revisions of an active stack
  - **Open threads:** an open thread's origin or last good anchor uses it
  - **Drafts:** a draft review uses it
  - **Resolved threads:** a thread resolved in the last 90 days uses it
  - **Merged stacks:** its stack merged less than 30 days ago

  Delete released pins with `git update-ref -d <ref> <sha>`. Eyeballs never runs `gc` or `prune`. When a pin is gone, the "then" view falls back to the stored snippet and `diff_hunk`.
- **Side effects:** pins show in `git log --all`, and `git push --mirror` would publish them ([git-push](https://git-scm.com/docs/git-push)).

### Tests that prove porting

- **Scenario corpus:** a script builds real repos in temporary folders, one per case:
  - **Moved trunk:** rebase onto a moved trunk
  - **Insert above:** insert lines above the comment
  - **Edit in place:** edit the commented lines
  - **Pure deletion:** pure deletion, which must give `outdated` with a near-line hint
  - **Formatter:** formatter run
  - **Move within file:** function moved within the file
  - **Far move:** function moved to another file or layer
  - **Short block elsewhere:** a short block that also appears in another file, which must show "Check placement"
  - **Rename or delete:** file renamed or deleted
  - **Squash-merged parent:** squash-merged parent, then `--onto`
  - **Branch rename:** `git branch -m`
  - **Modify:** modify rename, fold and reorder
  - **Repeated code:** repeated code
  - **Brace only:** a comment on `}`
  - **Encodings:** CRLF, non-UTF-8 and binary files
  - **Base side:** base-side comment after the parent changed
- **Property test:** 10,000 random edit scripts. A `current` or `moved` anchor's text must equal the source byte for byte. No range may fall outside the file, and nothing may crash.
- **Invariants:** `eyeballs doctor` and every test teardown check these:
  - **Anchors:** every open thread has an anchor on its stack's latest revision
  - **Pins:** every pin row has a ref
  - **Drafts:** every stack has at most one draft

---

## F. Build and release: copy wreckingball, then add targets in stages

### Files to reuse from wreckingball

- **`project.yml`:** the same options, `bundleIdPrefix: coops`, `DEVELOPMENT_TEAM: HGQW7A6TH6`, Hardened Runtime and `GENERATE_INFOPLIST_FILE`.
- **`.github/workflows/build.yml`:** every step kept, with names changed to Eyeballs.
- **`.gitignore`:** with `Eyeballs.xcodeproj/` in place of the Wreckingball project.
- **`LICENSE`:** the GPL-3.0 text. The README says "either version 3 of the License, or (at your option) any later version", as wreckingball's does.
- **`Utilities/Logger.swift`:** the `Log` enum pattern.
- **`Control/Command.swift`:** the URL parsing pattern.
- **`Tools/MakeIcon.swift`:** draw the app icon in code.
- **README:** the same plain style and sections.

### Changes from wreckingball

- **Exact package versions:** GRDB `exactVersion: "7.11.1"`, swift-argument-parser `exactVersion: "1.8.2"`, and swift-tree-sitter 0.10.0 from PR 14. Exact versions keep CI builds repeatable, because `Package.resolved` sits inside the gitignored `.xcodeproj`.
- **Xcode version:** `xcodeVersion: "16.3"`, because GRDB needs Swift tools 6.1. Wreckingball uses `"16.0"`.
- **Settings at project level:** wreckingball puts settings at target level. Here `MARKETING_VERSION` appears once in `project.yml`, at project level, so the CI version step still works.
- **Embedded CLI:** the `eyeballs-cli` `tool` target goes into `Contents/Helpers`, with `codeSign: true`, `SKIP_INSTALL: YES` and `-i coops.eyeballs.cli`.
- **No embedded frameworks:** everything links statically, because an ad hoc signed app with the hardened runtime cannot load a non-platform framework.
- **No entitlements file:** the app uses no sandbox, camera or microphone.
- **The app stays open** after its last window closes, unlike wreckingball. It also offers Open at Login.
- **CI adds steps** in stages. [CI steps, in stages](#ci-steps-in-stages) lists them.
- **CLI install:** the menu item Install Command Line Tool links `~/.local/bin/eyeballs` to the helper.

### Package versions

Each was read from the project's GitHub releases page with `gh api repos/<owner>/<repo>/releases/latest` on 2026-10-16.

| Package | Version | Released | Used |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift/releases) | 7.11.1 | 2026-06-18 | Store, from PR 5. Needs Swift tools 6.1, so Xcode 16.3 or later. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser/releases) | 1.8.2 | 2026-06-04 | CLI |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen/releases) | 2.46.0 | 2026-07-16 | Project generation (Homebrew in CI) |
| [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter/releases) | 0.10.0 | 2026-03-18 | Highlighting, from PR 14 |
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess/releases) | 1.0.2 | 2026-10-16 | Not used: published the day this design was written |
| [MCP swift-sdk](https://github.com/modelcontextprotocol/swift-sdk/releases) | 0.12.1 | 2026-05-07 | Not used: no MCP in version 1 |
| [gh-stack](https://github.com/github/gh-stack/releases) | v0.2.1 | 2026-10-09 | Catalog format target |

### Repository layout

```text
project.yml                    Eyeballs.xcodeproj is generated and gitignored
Eyeballs/                      App: App/, Window/, Sidebar/, DiffPane/, Threads/, Review/, Backend/, Utilities/, Info.plist
Store/                         EyeballsStore: schema, migrations, Migrations.lock, records, backups (from PR 5)
CLI/                           eyeballs tool: one file per command
Packages/EyeballsCore/         Local package, no dependencies: Sources/EyeballsCore, Sources/EyeballsKit, Tests
Packages/EyeballsGrammars/     Vendored tree-sitter grammars, each with its LICENSE and SOURCES.md (from PR 14)
Tests/StoreTests/              Store tests against $EYEBALLS_HOME (from PR 5)
Tests/BackendTests/            The review service against real fixture repos and a temporary store (from PR 8)
Scripts/fake-agent.sh          The agent loop without an agent (from PR 8)
plugin/                        Claude Code plugin (from PR 9)
.claude-plugin/marketplace.json  (from PR 9)
Tools/MakeIcon.swift           Icon drawn in code
docs/design.md                 This design
.github/workflows/build.yml
README.md  LICENSE (GPL-3.0, or any later version)  .gitignore (wreckingball's, with Eyeballs.xcodeproj/)
```

### project.yml for PR 1

PR 1 holds only the app, the CLI and the core package (fix 4). XcodeGen fails validation with `invalidTargetSource` when a target's source folder is missing ([SpecValidation.swift](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/ProjectSpec/SpecValidation.swift)). Git keeps no empty folders, so a `Store/` target before PR 5 would break `xcodegen generate` in CI.

The PR 1 shape is the committed [`project.yml`](../project.yml). Later PRs change that file, so read it there rather than copying it here.

### What PR 5 adds to project.yml

PR 5 adds GRDB, the `EyeballsStore` target and its tests, and the Profile action's home. The app and the tests get GRDB and `EyeballsKit` through the store, as the first bullet below explains. Merge these keys into the PR 1 file.

```yaml
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift.git
    exactVersion: "7.11.1"

targets:
  EyeballsStore:
    type: library.static
    platform: macOS
    sources: [Store]
    dependencies:
      - package: EyeballsCore
        product: EyeballsKit
        link: true
      - package: GRDB
        link: true

  Eyeballs:
    dependencies:
      - target: EyeballsStore
      - package: EyeballsCore
        product: EyeballsCore
      - target: eyeballs-cli
        embed: true
        codeSign: true
        copy:
          destination: wrapper
          subpath: Contents/Helpers

  EyeballsStoreTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/StoreTests]
    dependencies:
      - target: EyeballsStore
      - package: EyeballsCore
        product: EyeballsCore

schemes:
  Eyeballs:
    build:
      targets:
        Eyeballs: all
    test:
      targets:
        - EyeballsStoreTests
        - package: EyeballsCore/EyeballsCoreTests
    profile:
      environmentVariables:
        EYEBALLS_HOME: "${HOME}/Library/Application Support/Eyeballs-Debug"
```

- **`libEyeballsStore.a` carries GRDB and `EyeballsKit`, so the app and the test bundles list neither.** The store lists both with `link: true`. Without it, Xcode never passes on GRDB's SQLite module map, and the store fails to build with "unable to resolve module dependency: 'GRDBSQLite'". Xcode then puts a static library's package products inside its archive. A target that lists GRDB or `EyeballsKit` again links it twice and fails with hundreds of duplicate symbols. Such a target can still `import` both. If the store ever lists the `EyeballsCore` product too, take `EyeballsCore` off the app and the tests as well.
- **The app and `EyeballsStoreTests` list `EyeballsCore` themselves (fix 4).** By default XcodeGen links no package product into a static library (`let link = dependency.link ?? (target.type != .staticLibrary)` in [PBXProjGenerator.swift](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/XcodeGenKit/PBXProjGenerator.swift)), `transitivelyLinkDependencies` defaults to false, and the store does not use `EyeballsCore`.
- **The Profile action uses the Debug home (fix 1).** XcodeGen profiles with the Release config ([ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), "release: profile, archive"). Without this variable, an Instruments run would open the real store and socket. XcodeGen expands `${HOME}` when it generates the project. The instance lock still stops a profiled build and a Debug build running at once.

### What PR 9 adds

PR 9 adds nothing to `project.yml`. It adds the plugin files and the "Check plugin files" CI step.

### Why project.yml looks like this

- **One `MARKETING_VERSION` line.** Wreckingball's CI finds the version with `grep -E '^\s*MARKETING_VERSION:' project.yml` ([wreckingball's build.yml](https://github.com/danielcooper/wreckingball/blob/main/.github/workflows/build.yml)). A second occurrence would break the version name, so the setting lives once, at project level.
- **Static linking only.** Under the hardened runtime, ad hoc code with no Team ID can load only platform libraries ([Apple DTS](https://developer.apple.com/forums/thread/782645)). So nothing is an embedded framework.
- **The CLI goes in `Contents/Helpers`.** `copy` and `codeSign: true` are both needed, because XcodeGen otherwise embeds a tool in Resources with Code Sign On Copy off. With both, XcodeGen makes a custom Copy Files phase with CodeSignOnCopy ([PBXProjGenerator.swift](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/XcodeGenKit/PBXProjGenerator.swift), `processTargetDependency`). Helpers also avoids `eyeballs` colliding with `Eyeballs` on a case-insensitive disk.
- **The identifier survives the copy.** Xcode's re-sign on copy passes `--preserve-metadata=identifier,entitlements,flags` ([swift-build CodeSign.swift](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBCore/SpecImplementations/Tools/CodeSign.swift)). So the CI checks for `Identifier=coops.eyeballs.cli` and `adhoc,runtime` should pass.
- **`-i` and `SKIP_INSTALL`** follow [Apple's steps for embedded helper tools](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app).
- **Separate Debug identity.** The Debug bundle ID and URL scheme stop a Debug build catching Release URLs.

### Packages/EyeballsCore/Package.swift

See the committed [`Packages/EyeballsCore/Package.swift`](../Packages/EyeballsCore/Package.swift). It has no dependencies, and both products are static libraries.

### CI steps, in stages

Keep every step of [wreckingball's build.yml](https://github.com/danielcooper/wreckingball/blob/main/.github/workflows/build.yml), renamed for Eyeballs:

- **Runner:** `macos-26`
- **Xcode:** `setup-xcode latest-stable`
- **XcodeGen:** `brew install xcodegen`, then `xcodegen generate`
- **Version:** the version step
- **Build:** the ad hoc Release build with `CURRENT_PROJECT_VERSION=${{ github.run_number }}`
- **Release:** `ditto`, `upload-artifact` and `gh release create`

Each added step arrives with the PR that makes it pass (fix 4):

| Step | Added in | What it checks |
|---|---|---|
| Test core package | PR 1 | `swift test --package-path Packages/EyeballsCore` |
| Test app | PR 1 | `xcodebuild test` on the scheme's test targets: the core tests from PR 1, the store tests from PR 5 |
| Check the app | PR 1 | Architectures, signatures, the helper's identifier and `adhoc,runtime` flags, and that `eyeballs --version` matches `Info.plist` |
| `doctor` line in Check the app | PR 5 | `eyeballs doctor --json` runs against an empty home and exits 0 with the app not running |
| Check plugin files | PR 9 | The plugin's JSON files parse, monitor keys are known, the wrapper parses, and the plugin version matches a release tag |

PR 1's steps are in the committed [`.github/workflows/build.yml`](../.github/workflows/build.yml).

PR 5 adds this line to the end of "Check the app". Before PR 5, `doctor` does not exist and swift-argument-parser would exit 64.

```yaml
          EYEBALLS_HOME="$RUNNER_TEMP/eyeballs-home" "$cli" doctor --json > /dev/null
```

PR 9 adds this step:

```yaml
      - name: Check plugin files
        run: |
          for f in .claude-plugin/marketplace.json plugin/.claude-plugin/plugin.json \
                   plugin/hooks/hooks.json plugin/monitors/monitors.json; do
            jq -e . "$f" > /dev/null
          done
          jq -e 'all(.[]; (keys - ["name","command","description","when"]) == [])' plugin/monitors/monitors.json
          sh -n plugin/bin/eyeballs
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
            test "$(jq -r .version plugin/.claude-plugin/plugin.json)" = "${GITHUB_REF_NAME#v}"
          fi
```

- **Fixture repos need no git setup.** They pass `-c user.name=Eyeballs -c user.email=eyeballs@example.invalid`.
- **The release zip holds only `Eyeballs.app`.** The plugin installs from the repo's marketplace.

### Installing the CLI and first launch

- **Menu item.** Install Command Line Tool creates `~/.local/bin/eyeballs` as a symlink to `<app>/Contents/Helpers/eyeballs`. Writing to `~/.local/bin` needs no admin prompt, unlike `/usr/local/bin`. `~/.local/bin` is often on PATH ahead of `/usr/local/bin`.
- **Debug builds install a different link (fix 8).** A Debug build creates `~/.local/bin/eyeballs-debug`. Otherwise one click in a Debug build run from Xcode would point every agent session at the Debug socket and store.
- **Repair at launch (fix 8).** The Release app repairs `~/.local/bin/eyeballs` when it points into an `Eyeballs.app` that no longer exists, or into any bundle whose identifier is not `coops.eyeballs`. It never overwrites a file that is not a symlink.
- **README.** Write it in wreckingball's plain style. Cover:
  - **Download:** downloading the app
  - **First launch:** with `xattr -dr com.apple.quarantine /Applications/Eyeballs.app`
  - **CLI:** installing the CLI
  - **Plugin:** installing the plugin
  - **Permission:** adding the `Bash(eyeballs *)` rule
  - **Loop:** the review loop
  - **Licence:** in wreckingball's words: "either version 3 of the License, or (at your option) any later version"

---

## G. Delivery plan: small PRs, one at a time

### How the work is delivered

- **One PR at a time.** Stop after each PR so the reviewer can review it.
- **Ask the reviewer before every push.** PR 1 is the first commit on `main` of `danielcooper/eyeballs`. Every later PR gets its own branch.
- **PR descriptions are one or two plain paragraphs.**
- **Eyeballs reviews itself.** From PR 9 on, you can review Eyeballs' own PRs in Eyeballs.

### The PR table

PRs 0 to 9 are the MVP. "Fix N" points to [Changes after design review](#changes-after-design-review).

| PR | Builds | Verify |
|---|---|---|
| 0 | A throwaway spike of the diff pane, never merged: a 50,000-line diff with 200 thread rows, plus a live composer | Opens in under 1 s. Scrolls without hitches in Instruments. The 4 focus and height checks in fix 2 pass. Decide: the table, or a custom document view. |
| 1 | Skeleton: `project.yml` with the app, the CLI and the core package only; empty window; `Log`; URL stub; `eyeballs --version`; icon; CI; README; LICENSE; `docs/design.md` | CI is green. The helper's version matches `Info.plist`. `codesign -dv` shows `adhoc` and `runtime`. `open eyeballs://` launches the app. |
| 2 | Git and diff core: a `Git` runner, one serial `cat-file --batch` queue, a unified-diff parser, `--raw -z` and `--numstat -z` parsing | Golden tests cover rename, binary, mode change, symlink, submodule, CRLF and non-UTF-8 paths. 100 concurrent blob reads all return the right blob. A fuzz test never crashes. |
| 3 | Stack discovery: the catalog reader, single branch and `--branches`, the 4 base rules, the mid-operation rules in fix 9 | Fixture catalogs pass. A read-only run on a real gh-stack repository finds the same layers and bases as `git merge-base` and `git log`, including the layer that needs a restack. Never run `gh stack view` there, because it rewrites `.git/gh-stack`. |
| 4 | Read-only stack window: sidebar, file list, unified diff pane, pinned headers, collapsing big files, File > Open Repository | Each layer's file counts in a real gh-stack repository match `git diff --numstat <base> <head>`. Record the spike's numbers on real data. |
| 5 | Store and socket: the `EyeballsStore` target with GRDB and its tests; the instance lock; backups; the BSD socket with the UID check; `status` and `doctor`; the exit-code mapping; Install Command Line Tool; a separate Debug store | A second macOS user cannot connect. A second app instance quits. Changing a shipped migration fails a test. `status` with the app closed exits 0. |
| 6 | Revisions, pins, `eyeballs review` and `attach`, layer matching by branch then PR, `eyeballs://stack/N` | `review` twice gives `"created": false`, and an amend gives r2. `git gc --prune=now` keeps the pinned commits. A paused rebase exits 75. Pin tests run in a scratch clone of a real gh-stack repository, never in the original. |
| 7 | Commenting and Submit: gutter selection, autosaved composers, drafts, threads, resolve and reopen, the simple porter | Killing the app while you type loses nothing. A stack never has two drafts. Inserting lines above a comment gives `moved`. |
| 8 | The agent loop: `wait`, `inbox`, `show`, `reply` and `threads`; event routing per fixes 10 and 11; Dock badge; status pill; Copy prompt; Send now, which ports per fix 13 | `Scripts/fake-agent.sh` runs the whole loop against a Debug-only submit and checks every output. Quitting the app during `wait` still delivers after relaunch. |
| 9 | The Claude Code plugin: marketplace, skill, monitor, hooks and wrapper (end of MVP) | `claude plugin validate ./plugin` passes. A manual checklist in a real session shows: an idle session wakes from `wait`; Stop blocks once per reason; `/compact` restores context; the wrapper fails softly if the app is missing. |

PR 0 is done. The table won, with height estimation off, and the spike measured with a `CADisplayLink` self-test rather than Instruments. [Diff pane spike results (PR 0)](#diff-pane-spike-results-pr-0) holds the numbers.

The sections below add the detail each builder needs. They never replace a row of the table.

### PR 0: Diff pane spike (done, never merged)

- **Built:** a synthetic diff of 50,202 rows with 200 thread rows of mixed heights and one live composer, in an `NSTableView`.
- **Result:** launch, warm scrolling and the 4 checks in fix 2 all passed, measured with a `CADisplayLink` self-test rather than Instruments. The first scroll after launch can still hitch, by up to 86 ms (assumption 11). Use the table with height estimation off.

### PR 1: Skeleton and CI

- **Builds:**
  - **`project.yml`** with the app, the CLI and the core package only, in the PR 1 shape in section F
  - **The local package** with one test
  - **An empty window,** the `Log` enum and the URL handler stub
  - **`eyeballs --version`** in `Contents/Helpers`
  - **The icon** from `Tools/MakeIcon.swift`
  - **CI** with the PR 1 steps, README, LICENSE (GPL-3.0, or any later version), `.gitignore` and `docs/design.md`
- **Verify:**
  - **CI:** The build is green, and `xcodegen generate` works on a fresh checkout.
  - **Version:** The helper's version matches `Info.plist`.
  - **Signature:** `codesign -dv` shows `adhoc` and `runtime`.
  - **URL scheme:** `open eyeballs://` launches the app.
  - **Downloaded zip:** The helper runs from a terminal after the README's `xattr` step on a downloaded zip.

### PR 2: Git and diff core

- **Builds:**
  - **The `Git` runner** around `Process`, with the hardened flags in section A
  - **One serial queue** for a long-lived `cat-file --batch` (fix 5)
  - **The byte-level unified-diff parser**
  - **Parsing** of `--raw -z` and `--numstat -z`
- **Verify:**
  - **Golden tests:** Tests on fixture repos cover rename, copy, binary, mode change, symlink, submodule, no newline at the end, CRLF and non-UTF-8 paths.
  - **Concurrent reads:** 100 concurrent reads of different blobs all return the right blob.
  - **Fuzzing:** A random-byte fuzz test never crashes the parser.

### PR 3: Stack discovery

- **Builds:**
  - **The catalog reader:** the common file, the legacy worktree files and the `schemaVersion` refusal
  - **Single-branch and `--branches` stacks**
  - **The 4 base rules** and the newer-trunk choice
  - **The mid-operation rules** (fix 9): modify-file phases and `renamed_branches`, paused rebases that touch a stack branch, prunable worktrees skipped, and a stale `gh-stack-rebase-state` warning
- **Verify:**
  - **Fixture catalogs:** Catalogs shaped like a real gh-stack catalog pass, and the out-of-shape layer reports "needs restack".
  - **Modify phases:** A `pending_submit` modify file allows a snapshot. An `applying` or `conflict` one reports `mid_operation`.
  - **Unrelated rebases:** A paused rebase on a branch outside the stack does not block. A prunable worktree is ignored.
  - **Real repository:** A read-only run on a real gh-stack repository finds the same layers and bases as `git merge-base` and `git log`. Never run `gh stack view` there.

### PR 4: Read-only stack window

- **Builds:**
  - **The main window:** sidebar, file list and the unified diff pane
  - **Pinned file headers,** line wrapping and big-file collapse
  - **File > Open Repository**
  - **The row-height model:** arithmetic for plain ASCII lines and `CTLine` for the rest (fix 7), and thread-row measuring at the real column width (fix 3), ready for PR 7's threads
- **Follow the spike's lessons,** as written in [How the diff pane works](#how-the-diff-pane-works):
  - **Estimation off** before the table exists
  - **The top row** from `rows(in: visibleRect)`, never `row(at:)`
  - **Jumps** offset by the sticky header's height
  - **Every row recomputed** on a width change, with the top row kept
  - **Height changes** with animation off, then the top row restored
  - **Composer text** in the model and the single-letter shortcut guard, ready for PR 7
- **Verify:**
  - **File counts:** Each layer's file counts in a real gh-stack repository match `git diff --numstat <base> <head>`.
  - **Spike numbers:** Record them on real data: launch to first row, hitches while scrolling, a jump to a far row, a layer reload and a 300-point resize.
  - **Wide characters:** A line with tabs, a wide East Asian character or an emoji wraps without clipping.
  - **Long comments:** A test card with a 300-character comment shows every line at every window width.

### PR 5: Store and socket

- **Builds:**
  - **The `EyeballsStore` target,** GRDB and `EyeballsStoreTests`, in the PR 5 shape in section F
  - **Schema 1,** `synchronous=FULL`, backups, `quick_check` and the migration lock
  - **The instance lock** and the Profile action's Debug home (fix 1)
  - **The BSD-socket server** with the UID check
  - **CLI commands:** `status`, `doctor` (exit 0 with the app not running, unless `--strict`) and app launch from the CLI (fix 4)
  - **The wrapper** around `main` that maps every exit code (fix 6)
  - **Install Command Line Tool,** with `eyeballs-debug` for Debug builds and the Release repair rule (fix 8), and Open at Login
  - **The separate Debug store**
  - **The `doctor` line** in CI
- **Verify:**
  - **Other users:** A second macOS user cannot connect.
  - **Second instance:** A second app instance shows `Eyeballs is already running from <path>` and quits.
  - **Migration lock:** Changing a shipped migration fails the lock test. A pre-migration backup appears.
  - **App closed:** `status` with the app closed prints "app not running" and exits 0.
  - **Exit mapping:** An injected unknown error exits 70, while `hook` and `status` still exit 0.
  - **Linking:** The build log shows no duplicate-symbol warnings for GRDB.
  - **Debug link:** A Debug build's link is `eyeballs-debug`. The Release app repairs an `eyeballs` link that points into the Debug bundle.
  - **Profile run:** A Profile run in Instruments leaves the real store untouched. The app logs its home folder at launch, which shows this.

### PR 6: Revisions, pins and `eyeballs review`

- **Builds:**
  - **Snapshots,** `snapshot_file`, the content-hash rule and `human_start` revisions
  - **Pins** and the pin sweeper
  - **`review` and `attach`**
  - **Layer matching** by branch, then by `renamed_branches` from a `pending_submit` modify file (fix 9), then by PR
  - **`eyeballs://stack/N`**
- **Verify:**
  - **Unchanged stack:** Running `review` twice gives `"created": false`. After an amend, it gives r2.
  - **Pins survive gc:** `git for-each-ref refs/eyeballs/` lists the pins, and `git gc --prune=now` keeps the pinned commits.
  - **Orphan pins:** Killing the process between pin and rows leaves an orphan pin, swept after 24 hours on an injected clock.
  - **Refusals:** Outside a repo, `review` exits 65. During a paused rebase of a stack branch, it exits 75.
  - **Modify rename:** After a `gh stack modify` rename, `review` succeeds and the layer keeps its ID.
  - **Scratch clone:** Pin tests run in a scratch clone of a real gh-stack repository, never in the original.

### PR 7: Commenting and Submit

- **Builds:**
  - **Gutter click and drag,** composers with autosave (text in the model, keyed by thread ID), drafts and threads
  - **The review bar** and Submit sheet, resolve and reopen, and `comment_edit`
  - **The PR 7 porter:** same blob, then Gerrit's shift rule, otherwise outdated
- **Verify:**
  - **Crash safety:** Kill the app while typing, and the text is back after relaunch.
  - **Scrolled composer:** Type in a composer, scroll it far away, type again and scroll back. All the text is there, and no shortcut fired.
  - **One draft:** A stack never has two drafts.
  - **Snippet:** A thread's snippet matches `git show <head>:<path> | sed -n '40,44p'`.
  - **Simple port:** A rebase that only inserts lines above a comment gives `moved`.

### PR 8: The agent loop

- **Builds:**
  - **Commands:** `wait`, `inbox`, `show`, `reply` (blocks and `--json`) and `threads`
  - **The driver rule,** with the dead-driver takeover and saved non-driver replies (fix 11)
  - **Delivery state,** where `inbox` returns every waiting thread and labels the ones shown before (fix 11)
  - **Event routing** to every `wait` and `watch` connection of the driver's Claude process (fix 10)
  - **The whole-stack unreplied check** in `review` (fix 11)
  - **The Dock badge,** the status pill and Copy prompt
  - **Send now** as a one-comment submit that ports (fix 13)
  - **A Debug-only `debug.submitReview` operation,** which a script sends with the hidden Debug-only command `eyeballs debug-submit-review`. It comments as you, then submits, through the same steps as the window. A second hidden command, `eyeballs debug-snapshot-window`, draws the window into a PNG.
- **Verify:**
  - **Fake agent:** `Scripts/fake-agent.sh` runs `review`, `debug.submitReview`, `wait`, `inbox`, `reply` and `review`, and checks every output.
  - **Budgets:** Golden packets enforce the token budgets.
  - **Relaunch:** Quitting the app during `wait` and relaunching it still delivers.
  - **Fan-out:** Two `wait` connections and one `watch` connection from one Claude process all get the event.
  - **Interrupted inbox:** After an interrupted `inbox`, the next `inbox` shows the same threads, labelled "shown before".
  - **Non-driver reply:** A `reply` from a session that is not the driver is saved, with the warning `not_driver`.
  - **Dead driver:** When the driver's process is gone, the next session to run `inbox` becomes the driver.
  - **Send now port:** Send now on r4 while r5 exists gives the agent r5 line numbers.
  - **Escapes:** ESC in code comes out escaped.

### PR 9: The Claude Code plugin (end of MVP)

- **Builds:**
  - **The plugin files:** the marketplace, plugin, skill, hooks and `bin/eyeballs`
  - **The monitor** with `"when": "on-skill-invoke:review"` (fix 12). Check the exact value against the docs first.
  - **The Stop hook** with no `stop_hook_active` early exit and no "a wait is connected" shortcut (fixes 10 and 12)
  - **The "Check plugin files" CI step**
- **Verify:** `claude plugin validate ./plugin` passes. Then run a manual checklist in a real session:
  - **Background wait:** An idle session wakes from a background `wait`.
  - **Monitor wake:** An idle session wakes from a monitor line. This is an assumption under test. If it fails, `next` stays `run_wait_in_background`.
  - **Monitor start:** The monitor starts only after `/eyeballs:review` runs. A session that never runs the skill has no Eyeballs monitor, and backgrounding it shows no dialog because of Eyeballs.
  - **Stop hook:** Stop blocks exactly once per reason, including after a partial reply.
  - **Compact and clear:** `/compact` brings back the SessionStart context. `/clear` keeps the driver role.
  - **Other repos:** A session in another repo prints nothing.
  - **Missing app:** The wrapper fails softly with the app uninstalled.
  - **Watch:** `watch` survives the app quitting, and finds its Claude process.

### After the MVP: PRs 10 to 15

Each item is one PR.

- **PR 10: The full porter,** with the scenario corpus and the property test (fix 14). It adds the whitespace retry, narrowing, content search, search elsewhere, the confidence score, Move here, and the stricter checks for deletions and far moves.
  - **Verify:** the scenario corpus passes, and the property test finds zero false positives in 10,000 runs. Deleted lines give `outdated` with a near-line hint. A short block found only in another file, with no matching context, shows "Check placement".
- **PR 11: Review rounds.** "Since last review" diffs, "Rebased only" detection, Viewed marks, "Check the fix" and notifications.
  - **Verify:** a rebase-only round shows "Rebased only". A squash-merged child's interdiff is empty. A Viewed mark survives a rebase. An unchanged `addressed` thread shows "No change found". Notification permission survives an app update, or the README explains the prompt.
- **PR 12: Layer identity through gh-stack modify** (rename, fold, reorder), using `snapshot_commit` and patch-id overlap of 0.5 or more, with folded and dropped layers in the UI. Renames from a `pending_submit` modify file already work from PR 6.
  - **Verify:** scenario tests for modify rename, fold and reorder, for `git branch -m`, and for `sync --prune`.
- **PR 13: Split view,** word-level highlights and context expansion. It uses delta-style pairing at distance 0.6 or less, plus token Myers through `difference(from:)`.
  - **Verify:** golden token diffs, and a visual check at wide and narrow widths.
- **PR 14: Syntax highlighting** with SwiftTreeSitter 0.10.0 and vendored grammars. Take Swift from `alex-pinkus/tree-sitter-swift`'s `with-generated-files` branch at a recorded SHA. The first grammars are in the open questions.
  - **Verify:** golden token runs for Swift, TypeScript and Python. No main-thread work over 16 ms.
- **PR 15: Character selection,** copy, Find and the full keyboard table. Find uses `NSTextFinderClient`.
  - **Verify:** a UI test copies across 3 rows. Find reaches collapsed files.

### Backlog

These wait until there is a reason to build them:

- **Codex support:** only if Codex is used. It was an assumption, not a stated need. If it comes, these notes apply:
  - **Pull only:** Codex pulls. It has no monitors and no `asyncRewake`, and a finished command never wakes the model ([Codex hooks](https://developers.openai.com/codex/hooks.md)).
  - **Stop hook:** A Stop hook (`eyeballs hook stop --agent codex`) injects a pending review once, and never waits for an hour, because you cannot type to Codex while the hook waits.
  - **Session ID:** `CODEX_THREAD_ID` exists only in Codex's source, not its docs, and the hook's `session_id` may not equal it.
  - **MCP timeout:** Codex's MCP tool timeout is a hard `min(server, requested)` with a 60 s default.
- **Pushing threads to GitHub PR reviews:** a pending review through `addPullRequestReviewThread`, only from a snapshot whose head equals the PR head. It adds `github_link` and `github_comment_link`. Re-pushing to a scratch PR must make no duplicates.
- **An `eyeballs mcp` server,** with hand-written JSON-RPC.
- **Plain-git stacks inferred** without gh-stack metadata.
- **Agent annotations and suggestion blocks.**
- **`eyeballs export`.**
- **An `asyncRewake` fallback** for setups without monitors: `eyeballs wait --rewake` in a hook, exiting 2 with the line on stderr.
- **Posting to `CLAUDE_CODE_MESSAGING_SOCKET`.**

### How to verify it end to end

1. **Core tests:** `swift test --package-path Packages/EyeballsCore` runs the diff parser, stack discovery and porting.
2. **App tests:** `xcodegen generate`, then `xcodebuild test -project Eyeballs.xcodeproj -scheme Eyeballs -destination 'platform=macOS'`.
3. **Release build:** the same ad hoc `xcodebuild` as CI, then the checks of `codesign`, the identifier and the version.
4. **Loop without an agent:** `Scripts/fake-agent.sh` runs review, a Debug submit, wait, inbox, reply and review against a fixture repo.
5. **Real stack, read-only:** open a real gh-stack repository and check each layer against `git diff --numstat`. Anything that writes pins runs in a scratch clone of it, with `.git/gh-stack` copied in.
6. **Real Claude Code session:** install the plugin from the local marketplace. Ask an agent to open a stack, then comment, submit, and watch it wake, fix, reply and resubmit. Then run `/compact` and `/clear`, and check that the session recovers.
7. **Dogfood:** review PRs 10 and later of Eyeballs in Eyeballs.

---

## H. Risks, assumptions and open questions

### Risks

- **The diff pane is the hardest part.** Selection, find and thread rows that change height all live in a recycled table.
  - **Mitigation:** the PR 0 spike passed every check with the table, apart from a warm-up hitch on the first scroll. The fallback is still a custom document view, as Xcode uses.
- **Two copies of the app could run.** A profiled build, a second download or an old CLI link would split state and wake-ups.
  - **Mitigation:** the instance lock and the Profile action's Debug home (fix 1).
- **A wake-up might not arrive.** Plugin monitors are experimental. Claude Code stops a monitor after a flood of events, and does not load monitors from project-scope plugins. The Eyeballs monitor also starts only after the skill runs.
  - **Mitigation:** the background `wait` is the main path. Every connection gets each event. Stop and SessionStart catch anything missed.
- **The app might not be running.** Hooks and `watch` never start it, so a review submitted just before you quit waits until the next agent command.
  - **Mitigation:** the app stays open after its last window closes, and Open at Login is offered.
- **A thread can land in the wrong place.**
  - **Mitigation:** the check step, the clear-winner rule, the context rule for far moves, outdated on deletion (fix 14), labels in words and Move here. Tune the 0.75 threshold on real agent diffs.
- **The catalog format can change.**
  - **Mitigation:** refuse `schemaVersion` above 1, and keep catalog fixtures under test.
- **Agents could bypass the CLI.** They run as you and could edit the database with `sqlite3`.
  - **Mitigation:** the skill forbids it. The app is the only process that holds the store open for writing.
- **Pins show up elsewhere.** They appear in `git log --all` and in other git apps, and travel with `git push --mirror`.
  - **Mitigation:** the README documents this, and retention releases pins.
- **Ad hoc signing has costs.** Gatekeeper blocks the first launch, and macOS may ask you for notification permission again after each update.
  - **Mitigation:** README steps, and a check in PR 11.
- **macOS asks about some folders.** Repos in `~/Documents` or `~/Desktop` trigger a files-and-folders prompt for Eyeballs.
  - **Mitigation:** the README explains the prompt.
- **Claude Code's limits apply.** It stops after 8 consecutive Stop continuations, and the session ID changes on `/clear`.
  - **Mitigation:** `stop_block` blocks once per reason, and the driver role follows the PID on `clear`.

### Assumptions

Each assumption names the PR that checks it.

1. **Monitor idle wake:** a plugin monitor's line wakes an idle session. The tools reference says only "Claude interjects when an event arrives". PR 9.
2. **Monitor environment:** a plugin monitor process sees `CLAUDE_CODE_SESSION_ID` or `CLAUDE_PID`. This is undocumented, and PID-ancestry matching is the fallback. PR 9.
3. **Monitor `when` value:** `"on-skill-invoke:review"` starts the monitor the first time the review skill runs. Check the exact value against the docs. PR 9.
4. **Monitors in agent view:** plugin monitors count as monitors for agent view's backgrounding, exit and idle rules, which is why the monitor waits for the skill. PR 9.
5. **Compaction:** compaction keeps the session key, so only `clear` needs the PID rebind. PR 9.
6. **Peer credentials:** `NWListener` does not expose them, so the server uses a BSD socket for `getpeereid`. PR 5.
7. **XcodeGen embedding:** a `tool` target embeds into `Contents/Helpers` with `codeSign: true`. The design checked this against XcodeGen's and swift-build's source, but no build has run it yet. PR 1.
8. **Version reading:** `CREATE_INFOPLIST_SECTION_IN_BINARY` lets the tool read its own version. The fallback is reading the enclosing app's `Info.plist`. PR 1.
9. **Linking:** checked in PR 5. GRDB links once, through `libEyeballsStore.a`, with no duplicate symbols. [What PR 5 adds to project.yml](#what-pr-5-adds-to-projectyml) gives the rule.
10. **Profile home:** XcodeGen expands `${HOME}` at generate time ([ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)), and Xcode passes the Profile action's environment to the profiled app. PR 5.
11. **Warm-up hitch:** pre-warming a hosting view at launch removes the first-scroll hitch. PR 4.
12. **Context expansion:** expanding context from blobs stays correct whatever the `-U` size. This rests on reasoning, and no test checks it yet. PR 13.

### Open questions, each with a default

The defaults hold unless you decide otherwise.

1. **Window focus:** when an agent runs `review`, the window comes to the front without taking keyboard focus. `--focus` overrides that.
2. **Approve:** it never lets the agent push, run `gh stack submit` or merge. Your permission for those stays in the terminal.
3. **Reply statuses:** `addressed`, `declined` and `question`.
4. **Pin retention:** the last 2 revisions, 90 days after a thread is resolved, and 30 days after a stack merges.
5. **Design doc:** it lives in `docs/design.md` in the public repo, because Eyeballs is a personal project.
6. **First grammars, in PR 14:** Swift, TypeScript and TSX, Python, Go, JSON, YAML and Markdown.
7. **Names in shipped text:** the skill and the packets name the human reviewer from `git config user.name`, because the repo is public.
8. **Copy:** line-only copy is acceptable until PR 15.

---

## Diff pane spike results (PR 0)

The spike ran on 2026-10-16 on an Apple silicon Mac with macOS 26.3, Xcode 26.6, Swift 6.3.3 and a 100 Hz display, using a Release build. Its code was thrown away. Section D and PR 4 follow its lessons.

### The decision: a table with height estimation off

Use a view-based `NSTableView`, with row-height estimation turned off: `NSTableViewCanEstimateRowHeights` = `NO`, registered as an app default before the table is created. The fallback, a custom document view, is not needed.

### What the spike built

- **The data:** a synthetic diff of 50,202 rows across about 100 files, with 200 comment threads and one live composer.
- **The rows:** code rows drawn with CoreText in a custom `NSView`. File headers are floating group rows. Thread rows are `NSHostingView`s with a SwiftUI card. The composer is an AppKit `NSTextView`.
- **The heights:** they come from the model. Code rows use arithmetic. Thread rows use `NSHostingController.sizeThatFits(in:)` at the real row width, cached by thread ID, version and width.
- **The composer's text:** it lives in the model, keyed by thread ID.
- **The measurements:** an automated self-test (`--selftest`) measured frame timing with a `CADisplayLink` and ran each check. Instruments was not used.

### The numbers

These are with estimation off, over 3 runs.

| Check | Result |
|---|---|
| Launch to first code row drawn | 321 to 377 ms (target under 1 s). With height estimation on: 165 to 280 ms. |
| Warm scrolling at 4,000 and 15,000 pt/s, 3 s each, 9 runs in all | 2 late frames in total, each 31 ms. About 1.6 ms of hitching per second on average. Apple's "good" line is 5. |
| First scroll after launch | A warm-up hitch in some runs: up to 86 ms once, often none |
| A thread above the viewport grows by 85 pt | The visible rows move 0 pt |
| Type into the composer, scroll it 4,000 pt away, type `e`, scroll back | The draft is "Hello e". The text view stays in the window and stays first responder. No table shortcut fires. |
| Jump to row 40,000 | Lands exactly below the sticky header on the first pass |
| Drag-select across 3 code rows and copy | Copies the exact characters, without line numbers or markers |
| Reload a different layer (20,084 rows) | 0 height mismatches among visible rows |
| Shrink the window by 300 pt | Every row rewraps, with 0 height mismatches, and the top row is kept |

### Lessons for PR 4

1. **Turn height estimation off.** With it on, `rect(ofRow: 1000)` was about 14,000 pt away from the row's true position, so the scroller and any jump by position would be wrong. With it off, the table asks for every row's height at reload (50,000 calls, tens of milliseconds), and geometry is exact.
2. **Never use `row(at:)` for the top visible row.** It returns the floating file header that covers the top of the viewport. Use the first row of `rows(in: visibleRect)`.
3. **Offset jumps by the sticky header's height,** so the target row lands below the header, not under it.
4. **Clicks at the top of the viewport hit the sticky header,** not the code row under it.
5. **Recompute heights when the width changes.** Heights depend on wrapping, so compute them only after the table has its real width. Recompute all rows when a live resize ends, and on any other width change, while keeping the top row in place.
6. **The table keeps the first-responder row alive off screen.** A composer scrolled away keeps keyboard focus and keeps receiving typing. Still guard single-letter shortcuts so they fire only when the table itself is first responder.
7. **Change heights with animation off** (`NSAnimationContext` duration 0 around `noteHeightOfRows`), then restore the top row and its offset.
8. **Expect a warm-up hitch** on the first scroll after launch. Pre-warming a hosting view at launch may remove it. This is not yet tested.

---

## Changes after design review

Two critics tried to break the merged design. These 14 fixes are now in the body, each in the section named.

1. **Instance lock (PR 5):** [Security rules](#security-rules), [Where state lives](#where-state-lives) and [What PR 5 adds to project.yml](#what-pr-5-adds-to-projectyml).
2. **Diff pane spike checks (PR 0):** a composer keeps its text after you scroll it off screen and back. A jump to a thread 40,000 rows down lands at the top. A reload of a different layer gives the right row heights. The spike also tries `NSTableViewCanEstimateRowHeights=NO`. Composer text lives in the model, keyed by thread ID. See [Diff pane spike results (PR 0)](#diff-pane-spike-results-pr-0) and [How the diff pane works](#how-the-diff-pane-works).
3. **Thread row heights at the real width (PR 4):** [How the diff pane works](#how-the-diff-pane-works).
4. **Targets and CI steps in stages, and `doctor --strict` (PRs 1, 5 and 9):** [project.yml for PR 1](#projectyml-for-pr-1), [What PR 5 adds to project.yml](#what-pr-5-adds-to-projectyml), [CI steps, in stages](#ci-steps-in-stages) and [Command reference](#command-reference).
5. **One serial `cat-file` queue (PR 2):** [Security rules](#security-rules) and [PR 2: Git and diff core](#pr-2-git-and-diff-core).
6. **Every exit code mapped (PR 5):** [Errors and exit codes](#errors-and-exit-codes).
7. **Wrapped code rows measured with `CTLine` (PR 4):** [How the diff pane works](#how-the-diff-pane-works).
8. **Debug CLI link and the repair rule (PR 5):** [Where state lives](#where-state-lives) and [Installing the CLI and first launch](#installing-the-cli-and-first-launch).
9. **Refuse only during a real operation (PR 3):** [How a stack is read](#how-a-stack-is-read) and [`eyeballs review`, step by step](#eyeballs-review-step-by-step).
10. **Every wake-up to every connection (PR 8):** [`eyeballs wait`](#eyeballs-wait), [`eyeballs watch`](#eyeballs-watch) and [Claude Code plugin](#claude-code-plugin).
11. **Inbox returns everything waiting, and the driver role moves on (PR 8):** [`eyeballs inbox`: the text packet](#eyeballs-inbox-the-text-packet), [`eyeballs reply`](#eyeballs-reply), [Command reference](#command-reference) and [Sessions and the driver](#sessions-and-the-driver).
12. **Stop hook without the early exit, and a monitor that waits for the skill (PR 9):** [Claude Code plugin](#claude-code-plugin).
13. **Send now ports like a submit (PR 8):** [What you do](#what-you-do) and [Porting rules](#porting-rules).
14. **Stricter porting checks for deletions and far moves (PR 10):** [Algorithm](#algorithm) and [How thread states appear](#how-thread-states-appear).

**Other changes from the approved plan:**

- **Codex** moved to the backlog, with its notes kept there.
- **The licence** is GPL-3.0-or-later, matching wreckingball's README.
- **The delivery plan's PR table** matches the approved plan row for row, with one exception. Rows 3, 4 and 6, and step 5 of How to verify it end to end, say "a real gh-stack repository". The plan names a private local clone there, but this file is public.
- **`wait --rewake` and exit code 2** moved to the backlog with the `asyncRewake` fallback.
- **`inbox --all`** is gone, because `inbox` now always returns every waiting thread.
- **Shipped text** names the reviewer from `git config user.name`.
