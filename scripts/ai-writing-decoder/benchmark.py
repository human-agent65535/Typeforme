#!/usr/bin/env python3
"""Run review fixtures without exposing their answers to the decoder."""

import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
INPUT_FIELDS = ('input', 'context_before', 'vocabulary_candidates')


def requests_for(cases):
    return [{key: case[key] for key in INPUT_FIELDS if key in case} for case in cases]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, default=HERE/'cases-for-review.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('decoder_arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Choose a new output file; prior runs are immutable')
    cases = json.loads(args.cases.read_text())
    if not isinstance(cases, list) or not cases or len({c['id'] for c in cases}) != len(cases):
        parser.error('Cases must be a nonempty list with unique IDs')
    command = args.decoder_arguments
    if command[:1] == ['--']:
        command = command[1:]
    payloads = requests_for(cases)
    report = dict(
        started_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        semantic_review='pending',
        source_sha256={str(p.relative_to(HERE)): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in sorted(HERE.rglob('*')) if p.suffix in {'.py', '.cc', '.swift', '.sh'}},
        requests_sha256=hashlib.sha256(json.dumps(payloads, ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        decoder_arguments=command,
        cases=cases,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Reserve the path before model execution, so interrupted runs still retain
    # their frozen inputs and cannot silently overwrite another run.
    with args.output.open('x') as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write('\n')
    process = subprocess.run(
        [sys.executable, str(HERE/'decode.py'), *command],
        input=''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in payloads),
        text=True, stdout=subprocess.PIPE,
    )
    responses = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
    report['process_exit_code'] = process.returncode
    report['results'] = [dict(case=case['id'], **response) for case, response in zip(cases, responses)]
    report['missing_responses'] = len(cases) - len(responses)
    report['completed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"Recorded {len(responses)}/{len(cases)} outputs in {args.output}; semantic review is pending.")
    return process.returncode or (1 if len(responses) != len(cases) else 0)


if __name__ == '__main__':
    sys.exit(main())
