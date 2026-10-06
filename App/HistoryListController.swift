import UIKit

@MainActor
final class HistoryListController: UITableViewController {
    private var days:[(date:Date,entries:[HistoryEntry])] = []
    private let timeFormatter:DateFormatter = { let f=DateFormatter();f.timeStyle = .short;return f }()
    private let dayFormatter:DateFormatter = { let f=DateFormatter();f.dateFormat="EEEE, MMM d";return f }()
    private var skippedRows = 0
    private var loading=false
    private let mode=UISegmentedControl(items:["Memories","Evidence"])
    private var message="Collecting observations. Memories appear after a completed ten-minute window."

    override func viewDidLoad() {
        super.viewDidLoad();title="History"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView=UIView()
        let heading=HistoryUI.label("History",style:.title2,weight:.bold)
        heading.font=UIFontMetrics(forTextStyle:.title2).scaledFont(for:.systemFont(ofSize:22,weight:.bold),maximumPointSize:28)
        heading.accessibilityTraits = .header
        let titleContainer=UIView();heading.translatesAutoresizingMaskIntoConstraints=false;titleContainer.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:titleContainer.leadingAnchor,constant:20),
            heading.trailingAnchor.constraint(equalTo:titleContainer.trailingAnchor),
            heading.topAnchor.constraint(equalTo:titleContainer.topAnchor),
            heading.bottomAnchor.constraint(equalTo:titleContainer.bottomAnchor)])
        let titleItem=UIBarButtonItem(customView:titleContainer)
        if #available(iOS 26.0, *) { titleItem.hidesSharedBackground=true }
        navigationItem.leftBarButtonItem=titleItem
        tableView.backgroundColor = .systemGroupedBackground;tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=140
        navigationItem.rightBarButtonItem=UIBarButtonItem(barButtonSystemItem:.done,target:self,action:#selector(close))
        refreshControl=UIRefreshControl();refreshControl?.addTarget(self,action:#selector(reload),for:.valueChanged)
        mode.selectedSegmentIndex=0;mode.addTarget(self,action:#selector(reload),for:.valueChanged)
        let header=UIView(frame:CGRect(x:0,y:0,width:view.bounds.width,height:54));header.addSubview(mode)
        mode.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([
            mode.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:20),
            mode.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-20),
            mode.topAnchor.constraint(equalTo:header.topAnchor,constant:8),
            mode.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-12)])
        tableView.tableHeaderView=header
        loadHistory()
    }
    @objc private func close() { dismiss(animated:true) }
    @objc private func reload() { loadHistory() }
    private func loadHistory() {
        #if targetEnvironment(simulator)
        if CommandLine.arguments.contains("--ui-preview") {
            apply(HistoryReadResult(entries:[
                HistoryEntry(date:Date(),label:"Safari",text:["A quieter way to keep track", "Notes on making useful things."]),
                HistoryEntry(date:Date().addingTimeInterval(-300),label:"Notes",text:["Weekend plans", "Book the train and find a place for lunch."]),
                HistoryEntry(date:Date().addingTimeInterval(-86400),label:"Music",text:["Evening playlist", "A little room to think."])
            ],skippedRows:0));return
        }
        #endif
        guard !loading else { return };loading=true
        Task {
            defer { loading=false;refreshControl?.endRefreshing() }
            do {
                let kind=mode.selectedSegmentIndex == 0 ? "memories":"evidence"
                let value=try await Task.detached(priority:.userInitiated) {
                    let folder=try HistoryPaths.folder()
                    let data=try? Data(contentsOf:folder.appendingPathComponent("memory-status.json"))
                    let status=data.flatMap{(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}
                    return (try HistoryReader.readNewest(StoragePolicy.historyFiles(folder),limit:300,kind:kind),status?["state"] as? String)
                }.value
                message=value.1 == "model_unavailable" ? "Apple Intelligence is unavailable. Your text evidence is still being saved. Enable Apple Intelligence in iPhone Settings to generate memories." : value.1 == "deferred" ? "Summarization is waiting for the on-device model. Your evidence is preserved." : "Collecting observations. Memories appear after a completed ten-minute window."
                apply(value.0)
            } catch { showMessage("History unavailable",detail:"Try refreshing in a moment. \(error.localizedDescription)") }
        }
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        guard let memory=days[indexPath.section].entries[indexPath.row].memory else {return}
        let controller=MemoryEvidenceController(memory:memory);navigationController?.pushViewController(controller,animated:true)
    }
    private func apply(_ result:HistoryReadResult) {
        let grouped=Dictionary(grouping:result.entries) { Calendar.current.startOfDay(for:$0.date) }
        days=grouped.keys.sorted(by:>).map { (date:$0,entries:grouped[$0] ?? []) };skippedRows=result.skippedRows
        if days.isEmpty { showMessage(mode.selectedSegmentIndex == 0 ? "Memories are taking shape":"Nothing saved yet",detail:mode.selectedSegmentIndex == 0 ? message:"Start capture and use your apps normally.") }
        else { contentUnavailableConfiguration=nil }
        tableView.reloadData()
    }
    private func showMessage(_ title:String, detail:String) {
        var configuration=UIContentUnavailableConfiguration.empty();configuration.image=UIImage(systemName:"clock.arrow.circlepath")
        configuration.text=title;configuration.secondaryText=detail;contentUnavailableConfiguration=configuration
    }
    override func numberOfSections(in tableView:UITableView) -> Int { days.count }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? {
        let day=days[section].date
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from:day)
    }
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int) -> String? {
        section == days.count-1 ? "Newest 300 items · Memories infer activity from captured screens; tap to inspect Evidence. Removal follows your Settings.\(skippedRows > 0 ? " Some unsupported records were skipped." : "")" : nil
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { days[section].entries.count }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let cell=tableView.dequeueReusableCell(withIdentifier:"history") ?? UITableViewCell(style:.subtitle,reuseIdentifier:"history")
        let entry=days[indexPath.section].entries[indexPath.row]
        var content=cell.defaultContentConfiguration();content.text=entry.memory?.title ?? ContextText.title(entry)
        content.textProperties.font = .preferredFont(forTextStyle:.subheadline);content.textProperties.color=HistoryUI.accent
        content.secondaryText=entry.memory == nil ? (["\(ContextText.usefulLabel(entry.label) ? entry.label+" · " : "")\(timeFormatter.string(from:entry.date))"]+ContextText.content(entry.text)).joined(separator:"\n"):"\(timeFormatter.string(from:Date(timeIntervalSince1970:entry.memory!.start)))–\(timeFormatter.string(from:Date(timeIntervalSince1970:entry.memory!.end)))\n"+entry.memory!.summary;content.secondaryTextProperties.font = .preferredFont(forTextStyle:.body)
        content.secondaryTextProperties.color = .label;content.secondaryTextProperties.numberOfLines=0
        content.textToSecondaryTextVerticalPadding=10;content.directionalLayoutMargins = .init(top:18,leading:18,bottom:18,trailing:18)
        cell.contentConfiguration=content;cell.selectionStyle=entry.memory == nil ? .none:.default;cell.accessoryType=entry.memory == nil ? .none:.disclosureIndicator;return cell
    }
}

