"""Turn only the simulator display off during the long run; this is not secure device locking."""
import json
import subprocess
import sys
import time
from pathlib import Path

device = sys.argv[1]
events = []


def marker(event, **fields):
    row = {"event": event, "host_wall": time.time(), **fields}
    events.append(row)
    Path("results/display-observations.json").write_text(json.dumps(events, indent=2))
    print(json.dumps(row), flush=True)


def wait_step(step):
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        container = subprocess.check_output(["xcrun", "simctl", "get_app_container", device,
                                            "dev.local.agent.BackgroundSpike", "data"], text=True).strip()
        rows = [json.loads(line) for line in (Path(container) / "Documents/events.jsonl").read_text().splitlines()]
        starts = [r for r in rows if r["event"] == "work_started" and r["seconds"] == 600]
        if starts:
            run = starts[-1]
            ticks = [r for r in rows if r["event"] == "tick" and r["pid"] == run["pid"]
                     and r["uptime"] >= run["uptime"] and r["steps"] >= step]
            if ticks:
                return ticks[-1]
        time.sleep(2)
    raise TimeoutError(f"Long run did not reach step {step}")


before = wait_step(60)
try:
    subprocess.run(["xcrun", "simctl", "io", device, "screenConfig", "power", "off"], check=True)
    marker("display_off", tick=before)
    after = wait_step(120)
    marker("work_continued_with_display_off", tick=after)
finally:
    subprocess.run(["xcrun", "simctl", "io", device, "screenConfig", "power", "on"], check=True)
    marker("display_on")
