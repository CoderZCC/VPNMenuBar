# Detach the VPN supervisor from the authtrampoline process group

Installed 0.2.25–0.2.27 builds dropped the VPN every 4–21 minutes. App logs showed the supervisor receiving SIGTERM (`supervisor_term`) followed by OpenConnect exiting; network was reachable and the server had not terminated the session.

`do shell script ... with administrator privileges` runs commands under `/System/Library/Frameworks/Security.framework/authtrampoline`, a launchd daemon (`com.apple.security.authtrampoline`). The backgrounded supervisor stayed in its process group (pgid = authtrampoline PID) even after reparenting to launchd. authtrampoline lingers idle and is later killed by the kernel (`memorystatus: killing (idle) authtrampoline ... due to idle-exit`); launchd then marks the service inactive and terminates the job's remaining process group. The idle-exit time depends on memory pressure, so disconnects looked random.

Evidence: on 2026-10-09 all eight disconnects occurred 0.3–3 s after a matching `killing (idle) authtrampoline` kernel line. Find them with `/usr/bin/log show --start ... --predicate 'eventMessage CONTAINS[c] "authtrampoline"'`. In zsh, plain `log` is a shell builtin; use `/usr/bin/log`. `ps -o pgid` on a live session shows the group leader directly.

The launcher now calls `POSIX::setsid()` before exec, giving the supervisor its own session and process group. Nothing in the client signals by process group; control EOF and explicit signals still stop the session. `tests/run-security-tests.sh` reproduces group termination with the old launcher and verifies the detached supervisor survives it.

Unprivileged fixtures do not prove the real daemon's reaping behavior. Accept the fix only after an installed build keeps a session alive across a logged authtrampoline idle-exit. Installed 0.2.28 passed this on 2026-10-09 (macOS 26.1): the session's authtrampoline was idle-killed nine minutes after connect, and OpenConnect, in its own process group, kept running with no disconnect logged.
