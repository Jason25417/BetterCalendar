#!/usr/bin/env python3
"""双端串行 archive + 上传 TestFlight（自 Codex /private/tmp/bc-release-dual.py 收编，2026-10-17）。
用法：python3 scripts/release-dual.py --build <号>；状态写 /private/tmp/bc-release-<号>/status.json。
发版一律用正式版 Xcode（DEVELOPER_DIR 固定为 /Applications/Xcode.app），beta 产物会被 Apple 拒收。"""
import argparse, datetime, json, os, plistlib, subprocess, sys
from pathlib import Path

ap=argparse.ArgumentParser();ap.add_argument('--build',required=True,type=int);args=ap.parse_args()
root=Path(__file__).resolve().parent.parent
out=Path(f'/private/tmp/bc-release-{args.build}');out.mkdir(exist_ok=True)
status_path=out/'status.json'
if status_path.exists():
    raise SystemExit('Existing release state retained; inspect ASC and live process before retrying.')
source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
if subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip():
    raise SystemExit('Release requires a clean, committed source checkout.')
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
state={'build':args.build,'sourceCommit':source,'pid':os.getpid(),'stage':'starting','platforms':{}}
def persist(stage):
    state['stage']=stage;state['updatedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp=status_path.with_suffix('.tmp');tmp.write_text(json.dumps(state,indent=2)+'\n');tmp.replace(status_path)
    print(stage,flush=True)
auth=['-allowProvisioningUpdates','-authenticationKeyPath',str(Path.home()/'.appstoreconnect/private_keys/AuthKey_MFLQ74N9N7.p8'),'-authenticationKeyID','MFLQ74N9N7','-authenticationKeyIssuerID','f6b800c3-7e46-4bbb-914e-4c8ca018e8f1']
options=out/'exportOptions.plist'
with options.open('wb') as f:plistlib.dump({'destination':'upload','method':'app-store-connect','teamID':'D2KWHV599Z','signingStyle':'automatic','uploadSymbols':True,'manageAppVersionAndBuildNumber':False},f)
try:
    for label,destination in [('macOS','generic/platform=macOS'),('iOS','generic/platform=iOS')]:
        archive=out/(label+'.xcarchive');log=out/(label+'-archive.log')
        persist(label+'-archive')
        with log.open('wb') as f:
            p=subprocess.run(['xcodebuild','-project','BetterCalendar.xcodeproj','-scheme','BetterCalendar','-configuration','Release','-destination',destination,'-archivePath',str(archive),'-derivedDataPath',str(out/'DerivedData'),*auth,'archive'],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
        if p.returncode:raise RuntimeError(label+' archive failed; see '+str(log))
        with (archive/'Info.plist').open('rb') as f:info=plistlib.load(f)
        props=info['ApplicationProperties']
        if str(props.get('CFBundleVersion'))!=str(args.build) or props.get('CFBundleIdentifier')!='com.jason.BetterCalendar':
            raise RuntimeError('Archive identity/version mismatch; upload not attempted.')
        state['platforms'][label]={'archive':str(archive),'version':props.get('CFBundleShortVersionString'),'build':props.get('CFBundleVersion'),'archiveSucceeded':True}
        persist(label+'-upload')
        log=out/(label+'-upload.log')
        with log.open('wb') as f:
            p=subprocess.run(['xcodebuild','-exportArchive','-archivePath',str(archive),'-exportPath',str(out/(label+'-export')),'-exportOptionsPlist',str(options),*auth],cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
        if p.returncode:raise RuntimeError(label+' upload uncertain/failed; query ASC before retrying. See '+str(log))
        state['platforms'][label]['exportSucceeded']=True
        persist(label+'-uploaded')
    persist('uploaded-both')
except Exception as e:
    state['failure']=str(e);persist('failed');raise
