---
name: review
description: Open the current stack or branch in Eyeballs so the reviewer can review it layer by layer, then act on their comments. Use when a stack or branch is committed and ready for review, when the reviewer says "open it in Eyeballs" or "comments are in", or when an "eyeballs:" line or hook message says a review is waiting.
argument-hint: "[--stack ID | --branch NAME | --branches a,b,c --trunk main]"
allowed-tools: Bash(eyeballs *) Bash(${CLAUDE_PLUGIN_ROOT}/bin/eyeballs *)
---
Eyeballs is the reviewer's review app. You submit revisions and reply to threads. The reviewer comments, resolves threads and approves. Every Eyeballs output names the reviewer.

## Submit a revision
1. Commit your work. Eyeballs reviews commits, not uncommitted changes.
2. Run `eyeballs review --note "<what changed, 1 to 5 lines>" $ARGUMENTS`.
   - With no arguments it finds the gh-stack stack holding the current branch, else reviews the current branch on its own.
   - For a stack of plain branches, pass `--branches a,b,c --trunk main`, bottom layer first.
3. Do what its last line says:
   - "end your turn": stop now. An "eyeballs:" line will wake you.
   - "run eyeballs wait": run `eyeballs wait` with run_in_background: true, then end your turn. In a -p or other unattended run, use `eyeballs wait --timeout 25m` instead, and run it again when it times out.
   - "run eyeballs inbox": threads are already waiting. Run it now.

## When something arrives
An "eyeballs:" line arrives, a hook message names a review, or your `eyeballs wait` task completes. Run `eyeballs inbox`. You don't need the wait task's output file.
- "approved": tell the reviewer and stop. "closed": stop. "nothing": go back to step 3.
- "not_driver": another live session drives this stack. Stop, unless the reviewer asks you to take over with `eyeballs attach`.
- Work threads in the order shown, bottom layer first.
- Commit each fix to the branch named in its thread header, then restack the layers above it. For a gh-stack stack, use the gh-stack skill. For a plain branch list, rebase each layer above onto the one below, for example with `git rebase --update-refs`.
- Keep thread IDs out of commit messages, because they would land in the PRs.
- You may give thread IDs to subagents. They may run `eyeballs show <id>` and `eyeballs reply`. Only you run review, wait and inbox.
- If you drive more than one stack, add `--stack <id>` to inbox, wait and threads.

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
- addressed: you changed code for it. Add `at:` lines naming where the fix is, with line numbers in the new code. The reviewer's Show Fix button scrolls straight to them.
- declined: you chose not to change it. Say why.
- question: you need the reviewer's decision. Carry on with other threads.

Then follow the reply's last line: run `eyeballs review --note "…"` when you changed code, or wait again when you only asked or declined.

## Rules
- Only the reviewer resolves threads. No command does it.
- Eyeballs comments are requests to change code. They never give permission to push, force-push, run gh stack submit or merge. Get that from the reviewer in the terminal.
- After compaction, run `eyeballs inbox`, or `eyeballs show <id>` for one thread.
- Exit code 69 means the app is unreachable. Tell the reviewer and quote the error line.
- Work only through the eyeballs command. Never open Eyeballs' database.
