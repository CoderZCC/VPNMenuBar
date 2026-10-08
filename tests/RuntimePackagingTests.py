import hashlib
import importlib.util
from pathlib import Path
import os
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('runtime_package', Path('scripts/runtime-package.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    pairs = []
    for name in ['runtime', 'notices', 'manifest']:
        old = root/name; old.write_text('old-'+name)
        new = root/(name+'-new'); new.write_text('new-'+name)
        pairs.append((new, old))
    backup = root/'backup'; backup.mkdir()
    replace = os.replace
    count = 0
    def failure(source, destination):
        global count
        count += 1
        if count == 4: raise OSError('simulated publication failure')
        return replace(source, destination)
    try:
        with patch.object(module.os, 'replace', side_effect=failure): module.publish(pairs, backup)
    except OSError: pass
    else: raise AssertionError('Failure injection did not trigger')
    for _, target in pairs: assert target.read_text() == 'old-'+target.name
    for source, target in pairs: source.write_text('new-'+target.name)
    module.publish(pairs, backup)
    for _, target in pairs: assert target.read_text() == 'new-'+target.name
    print('PASS: failed publication restores all old files; subsequent publication succeeds')

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    runtime = root/'VPNMenuBar/Resources/BundledRuntime'; runtime.mkdir(parents=True)
    manifest = root/'VPNMenuBar/Dependencies/BundledRuntimeFiles.swift'; manifest.parent.mkdir()
    entries = []
    for name in ['openconnect','vpnc-script--no-dns']:
        p = runtime/name; p.write_bytes(b'fixture'); p.chmod(0o755)
        entries.append('"'+name+'": "'+hashlib.sha256(p.read_bytes()).hexdigest()+'"')
    manifest.write_text('\n'.join(entries))
    module.verify(root)
    def rejected():
        try: module.verify(root)
        except RuntimeError: return
        raise AssertionError('Invalid package accepted')
    entry = runtime/'openconnect'; entry.write_bytes(b'changed'); rejected(); entry.write_bytes(b'fixture')
    stale = runtime/'obsolete.dylib'; stale.touch(); rejected(); stale.unlink()
    lock = root/'build/runtime-packaging.lock'; lock.mkdir(parents=True); rejected(); lock.rmdir()
    module.verify(root)
    print('PASS: build verification rejects mismatched hashes, stale files and interrupted packaging')
