"""Check portable configuration and synthetic developer-trust conversion."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

BASE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('trust_helper', BASE/'tools/prepare_developer_trust.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class BuildSetupTests(unittest.TestCase):
    def test_generated_targets_share_custom_identifiers(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            shutil.copy2(BASE/'make_background_project.py', folder)
            for name in ('App','Tunnel','Controls'): (folder/name).mkdir()
            config = {'team':'TESTTEAM','bundle_id':'org.example.fixture','group':'group.org.example.fixture',
                      'control_kind':'org.example.fixture.toggle','build':'12'}
            (folder/'.phone-history-build.json').write_text(json.dumps(config))
            env = {k:v for k,v in os.environ.items() if not k.startswith('PHONE_HISTORY_')}
            subprocess.run(['python3',str(folder/'make_background_project.py')],env=env,check=True,stdout=subprocess.DEVNULL)
            for file in ('App/History-Info.plist','Tunnel/Info.plist','Controls/Info.plist'):
                info = plistlib.loads((folder/file).read_bytes())
                self.assertEqual(info['PhoneHistoryAppGroup'],config['group'])
                self.assertEqual(info['PhoneHistoryProvider'],config['bundle_id']+'.capture')
                self.assertEqual(info['PhoneHistoryControlKind'],config['control_kind'])
                self.assertEqual(info['CFBundleVersion'],'12')
            project = (folder/'PhoneHistory.xcodeproj/project.pbxproj').read_text()
            self.assertIn('org.example.fixture.capture',project)
            self.assertIn('org.example.fixture.controls',project)
            self.assertNotIn('/Users/',project)

    def fixture(self, folder):
        key = Ed25519PrivateKey.generate()
        raw = key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())
        pub = key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
        source = folder/'synthetic.plist'
        source.write_bytes(plistlib.dumps({'private_key':raw,'public_key':pub,'host_identifier':'fixture-host'}))
        return source

    def test_valid_trust_conversion_is_private_and_cannot_overwrite(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root); source = self.fixture(folder); dest = folder/'converted.plist'
            command = [os.sys.executable,str(BASE/'tools/prepare_developer_trust.py'),'--source',str(source),'--out',str(dest)]
            subprocess.run(command,check=True,stdout=subprocess.DEVNULL)
            self.assertEqual(dest.stat().st_mode & 0o777,0o600)
            self.assertEqual(plistlib.loads(dest.read_bytes())['identifier'],'fixture-host')
            before = dest.read_bytes()
            self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0)
            self.assertEqual(dest.read_bytes(),before)

    def test_mismatched_remote_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            source = self.fixture(Path(root)); data = plistlib.loads(source.read_bytes())
            data['public_key'] = bytes(32);source.write_bytes(plistlib.dumps(data))
            with self.assertRaises(ValueError):helper.convert(source)

    def test_lockdown_record_is_not_a_remote_record(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root)/'lockdown.plist';source.write_bytes(plistlib.dumps({'HostID':'fixture'}))
            with self.assertRaises(ValueError):helper.convert(source)
