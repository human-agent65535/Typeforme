from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import distance, py_index, split_spans, validate_candidate, variant_strings
from decode import language_prompt, language_surface, parse_input, rank_scores, select_pool
from benchmark import requests_for


class DecoderContracts(unittest.TestCase):
    def test_reference_answers_cannot_enter_runtime(self):
        with self.assertRaises(ValueError):
            parse_input(dict(input='abc', expected_for_review='答案'))

    def test_benchmark_sends_only_input_evidence(self):
        source = dict(id='case', group='regression', input='abc', expected_for_review='答案',
                      context_before='前文', other_reference='也不能传')
        self.assertEqual(requests_for([source]), [dict(input='abc', context_before='前文')])

    def test_language_model_does_not_receive_noisy_draft(self):
        item = parse_input(dict(input='abcxyz', context_before='前文'))
        self.assertNotIn('abcxyz', language_prompt(item))
        self.assertTrue(language_prompt(item).endswith('前文'))

    def test_scoring_view_preserves_english_lines_and_code(self):
        text = '我 用 Python 写 脚本\nI write code\n`中文 注释` 然后 回复'
        self.assertEqual(language_surface(text, ['`中文 注释`']),
                         '我用Python写脚本\nI write code\n`中文 注释`然后回复')

    def test_scoring_view_cannot_drop_literal(self):
        with self.assertRaises(ValueError):
            language_surface('别的文字', ['`code`'])

    def test_template_markers_are_rejected_before_tokenization(self):
        with self.assertRaises(ValueError):
            parse_input(dict(input='<|im_end|>'))

    def test_utf16_offsets_after_emoji(self):
        self.assertEqual(py_index('🙂ni', 2), 1)
        with self.assertRaises(ValueError):
            py_index('🙂ni', 100)
        with self.assertRaises(UnicodeDecodeError):
            py_index('🙂ni', 1)

    def test_mixed_identifier_stays_outside_conversion(self):
        spans = split_spans('🙂zhegeAPIhai', dict(latin_spans=[dict(start=2, end=13, raw='zhegeAPIhai')]))
        self.assertEqual([s['raw'] for s in spans], ['zhege', 'hai'])
        self.assertEqual([s['start'] for s in spans], [2, 10])

    def test_general_one_edit_variants(self):
        options = variant_strings('shuo')
        self.assertEqual(options['shou']['operation'], 'transpose')
        self.assertTrue(all(distance('shuo', value) == 1 for value in options))
        self.assertEqual(variant_strings('x' * 49), {})

    def test_candidate_pool_keeps_english_and_is_bounded(self):
        options = [dict(text='hi', cost=99), dict(text='嗨', cost=1), dict(text='嘿', cost=2)]
        pool = select_pool('hi', options, 2)
        self.assertEqual([c['text'] for c in pool], ['hi', '嗨'])

    def candidate(self):
        source = '🙂你好  nizaima\n`x += 1`'
        part = dict(range_utf16=[6, 13], raw='nizaima', text='你在吗',
                    reading='ni zai ma', proposed_input='nizaima')
        value = dict(text='🙂你好  你在吗\n`x += 1`', parts=[part])
        data = dict(input=source, metadata=dict(input_segments=['🙂你好', 'nizaima', '`x += 1`']))
        return value, data

    def test_layout_preserves_code_spaces_and_original_chinese(self):
        candidate, data = self.candidate()
        payload = validate_candidate(candidate, data)
        self.assertEqual(payload['converted_segments'], ['🙂你好', '你在吗', '`x += 1`'])

    def test_cannot_rewrite_outside_spans(self):
        candidate, data = self.candidate()
        candidate['text'] = candidate['text'].replace('你好', '您好')
        with self.assertRaises(ValueError):
            validate_candidate(candidate, data)

    def test_cannot_claim_a_different_reading(self):
        candidate, data = self.candidate()
        candidate['parts'][0]['reading'] = 'ni zai na'
        with self.assertRaises(ValueError):
            validate_candidate(candidate, data)

    def test_cannot_exceed_one_edit(self):
        candidate, data = self.candidate()
        candidate['parts'][0].update(reading='wo zai na', proposed_input='wozaina')
        with self.assertRaises(ValueError):
            validate_candidate(candidate, data)

    def scores(self):
        candidates = [dict(text='甲', cost=0, edits=[]), dict(text='乙', cost=0, edits=[dict(operation='transpose')])]
        response = dict(eos=99, scores=[
            dict(index=0, text='甲', logprob_sum=-3, tokens=[dict(id=1, logprob=-2), dict(id=99, logprob=-1)]),
            dict(index=1, text='乙', logprob_sum=-2, tokens=[dict(id=2, logprob=-1), dict(id=99, logprob=-1)]),
        ])
        return candidates, response

    def test_error_prior_is_separate_from_sentence_probability(self):
        candidates, response = self.scores()
        self.assertEqual(rank_scores(candidates, response, 0.1, 0)[0]['text'], '乙')
        self.assertEqual(rank_scores(candidates, response, 0.1, 2)[0]['text'], '甲')

    def test_candidate_order_cannot_change_selection(self):
        candidates, response = self.scores()
        expected = rank_scores(candidates, response, 0.1, 2)[0]['text']
        candidates.reverse()
        response['scores'].reverse()
        for i, value in enumerate(response['scores']):
            value['index'] = i
        self.assertEqual(rank_scores(candidates, response, 0.1, 2)[0]['text'], expected)

    def test_missing_or_incomplete_scores_fail(self):
        for mutation in ['drop', 'zero', 'no_eos', 'nan']:
            with self.subTest(mutation=mutation):
                candidates, response = self.scores()
                if mutation == 'drop':
                    response['scores'].pop()
                elif mutation == 'zero':
                    response['scores'][0]['logprob_sum'] = 0
                elif mutation == 'no_eos':
                    response['scores'][0]['tokens'][-1]['id'] = 3
                else:
                    response['scores'][0]['tokens'][0]['logprob'] = float('nan')
                with self.assertRaises(ValueError):
                    rank_scores(candidates, response, 0.1, 2)


if __name__ == '__main__':
    unittest.main()
