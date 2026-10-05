<div align="center">

# learnings-for-claude

**Claude forgets everything when the session ends. This doesn't.**

A file-based knowledge library that Claude reads and writes on its own —
so you never have to re-explain the same thing twice.

[Install](#install) · [How It Works](#how-it-works) · [MCP Server](#mcp-server) · [Storage Options](#storage-options) · [Notion Sync](#notion-sync-optional) · [Structure](#structure)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/claude-library-mcp)](https://pypi.org/project/claude-library-mcp/)

**English** | [한국어](README.ko.md)

</div>

---

## The Problem

Working with Claude across sessions, this happens:

- You debug an API gotcha. Claude helps you figure out the workaround.
- Next session: Claude hits the exact same gotcha again.
- You explain it again. And again.

The fix is in your code. The *lesson* lives nowhere.

This system keeps the lesson.

---

## How It Works

**Writing** — Claude logs automatically when:

- An experiment or backtest reaches a conclusion
- You correct Claude's approach ("that's not how it works")
- A better method is discovered
- An API/library gotcha is found through debugging
- Useful insight from a doc or article
- A session analysis/comparison produces a reusable conclusion (query file-back)

Before saving, Claude applies a **Prediction Error filter**: "Was this surprising? Would I hit this again?" If the answer is in the docs, it's not worth saving.

A `SessionEnd` hook fires after each session. Claude reviews the conversation, judges if anything is worth keeping, and writes it to the library.

**Reading** — An MCP server (`claude-library-mcp`) makes the library searchable. Before answering technical questions or suggesting approaches, Claude searches the library for relevant past learnings.

**The flow:**

```
Session ends
    → SessionEnd hook fires (or /session-review)
    → Claude reviews: anything worth logging?
    → Classify: type (gotcha/strategy/pattern/decision) + durability (permanent/temporal)
    → Check: any cross-topic synthesis?
    → Write to library/[category]/[subcategory]/[topic]/
    → Update LIBRARY.md index + CHANGELOG.md
    → git commit + push
    → Notion sync (if enabled)

New session starts
    → You ask a question
    → MCP server searches library (index + body)
    → Claude reads relevant entries before responding
```

**Maintaining** — Three skills keep the library healthy:

| Skill | What it does | When to run |
|-------|-------------|-------------|
| `/library-lint` | Fix broken cross-refs, missing index entries, stale temporal items | Weekly or on-demand |
| `/library-evolve` | Suggest structural improvements (split categories, new templates) | Monthly |
| `/session-review` | Extract learnings + file-back + synthesis check | End of session |

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/install.sh)
```

The installer supports English and Korean. During install, you'll choose:
- How to manage `.claude-library/` with git ([Storage Options](#storage-options))
- Whether to enable [Notion sync](#notion-sync-optional)

### Update

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/update.sh)
```

### Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/uninstall.sh)
```

---

## MCP Server

The library is searchable via an MCP server published on PyPI.

The installer configures this automatically in `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "claude-library": {
      "command": "uvx",
      "args": ["--with", "mcp<2", "claude-library-mcp@latest"],
      "env": {
        "LIBRARY_ROOT": "~/claude-library"
      }
    }
  }
}
```

### Search

`library_search(query)` — Searches across topic names, file descriptions, categories, and file bodies. Uses tiered scoring (topic > filename > description > category > body) with AND-bias for multi-word queries and word boundary matching.

### Tools

| Tool | Description |
|------|-------------|
| `library_search(query)` | Search library by keywords |
| `library_read(path)` | Read a specific library file |
| `library_list()` | Show full LIBRARY.md index |

---

## Storage Options

Choose during install:

| Option | Description |
|--------|-------------|
| **Local only** | No git. Files stay in `~/claude-library/` |
| **Include in ~/.claude repo** | Tracked inside your existing `~/.claude` git repo |
| **Separate private repo** | Dedicated repo for the library. Syncs across machines. |

---

## Notion Sync (Optional)

Mirror your library to a Notion database. When enabled, every library entry is automatically synced to Notion after git push.

### Setup

During `install.sh`, you'll be asked:

```
Sync Library to Notion? [y/N]
```

If yes, you'll need:
- **NOTION_TOKEN** — [Create an internal integration](https://www.notion.so/my-integrations) and copy the token
- **Notion page ID** — The page where the DB will be created (last 32 chars of the page URL)

The installer creates an "AI Library" database:

| Column | Type | Description |
|--------|------|-------------|
| Title | title | Entry name |
| Category | select | Top-level (`dev`, `ml`, `finance`) |
| Subcategory | select | Second level (`tooling`, `crypto`, `testing`) |
| Topic | select | Specific subject (`claude-code`, `bb-rsi-longshort`) |
| Tags | multi_select | Related topics |
| Created | date | Entry date |
| Path | rich_text | File path in library |

### Migrate Existing Files

```bash
# Dry run
~/.claude/scripts/notion-library-migrate.sh --dry-run

