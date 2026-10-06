"""Compatibility checks for exported history sessions and dictionary resets."""
import json
import tempfile
import unittest
from pathlib import Path
from decode_history import records

class HistoryDecodeTests(unittest.TestCase):
    def decode(self, rows):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'history.jsonl'
            path.write_text('\n'.join(json.dumps(row) for row in rows))
            return list(records(path))

    def test_mixed_sessions_and_revisited_text(self):
        result = self.decode([
            {'v':1, 't':86400}, {'s':1, 'p':1, 'a':'Example', 'n':['Old text']},
            {'v':2, 't':86400}, {'s':2, 'p':1, 'a':'Example', 'n':['Page A', 'Shared']},
            {'s':3, 'p':1, 'n':['Page B'], 'c':[2,1]},
            {'s':4, 'p':2, 'a':'Second', 'n':['Elsewhere']},
            {'s':5, 'p':1}, {'s':6, 'p':1, 'c':[0,1]},
            {'s':7, 'p':1, 'reset_p':True, 'n':['Fresh dictionary']},
            {'s':8, 'p':1, 'reset':True, 'a':'New session', 'n':['Restart']},
        ])
        self.assertEqual(result[2]['current_observed_text'], ['Page B','Shared'])
        self.assertEqual(result[4]['current_observed_text'], ['Page B','Shared'])
        self.assertEqual(result[5]['changed_text'], [])
        self.assertEqual(result[5]['current_observed_text'], ['Page A','Shared'])
        self.assertEqual(result[6]['current_observed_text'], ['Fresh dictionary'])
        self.assertEqual(result[7]['AX_label'], 'New session')
        self.assertEqual(result[0]['time'], '1970-01-02T00:00:01+00:00')

if __name__ == '__main__': unittest.main()
