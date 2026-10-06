import UIKit

@MainActor
final class HistoryAboutController: UITableViewController {
    private let sections:[(String,String)] = [
        ("A little memory for your phone", "Phone History saves changed text context as you move between apps. Capture runs entirely on this iPhone. You can pause it at any time."),
        ("Quick control", "Open Control Center, hold an empty area and tap Add a Control. Search for Phone History. Once setup is complete, the control starts and pauses capture without opening the app."),
        ("What gets saved", "Visible text is read on-device from temporary frames every 10–30 seconds, with accessibility text as fallback. Apple Intelligence summarizes batches into memories linked to evidence. Frames are discarded; taps and keystroke events are not logged. Brief or protected screens may be missed. Visible drafts may be included."),
        ("Your data", "Retention follows your choice in Settings: no removal, a sliding window (512 KB by default), or sending to an active approved desktop. Confirmed transfers remove only the saved phone copy. OCR evidence is limited to 2 KB per observation, with a 4 MB daily writing ceiling. Export a copy from Settings, or pause capture before erasing local history."),
        ("Desktop connection", "Codex or Claude on a desktop you approve can read up to seven days of saved text over the same Wi-Fi. Compare the pairing fingerprint before approving. Revoking access prevents future reads; copies already exported remain on that desktop."),
        ("The VPN indicator", "Capture uses a local VPN worker for its on-device connection. iOS controls the VPN indicator. Another packet-tunnel VPN cannot run alongside capture."),
        ("Open source", "Phone History is open source under MIT. Its local packet transport uses code from LocalDevVPN by Stossy11 and the SideStore Team under the StosVPN License; its developer-service client uses idevice by Jackson Coxson under MIT. License notices are included with the app."),
        ("Pilot setup", "This developer pilot requires a registered iPhone, Developer Mode and one-time developer trust setup through its own trusted Mac. No separate VPN app is needed. The installer cannot set up an unregistered phone.")
    ]
    override func viewDidLoad() {
        super.viewDidLoad();title="How it works"
        tableView.backgroundColor = .systemGroupedBackground;tableView.rowHeight=UITableView.automaticDimension;tableView.estimatedRowHeight=130
        navigationItem.rightBarButtonItem=UIBarButtonItem(barButtonSystemItem:.done,target:self,action:#selector(close))
    }
    @objc private func close() { dismiss(animated:true) }
    override func numberOfSections(in tableView:UITableView) -> Int { sections.count }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int) -> Int { 1 }
    override func tableView(_ tableView:UITableView,titleForHeaderInSection section:Int) -> String? { sections[section].0 }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath) -> UITableViewCell {
        let cell=UITableViewCell();var content=cell.defaultContentConfiguration();content.text=sections[indexPath.section].1
        content.textProperties.font = .preferredFont(forTextStyle:.body);content.textProperties.numberOfLines=0
        cell.contentConfiguration=content;cell.selectionStyle = .none;return cell
    }
}
