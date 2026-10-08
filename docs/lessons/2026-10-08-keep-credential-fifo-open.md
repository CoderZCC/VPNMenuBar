---
title: Keep a credential FIFO open until its reader is attached
date: 2026-10-08
tags: [macos, ipc, security, lifecycle]
severity: high
---

## Symptom

The nonprivileged supervisor integration test failed with `AssertionError: supervisor output did not arrive`. The fake VPN waited for its first credential line despite a successful client write.

## Root Cause

The client opened a FIFO RDWR, wrote a line and closed it before the supervisor's child opened the read end. Once all descriptors closed, the kernel discarded the pipe and buffered bytes. Creating a named FIFO does not make its contents durable.

## Wrong Path

Closing stdin immediately works with a Process-owned anonymous pipe whose child is already attached. Applying that pattern to a newly authorized, independently scheduled FIFO reader is racy. A successful write alone does not prove delivery.

## Fix

`OpenConnectProcess.start` retains the input descriptor until session stop and allows only one credential submission. OpenConnect reads newline-terminated password input. A separate control FIFO provides lifecycle/EOF cancellation. Credentials remain off regular files, AppleScript and argv.

## Prevention

- Code: keep input alive and bind cancellation to the dedicated control channel.
- Process: generate TOTP after authorization, since a prompt can outlive its validity window.
- Detection: `bash tests/run-security-tests.sh` runs real FIFOs and the actual supervisor shell using a non-root fake VPN; it asserts credential delivery and EOF-driven child termination. This does not replace privileged signed-App acceptance.

## Review follow-up: shell boundaries and supervisor teardown

OpenConnect evaluates its `--script` value with `sh -c`. Quoting the outer argv alone loses protection at that second shell boundary, so a path containing `Application Support` fails with exit 127. Quote the script value before quoting the full invocation. The fixture now executes that argument through a shell instead of ignoring it.

A supervisor EXIT trap must terminate and wait for its owned VPN child before deleting the session directory. Removing only the directory leaves the VPN alive while client liveness checks report disconnected. The shared cleanup also reaps control/watchdog/timer workers; ownership checks prevent signaling a reused PID. If the VPN does not exit after TERM, retain the session and supervisor rather than falsely reporting successful cleanup. An uncatchable SIGKILL is outside shell-trap guarantees.

Regression coverage includes control EOF, supervisor TERM and HUP, asserting that the session is removed only after its children stop. These are unprivileged fixtures, not real VPN teardown or signed-App acceptance.

## References

- `VPNMenuBar/Core/OpenConnectProcess.swift`
- `tests/SecurityHardeningTests.swift`
- `tests/run-security-tests.sh`
