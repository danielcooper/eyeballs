#!/bin/bash
# Runs the whole agent loop against a Debug build of Eyeballs, with this script as the agent and
# a Debug-only operation as the reviewer. It checks every output and exit code.
#
# Usage: Scripts/fake-agent.sh [path/to/Debug/Eyeballs.app]
#
# It builds a two-branch stack in a temporary repo, starts the app with its own temporary
# EYEBALLS_HOME, and quits the app when it finishes. The app's window appears while it runs.
set -euo pipefail

app="${1:-build/Build/Products/Debug/Eyeballs.app}"
cli="$app/Contents/Helpers/eyeballs"
if [ ! -x "$cli" ]; then
  echo "fake-agent: there is no Debug build at $app. Build the Eyeballs scheme in Debug, or pass the app's path." >&2
  exit 1
fi
app="$(cd "$app" && pwd)"
cli="$app/Contents/Helpers/eyeballs"

# A short folder, because a Unix socket path must stay under 104 bytes.
work="$(mktemp -d /tmp/eb-fa.XXXXXX)"
export EYEBALLS_HOME="$work/home"
repo="$work/repo"
app_pid=""
checks=0

# Claude Code's environment, with this script's own process standing in for Claude.
export CLAUDECODE=1
export CLAUDE_CODE_SESSION_ID="fake-agent-$$"
export CLAUDE_PID=$$
unset CODEX_THREAD_ID

quit_app() {
  if [ -n "$app_pid" ]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
  fi
}

cleanup() {
  quit_app
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "fake-agent: FAILED: $1" >&2
  echo "--- stdout" >&2
  printf '%s\n' "$out" >&2
  echo "--- stderr" >&2
  printf '%s\n' "$err" >&2
  exit 1
}

# run EXPECTED_STATUS COMMAND...: runs a command, keeping its stdout in $out and stderr in $err.
run() {
  local expected=$1
  shift
  set +e
  out="$("$@" 2>"$work/stderr")"
  status=$?
  set -e
  err="$(cat "$work/stderr")"
  checks=$((checks + 1))
  [ "$status" -eq "$expected" ] || fail "$* exited $status, expected $expected"
}

# has TEXT: the last command printed TEXT somewhere on stdout.
has() {
  checks=$((checks + 1))
  printf '%s\n' "$out" | grep -qF -- "$1" || fail "expected stdout to contain: $1"
}

# says_err TEXT: the last command printed TEXT on stderr.
says_err() {
  checks=$((checks + 1))
  printf '%s\n' "$err" | grep -qF -- "$1" || fail "expected stderr to contain: $1"
}

# line N TEXT: line N of the last command's stdout is exactly TEXT.
line() {
  checks=$((checks + 1))
  [ "$(printf '%s\n' "$out" | sed -n "$1p")" = "$2" ] || fail "expected line $1 to be: $2"
}

# last_line TEXT: the last line of stdout is exactly TEXT.
last_line() {
  checks=$((checks + 1))
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "$1" ] || fail "expected the last line to be: $1"
}

git_quiet() {
  git -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@" >/dev/null 2>&1
}

start_app() {
  "$app/Contents/MacOS/Eyeballs" -ApplePersistenceIgnoreState YES >>"$work/app.log" 2>&1 &
  app_pid=$!
  for _ in $(seq 1 100); do
    [ -S "$EYEBALLS_HOME/run/eyeballs.sock" ] && "$cli" status --json 2>/dev/null | grep -q '"app":"running"' && return 0
    sleep 0.1
  done
  out="$(cat "$work/app.log")"
  err=""
  fail "the app did not start listening within 10 s"
}

# wait_for_file_line FILE: waits up to 10 s for a background command to write its line.
wait_for_output() {
  for _ in $(seq 1 100); do
    [ -s "$1" ] && grep -q "exit=" "$1" && return 0
    sleep 0.1
  done
  out="$(cat "$1")"
  err=""
  fail "a background eyeballs wait did not finish within 10 s"
}

# waits_connected: waits until this agent's background wait is connected.
waits_connected() {
  for _ in $(seq 1 100); do
    "$cli" status --json 2>/dev/null | grep -q '"listening":\["wait"' && return 0
    sleep 0.1
  done
  out="$("$cli" status --json)"
  err=""
  fail "the background eyeballs wait never connected"
}

