"""Bounded pinyin spelling alternatives and complete, aligned Rime candidates.

No reference answers or case identifiers enter this module. The explicit
limits are experiment parameters, not measured probability calibration.
"""
from collections import defaultdict
import heapq
import math
import re

from runtime import LineTool

POLICY = dict(native_per_reading=80, dictionary_per_range=16, scanned_per_range=120,
              max_paths_per_edit_kind=8, max_span_candidates=240, whole_beam=600,
              per_span_max_edits=1, spelling_edit_penalty=6.0,
              original_keep_penalty=10.0, chinese_alternatives_per_path_round=2)

def distance(a, b):
    rows = [list(range(len(b)+1))]
    for i, ca in enumerate(a, 1):
        row=[i]
        for j, cb in enumerate(b,1):
            value=min(row[j-1]+1, rows[-1][j]+1, rows[-1][j-1]+(ca!=cb))
            if i>1 and j>1 and ca==b[j-2] and a[i-2]==cb:
                value=min(value,rows[-2][j-2]+1)
            row.append(value)
        rows.append(row)
    return rows[-1][-1]


def best_dictionary_path(data):
    # A bounded lexical score ranks alternatives; it is not semantic correctness.
    edges=defaultdict(list)
    for word in data['words']:
        if word['reading'].replace(' ','') != data['input'][word['start']:word['end']].replace("'",''): continue
        edges[word['start']].append(word)
    best={0:(0.,[],[])}
    for start in sorted(edges):
        if start not in best: continue
        base,texts,readings=best[start]
        for word in edges[start]:
            score=base+word['weight']
            end=word['end']
            if end not in best or score>best[end][0]: best[end]=(score,texts+[word['text']],readings+word['reading'].split())
    result=best.get(len(data['input']))
    if not result: return None
    score,texts,readings=result
    return dict(score=score/max(1,len(readings)), text=''.join(texts), reading=' '.join(readings))

def variants(raw):
    # One edit anywhere. No vocabulary, expected answer, or case identifier is used.
    if len(raw)<3 or len(raw)>48 or not raw.isalpha(): return []
    result={}
    for i in range(len(raw)):
        changed=raw[:i]+raw[i+1:]
        result.setdefault(changed, dict(operation='delete_extra_letter',at=i,original=raw[i],replacement=''))
    for i in range(len(raw)-1):
        if raw[i]!=raw[i+1]:
            changed=raw[:i]+raw[i+1]+raw[i]+raw[i+2:]
            result.setdefault(changed,dict(operation='transpose',at=i,original=raw[i:i+2],replacement=raw[i:i+2][::-1]))
    for i in range(len(raw)+1):
        for letter in 'abcdefghijklmnopqrstuvwxyz':
            changed=raw[:i]+letter+raw[i:]
            result.setdefault(changed,dict(operation='insert_missing_letter',at=i,original='',replacement=letter))
    return list(result.items())


def py_index(source, utf16_offset):
    if type(utf16_offset) is not int or not 0 <= utf16_offset <= len(source.encode('utf-16-le')) // 2:
        raise ValueError('Invalid UTF-16 range')
    return len(source.encode('utf-16-le')[:utf16_offset * 2].decode('utf-16-le'))


def split_spans(source, metadata):
    result = []
    for span in metadata['latin_spans']:
        # A run of capitals inside a mixed-case span is an identifier boundary.
        # Leading sentence capitalization remains available for pinyin decoding.
        raw = span['raw']
        cursor = 0
        for match in re.finditer(r'[A-Z]{2,}', raw):
            if match.start() > cursor:
                result.append(dict(start=span['start'] + cursor, end=span['start'] + match.start(), raw=raw[cursor:match.start()]))
            cursor = match.end()
        if cursor < len(raw):
            result.append(dict(start=span['start'] + cursor, end=span['end'], raw=raw[cursor:]))
    return result


def neighbors():
    keys = {}
    for row, (offset, letters) in enumerate([(0.0, 'qwertyuiop'), (0.25, 'asdfghjkl'), (0.75, 'zxcvbnm')]):
        for column, letter in enumerate(letters):
            keys[letter] = (column + offset, row)
    return {a: [b for b in keys if a != b and math.dist(keys[a], keys[b]) <= 1.3] for a in keys}


