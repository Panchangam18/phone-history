"""Exercise real setup gates and trust validation with synthetic credentials."""
from pathlib import Path
import subprocess
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[1]

class OnboardingTests(unittest.TestCase):
    def test_setup_and_trust_import(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / 'setup-check'
            subprocess.run(['xcrun', 'swiftc', str(BASE/'App/SetupState.swift'),
                            str(BASE/'App/DeveloperTrust.swift'), str(BASE/'tests/setup-flow/main.swift'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
