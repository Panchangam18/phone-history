import UIKit
import UniformTypeIdentifiers
import NetworkExtension
import CryptoKit

@MainActor
final class DesktopAccessController: UITableViewController, UIDocumentPickerDelegate {
    private var pairs: [DesktopPair] = []
    private var endpoint = "Start capture to make desktop access available."
    private var loading=false
    private var reviewedLaunchRequest = false
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Desktop connection"
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = .systemGroupedBackground;tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=72;view.tintColor=HistoryUI.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem:.done,target:self,action:#selector(close))
        let label = UILabel(); label.numberOfLines = 0; label.font = .preferredFont(forTextStyle:.subheadline); label.textColor = .secondaryLabel
        label.text = "Give Codex or Claude access to your phone’s memory. Only desktops you approve can read history, over the same Wi-Fi.\n\nCreate a request with the desktop connector, import it here, then compare the fingerprint before approving."
        let header = UIView(); header.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo:header.topAnchor,constant:16),label.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-16),label.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:20),label.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-20),label.widthAnchor.constraint(equalToConstant:max(250,view.bounds.width-40))])
        header.frame.size = header.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        tableView.tableHeaderView = header; refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !reviewedLaunchRequest && CommandLine.arguments.contains("--pair-desktop") {
            reviewedLaunchRequest = true
            let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            reviewRequest(documents.appendingPathComponent("phone-history-desktop-request.json"))
        }
    }
    @objc private func close() { dismiss(animated:true) }
    private func refresh() {
        guard !loading else { return };loading=true
        Task {
            defer { loading=false }
            do {
                let value=try await Task.detached(priority:.utility) {
                    let folder=try HistoryPaths.folder()
                    return (try DesktopAccess.load(folder).pairs,DesktopExportServer.wifiAddresses())
                }.value
                pairs=value.0
                if !value.1.isEmpty { endpoint="Same Wi-Fi · \(value.1.joined(separator:", ")):\(DesktopAccess.port)\nCapture must be running. Update the desktop’s host if your Wi-Fi address changes." }
                tableView.reloadData()
            } catch { showError(error) }
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : pairs.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Connect a desktop" : "Approved desktops (\(pairs.count)/8)" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { section == 0 ? endpoint : "Approval grants read access to up to seven days of saved text. Approved desktops can also request a fresh, bounded AX text check (once per 30 seconds). Screenshots are off by default; enable them separately for a trusted desktop. No desktop can control your phone through this connector." }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style:.subtitle,reuseIdentifier:nil)
        if indexPath.section == 0 { cell.textLabel?.text = "Import desktop pairing request"; cell.textLabel?.textColor = HistoryUI.accent;cell.imageView?.image=UIImage(systemName:"plus.circle.fill");cell.imageView?.tintColor=HistoryUI.accent }
        else {
            let pair = pairs[indexPath.row]; cell.textLabel?.text = pair.name; cell.detailTextLabel?.text = pair.allowsScreenshots ? "Screenshots allowed · Tap to manage" : "Screenshots off · Tap to manage"; cell.accessoryType = .disclosureIndicator;cell.imageView?.image=UIImage(systemName:"laptopcomputer");cell.imageView?.tintColor=HistoryUI.accent
        }
        cell.detailTextLabel?.numberOfLines=0;cell.textLabel?.font = .preferredFont(forTextStyle:.body);cell.textLabel?.adjustsFontForContentSizeCategory=true;cell.detailTextLabel?.font = .preferredFont(forTextStyle:.caption1);cell.detailTextLabel?.adjustsFontForContentSizeCategory=true
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        if indexPath.section == 0 {
            guard pairs.count < 8 else { showErrorMessage("Revoke a desktop before adding another."); return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.json],asCopy:true)
            picker.delegate = self; present(picker,animated:true)
        } else { manage(pairs[indexPath.row],source:tableView.cellForRow(at:indexPath)) }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }; reviewRequest(url)
    }
    private func reviewRequest(_ url: URL) {
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0 <= 4096 else { throw DesktopAccess.AccessError.invalidRequest }
            let data = try Data(contentsOf:url)
            guard let request = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  request["protocol"] as? String == DesktopAccess.protocolName,
                  let name = request["desktop_name"] as? String, !name.isEmpty, name.count <= 80,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  let encoded = request["desktop_public_key"] as? String,
                  let publicData = Data(base64Encoded:encoded), publicData.count == 32 else { throw DesktopAccess.AccessError.invalidRequest }
            _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation:publicData)
            let fingerprint = DesktopAccess.fingerprint(publicData)
            let alert = UIAlertController(title:"Approve \(name)?",message:"Compare this fingerprint with the connector on that desktop:\n\n\(fingerprint)\n\nThis desktop can read saved text from the last seven days, including private content, and request fresh bounded accessibility text. Approve only a desktop you trust.",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
            alert.addAction(UIAlertAction(title:"Approve desktop",style:.default) { [weak self] _ in
                guard let self else { return }
                do {
                    let folder = try HistoryPaths.folder(); var state = try DesktopAccess.load(folder)
                    guard state.pairs.count < 8 else { throw DesktopAccess.AccessError.invalidRequest }
                    if let existing = state.pairs.first(where:{$0.publicKey == encoded}) { self.share(existing); return }
                    let pair = DesktopPair(id:UUID().uuidString,name:name,publicKey:encoded,approvedAt:Date().timeIntervalSince1970)
                    state.pairs.append(pair); try DesktopAccess.save(state,folder:folder)
                    self.notifyWorker(); self.refresh(); self.share(pair)
                } catch { self.showError(error) }
            })
            present(alert,animated:true)
        } catch { showErrorMessage("This is not a valid desktop pairing request.") }
    }
    private func manage(_ pair:DesktopPair,source:UIView?) {
        let sheet=UIAlertController(title:pair.name,message:"Saved text and fresh AX checks are allowed. Screenshots can reveal everything visible, including private content. They are requested on demand, at most once per 30 seconds, and never saved to phone history.",preferredStyle:.actionSheet)
        sheet.addAction(UIAlertAction(title:pair.allowsScreenshots ? "Turn off screenshots" : "Allow screenshots",style:.default) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await Task.detached(priority:.utility) {
                        let folder=try HistoryPaths.folder();var state=try DesktopAccess.load(folder)
                        guard let index=state.pairs.firstIndex(where:{$0.id==pair.id}) else { throw DesktopAccess.AccessError.unauthorized }
                        state.pairs[index].allowsScreenshots = !pair.allowsScreenshots
                        try DesktopAccess.save(state,folder:folder)
                    }.value
                    self.refresh()
                } catch { self.showError(error) }
            }
        })
        sheet.addAction(UIAlertAction(title:"Share connection file",style:.default) { [weak self] _ in self?.share(pair) })
        sheet.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        sheet.popoverPresentationController?.sourceView=source ?? view
        sheet.popoverPresentationController?.sourceRect=(source ?? view).bounds
        present(sheet,animated:true)
    }
    private func share(_ pair: DesktopPair) {
        do {
            let state = try DesktopAccess.load(HistoryPaths.folder())
            let host = DesktopExportServer.wifiAddresses().first ?? ""
            let value: [String:Any] = ["protocol":DesktopAccess.protocolName,"pair_id":pair.id,
                "phone_public_key":try DesktopAccess.privateKey(state).publicKey.rawRepresentation.base64EncodedString(),
                "desktop_public_key":pair.publicKey,"desktop_name":pair.name,"host":host,"port":DesktopAccess.port]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopPairing",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
            let url = directory.appendingPathComponent("phone-history-connection.json")
            let data = try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:url,options:[.atomic,.completeFileProtection])
            // Public approval metadata only. Developer trust and both private
            // keys remain outside the document container.
            let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            let approvals = documents.appendingPathComponent("agent-connections",isDirectory:true)
            try FileManager.default.createDirectory(at:approvals,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
            try data.write(to:approvals.appendingPathComponent("\(pair.id).json"),options:[.atomic,.completeFileProtection])
            let share = UIActivityViewController(activityItems:[url],applicationActivities:nil)
            share.popoverPresentationController?.sourceView = view; present(share,animated:true)
        } catch { showError(error) }
    }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        do {
            let folder = try HistoryPaths.folder(); var state = try DesktopAccess.load(folder)
            let id = pairs[indexPath.row].id; state.pairs.removeAll {$0.id == id}
            try DesktopAccess.save(state,folder:folder); notifyWorker(); refresh()
            let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try? FileManager.default.removeItem(at:documents.appendingPathComponent("agent-connections/\(id).json"))
        } catch { showError(error) }
    }
    private func notifyWorker() {
        Task {
            if let all = try? await NETunnelProviderManager.loadAllFromPreferences(),
               let manager = all.first(where:{($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == HistoryPaths.provider}),
               let session = manager.connection as? NETunnelProviderSession {
                try? session.sendProviderMessage(Data("desktop-access-changed".utf8)) { _ in }
            }
        }
    }
    private func showError(_ error: Error) { showErrorMessage("Desktop access could not be updated. \(error.localizedDescription)") }
    private func showErrorMessage(_ message: String) {
        let alert = UIAlertController(title:"Desktop access",message:message,preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"OK",style:.default)); present(alert,animated:true)
    }
}