KEY_NEIGHBORS = neighbors()


def variant_strings(raw):
    result = dict(variants(raw))
    if 3 <= len(raw) <= 48 and raw.isalpha():
        for i, letter in enumerate(raw):
            for other in KEY_NEIGHBORS.get(letter, []):
                changed = raw[:i] + other + raw[i + 1:]
                result.setdefault(changed, dict(operation='neighbor_substitution', at=i, original=letter, replacement=other))
    return result



class Generator:
    def __init__(self, tools_directory, rime_data, scratch, grammar_file, plugin):
        from pathlib import Path
        tools_directory = Path(tools_directory)
        grammar_file = Path(grammar_file).resolve()
        grammar_name = grammar_file.stem
        Path(scratch, grammar_file.name).symlink_to(grammar_file)
        self.workers = []
        try:
            self.probe = LineTool([str(tools_directory/'rime_analysis'), str(rime_data), str(scratch)])
            self.workers.append(self.probe)
            self.poet = LineTool([str(tools_directory/'rime_sentences'), str(rime_data),
                                  str(scratch), grammar_name, str(plugin)])
            self.workers.append(self.poet)
            self.codec = LineTool([str(tools_directory/'layout')])
            self.workers.append(self.codec)
        except BaseException:
            self.close()
            raise
        self.cache = {}
        self.poet_cache = {}
        self.query_count = 0
        self.poet_count = 0

    def query(self, mode, raw):
        key = mode + '\t' + raw
        if key not in self.cache:
            self.cache[key] = self.probe.query(key)
            self.query_count += 1
        return self.cache[key]

    def sentences(self, raw):
        if raw not in self.poet_cache:
            self.poet_cache[raw] = self.poet.query(raw)
            self.poet_count += 1
        return self.poet_cache[raw]['candidates']

    def close(self):
        for worker in self.workers:
            worker.close()

    def span_options(self, span, vocabulary):
        raw = span['raw'].lower()
        exact = self.sentences(raw) if len(raw) <= 48 else []
        paths = [dict(input=raw, edit=None, candidates=exact)]
        proposals = []
        for changed, edit in variant_strings(raw).items():
            graph = self.query('G', changed)
            if graph['interpreted'] != len(changed):
                continue
            if not any(p['abbreviations'] == 0 and p['corrections'] == 0 for p in graph['paths']):
                continue
            score = best_dictionary_path(self.query('E', changed))
            if score:
                proposals.append(dict(input=changed, edit=edit, lexical_score=score['score']))
        grouped = defaultdict(list)
        for proposal in proposals:
            grouped[proposal['edit']['operation']].append(proposal)
        retained = []
        for kind, group in sorted(grouped.items()):
            group.sort(key=lambda p: (-p['lexical_score'], p['input']))
            selected = []
            seen_positions = set()
            # Reserve different error positions before a second spelling at one position.
            for proposal in group:
                if proposal['edit']['at'] in seen_positions:
                    continue
                selected.append(proposal)
                seen_positions.add(proposal['edit']['at'])
                if len(selected) == POLICY['max_paths_per_edit_kind']:
                    break
            for proposal in group:
                if len(selected) == POLICY['max_paths_per_edit_kind']:
                    break
                if proposal not in selected:
                    selected.append(proposal)
            retained.extend(selected)
        for proposal in retained:
            candidates = self.sentences(proposal['input'])
            if candidates:
                paths.append({**proposal, 'candidates': candidates})
        # Explicit supplied personal-vocabulary entries are input evidence shared
        # with the baseline. They are not loaded from expected answers.
        for hint in vocabulary:
            matched = hint.get('matched_span', '')
            spelling = ''.join(hint.get('speech_hint', '').split()).lower()
            if not matched or matched.lower() != spelling:
                continue
            for match in re.finditer(re.escape(matched), span['raw'], re.IGNORECASE):
                left_raw, right_raw = raw[:match.start()], raw[match.end():]
                left = self.sentences(left_raw)[:8] if left_raw else [dict(text='', reading='', score=0, words=[])]
                right = self.sentences(right_raw)[:16] if right_raw else [dict(text='', reading='', score=0, words=[])]
                hinted = []
                for a in left:
                    for b in right:
                        hinted.append(dict(text=a['text'] + hint['surface'] + b['text'],
                                           reading=' '.join(v for v in [a['reading'], hint['speech_hint'], b['reading']] if v),
                                           score=a['score'] + b['score'] - 13.815510557964274,
                                           words=[], supplied_vocabulary=hint['surface']))
                hinted.sort(key=lambda c: -c['score'])
                if hinted:
                    paths.append(dict(input=raw, edit=None, vocabulary=True, candidates=hinted[:80]))
        all_options = []
        for path_index, path in enumerate(paths):
            for rank, candidate in enumerate(path['candidates']):
                # All alternatives cover the same raw span. Dividing by the
                # candidate's syllable count would reward added syllables.
                score = -candidate['score'] + (POLICY['spelling_edit_penalty'] if path['edit'] else 0)
                all_options.append(dict(text=candidate['text'], reading=candidate['reading'],
                                        proposed_input=path['input'], edit=path['edit'], cost=score,
                                        native_score=candidate['score'], path_index=path_index,
                                        path_rank=rank + 1, words=candidate['words'],
                                        supplied_vocabulary=candidate.get('supplied_vocabulary')))
        all_options.sort(key=lambda c: (c['cost'], c['text'], c['proposed_input']))
        # Keep a broad pool for constructing complete candidates. Diversity
        # reservations in whole_candidates() occur before final Top-K trimming.
        selected = []
        seen = set()
        def add(option):
            if option['text'] not in seen:
                selected.append(option)
                seen.add(option['text'])
        for option in all_options:
            if option['path_index'] == 0 and option['path_rank'] <= 80:
                add(option)
        for option in all_options:
            if option['path_index'] != 0 and option['path_rank'] <= 3:
                add(option)
        for option in all_options:
            if len(selected) >= POLICY['max_span_candidates']:
                break
            add(option)
        floor = min((c['cost'] for c in selected), default=0)
        for option in selected:
            option['cost'] -= floor
        selected.sort(key=lambda c: (c['cost'], c['text']))
        keep = dict(text=span['raw'], reading=None, proposed_input=span['raw'], edit=None,
                    cost=POLICY['original_keep_penalty'] if exact else 0,
                    path_index=-1, path_rank=1, native_score=None, words=[])
        selected.append(keep)
        return dict(span=span, options=selected, proposed_path_count=len(proposals),
                    paths=[{k:v for k,v in p.items() if k != 'candidates'} | {'candidate_count':len(p['candidates'])} for p in paths])

    def whole_candidates(self, source, spans):
        if not spans:
            return [dict(text=source, cost=0, parts=[], edits=[], keep_original=True)]
        option_lists = [s['options'] for s in spans]

        def materialize(indices):
            result = []
            cursor = 0
            parts = []
            edits = []
            for data, index in zip(spans, indices):
                span, option = data['span'], data['options'][index]
                start, end = py_index(source, span['start']), py_index(source, span['end'])
                result.extend([source[cursor:start], option['text']])
                cursor = end
                parts.append(dict(range_utf16=[span['start'],span['end']], raw=span['raw'],
                                  text=option['text'], reading=option['reading'],
                                  proposed_input=option['proposed_input'], path_index=option['path_index'],
                                  path_rank=option['path_rank']))
                if option['edit']:
                    edits.append(dict(range_utf16=[span['start'],span['end']], **option['edit']))
            result.append(source[cursor:])
            return dict(text=''.join(result), cost=sum(opts[i]['cost'] for opts,i in zip(option_lists,indices)),
                        parts=parts, edits=edits)

        # Candidate generation never reads reference answers. Besides a normal
        # cost beam, retain complete sentences changing each path independently.
        beam = [(0.0, ())]
        for options in option_lists:
            expanded = [(score + option['cost'], indices + (i,))
                        for score, indices in beam for i,option in enumerate(options)]
            beam = heapq.nsmallest(POLICY['whole_beam'], expanded)
        best_indices = tuple(min(range(len(options)), key=lambda i:options[i]['cost']) for options in option_lists)
        pooled = [materialize(indices) for _,indices in beam]
        for s, options in enumerate(option_lists):
            for i, option in enumerate(options):
                if option['path_rank'] <= 3 or option['path_index'] == 0:
                    indices = list(best_indices)
                    indices[s] = i
                    pooled.append(materialize(indices))
        keep = materialize(tuple(next(i for i,c in enumerate(options) if c['path_index'] == -1) for options in option_lists))
        keep['keep_original'] = True
        pooled.append(keep)
        unique = {}
        for candidate in sorted(pooled, key=lambda c:(c['cost'], c['text'])):
            unique.setdefault(candidate['text'], candidate)
        # Within a fixed global budget, interleave unchanged-spelling candidates
        # and spelling-edit candidates, retaining correction-position diversity.
        exact = [c for c in unique.values() if not c['edits'] and c['text'] != source]
        corrected_groups = defaultdict(list)
        for candidate in unique.values():
            if candidate['edits']:
                signature = tuple((tuple(e['range_utf16']),e['operation'],e['at'],e['replacement']) for e in candidate['edits'])
                corrected_groups[signature].append(candidate)
        groups = sorted(corrected_groups.values(), key=lambda group:group[0]['cost'])
        corrected = []
        for depth in range(0,80,POLICY['chinese_alternatives_per_path_round']):
            for group in groups:
                corrected.extend(group[depth:depth+POLICY['chinese_alternatives_per_path_round']])
        ordered = [keep]
        seen = {source}
        for i in range(max(len(exact),len(corrected))):
            for items in (exact,corrected):
                if i < len(items) and items[i]['text'] not in seen:
                    ordered.append(items[i]); seen.add(items[i]['text'])
        for candidate in unique.values():
            if candidate['text'] not in seen:
                ordered.append(candidate); seen.add(candidate['text'])
        return ordered



