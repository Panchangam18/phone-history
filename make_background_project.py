"""Generate the small native app/extension project; Xcode manages provisioning."""
from pathlib import Path
import hashlib, json, os, plistlib, re

BASE = Path(__file__).resolve().parent
config_path = BASE/'.phone-history-build.json'
config = json.loads(config_path.read_text()) if config_path.exists() else {}
def option(name, default=''):
    return os.environ.get('PHONE_HISTORY_'+name.upper(), str(config.get(name,default)))
TEAM = option('team')
BUNDLE = option('bundle_id','com.example.phonehistory')
GROUP = option('group','group.'+BUNDLE)
CONTROL_KIND = option('control_kind',BUNDLE+'.capture-toggle')
BUILD = option('build','75')
VERSION = option('version','1.0')
for name,value in [('bundle_id',BUNDLE),('group',GROUP),('control_kind',CONTROL_KIND)]:
    if not re.fullmatch(r'[A-Za-z0-9.-]+',value): raise ValueError('Invalid '+name)
if not BUILD.isdigit(): raise ValueError('Build must be an integer')
runtime_info = {'PhoneHistoryAppGroup':GROUP,'PhoneHistoryProvider':BUNDLE+'.capture',
                'PhoneHistoryControlKind':CONTROL_KIND}
PROJECT = BASE/'PhoneHistory.xcodeproj'
PROJECT.mkdir(exist_ok=True)

def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def settings(values):
    return '{'+''.join(f'{key} = {q(value)};' for key,value in values.items())+'}'
objects = {}
def add(name,body): objects[ident(name)] = body; return ident(name)

entitlements = {'com.apple.developer.networking.networkextension':['packet-tunnel-provider'],
    'com.apple.security.application-groups':[GROUP]}
for folder in ['App','Tunnel']:
    (BASE/folder/'History.entitlements').write_bytes(plistlib.dumps(entitlements))
app_info = {'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleDisplayName':'Phone History',
    'CFBundleName':'PhoneHistoryProbe','CFBundleExecutable':'$(EXECUTABLE_NAME)',
    'CFBundlePackageType':'APPL','CFBundleVersion':BUILD,'CFBundleShortVersionString':VERSION,
    'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIApplicationSceneManifest':{
        'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[
            {'UISceneConfigurationName':'Default Configuration'}]}},
    'NSLocalNetworkUsageDescription':'Let desktops you approve read encrypted phone history over the same Wi-Fi.',
    'UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True}
app_info.update(runtime_info)
(BASE/'App/History-Info.plist').write_bytes(plistlib.dumps(app_info))
extension_info = {'CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'PhoneHistoryCapture','CFBundleDisplayName':'Phone History Capture',
    'CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'XPC!', 'CFBundleVersion':BUILD,'CFBundleShortVersionString':VERSION,
    'NSExtension':{'NSExtensionPointIdentifier':'com.apple.networkextension.packet-tunnel','NSExtensionPrincipalClass':'PacketTunnelProvider'}}
