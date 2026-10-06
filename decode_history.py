"""Decode exported generic AX context deltas; no app-specific rules."""
import argparse, datetime, json
from pathlib import Path

def records(path):
    states = {}
    epoch = 0
    version = 1
    for line in path.read_text().splitlines():
        row = json.loads(line)
        if 'v' in row:
            version = row['v']
            epoch = row['t']
            states.clear()
            continue
        if row.get('reset'): states.clear()
        pid = row['p']
        previous = states.get(pid, {'label': '', 'text': [], 'dictionary': []})
        if version == 2:
            dictionary = [] if row.get('reset_p') else list(previous['dictionary'])
            added = row.get('n', [])
            dictionary.extend(added)
            if 'c' in row:
                text = [dictionary[i] for i in row['c']]
            elif added:
                text = added
            else:
                text = list(previous['text'])
        elif version == 1:
            dictionary = []
            text = list(previous['text'])
            for index in sorted(row.get('r', []), reverse=True):
                if 0 <= index < len(text): text.pop(index)
            text = sorted(set(text + row.get('n', [])))
        else:
            raise ValueError(f'Unsupported history version {version}')
        state = {'label': row.get('a', previous['label']), 'text': text, 'dictionary': dictionary}
        states[pid] = state
        yield {'time': datetime.datetime.fromtimestamp(epoch+row['s'], datetime.timezone.utc).isoformat(),
            'AX_process': pid, 'AX_label': state['label'], 'changed_text': row.get('n', []),
            'current_observed_text': state['text'], 'coverage': 'sampled, partial; host app identity unverified'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('history', type=Path)
    args = parser.parse_args()
    for row in records(args.history): print(json.dumps(row, ensure_ascii=False))
