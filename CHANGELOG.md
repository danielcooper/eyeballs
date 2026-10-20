# Changelog

This file lists the changes in each release of Eyeballs, newest first.

## 0.2.0 - 2026-10-20

### Added

- **A Commits view.** The middle column has a Commits tab that lists the layer's commits. Pick one to see only that commit's changes. To comment, go back to all changes.

## 0.1.0 - 2026-10-20

The first release.

### Added

- **Stack review, one layer at a time.** Eyeballs reads gh-stack stacks, explicit branch lists and single branches, and shows each layer's diff in a native window.
- **Threads that last.** Comment on a line, a range, a file or a whole layer. Threads follow the code through rebases, or show as outdated with their original code.
- **The agent loop.** The `eyeballs` command lets an agent open a review, wait for your comments, read them, reply and submit a new revision.
- **A Claude Code plugin.** It adds a review skill, a monitor and hooks, so the agent wakes when your comments arrive.
- **Closing stacks.** Close a stack you are done with from the sidebar or the Review menu.
