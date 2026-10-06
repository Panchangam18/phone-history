# Private activity journal: content-rights assessment

Engineering assessment dated 2026-10-05. This describes the product and unresolved declarations; it is not a worldwide legal clearance.

## Product facts

Capture and summarization run on the user's iPhone. The app samples context already visible to that user, retains bounded text and metadata, and discards temporary screen frames after OCR. It does not operate a third-party content catalog, download audio/video, ask for social-account credentials, or send captured history to the developer. Export to a user-approved desktop is optional. The default local storage budget is 512 KiB. Build 65 additionally excludes the history/trust folder and diagnostic mirror from system backups; this cannot remove older backup copies.

Private recollection and concise summaries are the intended purpose. Recording must be opted into and can be paused from the app or Control Center. Neither on-device storage nor user consent establishes ownership of the underlying third-party material.

## What these facts support

Limited, personal, noncommercial, transformative recollection is a stronger argument than publishing or reselling a content archive. In the United States these facts can inform fair-use factors, but fair use remains case-specific. The amount and nature of copied material and its market effect also matter. A bounded store can still contain an entire short post or private message. The U.S. argument does not establish the rules in every worldwide storefront.

## Apple declarations remain separate

App Store Connect asks whether the app contains, shows or accesses third-party content. The affirmative option additionally attests to necessary rights. Capture can access third-party text; the absence of a developer-hosted catalog does not by itself support the negative answer. The account holder must establish the basis for the rights declaration before it is saved.

App Review Guideline 5.2.2 separately addresses apps using, accessing or displaying content from third-party services, including their terms. A device owner's consent is relevant to recording, but is not permission from every service. Local-only processing is an important disclosure, not an automatic exemption from this guideline.

Developer-service capture, the background packet tunnel and recording indication also require review under 2.5.1, 2.5.4, 2.5.14 and potentially 5.4. Packaging cannot establish eligibility, and this assessment does not promise approval.

## Submission wording

Describe a user-controlled, private activity journal. Disclose the actual developer-service and temporary-frame pipeline, local processing, optional export and setup requirements. Do not claim universal capture, ownership of third-party content, legal clearance or previously approved APIs. Do not conceal functionality to obtain review.

Sources checked 2026-10-05:

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), particularly 5.2.1 and 5.2.2.
- [U.S. Copyright Office: Fair Use](https://www.copyright.gov/fair-use/).
