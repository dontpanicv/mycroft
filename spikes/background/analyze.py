"""Summarize persisted observations; a rejected request is not a runtime-limit result."""
import json
import sys
from pathlib import Path


def summarize(rows):
    submissions = []
    intent = []
    runs = []
    for row in rows:
        event = row["event"]
        if event == "continued_submit":
            submissions.append({"strategy": row["strategy"], "uptime": row["uptime"], "pid": row["pid"]})
        elif event == "continued_submission_error":
            request = next(r for r in reversed(submissions) if r["pid"] == row["pid"])
            request.update(error=row["description"], domain=row["domain"], code=row["code"],
                           response_ms=round((row["uptime"] - request["uptime"]) * 1000, 2))
        elif event.startswith("intent_"):
            intent.append(row)
            if event == "intent_cancelled":
                run = next((r for r in reversed(runs) if r["pid"] == row["pid"]), None)
                if run is not None:
                    run["cancel_reason"] = row["reason"]
                    run["cancel_after_seconds"] = round(row["uptime"] - run["start"], 3)
        elif event == "work_started":
            runs.append({"mode": row["mode"], "pid": row["pid"], "requested_steps": row["seconds"],
                         "reports_progress": row["reportsProgress"], "resume": row["resume"],
                         "start": row["uptime"], "ticks": [], "reloads": [], "completed": False})
        elif event in ("tick", "reload_verified", "work_completed"):
            run = next(r for r in reversed(runs) if r["pid"] == row["pid"])
            if event == "tick":
                run["ticks"].append(row)
            elif event == "reload_verified":
                run["reloads"].append(row)
            else:
                run["completed"] = True
    for run in runs:
        ticks = run.pop("ticks")
        run["observed_ticks"] = len(ticks)
        run["background_ticks"] = sum(t["appState"] == 2 for t in ticks)
        run["last_step"] = ticks[-1]["steps"] if ticks else None
        run["last_generation"] = ticks[-1]["generation"] if ticks else None
        run["observed_seconds"] = round(ticks[-1]["uptime"] - run["start"], 3) if ticks else 0
        run["max_tick_gap_seconds"] = round(max((b["uptime"] - a["uptime"] for a, b in zip(ticks, ticks[1:])), default=0), 3)
    return {"continued_submissions": submissions, "intent_events": intent, "work_runs": runs}


def validate_control(rows):
    """Check behavior changed after reload, retaining the previous counter and score."""
    reloads = [r for r in rows if r["event"] == "reload_verified"]
    assert reloads, "No successful local JavaScript reload was observed"
    for reloaded in reloads:
        following = [r for r in rows if r["pid"] == reloaded["pid"] and r["event"] == "tick"
                     and r["uptime"] > reloaded["uptime"]]
        assert following, "No work after reload"
        first = following[0]
        assert first["steps"] == reloaded["steps"] + 1, "Counter did not resume"
        assert first["generation"] == 2, "New source did not execute"
        assert first["score"] == 15, "New source should add ten to the saved score of five"


if __name__ == "__main__":
    rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
    if len(sys.argv) > 2:
        rows = [row for row in rows if row["wall"] >= float(sys.argv[2])]
    validate_control(rows)
    print(json.dumps(summarize(rows), indent=2))
