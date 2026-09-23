# mktux Harness

> 🇧🇷 [Documentação em português](README.pt-BR.md)

A plugin for **Claude Code** and **Codex CLI** that takes a project from idea to
running code in a structured way: formal specification, phased planning, and
autonomous execution with mechanical validation — while keeping a human in control
at every decision point.

One repository, two engines, zero files copied into your projects.

One stack-agnostic core, with stack profiles on top for Laravel (Sail), Node.js
and Python; Go and Rust projects run on the generic path. See
[Stack profiles](#stack-profiles).

---

## Table of contents

- [The problem](#the-problem)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Getting started: a real example, from zero to commit](#getting-started-a-real-example-from-zero-to-commit)
- [The pipeline in detail](#the-pipeline-in-detail)
- [ralph in detail](#ralph-in-detail)
- [Hooks and telemetry](#hooks-and-telemetry)
- [Stack profiles](#stack-profiles)
- [Long-term memory (ai-memory)](#long-term-memory-ai-memory)
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
  /mktux:plan <slug> "<idea>"       router: reports state, advances ONE step
        │
        ├──▶ 0. feature-brief.md          interview → your intent, in your words
        │                                 ← the "must NOT change" field matters most
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
| **0** | the engine actually finished, no protocol error, within `RALPH_SESSION_TIMEOUT` | yes |
| **1** | did the session write code? A **signal**, not a verdict — a phase already correctly implemented writes nothing | no |
| **2** | the project's test suite, run **by ralph**, outside the agent's session | yes |
| **3** | an independent read-only verifier that judges **task by task** | yes |

Gate 3 is what catches the lie. It runs in a separate session, on a cheap model.
ralph hands it the phase's tasks already numbered, plus the files the phase
changed as a starting point. On Claude it has `Read`, `Glob` and `Grep` only —
**no Bash, no shell, no git**; on Codex it runs in a read-only sandbox, told not to
run builds or tests. For each task in the plan it emits exactly one line:

```
TASK 1: DONE
TASK 2: INCOMPLETE — CsvDocument has no render() method
TASK 3: NOT-CODE — needs a human to run `sail npm run build`
```

`INCOMPLETE` fails the phase and triggers a fix cycle. `NOT-CODE` does not fail —
it becomes a manual pending item in the report.

A task the plan types as `- [ ] (manual) …` — run the formatter, build assets,
check on a real phone — never reaches the verifier. ralph leaves it out of the
numbered list, drops any verdict on it, and lists it under *Pendencias manuais*
at the end of the run: the checklist for whoever opens the PR.

A phase marked `**Check-only phase**` — the close-out that only asserts state —
gets no session up front. ralph runs gates 2 and 3 against HEAD; green closes the
phase with no session and no commit, red opens cycle 1 as a fix with the verdict
in hand. In a real run, a phase like that opened a session, wrote nothing and
spent 2.4M input tokens to reach the same verdict.

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

The harness's own suites run offline, with mock engines and no tokens spent:

```bash
cd plugins/mktux-harness
scripts/test-ralph.sh      # ralph: gates, cycles, limits, dashboard, profiles
scripts/test-layout.sh     # manifests, profiles, skill references, hooks, mktux-profile, core guard
```

---

## Getting started: a real example, from zero to commit

Let's build a real feature: **export the customer list as CSV**, in a multi-tenant
Laravel SaaS, with the export gated to the Business plan.

### Step 0 — the brief

Describe the feature in the command itself. You never author this document.

```
/mktux:plan customer-export "export the customer list as CSV, gated to the Business plan"
```

The brief does not exist, so the router hands off to `plan-feature-brief`. It
reads the codebase **before** asking anything — your role enum, your plan gating,
the screens next to the one you named — then interviews you in batches about only
what it could not detect. It pushes hardest on one question: *what must not change
behavior?* Answering "nothing" is not accepted until it has walked you through the
neighbouring screens it found.

The result is `docs/features/customer-export/feature-brief.md`, in your language,
filled in — no placeholders, no unticked checkboxes:

```markdown
# Feature Brief — Customer export

## O que é essa feature?

A button on the customer list that downloads a CSV of that tenant's customers,
respecting the filters already applied on screen.

## Por que estamos construindo isso?

The owner sends the list to their accountant every month and copies it off the
screen by hand today.

## O que DEVE entrar nessa feature?

- An "Export CSV" button on the customer list
- The CSV respects the search and period filters already applied on screen
- Columns: name, email, phone, signup date, total spent

## O que NÃO entra nessa feature (por hora)?

- Excel/xlsx export
- Scheduled export by email

## O que NÃO pode mudar de comportamento?

- The customer list itself: pagination, search and ordering stay identical
- The "total spent" calculation — it already exists and the dashboard uses it

## Regras de negócio que você já sabe?

- Only the Business plan exports. Starter and Pro see a disabled button with an
  upgrade hint.
- The national ID number never leaves in the file.

## Quem usa essa feature?

- admin (owner) — exports
- staff — deliberately out; does not see the button

## Mexe em dado pessoal?

Yes — name, email, phone. The data leaves the system in a file: yes.
```

> Section titles stay in Portuguese even when you write the content in English —
> they are addresses, and step 1 reads the brief by them.

> The **"O que NÃO pode mudar de comportamento"** section does the heaviest lifting. It
> becomes the `Do not touch` block the harness repeats inside every phase — the
> thing that stops a blind session from rewriting a list that already works.

Prefer to write it by hand? Still supported, same file and same shape — the
template ships next to the `plan-feature-brief` skill. The interview is a
convenience, not a requirement.

Changed your mind later? Re-run `/mktux:plan-feature-brief customer-export "<what
changed>"`. It re-reads what is there and asks only about the delta, then the
stamp goes stale and `/mktux:plan` tells you to regenerate step 1.

### Step 1 — the feature description

```
/mktux:plan customer-export
```

The router now reports state and advances one step:

```
| Artifact                 | State                     |
|--------------------------|---------------------------|
| feature-brief.md         | present                   |
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
- [ ] `tests/Feature/Customer/ExportCustomersTest.php` (new file) covers these scenarios, one test case each:
  - Business tenant exports → CSV download with one row per customer (US-1.1)
  - export with a name filter → only the matching customers in the CSV (US-1.1)
  - Business tenant exports → header row has no national ID column (US-1.1)
- [ ] `tests/Feature/Customer/ExportCustomersPlanGateTest.php` (new file) covers these scenarios, one test case each:
  - Starter tenant POSTs to `customers.export` → 403 (US-3.1)
  - Pro tenant POSTs to `customers.export` → 403 (US-3.1)

**Completion criteria:** `ExportCustomersAction` exists and is covered.
`tests/Feature/Customer/CustomerListTest.php` still passes **unmodified** — if it
needs editing to go green, the list behavior changed and must be corrected
instead.

---
```

Five things there are deliberate:

1. **The phase repeats its own guards.** The `Do not touch` block lives inside the
   phase, not in a preamble — because `ralph` discards everything that is not
   between phase headings. A preamble is invisible to the agent.

2. **The last task is a state, not a command.** "No file references the ID column"
   is something the verifier can check with Grep. "Confirm with `grep -rn` that…"
   is not — that comes back `NOT-CODE` and becomes a manual pending item. A real
   procedure (formatter, asset build) goes in as `- [ ] (manual) …`, out of
   gate 3 by construction.

3. **Each task's first line stands on its own.** `ralph` counts the checkboxes and
   hands the verifier a numbered list of first lines, so the verifier never
   counts by reading. Details go in plain `-` sub-bullets: every `- [ ]`, at any
   indentation, becomes a task with its own verdict.

4. **Each test file is its own task, with a closed scenario list.** The verifier
   checks that every listed scenario has a test case — and asks for nothing
   beyond the list. "Tests prove every precondition" gives it nothing to close:
   in a real run it rebuilt its own list each cycle, and the fix session chased
   a target that moved while the plan stayed the same.

5. **A rule that crosses layers is cited in every phase it lands in.** "Write
   everything before swapping the column; on failure keep the column and show
   the admin a validation error" is an action clause *and* a controller clause.
   Each phase that gets a clause cites the `BR-NN` and carries a task and a
   scenario for it. In a real run only the action phase cited the rule: both
   phases passed all four gates, and a failed upload still reached the admin as
   a 500.

`ralph` reads the `Read first:` line and the ids the phase cites, and hands the
session **only those excerpts** — the named section, the `BR-NN` rule, the
`US-N.N` story, the table — plus the documents' paths for a targeted lookup.
Telling the session to "read the context documents" made 25 of 26 sessions in a
real run read all of them end to end, some 19k tokens riding in the context of
every later turn. So cite by exact heading and by id: "see the description" is
not an address.

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
`CLAUDE.md`, the `security-auditor` subagent's audit, and the manual pending
items — `(manual)` tasks and `NOT-CODE` verdicts — left for you.

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
3. the **stack profile** of the directory ralph runs from
   (`profiles/<name>/profile.sh`; it does not walk up):

| Profile | Detected by | Command |
|---|---|---|
| Laravel | `artisan` | `vendor/bin/sail artisan test --compact` with Sail; else `composer test` if there is a `scripts.test`; else `php artisan test` |
| Node.js | `package.json` | `npm run check` when available; else `npm test` |
| Python | `pyproject.toml` | `uv run pytest` with `uv.lock`; `poetry run pytest` with `poetry.lock`; else `pytest` |

4. manifest detection:

| Detected | Command |
|---|---|
| `composer.json` with `scripts.test` | `composer test` |
| `package.json` with `scripts.test` | `npm test` |
| `pytest.ini` / `pyproject [tool.pytest]` | `pytest`; `uv run pytest` with `uv.lock`; `poetry run pytest` with `poetry.lock` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |

5. nothing resolved → loud warning and gate 2 skipped (gate 3 holds on its own)

The profile also checks the environment in preflight — containers down,
Node.js dependencies absent, or pytest missing from the project environment →
abort before every gate 2 burns a fix cycle — and adds notes to the
implementation prompt, including how to run a focused test in that stack. The
prompt asks for focused tests while working and the full command once, at the
end: running the whole suite after every item cost minutes per item. The
resolved command reaches every session as
`RALPH_TEST_CMD`, so the `test-runner` subagent runs exactly what gate 2 runs.
To see what ralph will resolve in a project without running anything:
`bash "$CLAUDE_PLUGIN_ROOT/scripts/mktux-profile.sh" test-cmd`.

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
| `RALPH_MEMORY` | `0` disables the per-phase page in [ai-memory](#long-term-memory-ai-memory). Turns itself off when the binary is missing or the server is down |
| `RALPH_MEMORY_BIN` | ai-memory binary (default `ai-memory` on PATH) |
| `RALPH_HOOK_ISOLATION` | `0` lets ai-memory's hooks run inside ralph's sessions (default `1`: isolate). Independently, every Codex session ralph starts runs with `-c features.memories=false`, so Codex's native memory never brings earlier sessions into a cold one |
| `RALPH_VERBOSE` | `1` mirrors engine output |
| `RALPH_DASHBOARD` | `1` enables the built-in panel |
| `MKTUX_SPEC_DIR` | spec root (default `docs/features`) |
| `MKTUX_HARNESS_ROOT` | use a local clone instead of the plugin |
| `MKTUX_BIN_DIR` | where to install the wrappers (default `~/.local/bin`) |

| `RALPH_SESSION_TIMEOUT` | seconds an engine session may run before ralph kills it and everything it started (default `3600`, `0` disables). The killed session fails gate 0 with the cause |
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
    ├── phase-NN.verify-M.log      gate 3 session
    ├── phase-NN.verify-M.last.txt gate 3 final verdict (Codex)
    └── phase-NN.memory.log        `ai-memory write-page` output
```

`.phases/` and `.harness/` (hook telemetry) are registered in `.git/info/exclude`
automatically — ralph **does not touch** your project's `.gitignore`. A tracked
`.harness/` aborts the preflight: the telemetry changes on every tool call, so it
would land in every phase commit and gate 1 would see a write in every session.

---

## Hooks and telemetry

Hooks come from the plugin. There is nothing to configure per project.

| Hook | When | What it does |
|---|---|---|
| `profile-hook` | before every Bash call · Claude: after Edit/Write · Codex: end of turn | finds the stack profile walking up from the event's directory and hands the event to the profile's script; no profile, no-op |
| `log-event` | every event | appends to `.harness/events.jsonl` with timestamp and branch |
| `log-tokens` | end of session | records per-model usage in `.harness/tokens.jsonl`, with a `vendor` field so Claude and Codex land on the same chart. Each subagent gets its own line, with `parent` |

Laravel profile scripts (`profiles/laravel/hooks/`), called by `profile-hook`:

| Script | Event | What it does |
|---|---|---|
| `sail-guard` | `pre-bash` | blocks a command that would run PHP/DB on the host when the project uses Sail, and hands the agent the correct form |
| `pint-and-test` | `claude-post-edit` · `codex-stop` | runs Pint and the affected tests |

`pint-and-test` and `log-tokens` exist in **two versions, one per engine**, and
that is deliberate: Codex has no `Edit` hook, so it runs on `Stop` with git-driven
detection and returns `decision:block`; and it reads tokens from the rollout in
`~/.codex/sessions/`, while Claude reads the session transcript. Different data
sources. **Do not unify those two.**

Add to your project's `.gitignore`:

```gitignore
/.harness
```

ralph excludes `.harness/` on its own when it runs, but the hooks write it in
every session, not just ralph's: ignore it before your first commit.

---

## Stack profiles

The harness core — the planning skills, `ralph`, the four gates, the hooks, the
subagents — does not know any stack. What belongs to one stack lives in a
**stack profile**: the test command and how to check that the environment can
run it, the conventions a cold session must follow instead of inventing its own,
the hooks that guard the host, and the stack's security checklist.

That split is what lets one harness serve Laravel, Node and Python without
diluting any of them. Laravel's opinionated rules — PHP enums over lookup
tables, `created_by`/`updated_by`, never editing an executed migration, Sail for
everything — are exactly what keeps a cold session from improvising. They stay
intact; they just load only where they apply.

### What a profile decides

| Where | Without a profile | With the Laravel profile |
|---|---|---|
| ralph gate 2 — test command | manifest detection | `vendor/bin/sail artisan test --compact` with Sail; else `composer test`; else `php artisan test` |
| ralph preflight | — | Sail containers down → abort before the first session |
| ralph implementation prompt | the test command | + "artisan, composer, php and tests run INSIDE the container" |
| hook before every Bash call | no-op | `sail-guard` blocks PHP/DB on the host and hands back the Sail form |
| hook after an edit (Claude) / end of turn (Codex) | no-op | `pint-and-test`: Pint on the change, then the affected tests |
| `plan-database-schema` | your `CLAUDE.md`/`AGENTS.md` and the existing schema | + the Laravel database conventions |
| `plan-project-phases` | your commands, test framework and layout | + Sail commands, PHPUnit and `tests/Feature` paths, the Laravel phase order, Single Action Controllers, Blade |
| `test-runner` subagent | the resolved command | + artisan file/filter syntax, never on the host, the exact "Sail is not running" error |
| `security-auditor` / `review-phases` | the generic web checklist | + `route:list`, FormRequest, `$fillable`, `$request->all()`, `@csrf`, Actions not reading `request()` |

Your project's `CLAUDE.md` / `AGENTS.md` always wins over the profile: if Boost
says the project uses Pest, the plan uses Pest.

### How a profile is detected

A profile applies when its marker is present: `artisan` for Laravel,
`package.json` for Node.js and `pyproject.toml` for Python. More specific
profiles win; the Node.js detector does not claim a root that also carries a
Laravel or Python marker.

- **ralph** looks only at the directory it runs from: the paths a profile
  returns (`vendor/bin/sail`) are relative to that root.
- **Hooks and subagents** walk up from the current directory, so a Laravel app in
  a monorepo subfolder is still guarded while you work inside it.
- **Skills** look up the project root's markers in their profile table
  (`artisan` → `references/laravel.md`) and load the matching reference.

To see what applies to a project, without running anything:

```bash
P="$CLAUDE_PLUGIN_ROOT"                          # Codex: $PLUGIN_ROOT
bash "$P/scripts/mktux-profile.sh" name          # laravel, node, python — or exit 1
bash "$P/scripts/mktux-profile.sh" test-cmd      # what gate 2 and test-runner run
bash "$P/scripts/mktux-profile.sh" notes test-runner
```

### Node.js and Python profiles

- **Node.js:** prefers the project's complete `scripts.check` gate, falling back
  to `npm test`; requires `node`, `npm`, the major declared by `.node-version`
  / `.nvmrc`, and installed dependencies. Its
  `test-runner` notes preserve npm's `--` separator and never replace scripts
  with `npx` or a global binary.
- **Python:** preserves the project environment wrapper (`uv run`, `poetry run`
  or the active environment), checks that pytest is already available without
  installing anything, and points to `uv sync --extra dev` when that is where
  the project declares pytest.

Both profiles intentionally stop at test/lint mechanics. They do not impose a
framework, directory layout, database or web architecture.

### Projects without a profile (Go, Rust and others)

They run on the generic path — the whole harness, minus the stack rules:

- gate 2 and `test-runner` use manifest detection (see
  [Test command](#test-command-gate-2)): `go test ./...`, `cargo test`, or a
  supported manifest script. Override with `--test-cmd` or `RALPH_TEST_CMD`;
- the planning skills follow only your `CLAUDE.md` / `AGENTS.md` and the code
  that exists — so that is where your conventions go;
- `security-auditor` applies the generic web checklist;
- the stack hooks do nothing.

`test-runner` never prepares an environment: it does not install dependencies,
sync a virtualenv or start services. A missing dependency comes back as an
`ERROR:` line naming what to set up (for a uv project, `uv sync --extra dev`).

### Where a profile lives

```
plugins/mktux-harness/
├── profiles/laravel/
│   ├── profile.sh                 detection, test command, preflight, prompt notes, hook map
│   ├── agents/test-runner.md      notes only test-runner reads
│   └── hooks/                     sail-guard, pint-and-test
├── profiles/node/
│   ├── profile.sh                 npm gate, dependency preflight, prompt notes
│   └── agents/test-runner.md      npm argument and full-gate rules
├── profiles/python/
│   ├── profile.sh                 pytest command, environment preflight, prompt notes
│   └── agents/test-runner.md      pytest file/filter and wrapper rules
├── skills/<skill>/references/laravel.md
│                                  conventions a skill loads (schema, phases, security)
└── scripts/
    ├── lib/profile.sh             the contract, detection, manifest fallback
    └── mktux-profile.sh           the profile, answered for subagents
```

Conventions a skill loads live **next to the skill**, not under `profiles/`:
that is the one path both Claude Code and Codex resolve. A subagent that needs
the same text (the security checklist) reads it from there.

### Adding a profile

A profile is a `profiles/<name>/profile.sh` defining five functions (the contract
is in `scripts/lib/profile.sh`):

| Function | Answers |
|---|---|
| `profile_detect <dir>` | does this profile apply to `<dir>`? |
| `profile_test_cmd` | the default test command, from the project root |
| `profile_preflight <cmd>` | can the environment run `<cmd>`? `exit 1` with a message if not |
| `profile_prompt_notes` | extra lines for ralph's implementation prompt |
| `profile_hook <event>` | the script for `pre-bash`, `claude-post-edit` or `codex-stop`, if any |

Then, as the stack needs them: hook scripts under `profiles/<name>/hooks/`,
subagent notes under `profiles/<name>/agents/`, and a `references/<name>.md`
next to each skill that should carry conventions for it, plus a row in that
skill's profile table. The `ralph` and `setup` skills each get a heading under
their *Perfis de stack* section.

Stack names stay out of the core. `scripts/test-layout.sh` fails when a skill,
agent, hook or script names a stack anywhere but `profiles/`, a profile's skill
reference, or a registry block — the fence every profile table and *Perfis de
stack* section sits in:

```markdown
<!-- perfis -->
| Perfil | Marcador na raiz | Reference |
|---|---|---|
| Laravel | `artisan` | `references/laravel.md` |
<!-- /perfis -->
```

It also checks that every hook, reference and notes file a profile points at
exists, and that every reference in a registry block has its `profiles/<name>/`.
The `ai-context` skill loads its stack-specific ownership and wrapper rules from
the matching reference, so its core is covered by the same guard.

### Upgrading from 0.3

Nothing to change in your projects. What behaves differently:

- **Hooks** go through `profile-hook`, which calls the Laravel scripts only in a
  Laravel project. Other projects no longer run `sail-guard` or `pint-and-test`
  at all.
- **`test-runner`** resolves the command instead of hard-coding
  `sail artisan test`. Inside a ralph run it receives the gate 2 command through
  `RALPH_TEST_CMD`, so the two always agree.
- **Planning skills** stop pushing Laravel conventions onto Node and Python
  projects. In a Laravel project the plans come out the same — checked A/B on a
  real feature.
- **`review-phases` on Codex** now audits with the Laravel security checklist,
  instead of an unspecified "equivalent agent".
- **Python** projects with `uv.lock` or `poetry.lock` get `uv run pytest` /
  `poetry run pytest` instead of a bare `pytest` that failed on the host.
- **Node.js and Python** are now first-class profiles with dependency preflight,
  implementation notes and runner-specific argument rules.
- **`ai-context`** no longer assumes a container wrapper or ownership tool in
  its core; the Laravel-specific contract loads only when `artisan` matches.
- A plugin installed at **project scope** does not follow the user-scope update.
  List installs with `claude plugin list`, and update each project-scoped one
  from inside that project: `claude plugin update mktux@mktux-harness -s project`.

---

## Long-term memory (ai-memory)

The harness uses [ai-memory](https://github.com/akitaonrails/ai-memory) for
memory: a local server (`127.0.0.1:49374`) that keeps memory in a
git-versioned markdown wiki, with hooks in Claude Code and Codex. It is
**optional**: without it, ralph runs the same.

### Install (macOS, once per machine)

```bash
# native binary (Apple Silicon; Intel: swap aarch64 for x86_64)
mkdir -p ~/Applications/ai-memory && cd ~/Applications/ai-memory
gh release download -R akitaonrails/ai-memory -p 'ai-memory-macos-aarch64.tar.gz*'
shasum -a 256 -c ai-memory-macos-aarch64.tar.gz.sha256
tar -xzf ai-memory-macos-aarch64.tar.gz && ./ai-memory init
ln -sf "$PWD/ai-memory" ~/.local/bin/ai-memory

# server as a login service (launchd), on 127.0.0.1:49374
mkdir -p ~/Library/Logs/ai-memory
sed -e "s|__AI_MEMORY_BIN__|$PWD/ai-memory|" -e "s|__HOME__|$HOME|" \
  packaging/launchd/com.github.akitaonrails.ai-memory.plist \
  > ~/Library/LaunchAgents/com.github.akitaonrails.ai-memory.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.akitaonrails.ai-memory.plist

# hooks + MCP on both engines
ai-memory install-hooks --agent claude-code --project-strategy repo-root --apply
ai-memory install-hooks --agent codex       --project-strategy repo-root --apply
ai-memory install-mcp   --client claude-code --apply
ai-memory install-mcp   --client codex       --apply
```

- **Codex:** new hooks only run once trusted. Open `codex` once and pick
  *Trust all* under `/hooks`.
- **`install-mcp --client codex` failing with `invalid inline table`:**
  ai-memory's TOML parser rejects multi-line inline tables (TOML 1.1) in your
  `~/.codex/config.toml`. Add it by hand:

  ```toml
  [mcp_servers.ai-memory]
  url = "http://127.0.0.1:49374/mcp"
  default_tools_approval_mode = "approve"
  ```

### What ralph does with it

- **One page per phase.** After the commit, ralph runs `ai-memory write-page`
  and writes `ralph/<feature>/phase-NN.md` (tier `episodic`, tags `ralph` and
  `<feature>`). The page holds the commit SHA, the engine, the cycles, the
  changed files and the phase plan. It is a deterministic POST: no LLM, no
  extra session, and it works on both engines. Re-running with `--from`
  updates the page instead of duplicating it.
- **Sessions isolated from ai-memory's hooks.** ai-memory's `SessionStart`
  claims the pending handoff (the GET is destructive) and injects it as
  context. Without isolation, phase 1 would eat the handoff *you* left, every
  session would get the previous one's "where you left off", and the gate 3
  judge would stop being independent. When preflight finds the hooks in the
  user config, every ralph session (smoke, implementation, gate 3) runs
  without them:
  - **Claude:** `--setting-sources project,local` plus `--settings` holding
    your `settings.json` *minus* ai-memory's hooks. Model, effort, plugins
    and your other hooks stay.
  - **Codex:** `-c hooks.state={...={enabled=false}}` on ai-memory's handlers
    only. Trust for every other hook stays.
  - Needs `jq`. ai-memory hooks installed in a **project** config are not
    detected.
- **Fails open.** With no binary, memory switches off silently. With the
  server down, preflight warns. If a write fails, the phase warns and stays
  valid. Memory is a record, not a gate.

To look things up later, ask the agent "search memory for phase 3 of feature
X" (MCP `memory_query`), or run `ai-memory search "..."`.

### `/mktux:ai-context` and the ai-memory block

`ai-memory install-instructions` writes a
`<!-- ai-memory:start -->…<!-- ai-memory:end -->` block into
`CLAUDE.md`/`AGENTS.md`. `/mktux:ai-context` treats that block as foreign: it
keeps the block intact when it regenerates `AGENTS.md` and never seeds it as
hand-written content.

---

## What your project needs

**Required**

- A git repository, with a **clean** working tree when ralph runs.
- `CLAUDE.md` and/or `AGENTS.md` with the project's conventions. Ralph's sessions
  are cold: what is not there does not exist for them.
- A test suite that runs from a single command — detected automatically (see
  [Stack profiles](#stack-profiles)), or set with `--test-cmd` / `RALPH_TEST_CMD`.

**Recommended**

- `docs/features/` for the specs.
- Laravel profile: Sail containers up, and a dedicated `.env.testing`.

  > ⚠️ Without `.env.testing`, running the suite with `--env=testing` falls back
  > to the development `.env` — and a `migrate:fresh` wipes the dev database.
  > Confirm the file exists **before** the first run.

- Other stacks: the dev environment set up once (`npm install`,
  `uv sync --extra dev`, ...). ralph and `test-runner` run the tests; they never
  install anything.

---

## Command reference

In Claude Code, everything lives under the `/mktux:` namespace. In Codex, ask in
natural language — the skill of the same name loads.

| Command | Skill | What it does |
|---|---|---|
| `/mktux:plan <slug> "<idea>"` | `plan` | router: chain state + advance one step |
| `/mktux:plan-feature-brief <slug> "<idea>"` | `plan-feature-brief` | step 0: interview → `feature-brief.md` |
| `/mktux:plan-feature-description <slug>` | `plan-feature-description` | step 1 |
| `/mktux:plan-user-stories <slug>` | `plan-user-stories` | step 2 |
| `/mktux:plan-database-schema <slug>` | `plan-database-schema` | step 3 |
| `/mktux:plan-project-phases <slug>` | `plan-project-phases` | step 4 |
| `/mktux:ralph` | `ralph` | operational reference and troubleshooting |
| `/mktux:review-phases N` | `review-phases` | review the phase N commit |
| `/mktux:setup` | `setup` | install `ralph` on PATH, prepare the project |
| `/mktux:ai-context [path] [+id] [-id] [--adopt]` | `ai-context` | generate/refresh `AGENTS.md` + `docs/agents/*.md` from the implemented code |

Subagents (Claude Code): `test-runner`, `security-auditor`, `ai-context-inspector`,
`ai-context-core`, `ai-context-docs`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Contrato de formato violado` in preflight | a `## Phase` heading outside `## Phase N: <title>`. A malformed heading makes the phase **vanish silently** from the run |
| gate 3 fails on `cobertura incompleta` or an out-of-range index | the verifier ignored the numbered list in its prompt. Read the verdict (`verify-M.last.txt` on Codex, `verify-M.log` on Claude); if it repeats, change `RALPH_VERIFY_MODEL` |
| preflight aborts with `.harness/ esta versionado` | the telemetry was committed. `git rm -r --cached .harness` and commit |
| a task always comes back `NOT-CODE` | it is worded as a command (`run`, `confirm with git diff`). Reword it as a code state, or tag it `(manual)` if it really is a procedure |
| a close-out phase fails with nothing wrong in the code | a procedure task without `(manual)`: the verifier tries to judge what it cannot read. Tag it `(manual)` |
| phase fails every cycle until exhausted | a task with a conditional escape hatch (*"do X, but if it feels awkward, leave it"*). In doubt, the verifier picks INCOMPLETE |
| gate 2 red on the very first run | Laravel: Sail is down, or `.env.testing` is missing. Other stacks: the dev environment was never set up (dependencies, virtualenv) |
| ralph or `test-runner` picks the wrong test command | check with `mktux-profile.sh test-cmd` (see [Stack profiles](#stack-profiles)); override with `--test-cmd` or `RALPH_TEST_CMD` |
| `test-runner` returns `ERROR:` about a missing dependency | the environment is not set up. It never installs on its own: run the setup the line names (e.g. `uv sync --extra dev`) |
| the Laravel hooks do not fire | there is no `artisan` at or above the current directory — check with `mktux-profile.sh name` |
| the run restarts from phase 1 after you edit the plan | editing `project-phases.md` invalidates the stamp. Use `--from N` |
| `ralph: command not found` | run installation step 3, and check `~/.local/bin` is on your PATH |
| `mktux-harness: não encontrei ralph.sh` | the plugin is not installed on that machine, or point `MKTUX_HARNESS_ROOT` at a clone |
| preflight aborts with `Hooks do ai-memory em ... sem jq` | ai-memory's hooks are in your user config and isolating them needs `jq`. Install `jq`. Use `RALPH_HOOK_ISOLATION=0` only if you accept sessions claiming your handoffs |
| `Falha ao gravar no ai-memory` | read `.phases/logs/phase-NN.memory.log`. If the server died: `ai-memory status` and `launchctl kickstart -k gui/$(id -u)/com.github.akitaonrails.ai-memory`. The phase stays valid |

When a phase fails, read in this order:

1. `.phases/logs/phase-NN.verify-M.log` — what the verifier rejected
2. `.phases/logs/phase-NN.test-M.log` — what the suite rejected
3. `.phases/logs/phase-NN.cycle-M.log` — what the session tried to do
| gate 0 red with `passou de RALPH_SESSION_TIMEOUT` | a command inside the session waited for input that never came — a confirmation prompt, watch mode, a server in the foreground. The prompt asks for stdin closed (`< /dev/null`); fix the test or command that prompts |

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
    │   ├── plan/                       router
    │   ├── plan-feature-brief/          step 0: interview + brief template
    │   ├── plan-feature-description/
    │   ├── plan-user-stories/
    │   ├── plan-database-schema/      references/laravel.md: DB conventions
    │   ├── plan-project-phases/        ralph's contract + references/laravel.md
    │   ├── ralph/                      operation and troubleshooting
    │   ├── review-phases/              references/laravel.md: security audit
    │   ├── setup/
    │   └── ai-context/               AGENTS tree from the implemented code
    ├── agents/                         Claude only: test-runner, security-auditor,
    │                                   ai-context-{inspector,core,docs}
    ├── hooks/
    │   ├── hooks.json                  Claude  (${CLAUDE_PLUGIN_ROOT})
    │   ├── codex-hooks.json            Codex   (${PLUGIN_ROOT})
    │   ├── shared/                     profile-hook (dispatcher), log-event
    │   ├── claude/                     log-tokens
    │   └── codex/                      log-tokens
    ├── profiles/laravel/               what only a Laravel project uses
    │   ├── profile.sh                  detection, test command, preflight, hook map
    │   ├── agents/                     test-runner notes
    │   └── hooks/                      sail-guard (shared/), pint-and-test
    │                                   (claude/, codex/)
    └── scripts/
        ├── lib/profile.sh              profile contract, detection, manifest fallback
        ├── mktux-profile.sh            the profile, for agents: name, test-cmd, notes
        ├── ralph.sh                    the orchestrator
        ├── ralph-watch.sh              live panel, read-only
        ├── test-ralph.sh               ralph's own test suite
        ├── test-layout.sh              manifests, profiles, references, hooks, mktux-profile
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
(MIT © Beer and Code). The `/init` chain with freshness stamps, the pipeline
router idea, and `/ai-context` also come from there — `/mktux:ai-context` is that
command ported and adapted so `CLAUDE.md` stays owned by Laravel Boost and
`.ai/rules` stays the team's convention layer.

Thanks to the Beer and Code team for the mentorship and the original work.

The four-gate contract, gate 3's `NOT-CODE` verdict, the stop-on-cycle-without-
progress rule, the `ralph-watch` panel, and the phase-writing rules in the
`plan-project-phases` skill were developed and hardened in production runs on this
harness.

License: [MIT](LICENSE).