@MainActor
private final class MemoryEvidenceController:UITableViewController {
    private let memory:MemoryRecord
    private var entries:[HistoryEntry]=[]
    private var missing=0
    init(memory:MemoryRecord) {self.memory=memory;super.init(style:.insetGrouped)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func viewDidLoad() {
        super.viewDidLoad();title="Evidence";tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=160
        Task {
            do {
                let ids=Set(memory.sources)
                entries=try await Task.detached(priority:.utility) {
                    let folder=try HistoryPaths.folder();return try HistoryReader.readNewest(StoragePolicy.historyFiles(folder),limit:20000,includeNoise:true).entries.filter{ids.contains($0.id)}
                }.value
                missing=memory.sources.count-entries.count;tableView.reloadData()
            } catch {missing=memory.sources.count;tableView.reloadData()}
        }
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        tableView.deselectRow(at:indexPath,animated:true)
        if indexPath.section == 1,let child=entries[indexPath.row].memory {navigationController?.pushViewController(MemoryEvidenceController(memory:child),animated:true)}
    }
    override func numberOfSections(in tableView:UITableView)->Int {2}
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int {section == 0 ? 1:entries.count}
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int)->String? {section == 0 ? "AI-generated · \(memory.scope)":"Referenced observations"}
    override func tableView(_ tableView:UITableView,titleForFooterInSection section:Int)->String? {section == 1 ? "Partial observations; app identity may be unverified. \(missing>0 ? "\(missing) references are no longer on this phone because of retention or transfer.":"")":nil}
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
        let cell=UITableViewCell(style:.subtitle,reuseIdentifier:nil);var content=cell.defaultContentConfiguration()
        if indexPath.section == 0 {content.text=memory.title;content.secondaryText=memory.summary}
        else {let e=entries[indexPath.row];content.text="\(ContextText.title(e)) · \(e.date.formatted(date:.omitted,time:.shortened))";content.secondaryText=e.text.joined(separator:"\n")}
        content.textProperties.font = .preferredFont(forTextStyle:.subheadline);content.secondaryTextProperties.font = .preferredFont(forTextStyle:.body);content.secondaryTextProperties.numberOfLines=0
        cell.contentConfiguration=content;cell.selectionStyle = indexPath.section == 1 && entries[indexPath.row].memory != nil ? .default:.none
        cell.accessoryType=indexPath.section == 1 && entries[indexPath.row].memory != nil ? .disclosureIndicator:.none;return cell
    }
}
