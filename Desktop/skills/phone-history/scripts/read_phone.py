#!/usr/bin/env python3
"""Phone-approved skill entrypoint; summary generation requires an explicit user request."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('status','memories','evidence','search','history','check-now','summarize'))
    parser.add_argument('--minutes',type=int,default=60)
    parser.add_argument('--limit',type=int,default=20)
    parser.add_argument('--ids',nargs='+',help='Evidence IDs returned by a memory')
    parser.add_argument('--query',default='',help='All words must match one observation; empty pages raw evidence')
    parser.add_argument('--before',type=float,help='Timestamp from next_cursor')
    parser.add_argument('--before-id',help='Evidence ID from next_cursor')
    parser.add_argument('--host',help="Phone's local Wi-Fi IPv4 address, if it changed")
    parser.add_argument('--state',type=Path,default=Path.home()/'.phone-history/desktop.json')
    args=parser.parse_args()
    here=Path(__file__).resolve().parent
    candidates=[Path.home()/'.phone-history/connector/.venv/bin/python',here.parent/'.venv/bin/python']
    interpreter=next((str(p) for p in candidates if p.is_file()),None)
    if interpreter is None and importlib.util.find_spec('cryptography') is not None:
        interpreter=sys.executable
    if interpreter is None:
        parser.exit(1,'Phone History: missing Python cryptography dependency; install scripts/requirements.txt in the connector or skill virtual environment.\n')
    command=[interpreter,str(here/'phone_history_agent.py'),'--state',str(args.state),args.command]
    if args.command=='history':
        command+=['--require-phone','--minutes',str(args.minutes),'--limit',str(args.limit)]
    if args.command=='memories':command+=['--minutes',str(args.minutes),'--limit',str(min(20,args.limit))]
    if args.command=='search':
        command+=['--query',args.query,'--minutes',str(args.minutes),'--limit',str(args.limit)]
        if args.before is not None:command+=['--before',str(args.before)]
        if args.before_id is not None:command+=['--before-id',args.before_id]
    if args.command=='evidence':
        if not args.ids:parser.error('evidence requires --ids')
        command+=['--ids',*args.ids]
    if args.host:command+=['--host',args.host]
    raise SystemExit(subprocess.run(command).returncode)


if __name__=='__main__':main()