extension_info.update(runtime_info)
(BASE/'Tunnel/Info.plist').write_bytes(plistlib.dumps(extension_info))
(BASE/'Controls/History.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':[GROUP]}))
controls_info = dict(extension_info, CFBundleName='PhoneHistoryControls', CFBundleDisplayName='Phone History Controls', NSExtension={
    'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
(BASE/'Controls/Info.plist').write_bytes(plistlib.dumps(controls_info))

app_sources = ['Shared/MemoryPrompts.swift','Shared/BuildConfiguration.swift','Shared/NaturalMemory.swift','Shared/ContextText.swift','Shared/MemoryRecord.swift','App/HistoryApp.swift','App/HistoryController.swift','App/HistoryListController.swift',
    'App/HistorySettingsController.swift','App/HistoryUI.swift','App/HistoryAboutController.swift','App/DesktopAccessController.swift','Shared/HistoryPaths.swift','Shared/HistoryReader.swift',
    'Shared/DesktopAccess.swift','Shared/StoragePolicy.swift','Shared/HistoryOffload.swift','Tunnel/DesktopExportServer.swift','Shared/CaptureControlState.swift','Shared/SetCaptureIntent.swift']
ext_sources = ['Shared/MemoryPrompts.swift','Shared/BuildConfiguration.swift','Shared/NaturalMemory.swift','Shared/ContextText.swift','Shared/MemoryUsage.m','Shared/MemoryRecord.swift','Shared/MemoryEngine.swift','Tunnel/FrameObservation.swift','Tunnel/PacketTunnelProvider.swift','Tunnel/TunnelConnection.swift','Shared/HistoryPaths.swift',
    'Shared/HistoryReader.swift','Shared/DesktopAccess.swift','Shared/StoragePolicy.swift','Shared/HistoryOffload.swift','Tunnel/DesktopExportServer.swift','Shared/CaptureControlState.swift']
controls_sources = ['Shared/BuildConfiguration.swift','Controls/HistoryControls.swift','Shared/HistoryPaths.swift','Shared/CaptureControlState.swift','Shared/SetCaptureIntent.swift']
source_refs = {}
for path in sorted(set(app_sources+ext_sources+controls_sources)):
    file_type = 'sourcecode.c.objc' if path.endswith('.m') else 'sourcecode.swift'
    source_refs[path] = add('file:'+path,f'{{isa = PBXFileReference; lastKnownFileType = {file_type}; path = {q(path)}; sourceTree = "<group>";}}')
library = add('library','{isa = PBXFileReference; lastKnownFileType = archive.ar; path = "Core/target/aarch64-apple-ios/release/libphone_history_core.a"; sourceTree = "<group>";}')
resource_refs = [add('resource:'+path,f'{{isa = PBXFileReference; lastKnownFileType = text; path = {q(path)}; sourceTree = "<group>";}}')
    for path in ['ThirdParty/LocalDevVPN-LICENSE','ThirdParty/idevice-LICENSE','Shared/PrivacyInfo.xcprivacy']]
icon_ref = add('app-icon','{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "App/Assets.xcassets"; sourceTree = "<group>";}')
controls_icon_ref = add('controls-icon','{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "Controls/Assets.xcassets"; sourceTree = "<group>";}')
app_product = add('app-product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = PhoneHistoryProbe.app; sourceTree = BUILT_PRODUCTS_DIR;}')
ext_product = add('ext-product','{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = PhoneHistoryCapture.appex; sourceTree = BUILT_PRODUCTS_DIR;}')

controls_product = add('controls-product','{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = PhoneHistoryControls.appex; sourceTree = BUILT_PRODUCTS_DIR;}')

common = {'IPHONEOS_DEPLOYMENT_TARGET':'26.5','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0',
    'DEVELOPMENT_TEAM':TEAM,'CODE_SIGN_STYLE':'Automatic','TARGETED_DEVICE_FAMILY':'1',
    'SWIFT_OBJC_BRIDGING_HEADER':'App/Bridge.h','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING':'YES','SWIFT_OPTIMIZATION_LEVEL':'-O', 'STRIP_INSTALLED_PRODUCT':'YES',
    'DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym','DEAD_CODE_STRIPPING':'YES','GENERATE_INFOPLIST_FILE':'NO',
    'LIBRARY_SEARCH_PATHS':'$(inherited) $(SRCROOT)/Core/target/aarch64-apple-ios/release',
    'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'}
configs = {}
for target,bundle,info,ent in [('app',BUNDLE,'App/History-Info.plist','App/History.entitlements'),
        ('extension',BUNDLE+'.capture','Tunnel/Info.plist','Tunnel/History.entitlements'),
        ('controls',BUNDLE+'.controls','Controls/Info.plist','Controls/History.entitlements')]:
    values = dict(common,PRODUCT_BUNDLE_IDENTIFIER=bundle,INFOPLIST_FILE=info,CODE_SIGN_ENTITLEMENTS=ent,
        PRODUCT_NAME='PhoneHistoryProbe' if target=='app' else ('PhoneHistoryCapture' if target=='extension' else 'PhoneHistoryControls'),
        OTHER_LDFLAGS='$(inherited) -framework Foundation -framework NetworkExtension -framework Security -framework SystemConfiguration -lresolv -liconv -framework WidgetKit -framework AppIntents'+(' -framework UIKit' if target=='app' else ''))
    if target!='app': values.update(APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES')
    else: values['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    if target=='controls': values.pop('SWIFT_OBJC_BRIDGING_HEADER',None)
    ids = []
    for name in ['Debug','Release']:
        ids.append(add(target+'-'+name,'{isa = XCBuildConfiguration; buildSettings = '+settings(values)+'; name = '+name+';}'))
    configs[target] = add(target+'-configs','{isa = XCConfigurationList; buildConfigurations = ('+','.join(ids)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')

phases = {}
for target,sources in [('app',app_sources),('extension',ext_sources),('controls',controls_sources)]:
    builds = [add(target+'-source-'+path,'{isa = PBXBuildFile; fileRef = '+source_refs[path]+';}') for path in sources]
    source_phase = add(target+'-sources','{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+',); runOnlyForDeploymentPostprocessing = 0;}')
    lib_build = add(target+'-lib','{isa = PBXBuildFile; fileRef = '+library+';}') if target=='extension' else None
    lib_phase = add(target+'-frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('+(lib_build+',' if lib_build else '')+'); runOnlyForDeploymentPostprocessing = 0;}')
    resources = [add(target+'-resource-'+ref,'{isa = PBXBuildFile; fileRef = '+ref+';}') for ref in resource_refs]
    if target=='app': resources.append(add('app-icon-build','{isa = PBXBuildFile; fileRef = '+icon_ref+';}'))
    if target=='controls': resources.append(add('controls-icon-build','{isa = PBXBuildFile; fileRef = '+controls_icon_ref+';}'))
    resource_phase = add(target+'-resources','{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(resources)+',); runOnlyForDeploymentPostprocessing = 0;}')
    phases[target] = [source_phase,lib_phase,resource_phase]

embeds = []
dependencies = []
for target,product,name in [('extension',ext_product,'PhoneHistoryCapture'),('controls',controls_product,'PhoneHistoryControls')]:
    embeds.append(add(target+'-embed','{isa = PBXBuildFile; fileRef = '+product+'; settings = {ATTRIBUTES = (RemoveHeadersOnCopy,);};}'))
    proxy = add(target+'-proxy','{isa = PBXContainerItemProxy; containerPortal = '+ident('project')+'; proxyType = 1; remoteGlobalIDString = '+ident(target+'-target')+'; remoteInfo = '+name+';}')
    dependencies.append(add(target+'-dependency','{isa = PBXTargetDependency; target = '+ident(target+'-target')+'; targetProxy = '+proxy+';}'))
phases['app'].append(add('embed-phase','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ('+','.join(embeds)+',); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;}'))
for target,product,name,kind in [('app',app_product,'PhoneHistoryProbe','com.apple.product-type.application'),('extension',ext_product,'PhoneHistoryCapture','com.apple.product-type.app-extension'),('controls',controls_product,'PhoneHistoryControls','com.apple.product-type.app-extension')]:
    add(target+'-target','{isa = PBXNativeTarget; buildConfigurationList = '+configs[target]+'; buildPhases = ('+','.join(phases[target])+',); buildRules = (); dependencies = ('+(','.join(dependencies)+',' if target=='app' else '')+'); name = '+name+'; productName = '+name+'; productReference = '+product+'; productType = '+q(kind)+';}')
products = add('products','{isa = PBXGroup; children = ('+app_product+','+ext_product+','+controls_product+',); name = Products; sourceTree = "<group>";}')
group = add('group','{isa = PBXGroup; children = ('+','.join(list(source_refs.values())+resource_refs+[icon_ref,controls_icon_ref,library,products])+',); sourceTree = "<group>";}')
project_configs = []
for name in ['Debug','Release']:
    project_configs.append(add('project-'+name,'{isa = XCBuildConfiguration; buildSettings = {}; name = '+name+';}'))
project_list = add('project-configs','{isa = XCConfigurationList; buildConfigurations = ('+','.join(project_configs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')
add('project','{isa = PBXProject; attributes = {LastUpgradeCheck = 2600; TargetAttributes = {'+ident('app-target')+' = {ProvisioningStyle = Automatic;};'+ident('extension-target')+' = {ProvisioningStyle = Automatic;};'+ident('controls-target')+' = {ProvisioningStyle = Automatic;};};}; buildConfigurationList = '+project_list+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = '+group+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = ('+ident('app-target')+','+ident('extension-target')+','+ident('controls-target')+',);}')
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(k+' = '+v+';\n' for k,v in objects.items())+'}; rootObject = '+ident('project')+';}\n')
schemes = PROJECT/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
(schemes/'PhoneHistory.xcscheme').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'''+ident('app-target')+'''" BuildableName="PhoneHistoryProbe.app" BlueprintName="PhoneHistoryProbe" ReferencedContainer="container:PhoneHistory.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
print('Generated PhoneHistory app, packet-tunnel and Control Center extension project.')
