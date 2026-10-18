# iOS 27 background execution spike

This is an isolated native iOS experiment for a JavaScript agent that changes its own source and resumes from a checkpoint. It compares `BGContinuedProcessingTask` with `LongRunningIntent`, including an ordinary App Intent as a control.

The deterministic JavaScript workload requires no model credentials or network service. It does not integrate Pi Durable. JSON checkpoints isolate runtime replacement and persistence from the background APIs under test.

## Physical iPhone results — collected 18 October 2026

Tested on an iPhone 17 Pro Max running iOS 27.2 (24B5110a), with a Release build signed by Xcode 27.1 (27A9275), deployed over Wi-Fi. Both background APIs execute on this device, including the in-app intent button that failed on Simulator.

| Experiment | Device journal observation |
| --- | --- |
| Direct `BGContinuedProcessingTask`, `.fail`, with progress | Admitted; completed 600 steps in **615.926 s**. 589 ticks and the completion callback occurred in the background. |
| `LongRunningIntent`, in-app button, with progress | Completed 600 steps in **621.658 s**. 589 ticks and intent completion occurred in the background. |
| `LongRunningIntent`, progress updates disabled | Journal confirms `reportsProgress=false`. Cancelled after **58.187 s**, with reason `IntentCancellationReason.unknown`; 55 ticks, including 44 background ticks. This single observation does not establish a fixed timeout or prove why it was cancelled. |
| Local source rewrite and runtime replacement | Both completed 600-step runs changed generation 1 to generation 2 at step 5, restored the state, and then executed the changed scoring behavior. The reload was in the foreground; subsequent work continued in the background. |
| Locked-device observation, separate intent run | 53 ticks (steps 46–98) were recorded with protected data unavailable, spanning 53.642 s. The test later failed when it attempted foreground activation while the phone was locked; the workload's completion was not observed. |
| Process termination and relaunch | New PID 5015 restored generation 2 at step 8 from PID 5012, then completed step 12. `verify-recovery.py` passes. This was a foreground recovery control. |
| Direct `.fail` and `.queue`, short admission probes | Both reached their actual background-task handler. The observation windows ended after approximately 56 s; these are admission checks, not expiration measurements. |
| System Shortcuts invocation on the phone | Not validated: the app was absent from the Shortcuts catalog used by the UI test. No workload started. |

These completed runs establish more than ten minutes of observed execution for a finite, user-started job. They do not establish the maximum lifetime, unattended relaunch, or continuous 24/7 availability. Neither ten-minute run recorded protected-data unavailability. A focused `testReloadWhileBackgroundedOnDevice` test has also been added to press Home before step 5; its background reload has not yet been validated on the phone. Its first attempt waited for unlock, then failed before any test case began with “Lost connection to testmanagerd”; the retry could not find the device destination. CoreDevice now lists the phone as unavailable. These launch failures provide no workload evidence.

The workload is a small JavaScript step approximately once a second, with file I/O and state restoration. It does not test model inference, HTTP streaming, battery drain, thermal pressure, low power mode, memory pressure, or cancellation by the user. Source and checkpoint crash consistency remains a production concern.

Device evidence: `results/device-continued-10m-summary.json`, `results/device-long-intent-10m-summary.json`, `results/device-no-progress-valid-summary.json`, their matching raw journals and `.xcresult` bundles, and `results/device-partial-events.jsonl`. Open `device-report.html` for the physical-device comparison. Simulator evidence below is kept separate.

## Build and reproduce

Requires Xcode with the iOS 27 SDK/runtime and XcodeGen. The project is configured for unsigned simulator builds.

```sh
xcrun simctl create 'Agent Background Spike iOS 27' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0
# Substitute the returned identifier:
xcrun simctl boot SIMULATOR_UDID
bash run.sh SIMULATOR_UDID
```

The full UI suite includes a ten-minute workload and several observation windows. To run only one experiment, use `xcodebuild` with `-only-testing:BackgroundSpikeUITests/ProbeTests/TEST_NAME`. Tests are named in `UITests/ProbeTests.swift`.

The suite's `testProcessRecovery` starts work, terminates the app process, relaunches it, and taps Resume. Verify its journal evidence with:

```sh
python3 verify-recovery.py results/YOUR_RUN/events.jsonl
```

`display-probe.py SIMULATOR_UDID` can run alongside the ten-minute experiment. It turns the simulator display off after step 60 and back on after step 120. This does **not** simulate a passcode lock, protected-data unavailability, or physical device sleep.

