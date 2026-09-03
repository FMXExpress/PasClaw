#!/usr/bin/env python3
"""Fail when the source version is BEHIND the newest release tag.

Why. VersionFallback in PasClaw.Config is the product version, and the
Delphi build has no PASCLAW_VERSION env-var equivalent -- so it reports
VersionFallback verbatim. The Windows binaries on every release ARE the
Delphi build. When v0.1.3 shipped with VersionFallback still reading
'0.1.0-dev', every Windows user saw 0.1.0-dev in `pasclaw version`, in
/v1/version, in the gateway's Server: header, in the system prompt the
model reads, and in `pasclaw update`, which compared 0.1.0-dev against
v0.1.3 and told a freshly installed user they were out of date. It had
drifted silently across three releases because nothing checked.

The rule: VersionFallback must be >= the newest tag. Equal is the normal
state. Ahead is legitimate -- at release time the bump commit lands
before the tag exists. Behind is the bug, and the only state this fails.

Skips cleanly when no tags are reachable (shallow clone, fresh fork, CI
without fetch-depth 0) rather than failing: absent tags are not evidence
of a stale version.

Also checks the other three places a release has to touch, so a partial
bump cannot pass: the .dproj FileVersion / ProductVersion (Windows file
properties) and the installer default.
"""
import re
import subprocess
import sys

CONFIG = 'src/pkg/config/PasClaw.Config.pas'
DPROJ = 'src/pasclaw/PasClaw.dproj'
ISS = 'installer/pasclaw.iss'


def parts(v):
    """Numeric segments of a version; a -suffix sorts BEFORE the release."""
    v = v.strip().lstrip('vV')
    pre = '-' in v
    nums = [int(n) for n in re.findall(r'\d+', v.split('-')[0])]
    while len(nums) < 3:
        nums.append(0)
    return (nums[:3], 0 if pre else 1)


def read(path, pattern):
    m = re.search(pattern, open(path).read())
    return m.group(1) if m else None


def main():
    fallback = read(CONFIG, r"VersionFallback\s*=\s*'([^']+)'")
    if not fallback:
        print(f"{CONFIG}: VersionFallback not found")
        return 1

    problems = []

    # The other three must agree with the fallback's numeric version.
    want = '.'.join(str(n) for n in parts(fallback)[0])
    for path, pat, label in [
        (DPROJ, r'"FileVersion">([\d.]+)<', 'FileVersion'),
        (DPROJ, r'"ProductVersion">([\d.]+)<', 'ProductVersion'),
        (ISS, r'#define MyAppVersion "([^"]+)"', 'MyAppVersion'),
    ]:
        got = read(path, pat)
        if got is None:
            problems.append(f"{path}: {label} not found")
        elif '.'.join(str(n) for n in parts(got)[0]) != want:
            problems.append(
                f"{path}: {label} is {got}, but VersionFallback is {fallback}")

    try:
        tag = subprocess.run(['git', 'describe', '--tags', '--abbrev=0'],
                             capture_output=True, text=True, timeout=10)
        latest = tag.stdout.strip() if tag.returncode == 0 else ''
    except Exception:
        latest = ''

    if not latest:
        print(f"version sync: VersionFallback={fallback}; "
              "no tags reachable, tag comparison skipped")
    elif parts(fallback) < parts(latest):
        problems.append(
            f"{CONFIG}: VersionFallback is {fallback}, BEHIND the newest "
            f"tag {latest} -- Delphi builds ship this string verbatim")
    else:
        print(f"version sync: VersionFallback={fallback}, newest tag={latest}")

    for p in problems:
        print('  ' + p)
    if problems:
        print(f"version sync: {len(problems)} problem(s)")
        return 1
    print("version sync: OK")
    return 0


if __name__ == '__main__':
    sys.exit(main())
