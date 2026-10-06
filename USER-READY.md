# Developer pilot installation

This source repository does not provide a universal install download. The app and two extensions need signing for the recipient's registered phone and App Group. Developer Mode and a phone-specific remote pairing record are required. Follow the root README for a source build and trust import.

`package_pilot.py --build NUMBER` packages an existing signed build locally. It checks embedded profiles and installation integrity; `install_pilot.py` only installs on devices included in every signing profile. Do not publish those generated artifacts or claim they work on any iPhone.

After setup: start capture, approve the local VPN, use another app, then inspect evidence and memories. Add Phone History in Control Center for pause/resume. Optional desktop access requires a separate fingerprint approval; screenshots need an additional permission.

Before broader release: validate first-time onboarding on new phones, extended background/energy behavior, reboot and reconnect recovery, OS and model compatibility, protected content coverage, independent security review and a viable distribution route. Current native build and synthetic protocol tests are narrower evidence.
