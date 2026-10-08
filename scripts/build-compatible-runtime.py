#!/usr/bin/env python3
"""Build pinned runtime sources locally for macOS 13; no system installation."""
import hashlib, json, os, pathlib, shutil, subprocess, tarfile, sys, platform
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('This build recipe currently requires an Apple Silicon Mac')
required = ['curl','make','autoreconf','automake','glibtool','glibtoolize','pkg-config','ninja']
missing = [tool for tool in required if not shutil.which(tool)]
if missing: raise SystemExit('Missing build tools: '+', '.join(missing))
root = pathlib.Path(__file__).resolve().parent.parent
work = root/'build/runtime-macos13'
prefix = work/'prefix'
work.mkdir(parents=True, exist_ok=True)
prefix.mkdir(exist_ok=True)
env = os.environ.copy()
env.update(MACOSX_DEPLOYMENT_TARGET='13.0', CC='/usr/bin/clang', CXX='/usr/bin/clang++',
           CFLAGS='-O2 -mmacosx-version-min=13.0 -Werror=unguarded-availability-new', CXXFLAGS='-O2 -mmacosx-version-min=13.0 -Werror=unguarded-availability-new',
           CPPFLAGS=f'-I{prefix}/include', LDFLAGS=f'-L{prefix}/lib -mmacosx-version-min=13.0',
           PKG_CONFIG_LIBDIR=f'{prefix}/lib/pkgconfig', PKG_CONFIG_PATH='',
           ac_cv_func_strchrnul='no', gl_cv_onwards_func_strchrnul='future', gl_cv_func_strchrnul_works='no', am_cv_func_iconv_works='yes', LIBTOOLIZE=shutil.which('glibtoolize'))
# GNU makefiles require GNU libtool, not Apple's unrelated libtool command.
bin_dir = work/'tools'; bin_dir.mkdir(exist_ok=True)
link = bin_dir/'libtool'
if not link.exists(): link.symlink_to(shutil.which('glibtool'))
env['PATH'] = str(bin_dir)+':'+env['PATH']
sdk = subprocess.check_output(['xcrun','--show-sdk-path'], text=True).strip()
env.update(LIBXML2_CFLAGS='-I'+sdk+'/usr/include/libxml2', LIBXML2_LIBS='-lxml2',
           LIBSTOKEN_CFLAGS='-I'+str(prefix/'include'), LIBSTOKEN_LIBS='-L'+str(prefix/'lib')+' -lstoken')
p11_marker = work/'p11.done'
if not p11_marker.exists():
    p11_env = env | {'P11_BUILD_DIRECTORY': str(root/'build/p11-isolated/compiled-macos13'), 'P11_INSTALL_PREFIX': str(prefix)}
    with (work/'p11.log').open('w') as log:
        subprocess.run([sys.executable, str(root/'scripts/prepare-isolated-p11.py')], env=p11_env, stdout=log, stderr=subprocess.STDOUT, check=True)
    p11_marker.touch()
manifest = json.loads((root/'scripts/runtime-sources.json').read_text())
jobs = str(min(os.cpu_count() or 4, 8))
def run(args, cwd, log):
    subprocess.run(list(map(str,args)), cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
for name, item in manifest.items():
    marker=work/(name+'.done')
    if marker.exists():
        if marker.read_text().strip() != item['sha256']:
            raise RuntimeError('Source pin changed; use a clean build/runtime-macos13 directory')
        continue
    print('Building '+name, flush=True)
    archive=work/(name+'.tar')
    if not archive.exists(): subprocess.run(['curl','-fL','--retry','2','--max-time','180',item['url'],'-o',str(archive)],check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']: raise RuntimeError('Digest mismatch: '+name)
    source=work/(name+'-source')
    if not source.exists():
        source.mkdir()
        with tarfile.open(archive) as tar: tar.extractall(source,filter='data')
    src=next(p for p in source.iterdir() if p.is_dir())
    with (work/(name+'.log')).open('w') as log:
        if name in ('libtommath','libtomcrypt'):
            args=['make','-f','makefile.shared','-j'+jobs, 'PREFIX='+str(prefix)]
            if name=='libtomcrypt': args+=['CFLAGS='+env['CFLAGS']+' -I'+str(prefix/'include')+' -DUSE_GMP -DGMP_DESC -DUSE_LTM -DLTM_DESC', 'EXTRALIBS=-L'+str(prefix/'lib')+' -lgmp -ltommath']
            run(args,src,log);run(args+['install'],src,log)
        else:
            if (src/'Makefile').exists(): run(['make','clean'],src,log)
            if name=='gmp': run(['autoreconf','-is'],src,log)
            if name=='stoken': run(['./autogen.sh'],src,log)
            flags=['--prefix='+str(prefix),'--disable-static','--disable-nls']
            if name=='gmp': flags+=['--with-pic','--build=aarch64-apple-darwin']
            if name=='nettle': flags+=['--enable-shared','--disable-documentation']
            if name=='libidn2': flags+=['--with-libunistring-prefix='+str(prefix),'--disable-doc']
            if name=='stoken': flags+=['--without-gtk']
            if name=='gnutls': flags+=['--disable-doc','--disable-tools','--disable-tests','--disable-libdane','--disable-heartbeat-support','--with-p11-kit','--with-default-trust-store-file=/etc/ssl/cert.pem','--with-default-priority-string=NORMAL']
            if name=='openconnect': flags+=['--sbindir='+str(prefix/'bin'),'--with-vpnc-script=./vpnc-script--no-dns','--without-libpskc','--with-gnutls','--with-stoken','--disable-docs']
            run(['./configure']+flags,src,log)
            run(['make','-j'+jobs],src,log)
            run(['make','install'],src,log)
    marker.write_text(item['sha256']+'\n')
notices = work/'notices'; notices.mkdir(exist_ok=True)
shutil.copyfile(root/'scripts/runtime-sources.json', notices/'runtime-sources.json')
for name in manifest:
    source = next(p for p in (work/(name+'-source')).iterdir() if p.is_dir())
    target = notices/name; target.mkdir(exist_ok=True)
    for item in source.iterdir():
        if item.is_file() and item.name.upper().startswith(('COPYING','LICENSE','AUTHORS')):
            shutil.copyfile(item, target/item.name)
print('Runtime sources built in '+str(prefix),flush=True)

package_env = env | {'OPENCONNECT_BINARY': str(prefix/'bin/openconnect'), 'P11_KIT_LIBRARY': str(prefix/'lib/libp11-kit.0.dylib'), 'RUNTIME_MAX_MIN_OS': '13.0', 'RUNTIME_SOURCE_NOTICES': str(notices)}
subprocess.run([sys.executable, str(root/'scripts/prepare-bundled-runtime.py')], env=package_env, check=True)
