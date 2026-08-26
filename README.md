# mktux Harness

> 🇧🇷 [Documentação em português](README.pt-BR.md)

A plugin for **Claude Code** and **Codex CLI** that takes a project from idea to
running code in a structured way: formal specification, phased planning, and
autonomous execution with mechanical validation — while keeping a human in control
at every decision point.

One repository, two engines, zero files copied into your projects.

---

## Table of contents

- [The problem](#the-problem)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Getting started: a real example, from zero to commit](#getting-started-a-real-example-from-zero-to-commit)
- [The pipeline in detail](#the-pipeline-in-detail)
- [ralph in detail](#ralph-in-detail)
- [Hooks and telemetry](#hooks-and-telemetry)
- [What your project needs](#what-your-project-needs)
- [Command reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [What's in the box](#whats-in-the-box)
- [Credits](#credits)

---

## The problem

You hand a large feature to an agent. It starts well, and halfway through it
rewrites a screen that already worked, invents a migration nobody asked for, or
declares "implemented" something that does not exist. You find out three days
later.

The cause is not the model. It is that **a whole feature does not fit in one
session**, and a long session loses track of what must not be touched.

The mktux Harness attacks that with two ideas:

1. **Specification before code.** Four versioned artifacts that record decisions —
   including the negative ones, what must *not* change. Each stamps which version
   of its input it was born from, so you know when one goes stale.

2. **One cold session per phase, and four mechanical gates.** `ralph` splits the
   plan into phases, runs each in a fresh isolated session, and only considers a
   phase done when it clears four checks — none of which is "the agent said it
   finished".

---

## How it works

```
  feature-brief.md          you write this by hand, in your own words
        │                   ← the "what must NOT change" field matters most
        ▼
  /mktux:plan <slug>        router: reports state, advances ONE step
        │
        ├──▶ 1. feature-description.md    scope, rules, what is reused
        ├──▶ 2. user-stories.md           testable criteria, US-N.N ids
        ├──▶ 3. database-schema.md        DBML, or "this feature has no migration"
        └──▶ 4. project-phases.md         the plan ralph executes
        │
        ▼
  ralph docs/features/<slug>/project-phases.md
        │
        ├── Phase 1 ─▶ cold session ─▶ gate 0 ─ 1 ─ 2 ─ 3 ─▶ commit
        ├── Phase 2 ─▶ cold session ─▶ gate 0 ─ 1 ─ 2 ─ 3 ─▶ commit
        └── Phase N ─▶ ...
        │
        ▼
  /mktux:review-phases N    conventions + security audit of that commit
```

Every downward arrow is your decision. The harness never skips two steps at once,
and never starts writing code without a plan you have read.

### The four gates

A phase becomes a commit only when it clears all of them. **None of them is the
agent's exit code.**

| Gate | What it checks | Fails the phase? |
|---|---|---|
| **0** | the engine actually finished, no protocol error | yes |
| **1** | did the session write code? A **signal**, not a verdict — a phase already correctly implemented writes nothing | no |
| **2** | the project's test suite, run **by ralph**, outside the agent's session | yes |
| **3** | an independent read-only verifier that judges **task by task** | yes |

Gate 3 is what catches the lie. It runs in a separate session, on a cheap model,
with access to `Read`, `Glob` and `Grep` only — **no Bash, no shell, no git**. For
each task in the plan it emits exactly one line:

```
TASK 1: DONE
TASK 2: INCOMPLETE — CsvDocument has no render() method
TASK 3: NOT-CODE — needs a human to run `sail npm run build`
```

`INCOMPLETE` fails the phase and triggers a fix cycle. `NOT-CODE` does not fail —
it becomes a manual pending item in the report.

---

## Installation

Three steps, all once per machine.

### 1. Claude Code

```bash
# in the Claude Code prompt, not the terminal
/plugin marketplace add markintux/mktux-harness
/plugin install mktux@mktux-harness
```

Confirm:

```
/plugin
```

`mktux` should be listed as *installed, enabled*. Commands live under the
`/mktux:` namespace — `/mktux:plan`, `/mktux:ralph`, `/mktux:review-phases`.

### 2. Codex CLI

```bash
# in the terminal
codex plugin marketplace add markintux/mktux-harness
codex plugin add mktux@mktux-harness
```

Confirm:

```bash
codex plugin list
```

Codex has no plugin slash commands. There the harness surfaces as **skills** — ask
in natural language ("generate the phase plan for feature X") and the matching
skill loads.

### 3. `ralph` on your PATH

Neither Claude Code nor Codex exposes a plugin binary on the PATH. The harness
generates a wrapper that resolves the plugin path at run time — so
`plugin update` updates `ralph` along with it, with nothing to re-run.

```bash
# Claude Code (inside a session, the variable is already set)
bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-setup.sh"

# Codex
bash "$PLUGIN_ROOT/scripts/mktux-setup.sh"
```

Not sure where the plugin landed? Find it:

```bash
ls -d ~/.claude/plugins/*/mktux*/scripts 2>/dev/null
ls -d ~/.codex/plugins/cache/*/mktux*/*/scripts 2>/dev/null
```

Expected output:

```
mktux-harness — instalando comandos:
  instalado: /Users/you/.local/bin/ralph
  instalado: /Users/you/.local/bin/ralph-watch

PATH ok. Teste com: ralph --help
```

If it warns that `~/.local/bin` is not on your PATH, add to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal and confirm:

```bash
ralph --help
```

### Engine prerequisites

```bash
# Codex (ralph's default engine)
npm install -g @openai/codex
export OPENAI_API_KEY=...

# Claude
npm install -g @anthropic-ai/claude-code
export ANTHROPIC_API_KEY=...
```

### Developing the harness itself

To point `ralph` at your own clone instead of the installed plugin:

```bash
export MKTUX_HARNESS_ROOT=~/Documents/Code/ai/mktux-harness/plugins/mktux-harness
```

---

## Getting started: a real example, from zero to commit

Let's build a real feature: **export the customer list as CSV**, in a multi-tenant
Laravel SaaS, with the export gated to the Business plan.

### Step 0 — the brief

No skill writes this file. You do, in your own words.

```bash
mkdir -p docs/features/customer-export
```

Ask the harness for the template:

```
/mktux:plan customer-export
```

Since the brief does not exist, the router copies the template and stops. Open
`docs/features/customer-export/feature-brief.md` and fill it in:

```markdown
# Feature Brief — Customer export

## What is this feature?

A button on the customer list that downloads a CSV of that tenant's customers,
respecting the filters already applied on screen.

## Why are we building it?

The owner sends the list to their accountant every month and copies it off the
screen by hand today.

## What MUST be in this feature?

- An "Export CSV" button on the customer list
- The CSV respects the search and period filters already applied on screen
- Columns: name, email, phone, signup date, total spent

## What is NOT in this feature (for now)?

- Excel/xlsx export
- Scheduled export by email

## What must NOT change behavior?

- The customer list itself: pagination, search and ordering stay identical
- The "total spent" calculation — it already exists and the dashboard uses it

## Business rules you already know?

- Only the Business plan exports. Starter and Pro see a disabled button with an
  upgrade hint.
- The national ID number never leaves in the file.

## Who uses this feature?

- [x] admin (owner)
- [ ] staff

## Does it touch personal data?

- [x] Yes — name, email, phone
- Does the data leave the system in a file? yes
```

> The **"What must NOT change behavior"** section does the heaviest lifting. It
> becomes the `Do not touch` block the harness repeats inside every phase — the
> thing that stops a blind session from rewriting a list that already works.

### Step 1 — the feature description

```
/mktux:plan customer-export
```

The router now reports state and advances one step:

```
| Artifact                 | State                     |
|--------------------------|---------------------------|
| feature-brief.md         | present (manual)          |
| feature-description.md   | absent                    |
| user-stories.md          | absent                    |
| database-schema.md       | absent                    |
| project-phases.md        | absent                    |

Invoking plan-feature-description: first absent artifact in the chain.
```

The skill reads the brief, **inspects the codebase** (models, routes, policies,
the existing plan config) and writes
`docs/features/customer-export/feature-description.md` with numbered
`Business Rules`, `What exists and is reused`, `Data & Format Decisions`
(encoding, separator, filename) and `Out of Scope`.

If the brief is ambiguous about something that changes the design, the skill
**asks** via AskUserQuestion before writing. It does not resolve a real fork with
a guess.

Read the result. This is the cheapest moment to correct course.

### Step 2 — the user stories

```
/mktux:plan customer-export
```

The router sees the description is ready and advances to `plan-user-stories`. Out
comes `user-stories.md` with stable ids:

```markdown
**US-1.1** — As an owner on a **Business** plan, I want to download the customer
list filtered exactly as I see it on screen, so I can hand it to my accountant.

- Given I am on `/customers?search=maria&from=2026-01-01`
- When I click "Export CSV"
- Then a file named `customers-2026-01-01-to-2026-08-26.csv` downloads
- And it contains the same rows, in the same order, the table renders
- And no column contains a national ID number

**US-3.1** — As an owner on a **Starter** plan, I want to understand why I cannot
export, so I know what to upgrade to.

- Given I am on `/customers` on a Starter plan
- When I look at the export button
- Then it is disabled with an upgrade tooltip
- And a direct POST to `customers.export` returns 403
```

These ids become a **public interface**: every test in the phase plan cites which
stories it covers.

### Step 3 — the schema

```
/mktux:plan customer-export
```

This feature creates no table. The skill does **not** produce an empty document —
it opens with a verdict:

```markdown
## Summary

**This feature adds no migration.** It reads from existing tables only.
If any step of the implementation leads to a migration, the step is wrong —
re-read `feature-description.md`.

## New Tables
None.

## Modified Tables
None.
```

This is not bureaucracy. A cold session that cannot tell whether the feature has a
migration **will invent one**.

### Step 4 — the phase plan

This is where the harness earns its keep. Out comes `project-phases.md` in the
exact contract `ralph` executes:

```markdown
## Phase 2: Export action and plan gate

**Goal:** Build the CSV export action behind a Business-plan gate.

**Read first:** `feature-description.md` next to this file, section
"Data & Format Decisions".

**Do not touch in this phase:** `CustomerListController`, the customer index
Blade view, and `CustomerTotalSpentQuery` — the list, its pagination and the
total-spent calculation must behave exactly as before.

**Conventions here, to follow rather than "fix":** actions live in
`app/Actions/Customer/`, one class per use case, constructor property promotion.

**This phase has exactly 4 tasks.** Emit one verdict line per task, numbered 1 to
4 in the order they appear. The sub-bullets under "Automated tests to generate"
are part of the task above them, not tasks of their own.

**Tasks:**
- [ ] Create `App\Actions\Customer\ExportCustomersAction` returning a
      `CsvDocument`, reading through the existing `CustomerQuery`.
  - accepts the same filter DTO the list screen already builds
  - never selects the national ID column
- [ ] `App\Policies\CustomerPolicy` gains an `export` ability that returns false
      unless the tenant's plan is Business.
- [ ] Register `POST /customers/export` as `customers.export`, behind the
      `auth` and `tenant` middleware, declared **before** the
      `customers/{customer}` wildcard route.
  - a cold session will otherwise append it at the end, where the wildcard
    swallows the literal segment
- [ ] No file under `app/`, `routes/` or `resources/views/` references the
      national ID column in the export path.

  Automated tests to generate:
    - `tests/Feature/Customer/ExportCustomersTest.php` — Business downloads,
      filters respected, ID absent (US-1.1)
    - `tests/Feature/Customer/ExportCustomersPlanGateTest.php` — Starter and Pro
      get 403 on direct POST (US-3.1)

**Completion criteria:** `ExportCustomersAction` exists and is covered.
`tests/Feature/Customer/CustomerListTest.php` still passes **unmodified** — if it
needs editing to go green, the list behavior changed and must be corrected
instead.

---
```

Three things there are deliberate:

1. **The phase repeats its own guards.** The `Do not touch` block lives inside the
   phase, not in a preamble — because `ralph` discards everything that is not
   between phase headings. A preamble is invisible to the agent.

2. **The last task is a state, not a command.** "No file references the ID column"
   is something the verifier can check with Grep. "Confirm with `grep -rn` that…"
   is not — that comes back `NOT-CODE` and becomes a manual pending item.

3. **The task count is declared.** `ralph` counts with `grep`; the verifier counts
   by reading. If the two disagree, the phase fails even with everything green. In
   a real run that cost two cycles and 30 minutes.

**Read this file carefully.** It is the last cheap correction point. After this,
every mistake costs a session.

### Step 5 — execute

Clean working tree, Sail up:

```bash
git status --short          # must be empty
vendor/bin/sail up -d

ralph docs/features/customer-export/project-phases.md
```

With a live panel in this terminal:

```bash
ralph docs/features/customer-export/project-phases.md --dashboard
```

Or the panel in a separate terminal while the run goes in the first:

```bash
ralph-watch
```

Switching engine and model:

```bash
ralph docs/features/customer-export/project-phases.md --engine claude --effort high
```

The run goes phase by phase. Each phase: cold session → 4 gates → commit. If a
phase fails, it opens a fix cycle with the cause (3 by default) and, when those
run out, stops — unless you pass `--keep-going`.

Resuming from phase 3 after fixing the plan by hand:

```bash
ralph docs/features/customer-export/project-phases.md --from 3
```

> Editing `project-phases.md` invalidates the stamp and zeroes the progress. Use
> `--from N` so you do not re-run a phase that is already committed.

### Step 6 — review

```
/mktux:review-phases 2
```

You get a report with three sections: convention violations against the project's
`CLAUDE.md`, the `security-auditor` subagent's audit, and the `NOT-CODE` pending
items gate 3 left for you.

---

## The pipeline in detail

Each artifact stamps the hash of its inputs on **line 3**:

```markdown
# User Stories — Customer Export

<!-- inputs: feature-description.md@sha256:a1b2c3d4e5f6 -->
```

When you edit the feature description, `/mktux:plan` recomputes and warns:

```
stale: user-stories.md was born from an older version of feature-description.md
```

Re-running is an **upsert**: the skill interviews only about the delta and
refreshes the stamp.

| Skill | Produces | Reads |
|---|---|---|
| `plan` | nothing (router) | the folder's state |
| `plan-feature-description` | `feature-description.md` | `feature-brief.md` + codebase |
| `plan-user-stories` | `user-stories.md` | feature-description |
| `plan-database-schema` | `database-schema.md` | description + stories + real schema |
| `plan-project-phases` | `project-phases.md` | the three above + codebase |

To change the `docs/features/` root, set `MKTUX_SPEC_DIR`.

---

## ralph in detail

### Invariants

1. Every phase **and** every fix cycle runs in a **fresh session** with a
   self-contained prompt. Sessions are never reused.
2. Zero questions. Start to finish without human interaction.
3. A phase is "complete" only when it clears all 4 gates.
4. Usage limit hit → waits for the reset and re-runs the **same** phase, without
   consuming a fix cycle.
5. One commit per completed phase.

### Flags

| Flag | Effect |
|---|---|
| `--engine codex\|claude` | implementation engine (default: `codex`) |
| `--model <name>` | engine model |
| `--effort <level>` | codex: `low`..`ultra` · claude: `low`..`max` |
| `--from N` | start at phase N |
| `--keep-going` | continue after a phase fails |
| `--max-cycles N` | fix cycles per phase (default: 3) |
| `--no-verify` | disable gate 3 |
| `--test-cmd "<cmd>"` | the project's test command |
| `--dashboard` | live panel in this terminal |
| `--verbose` | mirror engine output to screen |
| `--no-smoke` | skip the engine smoke test in preflight |

### Test command (gate 2)

First rule that resolves wins:

1. `--test-cmd "<cmd>"`
2. `RALPH_TEST_CMD`
3. manifest detection:

| Detected | Command |
|---|---|
| Laravel Sail (`artisan` + `vendor/bin/sail`) | `vendor/bin/sail test` |
| `composer.json` with `scripts.test` | `composer test` |
| `artisan` | `php artisan test` |
| `package.json` with `scripts.test` | `npm test` |
| `pytest.ini` / `pyproject [tool.pytest]` | `pytest` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |

4. nothing resolved → loud warning and gate 2 skipped (gate 3 holds on its own)

Sail takes precedence over `composer test`, because the suite runs in the
container. Containers down → abort in preflight: every gate 2 would fail and burn
the fix cycles for nothing.

### Environment variables

| Variable | Effect |
|---|---|
| `RALPH_TEST_CMD` | gate 2 command |
| `RALPH_VERIFY` | `always` (default) / `auto` / `off` |
| `RALPH_VERIFY_MODEL` | model for the auxiliary sessions |
| `RALPH_VERIFY_EFFORT` | effort for those sessions |
| `RALPH_MAX_CYCLES` | fix cycles per phase |
| `RALPH_MAX_LIMIT_WAITS` | consecutive limit waits, per phase |
| `RALPH_SMOKE` | `0` disables the smoke test |
| `RALPH_MEM0` / `RALPH_MEM0_USER` | per-phase summary to mem0. **Off** until `RALPH_MEM0_USER` is set |
| `RALPH_VERBOSE` | `1` mirrors engine output |
| `RALPH_DASHBOARD` | `1` enables the built-in panel |
| `MKTUX_SPEC_DIR` | spec root (default `docs/features`) |
| `MKTUX_HARNESS_ROOT` | use a local clone instead of the plugin |
| `MKTUX_BIN_DIR` | where to install the wrappers (default `~/.local/bin`) |

### Where the run leaves its trail

```
.phases/
├── phase-NN.md              one file per phase, produced by the split
├── manifest.txt             input stamp
├── .progress                phases already completed
├── state/run.tsv            run snapshot, read by ralph-watch
└── logs/
    ├── run.log                    linear log of the whole run
    ├── phase-NN.cycle-M.log       implementation session
    ├── phase-NN.test-M.log        gate 2 output
    └── phase-NN.verify-M.log      gate 3 task-by-task verdict
```

`.phases/` is registered in `.git/info/exclude` automatically — ralph **does not
touch** your project's `.gitignore`.

---

## Hooks and telemetry

Hooks come from the plugin. There is nothing to configure per project.

| Hook | When | What it does |
|---|---|---|
| `sail-guard` | before every Bash call | blocks a command that would run PHP/DB on the host when the project uses Sail, and hands the agent the correct form |
| `log-event` | every event | appends to `.harness/events.jsonl` with timestamp and branch |
| `pint-and-test` | Claude: after Edit/Write · Codex: end of turn | runs Pint and the affected tests |
| `log-tokens` | end of session | records per-model usage in `.harness/tokens.jsonl`, with a `vendor` field so Claude and Codex land on the same chart |

`pint-and-test` and `log-tokens` exist in **two versions, one per engine**, and
that is deliberate: Codex has no `Edit` hook, so it runs on `Stop` with git-driven
detection and returns `decision:block`; and it reads tokens from the rollout in
`~/.codex/sessions/`, while Claude reads the session transcript. Different data
sources. **Do not unify those two.**

Add to your project's `.gitignore`:

```gitignore
/.harness
```

---

## What your project needs

**Required**

- A git repository, with a **clean** working tree when ralph runs.
- `CLAUDE.md` and/or `AGENTS.md` with the project's conventions. Ralph's sessions
  are cold: what is not there does not exist for them.
- A test suite that runs from a single command.

**Recommended**

- `docs/features/` for the specs.
- Laravel: Sail containers up, and a dedicated `.env.testing`.

  > ⚠️ Without `.env.testing`, running the suite with `--env=testing` falls back
  > to the development `.env` — and a `migrate:fresh` wipes the dev database.
  > Confirm the file exists **before** the first run.

---

## Command reference

In Claude Code, everything lives under the `/mktux:` namespace. In Codex, ask in
natural language — the skill of the same name loads.

| Command | Skill | What it does |
|---|---|---|
| `/mktux:plan <slug>` | `plan` | router: chain state + advance one step |
| `/mktux:plan-feature-description <slug>` | `plan-feature-description` | step 1 |
| `/mktux:plan-user-stories <slug>` | `plan-user-stories` | step 2 |
| `/mktux:plan-database-schema <slug>` | `plan-database-schema` | step 3 |
| `/mktux:plan-project-phases <slug>` | `plan-project-phases` | step 4 |
| `/mktux:ralph` | `ralph` | operational reference and troubleshooting |
| `/mktux:review-phases N` | `review-phases` | review the phase N commit |
| `/mktux:setup` | `setup` | install `ralph` on PATH, prepare the project |

Subagents (Claude Code): `test-runner` and `security-auditor`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Contrato de formato violado` in preflight | a `## Phase` heading outside `## Phase N: <title>`. A malformed heading makes the phase **vanish silently** from the run |
| phase fails with every verdict `DONE` | task count mismatch. The phase needs the `**This phase has exactly N tasks.**` line |
| a task always comes back `NOT-CODE` | it is worded as a command (`run`, `confirm with git diff`). Reword it as a code state |
| phase fails every cycle until exhausted | a task with a conditional escape hatch (*"do X, but if it feels awkward, leave it"*). In doubt, the verifier picks INCOMPLETE |
| gate 2 red on the very first run | Sail is down, or `.env.testing` is missing |
| the run restarts from phase 1 after you edit the plan | editing `project-phases.md` invalidates the stamp. Use `--from N` |
| `ralph: command not found` | run installation step 3, and check `~/.local/bin` is on your PATH |
| `mktux-harness: não encontrei ralph.sh` | the plugin is not installed on that machine, or point `MKTUX_HARNESS_ROOT` at a clone |

When a phase fails, read in this order:

1. `.phases/logs/phase-NN.verify-M.log` — what the verifier rejected
2. `.phases/logs/phase-NN.test-M.log` — what the suite rejected
3. `.phases/logs/phase-NN.cycle-M.log` — what the session tried to do

---

## What's in the box

```
mktux-harness/
├── .claude-plugin/marketplace.json     Claude Code manifest
├── .codex-plugin/marketplace.json      Codex manifest
├── .agents/plugins/marketplace.json    standard manifest
└── plugins/mktux-harness/
    ├── .claude-plugin/plugin.json
    ├── .codex-plugin/plugin.json       skills + hooks
    ├── skills/                         ← SINGLE SOURCE, both engines read it
    │   ├── plan/                       router + brief template
    │   ├── plan-feature-description/
    │   ├── plan-user-stories/
    │   ├── plan-database-schema/
    │   ├── plan-project-phases/        ralph's contract
    │   ├── ralph/                      operation and troubleshooting
    │   ├── review-phases/
    │   └── setup/
    ├── agents/                         Claude only: test-runner, security-auditor
    ├── hooks/
    │   ├── hooks.json                  Claude  (${CLAUDE_PLUGIN_ROOT})
    │   ├── codex-hooks.json            Codex   (${PLUGIN_ROOT})
    │   ├── shared/                     sail-guard, log-event
    │   ├── claude/                     pint-and-test, log-tokens
    │   └── codex/                      pint-and-test, log-tokens
    └── scripts/
        ├── ralph.sh                    the orchestrator
        ├── ralph-watch.sh              live panel, read-only
        ├── test-ralph.sh               ralph's own test suite
        └── mktux-setup.sh              installs the PATH wrappers
```

> The skills and ralph's own messages are written in Portuguese, by design — this
> is the language the team works in. The artifacts they produce
> (`feature-description.md`, `user-stories.md`, `project-phases.md`) are written
> in English, so the plan reads the same as the codebase.

---

## Credits

`ralph.sh`, `ralph-watch.sh` and `sail-guard.sh` descend from the
[**Beer and Code Harness**](https://github.com/beerandcodeteam/beer-and-code-harness)
(MIT © Beer and Code). The `/init` chain with freshness stamps, and the pipeline
router idea, also come from there.

Thanks to the Beer and Code team for the mentorship and the original work.

The four-gate contract, gate 3's `NOT-CODE` verdict, the stop-on-cycle-without-
progress rule, the `ralph-watch` panel, and the phase-writing rules in the
`plan-project-phases` skill were developed and hardened in production runs on this
harness.

License: [MIT](LICENSE).
