"""Verify persisted evidence from the testProcessRecovery UI experiment."""
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
starts = [r for r in rows if r["event"] == "work_started"]
resumed = next(r for r in reversed(starts) if r["resume"])
previous = next(r for r in reversed(starts) if r["uptime"] < resumed["uptime"])
saved = [r for r in rows if r["pid"] == previous["pid"] and r["event"] == "tick"
         and previous["uptime"] <= r["uptime"] < resumed["uptime"]][-1]
restored = next(r for r in rows if r["event"] == "runtime_loaded" and r["pid"] == resumed["pid"]
                and r["uptime"] >= resumed["uptime"])
completed = next(r for r in rows if r["event"] == "work_completed" and r["pid"] == resumed["pid"]
                 and r["uptime"] >= resumed["uptime"])
final_tick = next(r for r in rows if r["event"] == "tick" and r["pid"] == resumed["pid"]
                  and r["steps"] == 12 and r["uptime"] >= resumed["uptime"])
assert saved["generation"] == restored["generation"] == completed["generation"] == 2
assert saved["pid"] != restored["pid"]
assert 5 < saved["steps"] == restored["steps"] < 12
assert completed["steps"] == 12 and final_tick["score"] == 75
print(json.dumps({"passed": True, "old_pid": saved["pid"], "new_pid": restored["pid"],
                  "restored_step": restored["steps"], "restored_generation": restored["generation"],
                  "completed_step": completed["steps"]}, indent=2))
