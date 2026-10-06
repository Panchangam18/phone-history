"""Build the production UIKit sources for isolated simulator visual review."""
from pathlib import Path
import ast,plistlib,subprocess
base=Path(__file__).resolve().parent
tree=ast.parse((base/'make_background_project.py').read_text())
sources=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='app_sources' for t in n.targets))
app=base/'build/UI38Preview.app';app.mkdir(exist_ok=True)
info=plistlib.loads((base/'App/History-Info.plist').read_bytes());info['CFBundleIdentifier']='com.example.phonehistory.ui-preview';info['CFBundleExecutable']='PhoneHistoryProbe'
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
with (base/'build/ui38-simulator-build.log').open('w') as log:
 subprocess.run(['xcrun','swiftc','-sdk',sdk,'-target','arm64-apple-ios26.5-simulator','-parse-as-library']+[str(base/p) for p in sources]+['-o',str(app/'PhoneHistoryProbe')],stdout=log,stderr=subprocess.STDOUT,check=True)
 subprocess.run(['xcrun','actool',str(base/'App/Assets.xcassets'),'--compile',str(app),'--platform','iphonesimulator','--minimum-deployment-target','26.5','--target-device','iphone','--app-icon','AppIcon','--output-partial-info-plist',str(base/'build/ui38-assets.plist')],stdout=log,stderr=subprocess.STDOUT,check=True)
info.update(plistlib.loads((base/'build/ui38-assets.plist').read_bytes()))
(app/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print('Compiled production UIKit sources; preview fixtures are simulator-only.')
