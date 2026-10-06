import UIKit
import NetworkExtension

@MainActor
final class HistoryController: UIViewController {
    private let status = UILabel()
    private var manager: NETunnelProviderManager?
    private var busy = false { didSet { updateCaptureButton() } }
    private var captureEnabled = false
    private let stateTitle = HistoryUI.label("Paused",style:.title2,weight:.semibold)
    private let stateDot = UIView()
    private let captureButton = UIButton(type:.system)
    private let retentionValue = HistoryUI.label("512 KB",style:.title2,weight:.semibold)
    private let retentionCaption = HistoryUI.label("Storage budget",style:.caption1,color:.secondaryLabel)
    private var localBytes:Int64?
    private let savedSize = HistoryUI.label("—",style:.title2,weight:.semibold)
    private let previewStack = UIStackView()
    private let agentSubtitle = HistoryUI.label("Connect a desktop",style:.subheadline,color:.secondaryLabel)
    private var previewTask: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
    private var connectionTask: Task<Void,Never>?
    private var backgroundObserver:NSObjectProtocol?
    private let configurationQueue=DispatchQueue(label:"PhoneHistory.Visibility",qos:.userInitiated)

    private var started = false
    private var foregroundObserver: NSObjectProtocol?
    private var connectionObserver: NSObjectProtocol?
    private var workerStatus: [String:Any]?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = HistoryUI.accent
        buildInterface()
        foregroundObserver = NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.writeVisibility(true);self?.refreshStatus() }
        }
        connectionObserver = NotificationCenter.default.addObserver(forName:.NEVPNStatusDidChange,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active,let self else { return }
                if let connection=notification.object as? NEVPNConnection,connection !== self.manager?.connection { return }
                self.refreshConnectionStatus()
            }
        }
        backgroundObserver=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.writeVisibility(false) }
        }
        writeVisibility(true)
        do { try importBootstrapTrust(); refreshStatus() }
        catch { status.text = error.localizedDescription }
    }
    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let connectionObserver { NotificationCenter.default.removeObserver(connectionObserver) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("--ui-export") {
                Task { @MainActor in
                    try? await Task.sleep(for:.milliseconds(600))
                    guard let window=self.view.window else {return}
                    window.layoutIfNeeded()
                    let image=UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
                        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
                    }
                    if let data=image.pngData(),let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first {
                        try? data.write(to:folder.appendingPathComponent("store-preview.png"),options:.atomic)
                    }
                }
            }
            #endif
            if CommandLine.arguments.contains("--stop-history") { stopPressed() }
            else if CommandLine.arguments.contains("--start-history") { startPressed() }
            if CommandLine.arguments.contains("--summarize-history") {
                Task {
                    try? await Task.sleep(for:.seconds(3))
                    if let manager=try? await NETunnelProviderManager.loadAllFromPreferences().first(where:{($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider}),let session=manager.connection as? NETunnelProviderSession,session.status == .connected {
                        try? session.sendProviderMessage(Data("summarize-now".utf8)) { _ in }
                    }
                }
            }
            if CommandLine.arguments.contains("--pair-desktop") { agentsPressed() }
            if CommandLine.arguments.contains("--verification-export") {
                Task { try? await Task.sleep(nanoseconds:4_000_000_000); refreshStatus() }
            }
        }
    }
    private func buildInterface() {
        let logo=UIImageView(image:UIImage(named:"HistoryLogo"));logo.layer.cornerRadius=13;logo.layer.cornerCurve = .continuous;logo.clipsToBounds=true
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant:44),logo.heightAnchor.constraint(equalToConstant:44)])
        let brand=HistoryUI.label("Phone History",style:.title2,weight:.bold)
        let more=UIButton(type:.system);var moreConfig=UIButton.Configuration.glass();moreConfig.image=UIImage(systemName:"gearshape");moreConfig.cornerStyle = .capsule;more.configuration=moreConfig
        more.widthAnchor.constraint(equalToConstant:44).isActive=true;more.heightAnchor.constraint(equalToConstant:44).isActive=true
        more.accessibilityLabel="Settings";more.addTarget(self,action:#selector(settingsPressed),for:.touchUpInside)
        let heading=HistoryUI.stack([logo,brand,UIView(),more],spacing:12,axis:.horizontal);heading.alignment = .center
        stateDot.layer.cornerRadius=5;stateDot.backgroundColor = .tertiaryLabel
        NSLayoutConstraint.activate([stateDot.widthAnchor.constraint(equalToConstant:10),stateDot.heightAnchor.constraint(equalToConstant:10)])
        let stateRow=HistoryUI.stack([stateDot,stateTitle,UIView()],spacing:10,axis:.horizontal);stateRow.alignment = .center
        status.font = .preferredFont(forTextStyle:.subheadline);status.adjustsFontForContentSizeCategory=true;status.textColor = .secondaryLabel;status.numberOfLines=0
        status.text="Ready when you are."
        captureButton.addTarget(self,action:#selector(capturePressed),for:.touchUpInside)
        captureButton.heightAnchor.constraint(greaterThanOrEqualToConstant:54).isActive=true
        let metrics=HistoryUI.stack([
            HistoryUI.stack([savedSize,HistoryUI.label("Stored here",style:.caption1,color:.secondaryLabel)],spacing:3),
            HistoryUI.stack([retentionValue,retentionCaption],spacing:3)
        ],spacing:20,axis:.horizontal);metrics.distribution = .fillEqually
        let content=HistoryUI.stack([stateRow,status,captureButton,HistoryUI.separator(),metrics],spacing:18)
        let hero=HistoryTintCard();HistoryUI.inset(content,into:hero,amount:24)
        let recent=HistoryUI.label("Recent history",style:.headline)
        let all=UIButton(type:.system);all.setTitle("See all",for:.normal);all.addTarget(self,action:#selector(recentPressed),for:.touchUpInside)
        all.titleLabel?.font = .preferredFont(forTextStyle:.subheadline);all.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
        let recentHeading=HistoryUI.stack([recent,UIView(),all],axis:.horizontal);recentHeading.alignment = .center
        previewStack.axis = .vertical;previewStack.spacing=0
        let previewCard=HistoryUI.card(previewStack,inset:0)
        let recentSection=HistoryUI.stack([recentHeading,previewCard],spacing:2)
        let agents=HistoryUI.menuRow(title:"Desktop agents",subtitle:"Connect a desktop",symbol:"laptopcomputer",target:self,action:#selector(agentsPressed),subtitleView:agentSubtitle)
        let privacy=HistoryUI.label("Private by default · Stored on your iPhone",style:.caption1,color:.secondaryLabel);privacy.textAlignment = .center
        let stack=HistoryUI.stack([heading,hero,recentSection,agents,privacy],spacing:24)
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll);scroll.alwaysBounceVertical=true
        let refresh=UIRefreshControl();refresh.addTarget(self,action:#selector(pullRefresh(_:)),for:.valueChanged);scroll.refreshControl=refresh
        stack.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-40),
            stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),
            stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40)])
        updateCaptureButton()
    }
    private func updateCaptureButton() {
        var config=UIButton.Configuration.prominentGlass();config.cornerStyle = .capsule
        config.title=captureEnabled ? "Pause capture" : "Start capture"
        config.image=UIImage(systemName:captureEnabled ? "pause.fill" : "play.fill");config.imagePadding=9
        config.baseBackgroundColor=HistoryUI.accent;config.baseForegroundColor=UIColor { $0.userInterfaceStyle == .dark ? .black:.white };config.showsActivityIndicator=busy
        config.titleTextAttributesTransformer=UIConfigurationTextAttributesTransformer { attributes in
            var result=attributes;result.font = UIFont.preferredFont(forTextStyle:.headline);return result
        }
        captureButton.configuration=config;captureButton.isEnabled = !busy
        captureButton.accessibilityHint=captureEnabled ? "Pauses recording and keeps saved history." : "Starts recording changed text context on this phone."
    }
    @objc private func capturePressed() { if captureEnabled { stopPressed() } else { startPressed() } }
    @objc private func pullRefresh(_ sender:UIRefreshControl) { refreshStatus();sender.endRefreshing() }
    private func updatePresentation(state:String, enabled:Bool, bytes:Int64) {
        captureEnabled=enabled;stateTitle.text=state
        stateDot.backgroundColor=state == "Capturing" ? .systemGreen : (enabled ? .systemOrange : .tertiaryLabel)
        savedSize.text=ByteCountFormatter.string(fromByteCount:localBytes ?? bytes,countStyle:.file)
        updateCaptureButton()
    }
    private func loadPreview() {
        previewTask?.cancel()
        previewTask=Task {
            let entries: [HistoryEntry]
            do {
                let result=try await Task.detached(priority:.utility) {
                    let folder=try HistoryPaths.folder()
                    let files=StoragePolicy.historyFiles(folder)
                    let bytes=files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
                    var entries=try HistoryReader.readNewest(files,limit:3,kind:"memories").entries
                    if entries.isEmpty {entries=try HistoryReader.readNewest(files,limit:3,kind:"evidence").entries}
                    let pairs=(try? DesktopAccess.load(folder).pairs.count) ?? 0
                    return (entries.sorted { $0.date > $1.date },bytes,pairs)
                }.value
                guard !Task.isCancelled else { return }
                localBytes=result.1;savedSize.text=ByteCountFormatter.string(fromByteCount:result.1,countStyle:.file)
                agentSubtitle.text=result.2 == 0 ? "Connect Codex or Claude" : "\(result.2) approved \(result.2 == 1 ? "desktop":"desktops")"
                entries=result.0
            } catch { showPreview([],error:true);return }
            guard !Task.isCancelled else { return };showPreview(entries)
        }
    }

    private func showPreview(_ entries:[HistoryEntry], error:Bool=false) {
        for view in previewStack.arrangedSubviews { previewStack.removeArrangedSubview(view);view.removeFromSuperview() }
        if entries.isEmpty {
            let title=HistoryUI.label(error ? "History unavailable" : "Your history starts here",style:.subheadline,weight:.semibold)
            let detail=HistoryUI.label(error ? "Try refreshing in a moment." : "Start capture, then use your apps normally.",style:.subheadline,color:.secondaryLabel)
            let placeholder=UIView();HistoryUI.inset(HistoryUI.stack([title,detail],spacing:6),into:placeholder,amount:22);previewStack.addArrangedSubview(placeholder);return
        }
        let format=DateFormatter();format.timeStyle = .short
        for (index,entry) in entries.enumerated() {
            if index>0 { previewStack.addArrangedSubview(HistoryUI.separator()) }
            let name=HistoryUI.label(ContextText.title(entry),style:.subheadline,weight:.semibold)
            let time=HistoryUI.label(format.string(from:entry.date),style:.caption1,color:.secondaryLabel);time.setContentCompressionResistancePriority(.required,for:.horizontal)
            let heading=HistoryUI.stack([name,UIView(),time],spacing:10,axis:.horizontal);heading.alignment = .firstBaseline
            let excerpt=HistoryUI.label(entry.memory?.summary ?? ContextText.content(entry.text).joined(separator:" · "),style:.subheadline,color:.secondaryLabel);excerpt.numberOfLines=2
            let row=UIControl();let content=HistoryUI.stack([heading,excerpt],spacing:7);content.isUserInteractionEnabled=false
            HistoryUI.inset(content,into:row,amount:20);row.addTarget(self,action:#selector(recentPressed),for:.touchUpInside)
            row.isAccessibilityElement=true;row.accessibilityLabel="\(entry.label), \(time.text ?? ""). \(excerpt.text ?? "")";row.accessibilityTraits = .button
            previewStack.addArrangedSubview(row)
        }
    }
    private func refreshRetention() {
        guard let policy=try? StoragePolicy.load(HistoryPaths.folder()) else { return }
        switch policy.mode {
        case .window:retentionValue.text=ByteCountFormatter.string(fromByteCount:Int64(policy.maxBytes),countStyle:.binary);retentionCaption.text="Storage budget"
        case .none:retentionValue.text="No expiry";retentionCaption.text="Until you erase it"
        case .send:retentionValue.text="Transfer";retentionCaption.text="After a confirmed save"
        }
    }
    @objc private func settingsPressed() {
        let controller=HistorySettingsController(style:.insetGrouped)
        controller.exportHistory={ [weak self] in self?.exportPressed() }
        controller.eraseHistory={ [weak self] in self?.erasePressed() }
        controller.didChange={ [weak self] in self?.refreshRetention() }
        present(HistoryUI.sheet(controller),animated:true)
    }
    @objc private func aboutPressed() {
        present(HistoryUI.sheet(HistoryAboutController(style:.insetGrouped)),animated:true)
    }
    private func importBootstrapTrust() throws {
        let document = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let source = document.appendingPathComponent("vpn-trial-pairing.plist")
        guard FileManager.default.fileExists(atPath:source.path) else { return }
        let data = try Data(contentsOf:source)
        let record = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any]
        guard let record, (record["private_key"] as? Data)?.count == 32,
              (record["public_key"] as? Data)?.count == 32, record["identifier"] is String else {
            throw NSError(domain:"PhoneHistory",code:3,userInfo:[NSLocalizedDescriptionKey:"The developer trust file is invalid."])
        }
        let destination = try HistoryPaths.folder().appendingPathComponent("remote-pairing.plist")
        try data.write(to:destination,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
        try FileManager.default.removeItem(at:source)
    }
    @objc private func startPressed() {
        guard !busy else { return }
        busy = true; stateTitle.text="Starting"; status.text = "Starting capture. Approve the VPN configuration if iOS asks."
        Task {
            defer { busy = false }
            do {
                let pairing = try HistoryPaths.folder().appendingPathComponent("remote-pairing.plist")
                guard FileManager.default.fileExists(atPath:pairing.path) else {
                    throw NSError(domain:"PhoneHistory",code:4,userInfo:[NSLocalizedDescriptionKey:"Developer trust must be imported before capture can start."])
                }
                let all:[NETunnelProviderManager]
                if let manager { all=[manager] } else { all=try await NETunnelProviderManager.loadAllFromPreferences() }
                let manager = all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider } ?? NETunnelProviderManager()
                let config = NETunnelProviderProtocol()
                config.providerBundleIdentifier = HistoryPaths.provider
                config.serverAddress = "On-device history"
                config.providerConfiguration = ["schema":1]
                manager.protocolConfiguration = config
                manager.localizedDescription = "Phone History"
                manager.isEnabled = true
                let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]; manager.isOnDemandEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
                self.manager = manager
                var options: [String:NSObject] = [:]
                let args = CommandLine.arguments
                if let index=args.firstIndex(of:"--history-trial-seconds"), index+1<args.count, let seconds=Int(args[index+1]) {
                    options["trialSeconds"] = NSNumber(value:min(600,max(60,seconds)))
                }
                try manager.connection.startVPNTunnel(options:options)
                status.text = "Connecting. You can use your other apps normally."; refreshConnectionStatus()
            } catch { status.text = error.localizedDescription }
        }
    }
    @objc private func stopPressed() {
        guard !busy else { return }; busy = true;stateTitle.text="Pausing";status.text="Pausing capture…"
        Task {
            defer { busy = false }
            do {
                let all:[NETunnelProviderManager]
                if let manager { all=[manager] } else { all=try await NETunnelProviderManager.loadAllFromPreferences() }
                for manager in all where (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider {
                    manager.isOnDemandEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                    Task.detached(priority:.utility) { CaptureControlState.update(enabled:false) }
                }
                status.text = "Capture is paused. Your saved history is still here."; refreshConnectionStatus()
            } catch { status.text = error.localizedDescription }
        }
    }
    @objc private func refreshPressed() { refreshStatus() }
    private func refreshStatus() {
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-preview") { showSimulatorPreview();return }
        #endif
        guard refreshTask == nil else { return }
        loadPreview();refreshRetention()
        refreshTask=Task {
            defer { refreshTask=nil }
            do {
                let value=try await Task.detached(priority:.utility) {
                    let folder=try HistoryPaths.folder()
                    let data=try? Data(contentsOf:folder.appendingPathComponent("status.json"))
                    let value=data.flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] }
                    return value
                }.value
                workerStatus=value
                if CommandLine.arguments.contains("--verification-export") {
                    let folder=try HistoryPaths.folder()
                    try exportForInspection(folder)
                }
                refreshConnectionStatus()
            } catch { status.text=error.localizedDescription }
        }
    }
    private func writeVisibility(_ foreground:Bool) {
        let configuration:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,
            "label":Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "",
            "foreground":foreground,"updated_at":Date().timeIntervalSince1970]
        configurationQueue.async {
            guard let folder=try? HistoryPaths.folder(),let data=try? JSONSerialization.data(withJSONObject:configuration) else { return }
            try? data.write(to:folder.appendingPathComponent("capture-config.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
    }
    private func refreshConnectionStatus() {
        guard connectionTask == nil else { return }
        connectionTask=Task {
            defer { connectionTask=nil }
            do {
                let own:NETunnelProviderManager?
                if let manager { own=manager }
                else {
                    let all=try await NETunnelProviderManager.loadAllFromPreferences()
                    own=all.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider }
                }
                guard !Task.isCancelled else { return }
                manager=own
                let vpn = own?.connection.status ?? .disconnected
                let enabled=[NEVPNStatus.connected,.reasserting,.connecting].contains(vpn)
                Task.detached(priority:.utility) { CaptureControlState.update(enabled:enabled) }
                let value = workerStatus ?? [:]
                let age = max(0,Int(Date().timeIntervalSince1970-((value["updated_at"] as? NSNumber)?.doubleValue ?? 0)))
                let raw = value["state"] as? String ?? "waiting"
                let state: String
                let vpnState: String
                switch vpn {
                case .invalid,.disconnected: state = "Paused"; vpnState = "disconnected"
                case .connecting: state = "Starting"; vpnState = "connecting"
                case .disconnecting: state = "Stopping"; vpnState = "disconnecting"
                case .reasserting: state = "Reconnecting"; vpnState = "reasserting"
                case .connected:
                    vpnState = "connected"
                    state = age >= 90 ? "No recent capture update" : (raw == "running" ? "Capturing" : (raw == "reconnecting" ? "Reconnecting" : "Capture needs restart"))
                @unknown default: state = "Unknown"; vpnState = "unknown"
                }
                let bytes = (value["bytes_today"] as? NSNumber)?.int64Value ?? 0
                let hint = vpn == .disconnected || vpn == .invalid ? "Tap Start history to resume. Saved history remains on this phone." :
                    (state == "No recent capture update" || state == "Capture needs restart" ? "Tap Stop history, then Start history to retry." : "Status refreshes when you return.")
                updatePresentation(state:state,enabled:![NEVPNStatus.invalid,.disconnected,.disconnecting].contains(vpn),bytes:bytes)
                status.text = state == "Capturing" ? "Saving changed text across apps, on this phone." :
                    (state == "Paused" ? "Capture is paused. Your saved history is still here." : hint)
                let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                let destination = documents.appendingPathComponent("history-export/view-status.json")
                let snapshot:[String:Any] = ["vpn_status":vpnState,"effective_state":state,"worker_state":raw,
                    "worker_status_age_seconds":age,"on_demand_enabled":own?.isOnDemandEnabled ?? false,
                    "observed_at":Date().timeIntervalSince1970,"app_build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""]
                if CommandLine.arguments.contains("--verification-export") {
                    try JSONSerialization.data(withJSONObject:snapshot).write(to:destination,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                }
            } catch { status.text = "Could not check capture status. \(error.localizedDescription)" }
        }
    }
    @objc private func recentPressed() { present(HistoryUI.sheet(HistoryListController(style:.insetGrouped)),animated:true) }
    @objc private func agentsPressed() { present(HistoryUI.sheet(DesktopAccessController(style:.insetGrouped)),animated:true) }
    @objc private func erasePressed() {
        Task {
            do {
                let all = try await NETunnelProviderManager.loadAllFromPreferences()
                let active = all.contains { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider && ![NEVPNStatus.invalid,.disconnected].contains($0.connection.status) }
                let alert = UIAlertController(title:active ? "Stop capture first" : "Erase saved history?",message:active ? "Tap Stop history, wait until capture is paused, then erase." : "This deletes saved text and local inspection copies from this phone. Desktop approvals and setup are kept. Copies already exported to agents remain on those desktops.",preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:active ? "OK" : "Cancel",style:.cancel))
                if !active {
                    alert.addAction(UIAlertAction(title:"Erase history",style:.destructive) { [weak self] _ in
                        do {
                            let folder = try HistoryPaths.folder()
                            for name in ["Records","status.json","memory-status.json","memory-cursor.json"] {
                                let url = folder.appendingPathComponent(name)
                                if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
                            }
                            let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                            let copy = documents.appendingPathComponent("history-export")
                            if FileManager.default.fileExists(atPath:copy.path) { try FileManager.default.removeItem(at:copy) }
                            self?.refreshStatus()
                        } catch { self?.status.text = "History could not be erased. \(error.localizedDescription)" }
                    })
                }
                present(alert,animated:true)
            } catch { status.text = error.localizedDescription }
        }
    }
    private func exportForInspection(_ folder: URL) throws {
        // CoreDevice's app-group file export fails on this tested OS/toolchain.
        // Mirror only history/status to this app's document container when the
        // user opens or refreshes the app. Trust material is never exported.
        let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let destination = documents.appendingPathComponent("history-export",isDirectory:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true,
            attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication,.posixPermissions:0o700])
        if let data = try? Data(contentsOf:folder.appendingPathComponent("status.json")) {
            try data.write(to:destination.appendingPathComponent("status.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        let records = folder.appendingPathComponent("Records",isDirectory:true)
        if let files = try? FileManager.default.contentsOfDirectory(at:records,includingPropertiesForKeys:nil) {
            let owned = files.filter { $0.lastPathComponent.hasPrefix("history-") && $0.pathExtension == "jsonl" }
            let names = Set(owned.map { $0.lastPathComponent })
            for file in try FileManager.default.contentsOfDirectory(at:destination,includingPropertiesForKeys:nil)
                where file.lastPathComponent.hasPrefix("history-") && file.pathExtension == "jsonl" && !names.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at:file)
            }
            for file in owned {
                let data = try Data(contentsOf:file)
                try data.write(to:destination.appendingPathComponent(file.lastPathComponent),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
    @objc private func exportPressed() {
        do {
            let folder = try HistoryPaths.folder().appendingPathComponent("Records",isDirectory:true)
            let files = try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
            guard !files.isEmpty else { status.text = "No history records have been saved yet."; return }
            let share = UIActivityViewController(activityItems:files,applicationActivities:nil)
            share.popoverPresentationController?.sourceView = view
            present(share,animated:true)
        } catch { status.text = error.localizedDescription }
    }
    #if targetEnvironment(simulator)
    private func showSimulatorPreview() {
        let paused=CommandLine.arguments.contains("--ui-paused")
        updatePresentation(state:paused ? "Paused" : "Capturing",enabled:!paused,bytes:48320)
        status.text=paused ? "Capture is paused. Your saved history is still here." : "Saving changed text across apps, on this phone."
        agentSubtitle.text="1 approved desktop"
        showPreview([
            HistoryEntry(date:Date(),label:"Safari",text:["A quieter way to keep track", "Notes on making useful things."]),
            HistoryEntry(date:Date().addingTimeInterval(-300),label:"Notes",text:["Weekend plans", "Book the train and find a place for lunch."]),
            HistoryEntry(date:Date().addingTimeInterval(-600),label:"Music",text:["Evening playlist", "A little room to think."])
        ])
    }
    #endif

}
