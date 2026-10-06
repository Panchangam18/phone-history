#!/usr/bin/env python3
"""Install a signed pilot only on devices actually included in all profiles."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(args, **options):
    return subprocess.run(args, check=True, **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--device", help="Registered device UDID or CoreDevice identifier")
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    manifest = json.loads((package / "manifest.json").read_text())
    name = manifest["ipa_file"]
    if Path(name).name != name:
        raise ValueError("Invalid package manifest")
    ipa = package / name
    if hashlib.sha256(ipa.read_bytes()).hexdigest() != manifest["ipa_sha256"]:
        raise ValueError("Package checksum mismatch; install stopped")
    with tempfile.TemporaryDirectory(prefix="phone-history-install-") as folder:
        stage = Path(folder)
        run(["ditto", "-x", "-k", str(ipa), str(stage)])
        app = stage / "Payload/PhoneHistoryProbe.app"
        run(["codesign", "--verify", "--deep", "--strict", str(app)])
        registered = None
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        for bundle in [app] + sorted((app / "PlugIns").glob("*.appex")):
            profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")]))
            if profile["ExpirationDate"] <= now:
                raise ValueError("The signing profile has expired; request a newly signed package")
            devices = set(profile.get("ProvisionedDevices", []))
            registered = devices if registered is None else registered & devices
        if not registered:
            raise ValueError("No common registered devices in the app and extension profiles")
        if args.check_only:
            print("Checksum, signatures, signing expiry and all device profiles verified.")
            return
        output = stage / "devices.json"
        run(["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", str(output)], timeout=20)
        devices = json.loads(output.read_text())["result"]["devices"]
        matches = [item for item in devices if item.get("hardwareProperties", {}).get("udid") in registered
                   and (not args.device or args.device in (item["identifier"], item["hardwareProperties"]["udid"]))]
        if len(matches) != 1:
            raise ValueError("Connect and unlock one registered phone, or select it with --device. This IPA cannot install on an unregistered phone; its app and extensions must all be signed for that device first.")
        device = matches[0]
        version = device.get("deviceProperties", {}).get("osVersionNumber", "0")
        if tuple(int(part) for part in version.split(".")[:2]) < (26, 5):
            raise ValueError("This build requires iOS 26.5 or newer; capture was tested on iOS 26.6.2")
        run(["xcrun", "devicectl", "device", "install", "app", "--device", device["identifier"], str(app), "--timeout", "60"])
        print("Installed. Open Phone History and tap Start history. A first-time phone also needs Developer Mode and its own developer trust setup; no trust record is bundled.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit("Phone History: " + str(error))