def validate_candidate(selected, case_data):
    source=case_data['input']
    cursor=0
    reconstructed=[]
    for part in selected['parts']:
        start,end=[py_index(source,n) for n in part['range_utf16']]
        if start < cursor or end < start or source[start:end] != part['raw']:
            raise ValueError('Candidate spans do not align with the original draft')
        if part['reading']:
            if part['reading'].replace(' ','') != part['proposed_input'].lower().replace("'",''):
                raise ValueError('Candidate reading does not match its spelling path')
            if distance(part['raw'].lower(),part['proposed_input'].lower()) > 1:
                raise ValueError('Candidate exceeds the spelling-edit budget')
        else:
            if part['text'] != part['raw']:
                raise ValueError('An unconverted span was changed')
        reconstructed.extend([source[cursor:start],part['text']]);cursor=end
    reconstructed.append(source[cursor:])
    if ''.join(reconstructed) != selected['text']:
        raise ValueError('Candidate changed content outside its decoded spans')
    # Production layout treats whitespace inside a protected code block as
    # content. Apply each selected span to those original segment boundaries.
    converted_segments=[]
    search_start=0
    for original_segment in case_data['metadata']['input_segments']:
        segment_start=source.index(original_segment,search_start)
        segment_end=segment_start+len(original_segment)
        fragment=[]
        fragment_cursor=segment_start
        for part in selected['parts']:
            start,end=[py_index(source,n) for n in part['range_utf16']]
            if start>=segment_start and end<=segment_end:
                fragment.extend([source[fragment_cursor:start],part['text']])
                fragment_cursor=end
        fragment.append(source[fragment_cursor:segment_end])
        converted_segments.append(''.join(fragment))
        search_start=segment_end
    if re.findall(r'\s+',source) != re.findall(r'\s+',selected['text']):
        raise ValueError('Candidate changed the original whitespace')
    return dict(action='replace_target', converted_segments=converted_segments)
