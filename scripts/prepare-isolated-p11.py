#!/usr/bin/env python3
"""Build the pinned p11-kit in build/, without installing it on the system."""
import hashlib
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parent.parent
work = root/'build/p11-isolated'; work.mkdir(parents=True, exist_ok=True)
archives = [
    ('source.tar.xz', 'https://github.com/p11-glue/p11-kit/releases/download/0.26.5/p11-kit-0.26.5.tar.xz',
     'f2cc09111e44bf3fea58f023180b33acea90aa82d042d6fbb623fbc5ba033bb7', 'p11-kit-0.26.5'),
    ('meson.tar.gz', 'https://github.com/mesonbuild/meson/releases/download/1.9.1/meson-1.9.1.tar.gz',
     '4e076606f2afff7881d195574bddcd8d89286f35a17b4977a216f535dc0c74ac', 'meson-1.9.1'),
]
for name, url, digest, directory in archives:
    archive = work/name
    if not archive.exists():
        subprocess.run(['curl','-fL','--max-time','120',url,'-o',str(archive)],check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Source digest mismatch: '+name)
    if not (work/directory).exists():
        with tarfile.open(archive) as tar: tar.extractall(work, filter='data')
meson = [sys.executable, str(work/'meson-1.9.1/meson.py')]
compiled = Path(os.environ.get('P11_BUILD_DIRECTORY', str(work/'compiled')))
prefix = os.environ.get('P11_INSTALL_PREFIX', '/var/empty/vpnmenubar')
args = ['setup',str(compiled),str(work/'p11-kit-0.26.5'), '--prefix='+prefix]
if target := os.environ.get('MACOSX_DEPLOYMENT_TARGET'):
    args += ['-Dc_args=-mmacosx-version-min='+target, '-Dc_link_args=-mmacosx-version-min='+target]
if compiled.exists(): args.append('--reconfigure')
for option in ['system_config','user_config','module_config','module_path']:
    args.append('-D'+option+'=/var/empty/vpnmenubar')
args += ['-Dtrust_module=disabled','-Dlibffi=disabled','-Dsystemd=disabled','-Dnls=false','-Dman=false','-Dgtk_doc=false','-Dtest=true']
subprocess.run(meson+args,check=True)
subprocess.run(meson+['compile','-C',str(compiled)],check=True)
subprocess.run(meson+['test','-C',str(compiled),'--print-errorlogs','--num-processes','4','--timeout-multiplier','3'],check=True)

if os.environ.get('P11_INSTALL_PREFIX'):
    staged = compiled/'staged-install'
    subprocess.run(meson+['install','-C',str(compiled),'--destdir',str(staged)],check=True)
    shutil.copytree(staged/prefix.lstrip('/'), prefix, dirs_exist_ok=True)
