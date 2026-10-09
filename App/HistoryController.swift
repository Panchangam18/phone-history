import UIKit
import NetworkExtension

@MainActor
final class HistoryController: UIViewController {
    private let status = UILabel()
    private var manager: NETunnelProviderManager?
    private var busy = false { didSet { updateCaptureControl() } }
    private var captureEnabled = false
    private let stateTitle = HistoryUI.label("Paused",style:.body,weight:.medium)
    private let stateSubtitle = HistoryUI.label("Resume anytime",style:.subheadline,color:.secondaryLabel)
    private let captureSwitch = UISwitch()
    private let captureProgress = UIActivityIndicatorView(style:.medium)
    private let retentionValue = HistoryUI.label("512 KB",style:.body,weight:.medium)
    private let retentionCaption = HistoryUI.label("Storage budget",style:.subheadline,color:.secondaryLabel)
    private var localBytes:Int64?
    private let savedSize = HistoryUI.label("—",style:.body,weight:.medium)
    private let previewStack = UIStackView()
    private var previewTask: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
    private var connectionTask: Task<Void,Never>?
    private var startStatusTask:Task<Void,Never>?
    private var startStatusRevision=0
    private var captureStartedAt:Date?
    private var backgroundObserver:NSObjectProtocol?
    private let configurationQueue=DispatchQueue(label:"PhoneHistory.Visibility",qos:.userInitiated)

    private var started = false
    private var foregroundObserver: NSObjectProtocol?
    private var connectionObserver: NSObjectProtocol?
    private var workerStatus: [String:Any]?