echo "fake-agent: building a two-branch stack in $repo"
mkdir -p "$repo"
cd "$repo"
git_quiet init -b main
git config user.name Alex
git config user.email alex@example.invalid
seq -f "line %g" 1 20 >a.txt
git_quiet add a.txt
git_quiet commit -m "Base"
git_quiet checkout -b a
seq -f "line %g" 1 22 >a.txt
git_quiet commit -am "Add two lines"
git_quiet checkout -b b
echo "hello" >b.txt
git_quiet add b.txt
git_quiet commit -m "Add b"

echo "fake-agent: starting $app"
run 0 "$cli" --version
has "protocol 1"
run 0 "$cli" status --brief
line 1 "Eyeballs: app not running."
start_app
run 0 "$cli" status --brief
line 1 "Eyeballs: nothing open for this session."

echo "fake-agent: the agent submits revision 1"
run 0 "$cli" review --branches a,b --trunk main --note "First revision"
line 1 "Opened b (s1) r1 in Eyeballs: 2 layers, 2 files, +3 -0."
line 2 "Waiting on Alex: 0 threads. Waiting on you: 0."
last_line 'Next: run `eyeballs wait` with run_in_background: true, then end your turn.'
[ "$(printf '%s\n' "$out" | wc -l)" -le 6 ] || fail "review printed more than 6 lines"

run 0 "$cli" review --branches a,b --trunk main --json
has '"schema":"eyeballs.review/1","ok":true'
has '"revision":1,"created":false'
has '"next":"run_wait_in_background"'

run 0 git for-each-ref --format='%(refname)' refs/eyeballs/
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] || fail "expected 2 pins after revision 1"

echo "fake-agent: the agent waits in the background, and the reviewer submits"
("$cli" wait --timeout 30s >"$work/wait1.out" 2>&1; echo "exit=$?" >>"$work/wait1.out") &
waits_connected
run 0 "$cli" status --brief
line 1 "Eyeballs: you drive b (s1) at r1. Nothing waits on you. Listening: wait."
run 0 "$cli" debug-submit-review --path a.txt --line 21 --end-line 22 --body "Why add these two lines?" --summary "Close, one question."
line 1 "Submitted review 1 on b (s1) with t1."
wait_for_output "$work/wait1.out"
out="$(cat "$work/wait1.out")"
err=""
line 1 "eyeballs: Alex submitted review 1 on b (s1, r1): 1 thread, changes requested. Run: eyeballs inbox"
line 2 "exit=0"

echo "fake-agent: the Stop hook blocks once for the undelivered review"
run 0 sh -c "echo '{\"session_id\":\"$CLAUDE_CODE_SESSION_ID\",\"stop_hook_active\":true}' | '$cli' hook stop"
line 1 '{"decision":"block","reason":"Eyeballs: Alex submitted review 1 (1 thread). Run eyeballs inbox."}'
run 0 sh -c "echo '{\"session_id\":\"$CLAUDE_CODE_SESSION_ID\",\"stop_hook_active\":true}' | '$cli' hook stop"
[ -z "$out" ] || fail "the Stop hook blocked twice for one reason"

echo "fake-agent: SessionStart tells a compacted session what waits"
run 0 sh -c "echo '{\"session_id\":\"$CLAUDE_CODE_SESSION_ID\",\"source\":\"compact\"}' | '$cli' hook session-start"
has '"hookEventName":"SessionStart"'
has '"additionalContext":"Eyeballs: you drive b (s1) at r1. Review 1 is waiting. Run eyeballs inbox. Only Alex resolves threads."'

echo "fake-agent: the agent reads the inbox"
run 0 "$cli" inbox
line 1 "Eyeballs review 1 · b (s1) · r1 · changes requested"
line 2 '1 thread for you. Reply to it with `eyeballs reply --file -`.'
has "Alex: Close, one question."
has "## t1 · new · layer 1 a · a.txt:21-22"
has "   21 | line 21"
has "   22 | line 22"
has "Alex: Why add these two lines?"
last_line 'Next: fix the code bottom layer first, reply with `eyeballs reply --file -`, then run `eyeballs review --note "…"`.'

run 0 "$cli" inbox --peek --json
has '"schema":"eyeballs.inbox/1","ok":true,"status":"threads"'
has '"id":"t1","kind":"new","review":1,"shown_before":true'
has '"code":["line 21","line 22"]'

run 0 "$cli" wait --timeout 1s
line 1 "eyeballs: Nothing arrived within 1s. Run: eyeballs inbox"

