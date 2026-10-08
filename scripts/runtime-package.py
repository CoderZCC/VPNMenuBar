"""Transactional publication and build-time validation of the runtime payload."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys

def publish(pairs, backup):
    """Rollback every published path if any rename fails; no live file is edited."""
    saved, installed = [], []
    try:
        for index, (source, target) in enumerate(pairs):
            if target.exists():
                old = backup / str(index)
                os.replace(target, old)
                saved.append((old, target))
            os.replace(source, target)
            installed.append(target)
    except BaseException:
        for target in reversed(installed):
            if target.is_dir(): shutil.rmtree(target)
            else: target.unlink()
        for old, target in reversed(saved): os.replace(old, target)
        raise

def verify(root):
    if (root/'build/runtime-packaging.lock').exists():
        raise RuntimeError('Runtime packaging is active or was interrupted; rerun packaging before building')
    manifest = root/'VPNMenuBar/Dependencies/BundledRuntimeFiles.swift'
    text = manifest.read_text()
    hashes = dict(re.findall(r'"([^"\n]+)": "([0-9a-f]{64})"', text))
    if not {'openconnect','vpnc-script--no-dns'}.issubset(hashes):
        raise RuntimeError('Incomplete runtime manifest')
    directory = root/'VPNMenuBar/Resources/BundledRuntime'
    if {p.name for p in directory.iterdir()} != set(hashes):
        raise RuntimeError('Runtime file inventory differs from compiled manifest')
    for name, digest in hashes.items():
        p = directory/name
        if p.is_symlink() or not p.is_file() or not os.access(p, os.X_OK):
            raise RuntimeError('Invalid runtime file: '+name)
        if hashlib.sha256(p.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Runtime hash mismatch: '+name)
    if manifest.read_text() != text or (root/'build/runtime-packaging.lock').exists():
        raise RuntimeError('Runtime changed during verification')

if __name__ == '__main__':
    verify(Path(sys.argv[1]).resolve())
    print('Bundled runtime inventory and hashes verified')
