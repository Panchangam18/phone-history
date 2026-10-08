import subprocess
import tempfile
from pathlib import Path
import unittest

BASE = Path(__file__).resolve().parents[1]


class HistoryReaderTests(unittest.TestCase):
    def test_delta_references_and_direct_lookup_beyond_display_limit(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "reader"
            sources = ["BuildConfiguration", "HistoryPaths", "ContextText",
                       "NaturalMemory", "MemoryRecord", "StoragePolicy",
                       "DesktopAccess", "HistoryOffload", "HistoryReader"]
            subprocess.run(["xcrun", "swiftc"] +
                           [str(BASE / "Shared" / (name + ".swift")) for name in sources] +
                           [str(BASE / "tests/history-reader/main.swift"), "-o", str(binary)],
                           check=True)
            subprocess.run([str(binary)], check=True)
