"""Package the existing signed developer build without credentials or history."""
import argparse,hashlib,json,plistlib,shutil,subprocess,tempfile,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--build',type=int,required=True);a=p.parse_args()
base=Path(__file__).resolve().parent;release=base/'build/release';release.mkdir(exist_ok=True)
app=base/'build/BackgroundDerived/Build/Products/Release-iphoneos/PhoneHistoryProbe.app'
info=plistlib.loads((app/'Info.plist').read_bytes());assert info['CFBundleVersion']==str(a.build)
ipa=release/f'Phone-History-{info["CFBundleShortVersionString"]}-build{a.build}.ipa';download=release/f'Phone-History-pilot-build{a.build}-download.zip'
with tempfile.TemporaryDirectory(prefix='phone-history-release-') as directory:
 stage=Path(directory);payload=stage/'ipa/Payload';payload.mkdir(parents=True)
 subprocess.run(['ditto',str(app),str(payload/app.name)],check=True)
 subprocess.run(['ditto','-c','-k','--norsrc',str(payload.parent),str(ipa)],check=True)
 with zipfile.ZipFile(ipa) as z:
  assert 'Payload/PhoneHistoryProbe.app/PlugIns/PhoneHistoryCapture.appex/Info.plist' in z.namelist()
  assert 'Payload/PhoneHistoryProbe.app/PlugIns/PhoneHistoryControls.appex/Info.plist' in z.namelist()
  assert not any('pairing' in n.lower() or '/history-export/' in n for n in z.namelist())
 profiles=[]
 for item in [app]+sorted((app/'PlugIns').glob('*.appex')):
  profile=plistlib.loads(subprocess.check_output(['security','cms','-D','-i',str(item/'embedded.mobileprovision')]))
  profiles.append({'registered_devices':len(profile.get('ProvisionedDevices',[])),'expires_utc':profile['ExpirationDate'].isoformat()+'Z'})
 digest=hashlib.sha256(ipa.read_bytes()).hexdigest()
 manifest={'build':a.build,'ipa_file':ipa.name,'ipa_bytes':ipa.stat().st_size,'ipa_sha256':digest,'profiles':profiles,
   'distribution':'configured-phone developer pilot','public_release_ready':False,'contains_pairing_credentials':False,
   'capture_runtime':'embedded on-device extension','notes':'USER-READY.md describes live evidence and outstanding limits'}
 bundle=stage/f'Phone-History-pilot-build{a.build}';bundle.mkdir()
 shutil.copy2(ipa,bundle/ipa.name);shutil.copy2(base/'USER-READY.md',bundle/'USER-READY.md')
 shutil.copy2(base/'PRIVACY.md',bundle/'PRIVACY.md');shutil.copy2(base/'install_pilot.py',bundle/'install_pilot.py')
 shutil.copytree(base/'Desktop',bundle/'Desktop',ignore=shutil.ignore_patterns('__pycache__','.venv'))
 (bundle/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 # Discover the package's signing intersection, rather than hardcoding a phone.
 script='#!/bin/zsh\nset -euo pipefail\npackage_dir="${0:A:h}"\nexec /usr/bin/python3 "$package_dir/install_pilot.py" "$@"\n'
 installer=bundle/'Install-on-Mac.command';installer.write_text(script);installer.chmod(0o755)
 (bundle/'README.txt').write_text(f"PHONE HISTORY — DEVELOPER PILOT BUILD {a.build}\n\nThis package installs only on phones registered in its signing profiles.\nIt is not a public App Store/TestFlight release or a universal IPA.\nUnzip on a Mac with Xcode, unlock/connect the registered phone, and run\nzsh /path/to/Install-on-Mac.command\nThe installer checks all profiles, signing expiry and package integrity.\nKeep the IPA, manifest and installer together. No history or trust keys are included.\n\nOpen Phone History, tap Start history, then use other apps.\nNo separate LocalDevVPN app is needed. Stop history pauses capture.\nSaves bounded text changes; no taps or keystrokes. Optional on-demand MCP screenshots require separate phone permission and are never saved in history.\nDesktop/README.md explains approved-desktop access for Codex and Claude.\nRead USER-READY.md and PRIVACY.md for setup, coverage and limits.\n")
 subprocess.run(['ditto','-c','-k','--keepParent','--norsrc',str(bundle),str(download)],check=True)
 restored=stage/'roundtrip';subprocess.run(['ditto','-x','-k',str(download),str(restored)],check=True)
 subprocess.run(['zsh',str(restored/bundle.name/'Install-on-Mac.command'),'--check-only'],check=True)
 report=dict(manifest,download_file=download.name,download_bytes=download.stat().st_size,
   download_sha256=hashlib.sha256(download.read_bytes()).hexdigest(),roundtrip_signature_and_checksum_verified=True)
 (release/f'manifest-build{a.build}.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
