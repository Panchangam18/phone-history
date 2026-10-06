import UIKit

@MainActor
final class HistorySettingsController: UITableViewController {
    private var policy=StoragePolicy()
    private var receiver:DesktopPair?
    private var usedBytes:Int64=0
    private var desktopCount=0
    private var loading=false
    private var receiverExpiry:Task<Void,Never>?
    var exportHistory:(()->Void)?
    var eraseHistory:(()->Void)?
    var didChange:(()->Void)?
    override func viewDidLoad() {
        super.viewDidLoad();title="Settings";tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=80
        HistoryUI.sheetHeading("Settings",symbol:"gearshape",on:navigationItem)
        tableView.tableHeaderView=UIView(frame:CGRect(x:0,y:0,width:1,height:8))
        navigationItem.rightBarButtonItem=UIBarButtonItem(barButtonSystemItem:.done,target:self,action:#selector(close))
        refreshControl=UIRefreshControl();refreshControl?.addTarget(self,action:#selector(refresh),for:.valueChanged)
        refresh()
    }
    override func viewDidDisappear(_ animated:Bool) { super.viewDidDisappear(animated);receiverExpiry?.cancel() }
    override func viewWillAppear(_ animated:Bool) { super.viewWillAppear(animated);refresh() }
    @objc private func close() { dismiss(animated:true) }
    @objc private func refresh() {
        guard !loading else { return };loading=true
        Task {
        defer { loading=false }
        do {
            let value=try await Task.detached(priority:.utility) {
                let folder=try HistoryPaths.folder()
                let policy=try StoragePolicy.load(folder);let receiver=StoragePolicy.activeReceiver(folder)
                let used=StoragePolicy.historyFiles(folder).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
                return (policy,receiver,used,(try? DesktopAccess.load(folder).pairs.count) ?? 0)
            }.value
            policy=value.0;receiver=value.1;usedBytes=value.2;desktopCount=value.3
        } catch { showError(error) }
        tableView.reloadData();refreshControl?.endRefreshing()
        receiverExpiry?.cancel()
        if receiver != nil {
            // One expiry check while this screen is visible, not an idle poller.
            receiverExpiry=Task { [weak self] in
                do { try await Task.sleep(nanoseconds:90_000_000_000) } catch { return }
                guard let self,self.viewIfLoaded?.window != nil else { return };self.refresh()
            }
        }
    }
    }
    private var sections:[Int] { policy.mode == .window ? [0,1,2,4,3]:[0,1,4,3] }
    private func logicalSection(_ section:Int) -> Int { sections[section] }
    override func tableView(_ tableView:UITableView,heightForHeaderInSection section:Int) -> CGFloat {
        section == 0 ? 32:UITableView.automaticDimension
    }
    override func numberOfSections(in tableView:UITableView) -> Int { sections.count }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int {
        switch logicalSection(section) { case 0,4:return 1;case 1:return receiver == nil ? 2:3;case 2:return policy.mode == .window ? 1:0;default:return 3 }
    }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? {
        switch logicalSection(section) { case 0:return "On this phone";case 1:return "Data removal";case 2:return policy.mode == .window ? "Sliding window":nil;case 4:return nil;default:return "Manage history" }
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        switch logicalSection(section) {
        case 0:return "Saved text only. Capture has a separate 4 MB daily writing limit."
        case 1:
            if policy.mode == .send && receiver?.id != policy.receiverID { return "The selected receiver is offline. History stays on this phone until it reconnects. No copy is removed without confirmation that it was saved." }
            return receiver == nil ? "Start the receiver on an approved desktop to enable sending. Pull to refresh." : "All saved history can be sent, encrypted. Phone copies are removed only after the selected desktop confirms saving them. While offline, history stays here."
        case 2:return policy.mode == .window ? "Oldest complete segments are removed as the budget fills. The active segment stays readable. Applies to existing history too.":nil
        case 4:return nil
        default:return "Erasing local history keeps your desktop approvals and setup. Copies already exported are unaffected."
        }
    }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let cell=UITableViewCell(style:.subtitle,reuseIdentifier:nil);var title="";var detail=""
        let section=logicalSection(indexPath.section)
        switch section {
        case 0:title="Saved history";detail=ByteCountFormatter.string(fromByteCount:usedBytes,countStyle:.file);cell.selectionStyle = .none
        case 1:
            if indexPath.row == 0 { title="No removal";detail="Keep history until you erase it.";cell.accessoryType=policy.mode == .none ? .checkmark:.none }
            else if indexPath.row == 1 { title="Sliding window";detail="Keep recent history. Default budget: 512 KB.";cell.accessoryType=policy.mode == .window ? .checkmark:.none }
            else { title="Send to connected device";detail=receiver?.name ?? "";cell.accessoryType=policy.mode == .send && policy.receiverID == receiver?.id ? .checkmark:.none }
        case 2:title="Storage budget";detail=ByteCountFormatter.string(fromByteCount:Int64(policy.maxBytes),countStyle:.binary);cell.accessoryType = .disclosureIndicator
        case 4:
            title="Desktop connection";detail=desktopCount == 0 ? "Connect a desktop":"\(desktopCount) approved \(desktopCount == 1 ? "desktop":"desktops")"
            cell.accessoryType = .disclosureIndicator;cell.imageView?.image=UIImage(systemName:"laptopcomputer");cell.imageView?.tintColor=HistoryUI.accent
        default:
            title=["Export a copy","How it works","Erase saved history"][indexPath.row]
            cell.imageView?.image=UIImage(systemName:["square.and.arrow.up","info.circle","trash"][indexPath.row]);cell.imageView?.tintColor=indexPath.row == 2 ? .systemRed:HistoryUI.accent
            cell.accessoryType=indexPath.row == 1 ? .disclosureIndicator:.none
        }
        var content=cell.defaultContentConfiguration();content.text=title;content.secondaryText=detail
        content.textProperties.font = .preferredFont(forTextStyle:.body);content.textProperties.color=section == 3 && indexPath.row == 2 ? .systemRed:.label
        content.secondaryTextProperties.numberOfLines=0;content.secondaryTextProperties.font = .preferredFont(forTextStyle:.subheadline)
        cell.contentConfiguration=content
        if section != 0 { cell.accessibilityTraits = .button }
        if cell.accessoryType == .checkmark { cell.accessibilityTraits.insert(.selected) }
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        let section=logicalSection(indexPath.section)
        if section == 1 {
            var next=policy
            if indexPath.row == 0 { next.mode = .none;next.receiverID=nil }
            else if indexPath.row == 1 { next.mode = .window;next.receiverID=nil }
            else {
                guard let folder=try? HistoryPaths.folder(),let active=StoragePolicy.activeReceiver(folder),active.id == receiver?.id else { refresh();return }
                next.mode = .send;next.receiverID=active.id
            }
            commit(next)
        } else if section == 2 {
            let alert=UIAlertController(title:"Storage budget",message:"Keep the newest history within this budget. Oldest complete segments are removed while capture runs.",preferredStyle:.actionSheet)
            for bytes in [64,128,256,512,1024,5120].map({ $0 * 1024 }) { alert.addAction(UIAlertAction(title:ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.binary),style:.default) { [weak self] _ in guard let self else { return };var next=self.policy;next.maxBytes=bytes;self.commit(next) }) }
            alert.addAction(UIAlertAction(title:"Cancel",style:.cancel));alert.popoverPresentationController?.sourceView=tableView.cellForRow(at:indexPath);present(alert,animated:true)
        } else if section == 4 {
            navigationController?.pushViewController(DesktopAccessController(style:.insetGrouped),animated:true)
        } else if section == 3 {
            if indexPath.row == 1 { navigationController?.pushViewController(HistoryAboutController(style:.insetGrouped),animated:true) }
            else { let action=indexPath.row == 0 ? exportHistory:eraseHistory;dismiss(animated:true) { action?() } }
        }
    }
    private func commit(_ next:StoragePolicy) {
        if next.mode == .window,let folder=try? HistoryPaths.folder() {
            if usedBytes > Int64(next.maxBytes) {
                let budget=ByteCountFormatter.string(fromByteCount:Int64(next.maxBytes),countStyle:.binary)
                let alert=UIAlertController(title:"Remove older history?",message:"Keeping the newest history within \(budget) will remove older saved segments from this phone when capture runs. Export a copy first if you want to keep them.",preferredStyle:.alert)
                alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
                alert.addAction(UIAlertAction(title:"Use \(budget) budget",style:.destructive) { [weak self] _ in self?.save(next) });present(alert,animated:true);return
            }
        }
        save(next)
    }
    private func save(_ next:StoragePolicy) {
        do { try next.save(HistoryPaths.folder());policy=next;didChange?();refresh() } catch { showError(error) }
    }
    private func showError(_ error:Error) {
        let alert=UIAlertController(title:"Settings unavailable",message:error.localizedDescription,preferredStyle:.alert);alert.addAction(UIAlertAction(title:"OK",style:.default));present(alert,animated:true)
    }
}
