# Execute trust checks against the installed platform

The managed runtime validator originally rejected Apple's standard `otool` symlink and passed `anchor apple` to `codesign -R` without the `=` prefix required for an inline requirement. Shell syntax tests passed, but real validation failed before any VPN could start.

Select the protected regular `llvm-otool` file on recent CLT installations, retain ownership/permission/signature checks, and use `-R '=anchor apple'`. Do not solve platform-layout mismatches by broadly accepting arbitrary symlinks or removing signature validation.

`tests/verify-system-command-fixtures.py` executes the production tool selection and trust checks against installed Apple CLT without privilege or network access. It also executes DNS and sudoers commands in temporary fixtures with explicit privilege substitutions. Syntax tests and mocked dependencies cannot establish that a platform security check accepts legitimate installed software; execute the read-only checks separately from privileged acceptance.

The full runtime audit also needs negative execution tests. `llvm-otool -L` can produce no usable dependencies for a shell wrapper without a failing exit status. The validator now checks Mach-O headers and file types across all slices, rejects unparseable inspection output, and requires executable permission on the frozen script. Fixtures cover valid universal binaries with runtime-local libraries, forbidden Homebrew load paths, wrappers, truncated binaries, invalid libraries and a correct-but-non-executable script. Runtime now contains only the executable, dynamic libraries and pinned script; package metadata belongs outside it.
