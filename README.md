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
      "args": ["claude-library-mcp"],
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

## License

MIT
