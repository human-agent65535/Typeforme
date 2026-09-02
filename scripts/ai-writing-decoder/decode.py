#!/usr/bin/env python3
"""Experimental Rime + complete-candidate language likelihood decoder.

Input/output are local JSON lines. This tool does not install an app, start a
server, or update user dictionaries. Reference answers are never input fields.
"""

import argparse
import json
import math
from pathlib import Path
import re
import sys
import tempfile
import time

from candidates import Generator, split_spans, validate_candidate
from runtime import LineTool, own_process_group

REPO = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = dict(candidate_count=20, native_weight=0.1, edit_penalty=2.0)


def select_pool(source, candidates, limit):
    keep = next(c for c in candidates if c['text'] == source)
    result, seen = [keep], {source}
    by_cost = sorted(candidates, key=lambda c: (c['cost'], c['text']))
    # Preserve both low-cost readings and spelling-edit diversity. The original
    # remains an explicit option, including for intentional English.
    for pair in zip(by_cost, candidates):
        for candidate in pair:
            if len(result) >= limit:
                return result
            if candidate['text'] not in seen:
                result.append(candidate)
                seen.add(candidate['text'])
    return result


def parse_input(value):
    allowed = {'input', 'context_before', 'vocabulary_candidates'}
    if not isinstance(value, dict) or set(value) - allowed:
        raise ValueError('Expected input, optional context_before and vocabulary_candidates')
    source = value.get('input')
    context = value.get('context_before', '')
    if not isinstance(source, str) or not source.strip() or len(source) > 500:
        raise ValueError('input must contain 1–500 characters')
    if not isinstance(context, str) or len(context) > 500:
        raise ValueError('context_before must contain at most 500 characters')
    vocabulary = value.get('vocabulary_candidates', [])
    if not isinstance(vocabulary, list) or len(vocabulary) > 32:
        raise ValueError('At most 32 explicit vocabulary hints are supported')
    for hint in vocabulary:
        if not isinstance(hint, dict) or set(hint) - {'surface', 'speech_hint', 'matched_span', 'type'}:
            raise ValueError('Invalid vocabulary hint')
        if any(not isinstance(hint.get(k), str) or not 1 <= len(hint[k]) <= 100
               for k in ['surface', 'speech_hint', 'matched_span']):
            raise ValueError('Vocabulary needs surface, speech_hint and matched_span')
    # The native scoring prototype uses Qwen ChatML. Literal special tokens must
    # not become template control tokens while a candidate is being tokenized.
    if any('<|' in text for text in [source, context] + [v['surface'] for v in vocabulary]):
        raise ValueError('Literal ChatML markers are outside this decoder prototype')
    return dict(input=source, context_before=context, vocabulary_candidates=vocabulary)


def language_prompt(item):
    vocabulary = [v['surface'] for v in item['vocabulary_candidates']]
    prefix = ''
    if vocabulary:
        prefix = '<|im_start|>system\n词语提示：' + json.dumps(vocabulary, ensure_ascii=False) + '<|im_end|>\n'
    # The LLM sees a possible user utterance. Raw spelling evidence is evaluated
    # separately, so a mistaken Latin spelling cannot anchor its Chinese answer.
    return prefix + '<|im_start|>user\n' + item['context_before']


def language_surface(text, protected_literals):
    """Remove segmentation spaces touching Chinese only in the scoring view.

    Source layout, line breaks, English word spaces and protected literals stay
    in the candidate returned to the editor. This is not output formatting.
    """
    ranges, cursor = [], 0
    for literal in protected_literals:
        start = text.find(literal, cursor)
        if start < 0:
            raise ValueError('Scoring view lost a protected literal')
        cursor = start + len(literal)
        ranges.append((start, cursor))
    def is_han(character):
        code = ord(character)
        return (0x3400 <= code <= 0x9FFF or 0xF900 <= code <= 0xFAFF
                or 0x20000 <= code <= 0x323AF)
    def separator(match):
        start, end = match.span()
        if any(start < b and end > a for a, b in ranges):
            return match.group()
        if (start and is_han(text[start - 1])) or (end < len(text) and is_han(text[end])):
            return ''
        return match.group()
    return re.sub(r'[^\S\r\n]+', separator, text)