    override func viewDidLoad() {
        super.viewDidLoad()
        title="Phone history"
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
                self.refreshStatus()
            }
        }
        backgroundObserver=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.writeVisibility(false);self?.startStatusTask?.cancel();self?.startStatusTask=nil }
        }
        writeVisibility(true)
        do { try importBootstrapTrust(); refreshStatus() }
        catch { showStatus(error.localizedDescription) }
    }
    deinit {
        startStatusTask?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let connectionObserver { NotificationCenter.default.removeObserver(connectionObserver) }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !started {
            started = true
            #if DEBUG
            if CommandLine.arguments.contains("--summary-replay") {
                let background=UIApplication.shared.beginBackgroundTask(withName:"Summary replay")
                Task.detached(priority:.utility) {
                    await SummaryReplay.run()
                    await MainActor.run {UIApplication.shared.endBackgroundTask(background)}
                }
            }
            #endif
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
            if CommandLine.arguments.contains("--show-onboarding") || CommandLine.arguments.contains("--ui-onboarding") {showSetup()}
            else if !CommandLine.arguments.contains("--ui-preview"), !CommandLine.arguments.contains("--pair-desktop") {
                Task {
                    let hasTrust=await Task.detached(priority:.utility) { (try? HistoryPaths.folder()).map {FileManager.default.fileExists(atPath:$0.appendingPathComponent("remote-pairing.plist").path)} ?? false }.value
                    let configurations=(try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
                    let existing=hasTrust && configurations.contains {($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider}
                    if SetupState.shouldPresent(hasExistingSetup:existing) {showSetup()}
                }
            }
            if CommandLine.arguments.contains("--pair-desktop") { agentsPressed() }
            if CommandLine.arguments.contains("--verification-export") {
                Task { try? await Task.sleep(nanoseconds:4_000_000_000); refreshStatus() }
            }
        }
    }
    private func buildInterface() {
        let heading=HistoryUI.label("Phone history",style:.largeTitle,weight:.bold)
        heading.accessibilityTraits = .header
        let settings=UIButton(type:.system)
        var settingsStyle=UIButton.Configuration.plain()
        settingsStyle.image=UIImage(systemName:"gearshape")
        settingsStyle.preferredSymbolConfigurationForImage = .init(pointSize:22,weight:.regular)
        settingsStyle.baseForegroundColor=HistoryUI.accent
        settingsStyle.background.backgroundColor = .tertiarySystemFill
        settingsStyle.cornerStyle = .capsule
        settings.configuration=settingsStyle
        settings.accessibilityLabel="Settings"
        settings.addTarget(self,action:#selector(settingsPressed),for:.touchUpInside)
        NSLayoutConstraint.activate([settings.widthAnchor.constraint(equalToConstant:44),settings.heightAnchor.constraint(equalToConstant:44)])
        let homeHeading=HistoryUI.stack([heading,UIView(),settings],spacing:12,axis:.horizontal)
        homeHeading.alignment = .center
        let stateLabels=HistoryUI.stack([stateTitle,stateSubtitle],spacing:4)
        captureSwitch.onTintColor=HistoryUI.accent
        captureSwitch.accessibilityLabel="Capture"
        captureSwitch.addTarget(self,action:#selector(capturePressed),for:.valueChanged)
        captureSwitch.setContentHuggingPriority(.required,for:.horizontal)
        captureSwitch.setContentCompressionResistancePriority(.required,for:.horizontal)
        captureProgress.hidesWhenStopped=true
        let stateRow=HistoryUI.stack([stateLabels,captureProgress,captureSwitch],spacing:16,axis:.horizontal);stateRow.alignment = .center
        status.font = .preferredFont(forTextStyle:.footnote);status.adjustsFontForContentSizeCategory=true;status.textColor = .secondaryLabel;status.numberOfLines=0
        status.isHidden=true
        let metrics=HistoryUI.stack([
            HistoryUI.stack([savedSize,HistoryUI.label("Stored here",style:.subheadline,color:.secondaryLabel)],spacing:3),
            HistoryUI.stack([retentionValue,retentionCaption],spacing:3)
        ],spacing:20,axis:.horizontal);metrics.distribution = .fillEqually
        let configureStorageLayout = { [weak metrics] (category:UIContentSizeCategory) in
            let expanded=category.isAccessibilityCategory
            metrics?.axis=expanded ? .vertical:.horizontal
            metrics?.distribution=expanded ? .fill:.fillEqually
        }
        configureStorageLayout(traitCollection.preferredContentSizeCategory)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view:HistoryController, _:UITraitCollection) in
            configureStorageLayout(view.traitCollection.preferredContentSizeCategory)
        }
        let content=HistoryUI.stack([stateRow,HistoryUI.separator(),metrics],spacing:20)
        let captureCard=HistoryUI.card(content);captureCard.layer.cornerRadius=20
        let captureSection=HistoryUI.stack([captureCard,status],spacing:10)
        status.translatesAutoresizingMaskIntoConstraints=false
        status.leadingAnchor.constraint(equalTo:captureCard.leadingAnchor,constant:12).isActive=true
        status.trailingAnchor.constraint(equalTo:captureCard.trailingAnchor,constant:-12).isActive=true
        captureSection.alignment = .center
        captureCard.widthAnchor.constraint(equalTo:captureSection.widthAnchor).isActive=true
        let recent=HistoryUI.label("History",style:.headline);recent.accessibilityTraits = .header
        let historyIcon=HistoryUI.sectionIcon("clock.arrow.circlepath")
        let historyHeading=HistoryUI.stack([historyIcon,recent],spacing:HistoryUI.sectionIconSpacing,axis:.horizontal);historyHeading.alignment = .center
        let all=UIButton(type:.system);all.setTitle("See all",for:.normal);all.addTarget(self,action:#selector(recentPressed),for:.touchUpInside)
        all.titleLabel?.font = .preferredFont(forTextStyle:.subheadline);all.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
        let recentHeading=HistoryUI.stack([historyHeading,UIView(),all],axis:.horizontal);recentHeading.alignment = .center
        recentHeading.isLayoutMarginsRelativeArrangement=true
        recentHeading.directionalLayoutMargins=NSDirectionalEdgeInsets(top:8,leading:20,bottom:8,trailing:20)
        previewStack.axis = .vertical;previewStack.spacing=0
        let recentSection=HistoryUI.card(HistoryUI.stack([recentHeading,HistoryUI.separator(),previewStack],spacing:0),inset:0)
        let stack=HistoryUI.stack([homeHeading,captureSection,recentSection],spacing:24)
        let scroll=UIScrollView();scroll.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(scroll);scroll.alwaysBounceVertical=true
        let refresh=UIRefreshControl();refresh.addTarget(self,action:#selector(pullRefresh(_:)),for:.valueChanged);scroll.refreshControl=refresh
        stack.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            // Keep the frame fixed; UIKit applies the safe-area content insets.
            scroll.topAnchor.constraint(equalTo:view.topAnchor),scroll.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            stack.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:64),stack.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-40),
            stack.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),
            stack.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40)])
        updateCaptureControl()
    }
    private func updateCaptureControl() {
        // Leave the user's requested switch position visible while the async
        // transition runs; the connection callback supplies the final state.
        if !busy { captureSwitch.setOn(captureEnabled,animated:view.window != nil) }
        captureSwitch.isEnabled = !busy
        if busy { captureProgress.startAnimating() } else { captureProgress.stopAnimating() }
        captureSwitch.accessibilityHint=captureEnabled ? "Pauses capture and keeps saved history." : "Starts capture on this iPhone."
    }
    @objc private func capturePressed() {
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-preview") {
            let enabled=captureSwitch.isOn
            updatePresentation(state:enabled ? "Capturing" : "Paused",enabled:enabled,bytes:48320)
            showStatus(nil)
            return
        }
        #endif
        if captureEnabled { stopPressed() } else { startPressed() }
    }
    @objc private func pullRefresh(_ sender:UIRefreshControl) { refreshStatus();sender.endRefreshing() }
    private func showStatus(_ message:String?) {
        status.text=message
        status.isHidden=message?.isEmpty != false
    }
    private func setCaptureState(_ state:String) {
        stateTitle.text=state
        switch state {
        case "Capturing":stateSubtitle.text="On this iPhone"
        case "Paused":stateSubtitle.text="Resume anytime"
        case "Starting","Stopping","Pausing","Reconnecting":stateSubtitle.text="Please wait"
        default:stateSubtitle.text="Needs your attention"
        }
    }
    private func updatePresentation(state:String, enabled:Bool, bytes:Int64) {
        captureEnabled=enabled;setCaptureState(state)
        savedSize.text=ByteCountFormatter.string(fromByteCount:localBytes ?? bytes,countStyle:.file)
        updateCaptureControl()
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
                    return (entries.sorted { $0.date > $1.date },bytes)
                }.value
                guard !Task.isCancelled else { return }
                localBytes=result.1;savedSize.text=ByteCountFormatter.string(fromByteCount:result.1,countStyle:.file)
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
        controller.setupGuide={ [weak self] in self?.showSetup() }
        present(HistoryUI.sheet(controller),animated:true)
    }
    private func showSetup() {
        guard presentedViewController == nil else {return}
        let controller=SetupController()
        controller.startCapture={ [weak self] in guard let self else {return};try await self.beginCapture() }
        controller.didFinish={ [weak self] in self?.refreshStatus() }
        present(HistoryUI.sheet(controller),animated:true)
    }
    @objc private func aboutPressed() {
        present(HistoryUI.sheet(HistoryAboutController(style:.insetGrouped)),animated:true)
    }
    private func importBootstrapTrust() throws {
        let document = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let source = document.appendingPathComponent("vpn-trial-pairing.plist")
        guard FileManager.default.fileExists(atPath:source.path) else { return }
        try DeveloperTrust.install(source,folder:HistoryPaths.folder())
        try FileManager.default.removeItem(at:source)
    }
    @objc private func startPressed() {
        guard !busy else {return}
        if let folder=try? HistoryPaths.folder(),!FileManager.default.fileExists(atPath:folder.appendingPathComponent("remote-pairing.plist").path) {showSetup();return}
        Task {do {try await beginCapture()} catch {showStatus(error.localizedDescription)}}
    }
    private func beginCapture() async throws {
        guard !busy else {throw NSError(domain:"PhoneHistory",code:5,userInfo:[NSLocalizedDescriptionKey:"Capture is already changing state. Please try again in a moment."])}
        busy=true;setCaptureState("Starting");showStatus("Approve the VPN configuration if iOS asks.")
        defer {busy=false}
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
        captureStartedAt=Date()
        showStatus(nil);refreshStatus();monitorCaptureStart()
    }
    private func monitorCaptureStart() {
        startStatusTask?.cancel();startStatusRevision+=1
        let revision=startStatusRevision
        startStatusTask=Task { [weak self] in
            defer {if self?.startStatusRevision == revision {self?.startStatusTask=nil}}
            for _ in 0..<45 {
                do {try await Task.sleep(for:.seconds(1))} catch {return}
                guard let self,UIApplication.shared.applicationState == .active else {return}
                let value=await Task.detached(priority:.utility) {
                    guard let folder=try? HistoryPaths.folder(),let data=try? Data(contentsOf:folder.appendingPathComponent("status.json")) else {return [String:Any]()}
                    return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
                }.value
                guard !Task.isCancelled else {return}
                self.workerStatus=value;self.refreshConnectionStatus()
                let updated=(value["updated_at"] as? NSNumber)?.doubleValue ?? 0
                if self.manager?.connection.status == .connected,value["state"] as? String == "running",updated >= self.captureStartedAt?.timeIntervalSince1970 ?? 0 {return}
            }
            self?.captureStartedAt=nil;self?.refreshStatus()
        }
    }
    @objc private func stopPressed() {
        guard !busy else { return }; busy = true;setCaptureState("Pausing");showStatus(nil)
        startStatusTask?.cancel();startStatusTask=nil;captureStartedAt=nil
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
                showStatus(nil); refreshConnectionStatus()
            } catch { showStatus(error.localizedDescription) }
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
            } catch { showStatus(error.localizedDescription) }
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
                    let updated=(value["updated_at"] as? NSNumber)?.doubleValue ?? 0
                    if let captureStartedAt,Date().timeIntervalSince(captureStartedAt)<45,(updated<captureStartedAt.timeIntervalSince1970 || raw != "running") {state="Starting"}
                    else {state = age >= 90 ? "No recent capture update" : (raw == "running" ? "Capturing" : (raw == "reconnecting" ? "Reconnecting" : "Capture needs restart"))}
                @unknown default: state = "Unknown"; vpnState = "unknown"
                }
                let bytes = (value["bytes_today"] as? NSNumber)?.int64Value ?? 0
                let hint = state == "Starting" ? "Connecting to this iPhone…" : vpn == .disconnected || vpn == .invalid ? "Turn capture on to resume. Saved history stays on this iPhone." :
                    (state == "No recent capture update" || state == "Capture needs restart" ? "Turn capture off and on to retry." : "Status refreshes when you return.")
                updatePresentation(state:state,enabled:![NEVPNStatus.invalid,.disconnected,.disconnecting].contains(vpn),bytes:bytes)
                showStatus(state == "Capturing" || state == "Paused" ? nil : hint)
                let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                let destination = documents.appendingPathComponent("history-export/view-status.json")
                let snapshot:[String:Any] = ["vpn_status":vpnState,"effective_state":state,"worker_state":raw,
                    "worker_status_age_seconds":age,"on_demand_enabled":own?.isOnDemandEnabled ?? false,
                    "observed_at":Date().timeIntervalSince1970,"app_build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""]
                if CommandLine.arguments.contains("--verification-export") {
                    try JSONSerialization.data(withJSONObject:snapshot).write(to:destination,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                }
            } catch { showStatus("Could not check capture status. \(error.localizedDescription)") }
        }
    }
    @objc private func recentPressed() { present(HistoryUI.sheet(HistoryListController(style:.insetGrouped)),animated:true) }
    @objc private func agentsPressed() { present(HistoryUI.sheet(DesktopAccessController(style:.insetGrouped)),animated:true) }
    @objc private func erasePressed() {
        Task {
            do {
                let all = try await NETunnelProviderManager.loadAllFromPreferences()
                let active = all.contains { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider && ![NEVPNStatus.invalid,.disconnected].contains($0.connection.status) }
                let alert = UIAlertController(title:active ? "Pause capture first" : "Erase saved history?",message:active ? "Turn capture off, wait until it is paused, then erase." : "This deletes saved text and local inspection copies from this phone. Desktop approvals and setup are kept. Copies already exported to agents remain on those desktops.",preferredStyle:.alert)
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
                        } catch { self?.showStatus("History could not be erased. \(error.localizedDescription)") }
                    })
                }
                present(alert,animated:true)
            } catch { showStatus(error.localizedDescription) }
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
        try HistoryPaths.excludeFromBackup(destination)
        if let data = try? Data(contentsOf:folder.appendingPathComponent("status.json")) {
            try data.write(to:destination.appendingPathComponent("status.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        }
        for name in ["memory-status.json","last-exit.json","last-stop.json","desktop-server.json"] {
            if let data=try? Data(contentsOf:folder.appendingPathComponent(name)) {
                try data.write(to:destination.appendingPathComponent(name),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            }
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
            guard !files.isEmpty else { showStatus("No history records have been saved yet."); return }
            let share = UIActivityViewController(activityItems:files,applicationActivities:nil)
            share.popoverPresentationController?.sourceView = view
            present(share,animated:true)
        } catch { showStatus(error.localizedDescription) }
    }
    #if targetEnvironment(simulator)
    private func showSimulatorPreview() {
        if CommandLine.arguments.contains("--ui-dark") { overrideUserInterfaceStyle = .dark }
        if CommandLine.arguments.contains("--ui-large-type") { traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        let paused=CommandLine.arguments.contains("--ui-paused")
        let state=CommandLine.arguments.contains("--ui-stale") ? "No recent capture update" : (paused ? "Paused" : "Capturing")
        updatePresentation(state:state,enabled:!paused,bytes:48320)
        showStatus(CommandLine.arguments.contains("--ui-stale") ? "Turn capture off and on to retry." : nil)
        showPreview([
            HistoryEntry(date:Date(),label:"Safari",text:["A quieter way to keep track", "Notes on making useful things."]),
            HistoryEntry(date:Date().addingTimeInterval(-300),label:"Notes",text:["Weekend plans", "Book the train and find a place for lunch."]),
            HistoryEntry(date:Date().addingTimeInterval(-600),label:"Music",text:["Evening playlist", "A little room to think."])
        ])
    }
    #endif

}
