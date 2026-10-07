# Set up Phone History

The app has two setup screens: capture, then optional desktop connection. Storage and help stay inline. This is a developer pilot. The guided screens explain the steps, but cannot enable Developer Mode or create developer trust from an ordinary iPhone app. A compatible, registered iPhone and its own trusted Mac are still required. Setup on a new, previously unpaired device has not been verified.

## 1. Prepare the phone and Mac

Build and install using the [repository instructions](../README.md#build). Connect your iPhone by USB, unlock it, and approve **Trust This Computer** for your own Mac. In iPhone **Settings → Privacy & Security → Developer Mode**, enable Developer Mode, restart, and confirm. If the switch is missing, connect the device to Xcode first. The app’s **Open Settings** button shows a short guide and opens Phone History’s own settings using Apple’s supported shortcut. Go back to the main Settings list to reach Privacy & Security; the app cannot switch Developer Mode on itself.

Enable Apple Intelligence in **Settings → Apple Intelligence & Siri** on a supported phone and allow its model download to finish if you want activity memories. The app checks model availability. Evidence can still be retained without the model.

## 2. Import developer trust

Use a compatible [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) developer-service client on that Mac to establish a **classic remote developer tunnel** for that phone. An ordinary USB Lockdown record or a native Apple tunnel alone does not provide the signing record this app imports. Recent clients expose `remote start-tunnel --no-native --protocol tcp`; follow the client's installation and privilege instructions and approve any phone-side developer authentication yourself. Do not enable TLS-secret logging. Remote-pairing acquisition remains a developer step, and client commands can differ by version.

The client writes a remote pairing plist, commonly `~/.pymobiledevice3/remote_<device identifier>.plist`. Select the record for your own phone; never use another person's record. Stop the temporary Mac tunnel when acquisition is complete. Convert the record from the repository directory:

```sh
python3 -m venv Desktop/.venv
Desktop/.venv/bin/python -m pip install -r Desktop/requirements.txt
Desktop/.venv/bin/python tools/prepare_developer_trust.py \
  --source /private/path/to/remote-record.plist \
  --out /private/path/to/vpn-trial-pairing.plist
```

Transfer the converted plist directly to your own phone using AirDrop/Files. In the setup guide, tap **Import trust file** and select it. The app checks the Ed25519 key pair and imports only required fields into its protected, backup-excluded container. It leaves the selected source intact: delete the temporary exported copies from Files and your Mac after import. Never email, publish or commit this secret. Pause capture before replacing it.

For a USB-only bootstrap, the original developer route remains available:

```sh
xcrun devicectl device copy to --device YOUR_DEVICE \
  --domain-type appDataContainer --domain-identifier YOUR_BUNDLE_ID \
  --source /private/path/to/vpn-trial-pairing.plist \
  --destination Documents/vpn-trial-pairing.plist
```

Opening the app validates and imports that controlled Documents copy, then deletes it. Delete the Mac's temporary export yourself. Import validates the file's structure and signing keys; it does not prove that the phone accepts the record. Capture readiness is checked separately.

## 3. Choose storage and start capture

Setup shows your current storage policy and lets you customize it. The default is a **512 KiB sliding window by volume**. No removal keeps data until you erase it. Send to connected device appears only while an approved desktop receiver is active; deletion requires its save acknowledgment.

Tap **Start capture**, then approve iOS's **VPN configuration** prompt. The local VPN keeps the on-device developer connection alive. No separate VPN app is needed. iOS owns the VPN indicator, and another packet-tunnel VPN cannot run alongside capture. Setup checks for both a connected tunnel and a recent running-worker status before allowing completion. A VPN approval alone is not capture verification.

If capture never reports ready, check Developer Mode and the phone-specific trust record, then pause and retry. The app cannot grant itself missing developer authorization. On a locked phone, unlock and retry before diagnosing coverage. Captured activity is partial, not a tap/keystroke log.

## 4. Optional desktop connection

Use the same Wi-Fi on both devices and keep capture running. Follow [Desktop/README.md](../Desktop/README.md#pair-this-desktop) to create a desktop **public** pairing request. In setup, tap **Connect a desktop → Import pairing request**. Compare the full fingerprint on both devices, approve only a trusted desktop, and share the generated connection file back to it. Import that file into the connector and run its `status` command to verify the live connection. Installing a skill or MCP server alone grants no access.

Allow **Local Network** access if iOS asks. If denied, enable Phone History in **Settings → Privacy & Security → Local Network**, or open its app settings from setup. An IP address or saved desktop approval does not prove a live connection. Screenshots are disabled by default and require separate approval inside the desktop's settings. Revoke a desktop to stop future access; this does not delete copies it already saved.

You may skip desktop connection and add it later in **Settings → Desktop connection**. Capture itself does not need a Mac after successful bootstrap.

## 5. Add quick control

Open Control Center, hold an empty area, tap **Add a Control**, search for **Phone History**, and add the control. iOS requires you to add it yourself. The control starts and pauses capture once setup is complete.

Setup resumes from its last step if interrupted. Reopen it in **Phone History → Settings → Setup guide**. Existing trusted installations keep their current storage settings and approvals rather than being forced through first-launch setup.

Apple references: [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [supported app Settings shortcut](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring).
