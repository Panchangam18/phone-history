import UIKit
import UniformTypeIdentifiers
import NetworkExtension
import FoundationModels

@MainActor
final class SetupController: UIViewController, UIDocumentPickerDelegate {
    var startCapture: (() async throws -> Void)?
    var didFinish: (() -> Void)?
    private var step = SetupState.step()
    private var hasTrust = false
    private var captureVerified = false
    private var vpnActive = false
    private var desktops = 0
    private var policy = StoragePolicy()
    private var working = false
    #if targetEnvironment(simulator)
    private var previewTrust=false
    private var previewCapture=false
    private var previewDesktops=0
    private var interactivePreview:Bool {CommandLine.arguments.contains("--ui-interactive-setup")}
    private func previewPrompt(title:String,message:String,action:String,confirm:@escaping ()->Void) {
        let alert=UIAlertController(title:title,message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.addAction(UIAlertAction(title:action,style:.default) { _ in confirm();self.reloadState() })
        present(alert,animated:true)
    }
    #endif
    private var checkTask: Task<Void,Never>?
    private var activeObserver:NSObjectProtocol?
    private let scroll=UIScrollView()
    private let content = UIStackView()
    private let progress = HistoryUI.label(style:.subheadline,color:.secondaryLabel)
    private let primary = UIButton(type:.system)
    private let secondary = UIButton(type:.system)
    private let note = HistoryUI.label(style:.subheadline,color:.secondaryLabel)

    override func viewDidLoad() {
        super.viewDidLoad()
        title="Setup"; navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground; view.tintColor=HistoryUI.accent
        navigationItem.rightBarButtonItem=UIBarButtonItem(barButtonSystemItem:.close,target:self,action:#selector(close))
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-onboarding") {
            step = .capture
            if let index=CommandLine.arguments.firstIndex(of:"--ui-setup-step"),index+1<CommandLine.arguments.count,
               let number=Int(CommandLine.arguments[index+1]),let selected=SetupState.Step(rawValue:number) {step=selected}
        }
        #endif
        scroll.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(scroll)
        content.axis = .vertical; content.spacing=20
        content.translatesAutoresizingMaskIntoConstraints=false;scroll.addSubview(content)
        var buttonStyle=UIButton.Configuration.filled();buttonStyle.cornerStyle = .large
        buttonStyle.baseBackgroundColor=HistoryUI.accent;buttonStyle.contentInsets = .init(top:16,leading:24,bottom:16,trailing:24)
        primary.configuration=buttonStyle;primary.addTarget(self,action:#selector(nextPressed),for:.touchUpInside)
        secondary.addTarget(self,action:#selector(secondaryPressed),for:.touchUpInside)
        secondary.titleLabel?.font = .preferredFont(forTextStyle:.body);secondary.titleLabel?.adjustsFontForContentSizeCategory=true
        secondary.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
        let actions=HistoryUI.stack([note,primary,secondary],spacing:12)
        actions.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(actions)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo:view.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo:actions.topAnchor,constant:-16),
            content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:24),
            content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-16),
            content.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:20),
            content.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-20),
            content.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-40),
            actions.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),actions.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),
            actions.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-16)])
        activeObserver=NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in guard let self,self.viewIfLoaded?.window != nil else {return};self.reloadState() }
        }
        SetupState.save(step)
        render();reloadState()
    }
    deinit {if let activeObserver {NotificationCenter.default.removeObserver(activeObserver)}}
    override func viewWillAppear(_ animated:Bool) {super.viewWillAppear(animated);reloadState()}
    override func viewDidDisappear(_ animated:Bool) {super.viewDidDisappear(animated);checkTask?.cancel()}
    @objc private func close() {checkTask?.cancel();dismiss(animated:true,completion:didFinish)}
    private func button(_ title:String, _ action:Selector) -> UIButton {
        let button=UIButton(type:.system);button.setTitle(title,for:.normal)
        button.titleLabel?.font = .preferredFont(forTextStyle:.body);button.titleLabel?.adjustsFontForContentSizeCategory=true;button.titleLabel?.numberOfLines=0
        button.contentHorizontalAlignment = .leading;button.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
        button.addTarget(self,action:action,for:.touchUpInside);return button
    }
    private func row(_ title:String,_ text:String,_ symbol:String) -> UIView {
        let icon=HistoryUI.sectionIcon(symbol)
        let labels=HistoryUI.stack([HistoryUI.label(title,style:.headline),HistoryUI.label(text,style:.subheadline,color:.secondaryLabel)],spacing:6)
        let row=HistoryUI.stack([icon,labels],spacing:16,axis:.horizontal);row.alignment = .top;return row
    }
    private func render() {
        content.arrangedSubviews.forEach {content.removeArrangedSubview($0);$0.removeFromSuperview()}
        progress.text="\(step.rawValue+1) of \(SetupState.Step.allCases.count)"
        content.addArrangedSubview(progress)
        let heading=HistoryUI.label(step == .capture ? "Set up capture":"Connect your desktop",style:.largeTitle,weight:.bold)
        heading.accessibilityTraits = .header;content.addArrangedSubview(heading)
        note.isHidden=true;note.text=nil
        if step == .capture {
            let explanation=HistoryUI.label("Activity memories stay on this iPhone. Images are discarded; visible private content may be saved.",style:.subheadline,color:.secondaryLabel)
            content.addArrangedSubview(explanation)
            var rows:[UIView]=[
                row("Developer Mode required","Keep Developer Mode enabled for capture. Settings → Privacy & Security → Developer Mode; restart and confirm if enabling it.","wrench.and.screwdriver"),
                button("Open Settings",#selector(developerModeHelp))
            ]
            if !hasTrust {
                rows.append(row("Import developer trust","Connect to your own Mac by USB. Follow the Mac guide to export this phone’s secret trust file.","key"))
            } else {
                rows.append(row("Developer trust imported","Start capture to verify the on-device connection.","checkmark.circle"))
            }
            let storage:String
            switch policy.mode {
            case .window:storage=ByteCountFormatter.string(fromByteCount:Int64(policy.maxBytes),countStyle:.binary)
            case .none:storage="No removal"
            case .send:storage="Transfer after confirmed save"
            }
            content.addArrangedSubview(HistoryUI.card(HistoryUI.stack(rows,spacing:20)))
            if !hasTrust {content.addArrangedSubview(button("Mac setup guide ↗",#selector(macGuide)))}
            content.addArrangedSubview(button("Storage · " + storage,#selector(storageSettings)))
            content.addArrangedSubview(HistoryUI.label("Capture uses a local VPN. Approve iOS’s prompt; its VPN indicator stays visible. Another packet-tunnel VPN cannot run alongside it.",style:.subheadline,color:.secondaryLabel))
            if !SystemLanguageModel.default.isAvailable {
                content.addArrangedSubview(HistoryUI.label("For activity summaries, enable Apple Intelligence in Settings on a supported iPhone. Evidence still saves without it.",style:.subheadline,color:.secondaryLabel))
            }
            if vpnActive && !captureVerified {
                note.text="VPN connected. Waiting for capture to report ready.";note.isHidden=false
                content.addArrangedSubview(button("Check capture status",#selector(checkPressed)))
            }
            primary.configuration?.title = !hasTrust ? "Import trust file":(captureVerified ? "Continue":(vpnActive ? "Retry capture":"Start capture"))
            secondary.setTitle("Set up later",for:.normal)
        } else {
            let rows=[row(desktops > 0 ? "Desktop approved":"Optional agent access","Use the same Wi-Fi. Import your connector’s pairing request, compare fingerprints, approve, then share the connection file back.","laptopcomputer"),
                      row("You choose what to share","Allow Local Network if iOS asks. Screenshots need separate approval and stay off by default. Revoke access in Settings anytime.","lock")]
            content.addArrangedSubview(HistoryUI.card(HistoryUI.stack(rows,spacing:24)))
            content.addArrangedSubview(button(desktops > 0 ? "Manage desktop connection":"Connect a desktop",#selector(connectDesktop)))
            content.addArrangedSubview(button("Desktop connector guide ↗",#selector(desktopGuide)))
            content.addArrangedSubview(button("Open iPhone settings",#selector(appSettings)))
            content.addArrangedSubview(HistoryUI.label("For quick on/off, add Phone History from Control Center → Add a Control.",style:.subheadline,color:.secondaryLabel))
            if !captureVerified {note.text="Capture is paused or needs attention. Go back to start it.";note.isHidden=false}
            primary.configuration?.title = desktops > 0 ? "Done":"Skip for now"
            secondary.setTitle("Back",for:.normal)
        }
        primary.configuration?.showsActivityIndicator=working
        primary.isEnabled = !working && (step == .capture || SetupState.canAdvance(step,hasTrust:hasTrust,captureVerified:captureVerified))
        secondary.isEnabled = !working
        navigationItem.rightBarButtonItem?.isEnabled = !working
        navigationController?.isModalInPresentation=working
    }
    private func reloadState() {
        Task {
            do {try await readState();render()}
            catch {note.text="Could not check setup. \(error.localizedDescription)";note.isHidden=false}
        }
    }
    private func readState() async throws {
        #if targetEnvironment(simulator)
        if interactivePreview {
            hasTrust=previewTrust;captureVerified=previewCapture;vpnActive=previewCapture;desktops=previewDesktops
            policy=try await Task.detached(priority:.utility) {try StoragePolicy.load(HistoryPaths.folder())}.value
            return
        }
        #endif
        let value=try await Task.detached(priority:.utility) {
            let folder=try HistoryPaths.folder()
            let hasTrust=FileManager.default.fileExists(atPath:folder.appendingPathComponent("remote-pairing.plist").path)
            let status=(try? Data(contentsOf:folder.appendingPathComponent("status.json"))).flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] }
            return (hasTrust,try StoragePolicy.load(folder),(try? DesktopAccess.load(folder).pairs.count) ?? 0,status?["state"] as? String,(status?["updated_at"] as? NSNumber)?.doubleValue ?? 0)
        }.value
        let own=try await NETunnelProviderManager.loadAllFromPreferences().first {($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider}
        hasTrust=value.0;policy=value.1;desktops=value.2
        vpnActive=own?.connection.status == .connected
        captureVerified=hasTrust && SetupState.captureIsReady(vpnConnected:vpnActive,workerState:value.3,updatedAt:value.4)
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-preview") {hasTrust=step == .desktop;captureVerified=step == .desktop;vpnActive=captureVerified}
        #endif
    }
    private func advance() {
        guard let next=SetupState.Step(rawValue:step.rawValue+1) else {return}
        checkTask?.cancel();step=next;SetupState.save(step);render();resetScroll();reloadState()
        UIAccessibility.post(notification:.screenChanged,argument:progress)
    }
    @objc private func nextPressed() {
        guard !working else {return}
        if step == .capture && !hasTrust {importTrust();return}
        if step == .capture && !captureVerified {
            #if targetEnvironment(simulator)
            if interactivePreview {
                previewPrompt(title:"Allow capture?",message:"Simulator preview of the VPN approval. No VPN or capture will be started.",action:"Allow") {self.previewCapture=true}
                return
            }
            #endif
            working=true;render()
            Task {
                do {
                    guard let startCapture else {throw NSError(domain:"PhoneHistory",code:6,userInfo:[NSLocalizedDescriptionKey:"Capture is unavailable. Close setup and try again."])}
                    try await startCapture();working=false;reloadState()
                    checkTask?.cancel()
                    checkTask=Task { [weak self] in
                        for _ in 0..<15 {
                            do {try await Task.sleep(for:.seconds(2))} catch {return}
                            guard let self,self.viewIfLoaded?.window != nil,self.step == .capture else {return}
                            self.reloadState();if self.captureVerified {return}
                        }
                    }
                } catch {working=false;render();note.text=error.localizedDescription;note.isHidden=false}
            }
            return
        }
        guard SetupState.canAdvance(step,hasTrust:hasTrust,captureVerified:captureVerified) else {return}
        if step == .desktop {
            working=true;render()
            Task {
                do {
                    try await readState();working=false;render()
                    guard captureVerified else {return}
                    SetupState.complete();close()
                } catch {working=false;render();note.text=error.localizedDescription;note.isHidden=false}
            }
        } else {advance()}
    }
    @objc private func secondaryPressed() {
        if step == .capture {close()}
        else {checkTask?.cancel();step = .capture;SetupState.save(step);render();resetScroll();reloadState()}
    }
    private func resetScroll() {
        view.layoutIfNeeded();scroll.setContentOffset(CGPoint(x:0,y:-scroll.adjustedContentInset.top),animated:false)
    }
    @objc private func checkPressed() {reloadState()}
    @objc private func macGuide() {UIApplication.shared.open(URL(string:"https://github.com/Panchangam18/phone-history/blob/main/docs/SETUP.md")!)}
    @objc private func desktopGuide() {UIApplication.shared.open(URL(string:"https://github.com/Panchangam18/phone-history/blob/main/Desktop/README.md")!)}
    @objc private func appSettings() {UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!)}
    @objc private func developerModeHelp() {
        #if targetEnvironment(simulator)
        if interactivePreview {
            previewPrompt(title:"Developer Mode",message:"Simulator preview only. On an iPhone, this step opens Settings and you enable Developer Mode, restart and confirm.",action:"Try next step") {}
            return
        }
        #endif
        let alert=UIAlertController(title:"Enable Developer Mode",message:"The shortcut opens Phone History’s settings. Go back to the main Settings list, then Privacy & Security → Developer Mode. Turn it on, restart and confirm.\n\nIf the switch is missing, connect your iPhone to Xcode on your own Mac first.",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Open Settings",style:.default) { [weak self] _ in self?.appSettings() })
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel));present(alert,animated:true)
    }
    @objc private func storageSettings() {
        let settings=HistorySettingsController(style:.insetGrouped);settings.storageOnly=true
        navigationController?.pushViewController(settings,animated:true)
    }
    @objc private func connectDesktop() {
        #if targetEnvironment(simulator)
        if interactivePreview {
            if previewDesktops > 0 {
                previewPrompt(title:"Preview desktop",message:"Screenshots are off. This is a mock approval; no device has access.",action:"Revoke preview desktop") {self.previewDesktops=0}
            } else {
                previewPrompt(title:"Approve preview desktop?",message:"Preview of fingerprint approval. On a real device you import a public pairing request and compare its fingerprint with your desktop. No device is connected in this demo.",action:"Approve preview desktop") {self.previewDesktops=1}
            }
            return
        }
        #endif
        navigationController?.pushViewController(DesktopAccessController(style:.insetGrouped),animated:true)
    }
    @objc private func importTrust() {
        #if targetEnvironment(simulator)
        if interactivePreview {
            previewPrompt(title:"Import trust file",message:"Simulator preview: use a sample import. On your iPhone, you choose the secret file exported by its own Mac.",action:"Import sample") {self.previewTrust=true}
            return
        }
        #endif
        let picker=UIDocumentPickerViewController(forOpeningContentTypes:[.propertyList],asCopy:false)
        picker.delegate=self;present(picker,animated:true)
    }
    func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
        guard let source=urls.first else {return}
        working=true;render()
        Task {
            defer {working=false;reloadState()}
            let access=source.startAccessingSecurityScopedResource();defer {if access {source.stopAccessingSecurityScopedResource()}}
            do {
                let own=try await NETunnelProviderManager.loadAllFromPreferences().first {($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider}
                guard own == nil || [.invalid,.disconnected].contains(own!.connection.status) else {throw DeveloperTrust.ImportError.alreadyRunning}
                try await Task.detached(priority:.userInitiated) {try DeveloperTrust.install(source,folder:HistoryPaths.folder())}.value
                let alert=UIAlertController(title:"Trust imported",message:"The protected copy stays on this iPhone. Delete the temporary exported file from Files and your Mac; never send it to someone else.",preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"OK",style:.default));present(alert,animated:true)
            } catch {
                let alert=UIAlertController(title:"Couldn’t import trust",message:error.localizedDescription,preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"OK",style:.default));present(alert,animated:true)
            }
        }
    }
}
