# Privacy

Capture and memory generation run on the iPhone. Temporary frames feed native OCR and are discarded; saved history contains bounded text, process metadata, timestamps and generated memories with evidence IDs. Visible drafts and private material may be included. Sampling does not make sensitive content safe.

There is no analytics service or cloud relay in this app. Capture uses a local developer-service connection inside a packet-tunnel extension; it does not route general browsing traffic through an external server. iOS displays its standard VPN status.

History is stored in the app's shared container with file protection until first unlock after boot. This is native iOS data protection, not a promise of independent database encryption. Developer trust files use owner-only permissions and the same protection. Identity keys use the Keychain. Treat device backups and exported files as sensitive.

Default retention is a volume-based 512 KiB sliding window, not a time limit. Settings also supports no automatic removal or acknowledged transfer to an active approved desktop. A daily writing ceiling may stop new writes. Old evidence may expire before a summary that references it. Pause before erasing local history. Erasure or revocation does not delete copies already exported.

Desktop access requires explicit phone approval and public-key fingerprint comparison. Approved desktops can read retained history saved before approval, within the protocol's seven-day query range. The connector stores its private key at `~/.phone-history/desktop.json`; copying that file shares its access. Revocation blocks subsequent authenticated requests. Both devices must be locally reachable; do not expose the server through public routing.

Screenshots need a separate permission per approved desktop. A screenshot call returns one current image and does not save it in phone history. The desktop agent may retain the returned image. Ordinary memory questions should not trigger screenshots or repeated capture.

AI memories contain broad activity inferences. `evidenceChecked` establishes that supporting quotes occur in recorded text, not that every inferred claim is correct. `activityInferred` labels generated activity prose. OCR, process labels, displayed claims and model output all require judgment.

Developer pairing records, history, phone identifiers, signing profiles and desktop private keys are excluded from this source repository. Never submit them in issues or pull requests.