# Migrate all
~/.claude/scripts/notion-library-migrate.sh

# Specific category only
~/.claude/scripts/notion-library-migrate.sh --category ml
```

---

## Structure

Classification follows `TAXONOMY.md` — organized by domain/technique, not by tool or project name.

```
~/claude-library/
    LIBRARY.md          ← searchable index
    CHANGELOG.md        ← chronological log of all changes
    GUIDE.md            ← writing guide for Claude
    TAXONOMY.md         ← classification rules
    library/
      tooling/          ← claude-code, mcp-patterns, ...
      testing/          ← spring-isolation, ...
      ml/
        classification/ ← gradient-boosting, ...
        time-series/
      finance/
        crypto/         ← bb-rsi-longshort, donchian, ...
        equity/         ← cross-momentum, vol-targeting, ...
      infra/            ← cicd, kaggle-env, ...
      synthesis/        ← cross-topic conclusions
```

Each knowledge file has metadata and uses one of four type-specific templates:

```markdown
# [Title]

- Date: YYYY-MM-DD
- Source: [experiment / debugging / article]
- durability: permanent | temporal
- type: gotcha | strategy | pattern | decision
```

| Type | Sections | Use when |
|------|----------|----------|
| **gotcha** | Symptom → Cause → Fix → Prevention | API quirk, debugging surprise |
| **strategy** | Setup → Results → Conclusion → Next | Experiment or backtest |
| **pattern** | When → How → Tradeoffs | Reusable technique |
| **decision** | Options → Choice → Rationale | Architecture or approach choice |

**Durability** marks whether knowledge expires: `permanent` (hardware facts, math) vs `temporal` (version-dependent, config). Only temporal items get staleness checks during lint.

**Confidence tags** mark individual claims inline: `[verified]`, `[inferred]`, `[TODO]`.

---

## Why

Claude is a great thinking partner. But every session starts from zero.

You end up carrying the institutional memory yourself — re-explaining past failures, re-establishing context, re-correcting the same mistakes.

This shifts the memory from you to the system.

---

### Track an update branch

```bash
bash install.sh --branch feat/pg-multiuser-kb
bash update.sh --branch feat/pg-multiuser-kb
bash "$HOME/.claude/hooks/learnings-update-check.sh" --branch feat/pg-multiuser-kb --check-only
bash "$HOME/.claude/hooks/learnings-update-check.sh" --force
bash update.sh --branch main
```

The branch is stored in `~/.claude/hooks/.learnings-branch`; `LEARNINGS_BRANCH` overrides it for the current run. `--branch main` removes that file. Non-main branches run the MCP server from the same Git branch; main restores PyPI. Settings are backed up to `settings.json.bak`. Automatic checks only notify unless `LEARNINGS_AUTO_UPDATE=1` is set.

Prompt autoinjection is off by default. Install/update removes its old registration and installed file; run with `LIBRARY_AUTOINJECT=1` to opt in. Both existing MCP registrations receive `alwaysLoad: true`, preserving other settings.

`library-trigger.sh` is installed by default only for the `maintainer` profile (set `LIBRARY_TRIGGER=1` to enable it for `user`, `0` to disable). It searches on Bash errors (including `PostToolUseFailure`), `dev-bounce`/`bouncer start`, and checks new library Markdown files for symmetric duplicate similarity. Hooks use a 5-second timeout, fail quietly, deduplicate errors per session, and record `source=trigger:error|start|write` in `.activity`. Uninstall removes the hooks. CLI resolution: `LIBRARY_KB_CMD`, installed `claude-library-kb`, then the saved uvx package spec.

Official references: [alwaysLoad](https://code.claude.com/docs/en/mcp#exempt-a-server-from-deferral), [PostToolUse](https://code.claude.com/docs/en/hooks#posttooluse), [PostToolUseFailure](https://code.claude.com/docs/en/hooks#posttoolusefailure). Bash structured output documents `stdout`, `stderr`, `interrupted`, and `isImage`; exit-code fields are checked when present. Failure events use the top-level `error`. Both events support `additionalContext`.

## License

MIT

User-scope MCP servers are stored in `~/.claude.json` ([official documentation](https://code.claude.com/docs/en/mcp#user-scope)). Branch switches update existing `claude-library` registrations in both that file and `~/.claude/settings.json`, preserving other servers, `type`, `env`, and project data. Each changed file gets a `.bak`; JSON is validated before atomic replacement. Invalid JSON is left untouched. If neither file has a registration, the existing settings.json registration behavior is retained.

Rules installed in `~/.claude/CLAUDE.md` are enclosed by `<!-- learnings-for-claude:rules start -->` and `<!-- learnings-for-claude:rules end -->`. The table of contents stays outside this managed block. Updates replace only the managed block and save a `.bak`. Legacy files without markers are preserved; the new template is written to `CLAUDE.md.library-rules.new` for manual merging. Keep your table of contents and custom rules outside the markers when adopting the new template. Incomplete, reversed, or duplicate markers produce a warning without changing the file. Uninstall removes the managed block while preserving the table of contents; legacy removal remains supported.

PreCompact preserves incremental user/assistant transcript excerpts locally; the next Stop requests the existing background session review before the usual 20-response throttle. It does not block compaction. Pending excerpts remain local until that Stop; review excerpts are deleted by the reviewer. Install/update add `.activity/search-*.jsonl` to the library `.gitignore` without duplicates. Search logs contain raw prompts only in full mode; aggregate is the default. Already tracked files are left untouched.

[Official PreCompact contract](https://code.claude.com/docs/en/hooks#precompact): common input fields plus `trigger` (`manual`/`auto`) and `custom_instructions`. Exit 2 or `decision: block` can block compaction; `systemMessage` and `continue` are discarded, and `additionalContext` injection is not supported. Hence the deferred Stop review.

### Policy changelog checks

`policy-changelog-check.sh` snapshots policy text, SHA-256 hashes and changelog counts at SessionStart in `~/.claude/hooks/.policy-snapshots/<session_id>.json`, then checks changes at Stop. Policies include `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, and `~/claude-library/{GUIDE.md,TAXONOMY.md,decisions/**/*.md}` (including DECISIONS-GUIDE.md, excluding index.md and changelog sidecars). Ordinary policies append entries under their final `## 변경 이력` section. Injected policies use OKF `type: Changelog` sidecars under `decisions/_global/changelog/`: `claude-md.md` or `rules-X.md`.

