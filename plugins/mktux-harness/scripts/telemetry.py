#!/usr/bin/env python3
"""Local Ralph usage snapshots and per-invocation summaries (stdlib only)."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from datetime import datetime, timedelta, timezone


SESSION_UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
SESSION_HEADER = re.compile(
    rf"^\s*session[ _-]+id\s*:\s*({SESSION_UUID_PATTERN})\s*$", re.IGNORECASE
)
CODEX_BANNER = re.compile(r"OpenAI Codex \(?v[0-9].*")
CODEX_SEPARATOR = re.compile(r"-{4,}")


def lines(path):
    try:
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    value = json.loads(line)
                    if isinstance(value, dict):
                        yield value
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        return


def structured_rows(content):
    """Yield JSON or the leading JSONL stream, never JSON printed later by a tool."""
    try:
        value = json.loads(content)
        if isinstance(value, dict):
            yield value
            return
    except json.JSONDecodeError:
        pass
    for line in content.splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            break
        if not isinstance(value, dict):
            break
        yield value


def structured_session_ids(content, engine, mode=None):
    """Extract IDs only from the engine's own identity events."""
    if engine == "claude" and mode in ("verify", "judge"):
        return set()  # Claude runs these sessions with --output-format text.
    found = set()
    for row in structured_rows(content):
        if engine == "codex":
            payload = row.get("payload")
            if row.get("type") == "session_meta" and isinstance(payload, dict):
                value = payload.get("id")
                if isinstance(value, str) and value.strip():
                    found.add(value.strip())
            if row.get("type") == "thread.started":
                value = row.get("thread_id") or row.get("session_id")
                if isinstance(value, str) and value.strip():
                    found.add(value.strip())
        elif engine == "claude" and row.get("type") == "result":
            value = row.get("session_id")
            if isinstance(value, str) and value.strip():
                found.add(value.strip())
    return found


def text_session_ids(content, engine, mode=None):
    """Read the Codex CLI metadata block or a leading standalone header."""
    if engine == "claude" and mode in ("verify", "judge"):
        return set()  # Plain-text output is the model response, not CLI metadata.
    rows = content.splitlines()
    start = next((i for i, line in enumerate(rows) if line.strip()), None)
    if start is None:
        return set()

    if engine == "codex" and CODEX_BANNER.fullmatch(rows[start].strip()):
        if start + 1 >= len(rows) or not CODEX_SEPARATOR.fullmatch(rows[start + 1].strip()):
            return set()
        end = next((i for i in range(start + 2, len(rows))
                    if CODEX_SEPARATOR.fullmatch(rows[i].strip())), None)
        if end is None:
            return set()
        header_lines = rows[start + 2:end]
    else:
        header_lines = []
        for line in rows[start:]:
            if not SESSION_HEADER.fullmatch(line):
                break
            header_lines.append(line)
    return {match.group(1) for line in header_lines
            if (match := SESSION_HEADER.fullmatch(line))}


def extract_session_id(content, engine, mode=None):
    """Return (session_id, ambiguous) from structured metadata or a full header."""
    structured = structured_session_ids(content, engine, mode)
    if structured:
        return (next(iter(structured)), False) if len(structured) == 1 else (None, True)

    headers = text_session_ids(content, engine, mode)
    if len(headers) == 1:
        return next(iter(headers)), False
    if len(headers) > 1:
        return None, True
    return None, False


def root_dir():
    return Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()).resolve()


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def run_fields():
    phase = os.environ.get("RALPH_PHASE_NUM")
    if not phase:
        return {}
    cycle = os.environ.get("RALPH_PHASE_ATTEMPT", "")
    return {
        "ralph_phase": int(phase) if phase.isdigit() else phase,
        "ralph_cycle": int(cycle) if cycle.isdigit() else cycle,
        "ralph_mode": os.environ.get("RALPH_SESSION_MODE", ""),
        **({"ralph_run_id": os.environ["RALPH_RUN_ID"]} if os.environ.get("RALPH_RUN_ID") else {}),
    }