def rank_scores(candidates, response, native_weight, edit_penalty):
    scores = response.get('scores', [])
    if len(scores) != len(candidates):
        raise ValueError('Scorer did not evaluate every candidate')
    result = []
    for index, (candidate, score) in enumerate(zip(candidates, scores)):
        if score.get('index') != index or score.get('text') != candidate['text']:
            raise ValueError('Scoring response does not match candidate order')
        logp = score.get('logprob_sum')
        tokens = score.get('tokens', [])
        if not isinstance(logp, (int, float)) or not math.isfinite(logp) or logp > 0:
            raise ValueError('Missing or invalid complete-candidate probability')
        if not tokens or tokens[-1].get('id') != response.get('eos'):
            raise ValueError('Probability must include the end-of-message token')
        if any(not math.isfinite(t.get('logprob', float('nan'))) or t['logprob'] > 0 for t in tokens):
            raise ValueError('Invalid token probability')
        if not math.isclose(sum(t['logprob'] for t in tokens), logp, abs_tol=1e-5):
            raise ValueError('Token probabilities do not sum to the sentence score')
        joint = logp - native_weight * candidate['cost'] - edit_penalty * len(candidate['edits'])
        result.append(dict(index=index, text=candidate['text'], score=joint,
                           logprob_sum=logp, native_cost=candidate['cost'],
                           edits=candidate['edits']))
    # Equal scores use a stable surface-text tie break, independent of ID order.
    return sorted(result, key=lambda r: (-r['score'], r['text']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-directory', type=Path, default=REPO/'.build/ai-writing-decoder-tools')
    parser.add_argument('--rime-data', type=Path, default=REPO/'iOS/TypeformeKeyboard/RimeSharedSupport')
    parser.add_argument('--grammar-file', type=Path, required=True)
    parser.add_argument('--rime-plugin', type=Path, required=True)
    parser.add_argument('--model-path', type=Path)
    parser.add_argument('--backend-directory', type=Path)
    parser.add_argument('--candidates-only', action='store_true')
    parser.add_argument('--diagnostics', action='store_true', help='Include local candidate readings and scores')
    parser.add_argument('--candidate-count', type=int, default=DEFAULT_POLICY['candidate_count'])
    parser.add_argument('--native-weight', type=float, default=DEFAULT_POLICY['native_weight'])
    parser.add_argument('--edit-penalty', type=float, default=DEFAULT_POLICY['edit_penalty'])
    parser.add_argument('--score-layout', choices=['raw', 'prose'], default='prose')
    parser.add_argument('--service-parent-pid', type=int,
                        help='App-owned process group; service messages require an id')
    args = parser.parse_args()
    if not 1 <= args.candidate_count <= 128:
        parser.error('--candidate-count must be in 1–128')
    if any(not math.isfinite(x) or x < 0 for x in [args.native_weight, args.edit_penalty]):
        parser.error('Scoring penalties must be finite and nonnegative')
    if not args.candidates_only and (not args.model_path or not args.backend_directory):
        parser.error('Scoring requires --model-path and --backend-directory')
    paths = [args.grammar_file, args.rime_plugin, args.rime_data/'build/typeforme_pinyin.table.bin',
             args.rime_data/'build/typeforme_pinyin.prism.bin']
    paths += [args.tools_directory/name for name in ['rime_analysis', 'rime_sentences', 'layout']]
    if not args.candidates_only:
        paths += [args.model_path, args.tools_directory/'llama_score']
    if any(not p.is_file() for p in paths):
        parser.error('Required runtime file missing; run build.sh and inspect its prerequisites')
    if args.service_parent_pid is not None:
        own_process_group(args.service_parent_pid)

    failed = False
    with tempfile.TemporaryDirectory(prefix='typeforme-pinyin-decoder-') as scratch:
        generator = Generator(args.tools_directory, args.rime_data, scratch, args.grammar_file, args.rime_plugin)
        scorer = None
        try:
            if not args.candidates_only:
                scorer = LineTool([str(args.tools_directory/'llama_score'), str(args.model_path), str(args.backend_directory)])
            for line in sys.stdin:
                request_id = None
                try:
                    value = json.loads(line)
                    if args.service_parent_pid is not None:
                        request_id = value.pop('id', None) if isinstance(value, dict) else None
                        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 64:
                            raise ValueError('Service request requires an id')
                    item = parse_input(value)
                    # Caches accelerate a single draft's search. They must not
                    # retain every draft typed over a long-lived app session.
                    generator.cache.clear()
                    generator.poet_cache.clear()
                    start = time.monotonic()
                    metadata = generator.codec.query(json.dumps(dict(input=item['input']), ensure_ascii=False))
                    spans = [generator.span_options(span, item['vocabulary_candidates'])
                             for span in split_spans(item['input'], metadata)]
                    options = generator.whole_candidates(item['input'], spans)
                    candidates = select_pool(item['input'], options, args.candidate_count)
                    analysis_ms = round((time.monotonic() - start) * 1000, 2)
                    result = dict(candidate_count=len(candidates), analysis_ms=analysis_ms,
                                  semantic_review='pending', output_stage='pinyin_decoding_before_number_and_punctuation_preferences')
                    if args.candidates_only:
                        result['candidates'] = candidates
                    else:
                        surfaces = [language_surface(c['text'], metadata['protected_literals'])
                                    if args.score_layout == 'prose' else c['text'] for c in candidates]
                        response = scorer.query(json.dumps(dict(prompt=language_prompt(item),
                            candidates=[dict(text=text) for text in surfaces]), ensure_ascii=False))
                        for index, value in enumerate(response['scores']):
                            if value['index'] != index or value['text'] != surfaces[index]:
                                raise ValueError('Scored text does not match the requested scoring view')
                            value['text'] = candidates[index]['text']
                        ranked = rank_scores(candidates, response, args.native_weight, args.edit_penalty)
                        selected = candidates[ranked[0]['index']]
                        payload = validate_candidate(selected, dict(input=item['input'], metadata=metadata))
                        checked = generator.codec.query(json.dumps(dict(input=item['input'],
                            output=json.dumps(payload, ensure_ascii=False)), ensure_ascii=False))
                        if not checked.get('valid'):
                            raise ValueError(checked.get('validation_error', 'Production layout validation failed'))
                        result.update(text=checked['text'], decoded_text=selected['text'],
                                      converted_segments=payload['converted_segments'],
                                      edits=selected['edits'], score=ranked[0]['score'],
                                      score_layout=args.score_layout,
                                      model_ms=response['elapsed_ms'], structure_valid=True,
                                      elapsed_ms=round((time.monotonic() - start) * 1000, 2))
                        if args.diagnostics:
                            result.update(scores=ranked, candidates=candidates)
                    if args.service_parent_pid is not None:
                        result['id'] = request_id
                    print(json.dumps(result, ensure_ascii=False), flush=True)
                except (ValueError, RuntimeError, TimeoutError, KeyError, AssertionError, OSError) as error:
                    failed = True
                    result = dict(error=type(error).__name__, detail=str(error))
                    if args.service_parent_pid is not None:
                        result['id'] = request_id
                    print(json.dumps(result, ensure_ascii=False), flush=True)
        finally:
            generator.close()
            if scorer:
                scorer.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