echo "fake-agent: review refuses while t1 has no reply"
run 77 "$cli" review --branches a,b --trunk main
says_err "t1 has no reply yet, and eyeballs inbox already showed it."
run 77 "$cli" review --branches a,b --trunk main --json
has '"schema":"eyeballs.error/1","ok":false,"error":{"code":"unreplied"'

echo "fake-agent: a batch with an unknown thread sends nothing"
run 65 sh -c "printf '## t1 addressed\nDone.\n\n## t99 declined\nNo.\n' | '$cli' reply --file -"
says_err "t99 is not a thread in Eyeballs, so no reply was sent."
run 0 "$cli" threads
line 1 "t1  a  a.txt:21-22  waiting on you"

echo "fake-agent: the agent replies"
run 0 sh -c "'$cli' reply --file - <<'EOF'
## t1 addressed
at: a.txt:1-2
The two lines are needed. I added a note at the top of the file.
EOF"
line 1 "Sent 1 reply on review 1: 1 addressed."
line 2 'Next: run `eyeballs review --note "…"` so the reviewer sees your fixes.'
run 0 "$cli" threads
line 1 "t1  a  a.txt:21-22  waiting on Alex (you: addressed)"

echo "fake-agent: the agent amends layer a, restacks b and submits revision 2"
git_quiet checkout a
{ echo "# Numbered lines"; echo; seq -f "line %g" 1 22; } >a.txt
git_quiet commit --amend -am "Add two lines"
git_quiet checkout b
git_quiet rebase --onto a HEAD~1 b
run 0 "$cli" review --branches a,b --trunk main --note "Added a note at the top"
line 1 "Opened b (s1) r2 in Eyeballs: 2 layers, 2 files, +5 -0."
line 2 "Threads carried over: 1 moved."
line 3 "Waiting on Alex: 1 thread. Waiting on you: 0."
last_line 'Next: run `eyeballs wait` with run_in_background: true, then end your turn.'

run 0 "$cli" show t1
line 1 "t1 · Check the fix · layer 1 a · a.txt:23-24 · r2 moved"
has ">   23 | line 21"
has "Anchors: r1 21-22 original → r2 23-24 moved"
has "You (r1, addressed): The two lines are needed. I added a note at the top of the file."
has "  at: a.txt:1-2"

run 0 git for-each-ref --format='%(refname)' refs/eyeballs/
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 4 ] || fail "expected 4 pins after revision 2"
run 0 "$cli" status --brief
line 1 "Eyeballs: you drive b (s1) at r2. Nothing waits on you. Listening: nothing."

echo "fake-agent: the reviewer answers with Send now"
run 0 "$cli" debug-submit-review --thread t1 --body "Thanks. Keep the note short." --send-now
has "on t1 now."
run 0 "$cli" wait --timeout 5s
line 1 "eyeballs: Alex sent a comment on t1 in b (s1, r2). Run: eyeballs inbox"
run 0 "$cli" inbox
has "## t1 · follow-up · layer 1 a · a.txt:23-24"
has "You (r1, addressed): The two lines are needed."
has "Alex: Thanks. Keep the note short."

echo "fake-agent: a wait survives the app quitting and starting again"
("$cli" wait --timeout 30s >"$work/wait2.out" 2>&1; echo "exit=$?" >>"$work/wait2.out") &
waits_connected
quit_app
start_app
waits_connected
run 0 "$cli" debug-submit-review --thread t1 --body "Also check the second line." --verdict comment
line 1 "Submitted review 2 on b (s1) with t1."
wait_for_output "$work/wait2.out"
out="$(cat "$work/wait2.out")"
err=""
line 1 "eyeballs: Alex submitted review 2 on b (s1, r2): 1 thread. Run: eyeballs inbox"

run 0 "$cli" doctor --json
has '"schema":"eyeballs.doctor/1"'
has '{"name":"Anchors","status":"passed"'
has '{"name":"Pins","status":"passed"'

run 0 sh -c "echo '{\"session_id\":\"$CLAUDE_CODE_SESSION_ID\"}' | '$cli' hook session-end"
[ -z "$out" ] || fail "the SessionEnd hook printed something"

quit_app
run 0 "$cli" status --brief
line 1 "Eyeballs: app not running."
run 69 "$cli" threads
says_err "Eyeballs is not running."

echo "fake-agent: all $checks checks passed."