def append_snapshots(root, snapshots):
    if not snapshots:
        return
    folder = root / ".harness"
    folder.mkdir(exist_ok=True)
    target = folder / "tokens.jsonl"
    with (folder / "tokens.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # A Stop and the Ralph finalizer may observe the same transcript.
        def identity(row):
            return json.dumps({key: value for key, value in row.items() if key != "ts"}, sort_keys=True)
        existing = {identity(row) for row in lines(target)}
        with target.open("a", encoding="utf-8") as stream:
            for row in snapshots:
                key = identity(row)
                if key not in existing:
                    stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
                    existing.add(key)
        fcntl.flock(lock, fcntl.LOCK_UN)


def codex_file(session):
    base = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions"
    now = datetime.now(timezone.utc)
    recent = [base / (now - timedelta(days=days)).strftime("%Y/%m/%d") for days in range(3)]
    for folder in recent:
        for path in folder.glob(f"*-{session}.jsonl"):
            return path
    # Historical or late reconciliation: paid only when the recent lookup misses.
    for path in base.rglob(f"*-{session}.jsonl"):
        return path
    return None


def codex_snapshot(path, session, parent=None):
    model = "unknown"
    usage = None
    for row in lines(path):
        payload = row.get("payload") or {}
        if row.get("type") == "turn_context" and model == "unknown":
            model = payload.get("model") or model
        if row.get("type") == "event_msg" and payload.get("type") == "token_count":
            candidate = (payload.get("info") or {}).get("total_token_usage")
            if isinstance(candidate, dict) and isinstance(candidate.get("input_tokens"), int):
                usage = candidate
    if usage is None:
        return None
    row = {
        "ts": stamp(), "session_id": session, "vendor": "codex", "model": model,
        "input": usage.get("input_tokens", 0),
        "output": usage.get("output_tokens", 0),
        "cache_read": usage.get("cached_input_tokens", 0),
        "reasoning": usage.get("reasoning_output_tokens", 0),
        "total": usage.get("total_tokens", 0),
        **run_fields(),
    }
    if parent:
        row["parent"] = parent
    return row


def collect_codex(root, session):
    first = codex_file(session)
    if not first:
        return []
    found = []
    queue = [(first, session, None)]
    visited = set()
    base = first.parents[3] if len(first.parents) > 3 else first.parent
    # Children belong to the starting day or a later day if a run crosses UTC
    # midnight. Avoid rescanning unrelated historical transcripts at every Stop.
    try:
        started = datetime.strptime(first.name[8:18], "%Y-%m-%d")
        folders = [base / (started + timedelta(days=days)).strftime("%Y/%m/%d") for days in range(3)]
    except ValueError:
        folders = [first.parent]
    candidates = [p for folder in folders for p in folder.glob("rollout-*.jsonl")
                  if p.name[:27] >= first.name[:27]]
    while queue:
        path, ident, parent = queue.pop(0)
        if ident in visited:
            continue
        visited.add(ident)
        snapshot = codex_snapshot(path, ident, parent)
        if snapshot:
            found.append(snapshot)
        for child in candidates:
            if child == path or child in [item[0] for item in queue]:
                continue
            meta = next(lines(child), {})
            source = (meta.get("payload") or {}).get("source") or {}
            ancestor = ((source.get("subagent") or {}).get("thread_spawn") or {}).get("parent_thread_id") if isinstance(source, dict) else None
            if ancestor == ident:
                child_id = (meta.get("payload") or {}).get("id")
                if child_id and child_id not in visited:
                    queue.append((child, child_id, ident))
    append_snapshots(root, found)
    return found


def claude_snapshots(path, session, parent=None):
    groups = {}
    for row in lines(path):
        if row.get("type") != "assistant":
            continue
        msg = row.get("message") or {}
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        model = msg.get("model") or "unknown"
        counts = groups.setdefault(model, {"input": 0, "output": 0, "cache_creation": 0, "cache_read": 0, "messages": 0})
        counts["messages"] += 1
        for field, key in (("input", "input_tokens"), ("output", "output_tokens"),
                           ("cache_creation", "cache_creation_input_tokens"),
                           ("cache_read", "cache_read_input_tokens")):
            counts[field] += usage.get(key, 0) or 0
    result = []
    for model, counts in groups.items():
        row = {"ts": stamp(), "session_id": session, "vendor": "claude", "model": model,
               **counts, "total": counts["input"] + counts["output"], **run_fields()}
        if parent:
            row["parent"] = parent
        result.append(row)
    return result


def collect_claude(root, session, transcript):
    path = Path(transcript)
    if not path.is_file():
        return []
    result = claude_snapshots(path, session)
    for child in (path.with_suffix("") / "subagents").glob("agent-*.jsonl"):
        result.extend(claude_snapshots(child, child.stem.removeprefix("agent-"), session))
    append_snapshots(root, result)
    return result


def run_path(root, run_id):
    return root / ".harness" / "runs" / f"{run_id}.json"


def update_run(root, run_id, change):
    path = run_path(root, run_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with (path.parent / f"{run_id}.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(path.read_text()) if path.exists() else {"run_id": run_id, "attempts": []}
        change(data)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        temp.replace(path)
        fcntl.flock(lock, fcntl.LOCK_UN)


def summary(root, run_id, finished=False):
    def change(data):
        latest = {}
        for row in lines(root / ".harness" / "tokens.jsonl"):
            if row.get("ralph_run_id") != run_id:
                continue
            vendor = row.get("vendor")
            key = (vendor, row.get("session_id"), row.get("model") if vendor == "claude" else None)
            old = latest.get(key)
            # A delayed Stop can append an earlier snapshot after finalization.
            # Cumulative usage is monotonic within a session/model.
            def used(item):
                if vendor == "codex":
                    return item.get("input", 0) + item.get("output", 0)
                return sum(item.get(field, 0) for field in ("input", "output", "cache_read", "cache_creation"))
            if old is None or used(row) >= used(old):
                latest[key] = row
        counted = list(latest.values())
        fields = ("input", "output", "cache_read", "cache_creation")
        totals = {key: sum(row.get(key, 0) for row in counted) for key in fields}
        vendors = {vendor: {key: sum(row.get(key, 0) for row in counted if row.get("vendor") == vendor)
                            for key in fields} for vendor in ("codex", "claude")}
        roots = {row.get("session_id") for row in counted if not row.get("parent")}
        attempts = data.get("attempts", [])
        missing = [item for item in attempts if not item.get("session_id") or item["session_id"] not in roots]
        cycles = {(a.get("phase"), a.get("cycle")) for a in attempts if a.get("mode") == "impl" and (a.get("cycle") or 0) > 1}
        data["summary"] = {
            "status": "partial" if missing or (not finished and data.get("status") != "finished") else "complete",
            "sessions": len(roots), "subagents": len({r.get("session_id") for r in counted if r.get("parent")}),
            "correction_cycles": len(cycles), "counts": totals, "vendors": vendors,
            "codex_input_includes_cache_read": True,
            "claude_input_excludes_cache_creation_and_cache_read": True,
            "missing_attempts": len(missing),
        }
        if finished:
            data["status"] = "finished"
            data["finished_at"] = stamp()
    update_run(root, run_id, change)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("codex", "claude", "init", "record", "summary"))
    parser.add_argument("--root")
    parser.add_argument("--run-id")
    parser.add_argument("--plan")
    parser.add_argument("--version")
    parser.add_argument("--engine")
    parser.add_argument("--model")
    parser.add_argument("--effort")
    parser.add_argument("--verify-model")
    parser.add_argument("--verify-effort")
    parser.add_argument("--log")
    parser.add_argument("--rc", type=int)
    parser.add_argument("--finished", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve() if args.root else root_dir()
    run_id = args.run_id or os.environ.get("RALPH_RUN_ID", "")
    if args.action in ("codex", "claude"):
        payload = json.load(sys.stdin)
        if args.action == "codex" and payload.get("session_id"):
            collect_codex(root, payload["session_id"])
        if args.action == "claude" and payload.get("session_id") and payload.get("transcript_path"):
            collect_claude(root, payload["session_id"], payload["transcript_path"])
            if run_id and run_path(root, run_id).exists():
                def source(data):
                    data.setdefault("sources", {})[payload["session_id"]] = payload["transcript_path"]
                update_run(root, run_id, source)
        if run_id and run_path(root, run_id).exists():
            summary(root, run_id)
        return
    if not run_id:
        raise SystemExit("run id required")
    if args.action == "init":
        plan = Path(args.plan).resolve()
        def initialize(data):
            data.update({"created_at": stamp(), "plan": str(plan),
                         "plan_sha256": hashlib.sha256(plan.read_bytes()).hexdigest(),
                         "harness_version": args.version,
                         "harness_revision": os.environ.get("RALPH_HARNESS_REVISION") or None,
                         "engine": args.engine,
                         "models": {"impl": args.model or None, "verify": args.verify_model or None},
                         "efforts": {"impl": args.effort or None, "verify": args.verify_effort or None},
                         "status": "running"})
        update_run(root, run_id, initialize)
        summary(root, run_id)
    elif args.action == "record":
        log = Path(args.log)
        content = log.read_text(errors="replace") if log.exists() else ""
        log_digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
        ident, ambiguous = extract_session_id(content, args.engine, run_fields().get("ralph_mode"))
        if not ident and not ambiguous:
            candidates = {row.get("session_id") for row in lines(root / ".harness" / "tokens.jsonl")
                          if row.get("ralph_run_id") == run_id and not row.get("parent")
                          and row.get("ralph_phase") == run_fields().get("ralph_phase")
                          and row.get("ralph_cycle") == run_fields().get("ralph_cycle")
                          and row.get("ralph_mode") == run_fields().get("ralph_mode")}
            if len(candidates) == 1:
                ident = candidates.pop()
        if ident and args.engine == "codex":
            collect_codex(root, ident)
        if ident and args.engine == "claude":
            known = json.loads(run_path(root, run_id).read_text()).get("sources", {}).get(ident)
            transcript = Path(known) if known else None
            if not transcript:
                home = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "projects"
                transcript = next(home.rglob(f"{ident}.jsonl"), None) if home.exists() else None
            if transcript:
                collect_claude(root, ident, transcript)
        def add(data):
            attempt = {"phase": run_fields().get("ralph_phase"),
                "cycle": run_fields().get("ralph_cycle"), "mode": run_fields().get("ralph_mode"),
                "session_id": ident, "exit_code": args.rc, "log": str(log), "log_sha256": log_digest}
            if attempt not in data.setdefault("attempts", []):
                data["attempts"].append(attempt)
        update_run(root, run_id, add)
        summary(root, run_id)
    elif args.action == "summary":
        summary(root, run_id, args.finished)


if __name__ == "__main__":
    main()