```text
- YYYY-MM-DD · codex · what changed · 이유: why · 근거: session:<id or date/topic>
```

Actors are `human:kangraemin`, `claude-code/<model>`, `codex`, or `process:<script>`. Evidence is `commit:SHA`, `session:...`, or a document path. Use `이유: 사후 기록 — 이유 미확인` when the reason is unverified. Entries are append-only, newest last. Only changed lines within CLAUDE.md's `### 목차` section (up to the next heading or marker) are exempt. CATALOG.md is not a policy.

Missing entries block twice, then produce warnings from the third consecutive check. Adding history resets the counter; `stop_hook_active: true` does not bypass checks. Set `POLICY_CHANGELOG_ENFORCE=0` to disable. A missing snapshot is a no-op, and snapshots older than seven days are removed. update.sh appends `process:update.sh` entries only for actual managed-block, GUIDE or TAXONOMY changes, preserving previous history and offering user-edited documents as `.new` files.

[Official hook contract](https://code.claude.com/docs/en/hooks): stdin JSON supplies `session_id` and `hook_event_name`; SessionStart adds `source`, and Stop adds `stop_hook_active`. Blocking returns exit 0 with `{"decision":"block","reason":"..."}`; warnings use `systemMessage` without a decision. The separate `library-usage-log.sh` Stop hook runs with `async: true` and a 30-second timeout. Install/update deduplicate registrations; uninstall removes both hooks and the policy runtime.

### User profiles

`bash install.sh --profile user` is the default. Switch with `update.sh --profile user|maintainer`. The choice is stored in `~/.claude/hooks/.learnings-profile`; selecting `user` removes that file. `LEARNINGS_PROFILE` overrides the option and stored choice for the current invocation.

- `user`: defaults to `aggregate` usage logging. Prompts and search queries are replaced with the first 16 SHA-256 characters and their length. The policy changelog check hook is not installed or registered; updates remove existing registrations.
- `maintainer`: defaults to `full` logging of original text and installs/registers the policy changelog check hook.

Override logging at runtime with `LIBRARY_USAGE_LOG=off|aggregate|full`. The installer writes the default to `settings.json` under `env.LIBRARY_USAGE_LOG` and tracks its last managed value in a separate marker. User edits are preserved (setting the same value as the managed value is indistinguishable). `off` disables search and turn logging. Aggregate reports show only hashes and lengths for missed turns. Each human prompt UUID is logged once per session; subsequent Stop calls skip it.
