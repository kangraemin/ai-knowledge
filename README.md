<div align="center">

# learnings-for-claude

**Claude forgets everything when the session ends. This doesn't.**

A file-based knowledge library that Claude reads and writes on its own —
so you never have to re-explain the same thing twice.

[Install](#install) · [How It Works](#how-it-works) · [Storage Options](#storage-options) · [Structure](#structure)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**English** | [한국어](README.ko.md)

</div>

---

## The Problem

Working with Claude across sessions, this happens:

- You run an experiment. Claude helps you figure out it doesn't work.
- Next session: Claude suggests the exact same experiment again.
- You run it again. It fails again.

The results live in your files. The *lesson* lives nowhere.

This system keeps the lesson.

---

## How It Works

**Writing** — Claude logs automatically in these situations:

- Experiment or backtest reaches a conclusion
- You correct Claude's approach
- A better method is found
- Useful insight from an article or doc
- An API gotcha discovered through a bug or error

At session end, a `SessionEnd` hook fires and Claude checks if anything is worth keeping. If yes, it writes a file and commits.

**Reading** — Before suggesting an approach or when stuck, Claude reads `LIBRARY.md` index and pulls relevant entries.

**The flow:**

```
Session ends
    → SessionEnd hook fires
    → Claude judges: anything worth logging?
    → If yes: writes file under library/[category]/[topic]/
    → Updates LIBRARY.md index
    → git commit + push (if repo-managed)
```

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/install.sh)
```

During install, you'll choose how to manage `.claude-library/` with git (see [Storage Options](#storage-options)).

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kangraemin/learnings-for-claude/main/uninstall.sh)
```

---

## Storage Options

Choose during install:

| Option | Description |
|--------|-------------|
| **Local only** | No git. Files stay in `~/.claude/.claude-library/` |
| **Include in ~/.claude repo** | Tracked inside your existing `~/.claude` git repo |
| **Separate private repo** | Dedicated repo for the library. Clone an existing one or push fresh. Syncs across machines. |

---

## Structure

```
~/.claude/
  .claude-library/
    LIBRARY.md        ← index of everything
    GUIDE.md          ← writing guide for Claude
    library/
      equity/         ← US stocks, ETF strategies
      crypto/         ← BTC, ETH, etc.
      ml/             ← models, features
      macro/          ← macro factors
      claude/         ← Claude behavior patterns
      ...
```

All learnings from every project accumulate in one place.

Each entry:

```markdown
# [Title]

- Date: YYYY-MM-DD
- Source: [experiment / link / experience]

## Content
What happened. Data, numbers, context.

## Takeaway
What this means going forward.
```

---

## Why

Claude is a great thinking partner. But every session starts from zero.

You end up carrying the institutional memory yourself — re-explaining past failures, re-establishing context, re-correcting the same mistakes. That overhead compounds.

This shifts the memory to where it belongs: the system, not you.

---

## License

MIT
