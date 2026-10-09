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
    await_condition(lambda: os.getpgid(pid) == pid, 'supervisor inherited the authorization process group')
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
            status_file = session/'status'
            assert status_file.read_text().strip().isdigit(), 'numeric exit status missing'
            assert status_file.stat().st_mode & 0o777 == 0o644, 'client cannot read root exit status'
            assert not (session/'status.tmp').exists(), 'exit status was not atomically published'
            os.kill(pid, signal.SIGTERM)
        else:
            os.kill(pid, getattr(signal, 'SIG' + mode.removeprefix('AUTH_')))
        await_condition(lambda: not session.exists(), 'session cleanup did not finish')
        while select.select([output], [], [], .1)[0]:
            chunk = os.read(output, 4096)
            if not chunk: break
            data += chunk
        marker = b'VPNMB_CONTROL_CLOSED' if mode.endswith('EOF') else b'VPNMB_SUPERVISOR_' + mode.removeprefix('AUTH_').encode()
        assert marker in data, 'termination origin was not delivered to the client'
        assert b'CLEANUP_DONE' in data, 'runtime was removed before disconnect cleanup completed'
        assert all(not alive(child) for child in children), 'session removed while a child was still running'
        assert not (root/'injected').exists(), 'quoted username escaped into the privileged command'
        print('PASS: script path with spaces, credential delivery and child cleanup via ' + mode + ' (unprivileged fixture)')
    finally:
        for fd in fds: os.close(fd)
        for worker in children + [pid]:
            try: os.kill(worker, signal.SIGTERM)
            except ProcessLookupError: pass
# Compare the original inherited group with the isolated session.
def check_authorization_group(detached):
    script = root/'session.sh'
    if not detached:
        script = root/'inherited-session.sh'
        source = (root/'session.sh').read_text()
        assert 'defined(POSIX::setsid()) or exit 125; ' in source
        script.write_text(source.replace('defined(POSIX::setsid()) or exit 125; ', ''))
    launcher = subprocess.Popen(['/bin/sh', '-c', '/bin/sh "$1"; exec /bin/sleep 120',
                                 'fixture-launcher', str(script)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    session = pathlib.Path(launcher.stdout.readline().decode().strip())
    pid = int((session/'supervisor').read_text())
    fds = []
    try:
        if detached: await_condition(lambda: os.getpgid(pid) == pid, 'session isolation did not complete')
        else: assert os.getpgid(pid) == launcher.pid
        for name in ['output','input','control']:
            fds.append(os.open(session/name, os.O_RDWR | os.O_NONBLOCK))
        os.write(fds[1], b'fixture-password\n')
        data = b''
        deadline = time.monotonic()+5
        while b'Connected as fixture' not in data and time.monotonic()<deadline:
            if select.select([fds[0]], [], [], .1)[0]: data += os.read(fds[0],4096)
        assert b'Connected as fixture' in data
        os.killpg(launcher.pid, signal.SIGTERM)
        launcher.wait(timeout=5)
        if detached:
            time.sleep(.3)
            assert alive(pid) and not (session/'status').exists(), 'authorization group retirement stopped VPN'
            os.close(fds.pop())
            await_condition(lambda: (session/'status').exists(), 'detached session ignored client control EOF')
            os.kill(pid, signal.SIGTERM)
        else:
            await_condition(lambda: not alive(pid), 'control experiment did not reproduce group termination')
        await_condition(lambda: not session.exists(), 'session failed to clean up')
        print('PASS: isolated VPN survives authorization group cleanup and still obeys EOF' if detached
              else 'PASS: original inherited-group behavior reproduces unintended VPN termination')
    finally:
        for fd in fds: os.close(fd)
        if launcher.poll() is None:
            os.killpg(launcher.pid,signal.SIGTERM); launcher.wait(timeout=5)
        try: os.kill(pid,signal.SIGTERM)
        except ProcessLookupError: pass
check_authorization_group(False)
check_authorization_group(True)

PY

python3 tests/verify-system-command-fixtures.py "$TEST_DIR"

python3 tests/RuntimePackagingTests.py
