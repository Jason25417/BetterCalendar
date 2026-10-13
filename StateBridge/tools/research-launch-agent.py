#!/usr/bin/env python3
"""Personal login startup for the existing local recorder; no credentials here."""
import argparse
import os
import pathlib
import plistlib
import shutil
import subprocess
import time

LABEL = 'com.jason.BetterCalendar.research-recorder'
ROOT = pathlib.Path.home() / 'Library/Application Support/BetterCalendarResearch'
PLIST = pathlib.Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
DOMAIN = 'gui/' + str(os.getuid())
RECORDER = pathlib.Path(__file__).resolve().with_name('research-recorder.mjs')

def state():
    r = subprocess.run(['launchctl', 'print', DOMAIN + '/' + LABEL], capture_output=True, text=True)
    # Service registration does not by itself prove successful collection.
    print('registered=' + str(r.returncode == 0).lower())
    for line in r.stdout.splitlines():
        if line.strip().startswith(('state =', 'pid =', 'last exit code =')):
            print(line.strip())

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['install', 'status', 'disable'])
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.mode == 'status':
        state()
        return
    if args.mode == 'disable':
        # Preserve the plist and data. No broad process kill or data deletion.
        subprocess.run(['launchctl', 'bootout', DOMAIN + '/' + LABEL], capture_output=True)
        if PLIST.exists():
            PLIST.rename(ROOT / ('launch-agent-disabled-' + str(int(time.time())) + '.plist'))
        state()
        return
    node = shutil.which('node')
    if not node or not RECORDER.exists():
        raise SystemExit('node/recorder unavailable')
    # install never resumes an explicit stop. Move the STOP file manually only
    # when resuming is actually authorized. Process crash recovery is later.
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    value = {'Label': LABEL, 'ProgramArguments': [node, str(RECORDER), 'watch'],
             'RunAtLoad': True, 'KeepAlive': False, 'ProcessType': 'Background',
             'WorkingDirectory': str(RECORDER.parent),
             'StandardOutPath': str(ROOT / 'recorder-login.log'),
             'StandardErrorPath': str(ROOT / 'recorder-login-error.log')}
    for key in ['StandardOutPath', 'StandardErrorPath']:
        p = pathlib.Path(value[key]); p.touch(mode=0o600, exist_ok=True); p.chmod(0o600)
    if PLIST.exists():
        if plistlib.loads(PLIST.read_bytes()) != value:
            raise SystemExit('different existing configuration; inspect before replacing')
        check = subprocess.run(['launchctl', 'print', DOMAIN + '/' + LABEL], capture_output=True)
        if check.returncode == 0:
            state(); return
    PLIST.write_bytes(plistlib.dumps(value)); PLIST.chmod(0o600)
    result = subprocess.run(['launchctl', 'bootstrap', DOMAIN, str(PLIST)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit('launch agent registration failed: ' + str(result.returncode))
    state()

if __name__ == '__main__':
    main()
