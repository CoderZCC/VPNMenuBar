---
title: Audit API availability when lowering the macOS deployment target
date: 2026-10-08
tags: [macos, build, compatibility]
severity: high
---

## Symptom

A library built with `-mmacosx-version-min=13.0` still emitted: `'strchrnul' is only available on macOS 15.4 or newer [-Wunguarded-availability-new]`.

## Root Cause

Autoconf probes execute on the build host. On macOS 26, libidn2 detected the host's newer libc function and selected it despite the older deployment target. A Mach-O minimum OS value describes the target, but does not prove every executed API exists there.

## Wrong Path

Only lowering Info.plist or Mach-O version declarations would leave newer runtime dependencies and API calls intact. Even a source rebuild needs availability diagnostics and old-system testing.

## Fix

Build all dependencies from pinned sources with an explicit deployment target. Set `ac_cv_func_strchrnul=no` and `gl_cv_onwards_func_strchrnul=future` so gnulib uses its renamed compatibility implementation even when the SDK declares the newer function; treat unguarded availability warnings as errors. Reject packaged Mach-O files with minimum OS values above the intended target.

## Prevention

- Code-level: keep the availability warning and packaging minimum-version gate in the build recipe.
- Process-level: validate on the oldest supported macOS before claiming compatibility.
- Detection-level: inspect compilation warnings and undefined imports, not just `vtool` output.

## References

- `scripts/build-compatible-runtime.py`
- `scripts/prepare-bundled-runtime.py`
