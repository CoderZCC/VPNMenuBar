# Reset inherited signal dispositions and masks before starting the supervisor

Real system authorization passed runtime validation, but the VPN handshake timed out and supervisor shells remained alive. The child launch was delayed by the startup watchdog's full 60-second interval. Ordinary unprivileged FIFO tests passed.

An administrator-authorized `do shell script` probe reported `TERM=IGNORE` and a second probe reported `TERM_BLOCKED=1`. A shell entered with SIGTERM ignored cannot restore it using a shell trap. As a result, TERM-based watchdog cancellation and child cleanup did not behave like the unprivileged fixtures.

The fixed launcher uses the system `/usr/bin/perl` to restore default HUP, INT, TERM and PIPE dispositions and clear the inherited signal mask with POSIX sigprocmask before execing the supervisor shell. The PID remains stable across exec. Resetting the disposition alone did not fix the real failure; both disposition and mask must be reset.

`tests/run-security-tests.sh` now runs both EOF and TERM teardown cases with SIGTERM deliberately ignored and blocked in the launching parent. Both must deliver credentials promptly, stop the child and remove the session. Keep this regression: passing shell syntax checks or launching from a terminal does not reproduce the authorization launcher's process state.

The reset probe and synthetic process tests do not by themselves prove successful gateway authentication. Report actual VPN acceptance separately.

After resetting signals, a standalone authorized connection succeeded, but the installed application still reproduced a full 60-second watchdog wait. Session timestamps showed attachment immediately after supervisor creation and child creation exactly 60 seconds later. Do not use the standalone success to claim installed-app acceptance. Normal attachment now ends the watchdog through a bounded one-second polling loop, rather than relying on signal cancellation racing shell trap setup. Signal reset remains necessary for teardown. Verify the installed application's connect and disconnect paths separately.
