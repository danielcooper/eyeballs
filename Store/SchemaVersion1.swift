extension StoreMigrations {
    /// Schema version 1, exactly as design section B gives it.
    ///
    /// Never edit this text once it has shipped. `Migrations.lock` holds its hash, and a test fails
    /// if it changes. Add a new migration instead.
    static let schemaVersion1 = """
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
        """
}
