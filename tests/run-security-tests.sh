#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc VPNMenuBar/Config/*.swift VPNMenuBar/Dependencies/*.swift VPNMenuBar/Core/*.swift \
  VPNMenuBar/Util/AppLogger.swift tests/SecurityHardeningTests.swift -o "$TEST_DIR/security-tests"
"$TEST_DIR/security-tests" "$TEST_DIR"
/bin/sh -n "$TEST_DIR/validate.sh"
/bin/sh -n "$TEST_DIR/dns.sh"
/bin/sh -n "$TEST_DIR/revoke.sh"
/bin/sh -n "$TEST_DIR/session.sh"
python3 - "$TEST_DIR" <<'PY'
import os, pathlib, subprocess, sys, time, select, signal
root = pathlib.Path(sys.argv[1])
def alive(pid):
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')

def await_condition(predicate, reason):
    for _ in range(100):
        if predicate(): return
        time.sleep(.05)
    raise AssertionError(reason)

for mode in ['EOF', 'TERM', 'HUP', 'AUTH_EOF', 'AUTH_TERM']:
    def authorization_signals():
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    result = subprocess.run(['/bin/sh', str(root/'session.sh')], capture_output=True, text=True, timeout=10, check=True,
                            preexec_fn=authorization_signals if mode.startswith('AUTH_') else None)
    session = pathlib.Path(result.stdout.strip())
    assert session.parent == root
    pid = int((session/'supervisor').read_text())
    fds = []
    children = []
    try:
        output = os.open(session/'output', os.O_RDWR | os.O_NONBLOCK)
        stdin = os.open(session/'input', os.O_RDWR | os.O_NONBLOCK)
        control = os.open(session/'control', os.O_RDWR | os.O_NONBLOCK)
        fds.extend([output, stdin, control])
        os.write(stdin, b'fixture-password\n')
        data = b''
        deadline = time.monotonic() + 5
        while b'Connected as fixture' not in data and time.monotonic() < deadline:
            if select.select([output], [], [], .1)[0]: data += os.read(output, 4096)
        assert b'SCRIPT_OK' in data, 'script path with spaces was not executed'
        assert b'Connected as fixture' in data, 'supervisor output did not arrive'
        rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True).splitlines()
        children = [int(row.split()[0]) for row in rows if int(row.split()[1]) == pid]
        assert children, 'fixture child was not observed'
        if mode.endswith('EOF'):
            os.close(control); fds.remove(control)
            await_condition(lambda: (session/'status').exists(), 'closing control did not stop the child')
            os.kill(pid, signal.SIGTERM)
        else:
            os.kill(pid, getattr(signal, 'SIG' + mode.removeprefix('AUTH_')))
        await_condition(lambda: not session.exists(), 'session cleanup did not finish')
        assert all(not alive(child) for child in children), 'session removed while a child was still running'
        assert not (root/'injected').exists(), 'quoted username escaped into the privileged command'
        print('PASS: script path with spaces, credential delivery and child cleanup via ' + mode + ' (unprivileged fixture)')
    finally:
        for fd in fds: os.close(fd)
        for worker in children + [pid]:
            try: os.kill(worker, signal.SIGTERM)
            except ProcessLookupError: pass
PY

python3 tests/verify-system-command-fixtures.py "$TEST_DIR"

python3 tests/RuntimePackagingTests.py