The display experiment left the simulator showing a black screen despite reporting its display power on. Restarting the dedicated simulator and pressing Home restored UI testing. Recovery uses native UI buttons: an earlier `simctl openurl` approach was blocked by the system's “Open in Agent Background Spike?” confirmation.

## What executes

The app has foreground buttons for direct background-task submission and an in-app intent button. Its App Shortcuts expose the system invocation path, a ten-minute run, a run without progress reports, and an ordinary App Intent control.

The JavaScript starts with generation 1 and increments a counter and score. At step 5 it reads and modifies its own executable source through a native file bridge. The host persists the state, replaces its `JSContext`, loads generation 2 from the edited file, and restores the checkpoint. Generation 2 adds ten to the score per step instead of one. Native assertions verify both the preserved counter and changed behavior.

`Documents/events.jsonl` records timestamps, process IDs, `UIApplication` state, protected-data availability, source generation, steps, scores, API errors, and cancellation callbacks. Each record is flushed. `agent.js` and `checkpoint.json` remain in the same directory. `analyze.py` verifies the handover and summarizes measurements.

Each scenario starts fresh unless explicitly using **Resume persisted JavaScript**. Run one scenario at a time. The app is an experiment, not a production agent host or a general JavaScript sandbox.

Source and checkpoint files are written separately. The process-recovery test terminates after a completed checkpoint; it does not inject a crash between the source write and checkpoint write. A production host needs consistent version activation across that boundary.

## Simulator interpretation rules

- A successful XCTest observation is not a claim that the OS admitted background work. Read the app journal and system logs.
- Direct continued-processing submission on the tested simulator returns `BGTaskSchedulerErrorDomain` code 1: “BGTaskScheduler is not available on this platform.” Both `.fail` and `.queue` are tested. There is no fallback to foreground execution in this code path.
- Invoking `LongRunningIntent` from the in-app intent button reaches `perform()` but fails before the operation with `LNContextErrorDomain` code 2004. The system log says “No IntentContext available.” Invoke it through **Shortcuts → Library → Apps → Agent Background Spike** for the tested system context.
- The system-invoked intent executes in the background. However, Apple's framework logs that its underlying background-task submission failed because the scheduler is unavailable on Simulator. Its observed execution and progress timeouts therefore do not establish a physical iPhone's background-resource allowance.
- A duration test that finishes establishes an observed duration, not a maximum lifetime.
- Display-off simulation does not prove locked-iPhone behavior. Battery, thermal pressure, memory pressure, secure lock, actual networking, and real model latency remain device tests.

## Simulator measurements — 17 October 2026

| Experiment | Observation |
| --- | --- |
| Continued-processing `.fail` / `.queue` | Both rejected with scheduler-unavailable error 1; no handler execution |
| LongRunningIntent, in-app button | Context error 2004; no operation execution |
| LongRunningIntent, system Shortcuts with progress | Completed 120 steps in 126.679 s and 600 steps in 633.616 s; every tick was in the background |
| LongRunningIntent without progress updates | Timeout cancellation at 29.982 s, after 28 ticks |
| Ordinary App Intent | System-reported 30.00 s timeout; only 28 ticks observed |
| Simulator display off | Work advanced from step 61 to 120 during a 62.2 s interval |
| Process termination and relaunch | New PID restored generation 2 at step 8 and completed step 12 with score 75 |

The successful long-running intents still logged failure to obtain their underlying background-task request. These measurements establish simulator behavior, not a physical iPhone's maximum runtime or 24/7 availability.

## Evidence

Open `report.html` for the simulator report. `results/final-summary.json` contains the simulator measurements, `results/validation.json` records their evidence checks, and `results/environment.json` records the simulator environment and app source hashes at that time. The app and test harness have since changed for device testing; those older hashes do not describe the latest source. Raw journals, targeted system logs, screenshots, and `.xcresult` bundles are kept under `results/`.

Nine API/control/recovery scenarios completed across the four result bundles listed in `validation.json`. Additional discovery and harness-debugging attempts remain in the directory; they are not evidence of API runtime limits. The quality-delta check could not compare this new scratch project because it has no Git HEAD or previous baseline; the limitation is preserved in `results/quality-delta.txt`.

Relevant Apple documentation:

- [Continued background processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- [LongRunningIntent](https://developer.apple.com/documentation/appintents/longrunningintent)
- [Scheduler unavailable error](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/error/code/unavailable)

The installed SDK's `BackgroundTasks.framework/Headers/BGTaskScheduler.h` explicitly lists Simulator as an unsupported background-processing platform. The experiment verifies the actual rejection instead of injecting a simulated task launch.
