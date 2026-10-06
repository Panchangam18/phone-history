# App Store preparation

Status checked 2026-10-05: build 64 uploaded and processed in App Store Connect; Missing Compliance. Version 1.0 remains Prepare for Submission. Not submitted or approved.

## Prepared

- Public source and licenses, privacy/security documentation and desktop integration.
- App Store listing draft in `app-store-metadata.json`, including explicit developer-service setup limitations.
- Build 64 archived, installed on the development phone and accepted by Apple's upload validation. Both extensions have display names; all targets include the privacy manifest and version 1.0.
- Listing description, review notes, support/privacy URLs and the account holder's private review contact saved in App Store Connect. Contact details are intentionally absent from this repository.
- Data Not Collected privacy answers published with the account holder's explicit approval. Age rating overridden to 18+ for this private activity recorder.
- Native UI screenshot with synthetic data uploaded; no personal history included.
- All 42 desktop-export and setup tests passed. Specific-subject memory selection uses exact phrases from numbered evidence, with deterministic activity wording and one model pass per window. This does not eliminate OCR errors or prove actions.

## Eligibility questions that packaging cannot resolve

The capture path uses remote developer pairing, AX audit RPCs and DVT screenshot services. These are developer-service protocols, not a documented public cross-app recording API for ordinary applications. Guideline 2.5.1 requires public APIs and intended framework use; Guideline 2.5.4 constrains background services. The local VPN worker is not a general browsing VPN. Apple must assess that use rather than infer eligibility from another VPN app's listing.

Guideline 2.5.14 requires explicit consent and a clear visual/audible indication when recording user activity. The present app exposes its status and the standard system VPN indicator; whether that meets the requirement is unresolved. Do not silently add a different capture mechanism or hide activity from reviewers.

Guideline 5.4 applies specific conditions to apps offering VPN services, including organization enrollment. Its classification for this narrow local developer transport is unresolved; the developer's account type must be verified. The first external TestFlight build also undergoes review. TestFlight is not a workaround for an ineligible production design.

The reviewer needs working first-time setup on their own device. An imported trust file for a different person's phone cannot supply it. Developer Mode and a trusted Mac are disclosed requirements, not automatic onboarding. If those requirements cannot be accepted, a public-API capture design would change the product and needs an explicit decision before implementation.

## Remaining submission fields and checks

- Resolve build 64's Missing Compliance status and select it for the release. Test the production-signed build through internal TestFlight; development installation alone does not establish production capture behavior.
- Current iOS compatibility, recipient setup, reboot/reconnect behavior and longer energy checks.
- Account holder's content-rights declaration; any accessibility claims must reflect actual verification.
- Country availability and EU trader status where required; do not invent a legal status or trade address.
- Encryption export classification. The app uses both Apple CryptoKit and third-party TLS/cryptographic implementations; do not automatically claim encryption is limited to Apple's OS. French documentation may depend on France availability. No compliance exemption is set in Info.plist without a supported determination.
- Final submission only when the app can be fully exercised by reviewers and its declarations are accurate.

A target release date is not guaranteed. Do not claim upload, processing, submission, approval or distribution until the relevant state is verified.

Sources checked 2026-10-05:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), sections 2.1, 2.2, 2.5.1, 2.5.4, 2.5.14 and 5.4.
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
- [Encryption export documentation](https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/).
- [Review timing and expedited requests](https://developer.apple.com/help/app-review/after-submitting-for-review/request-expedited-review/).
