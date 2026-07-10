# Correction Prompt and Evaluation Practice

This document defines how Typeforme correction prompts are designed and evaluated. It separates transport correctness, ASR reliability, and natural-language quality so a prompt is not tuned to compensate for a different layer's failure.

## Ownership boundaries

### Inference harness

The harness owns the chat template, thinking mode, sampling parameters, context budget, timeout, and JSON transport. Change and evaluate these independently from prompt wording.

Qwen3.5 and Qwen3.6 officially use `chat_template_kwargs.enable_thinking=false` for non-thinking operation and do not officially support the older Qwen3 prompt-level soft switch. Their published non-thinking defaults are `temperature=0.7`, `top_p=0.8`, `top_k=20`, and `presence_penalty=1.5`, with a warning that higher presence penalty can introduce language mixing or reduce performance. These are starting points, not automatic product settings; Typeforme's preservation task still requires manual A/B review on the exact local and external runtimes.

Sources: [Qwen3.5-9B model card](https://huggingface.co/Qwen/Qwen3.5-9B), [Qwen3.6-27B model card](https://huggingface.co/Qwen/Qwen3.6-27B).

### ASR reliability

ASR hallucination decisions belong with audio-grounded evidence such as voice activity, non-vocal duration, model confidence or entropy, and cross-source acoustic evidence. Do not reject a transcript merely because its wording is a fluent declaration, narrative, command, or question.

Research associates hallucinations with non-vocal audio, but also shows that detection remains difficult on natural speech. HALAS reports only 53.1% F1 for state-of-the-art detectors on its human-annotated natural benchmark. Any future suppression mechanism therefore needs real audio, human labels, measured false-reject cost, and an explicit user-visible failure policy. A text-only LLM classifier is not an adequate substitute.

Sources: [Careless Whisper](https://arxiv.org/abs/2402.08021), [HALAS](https://arxiv.org/abs/2606.23048).

### Correction prompt

The correction prompt owns transformation of admitted transcript evidence. It should be small enough that the model can identify the controlling rules and should not attempt to infer whether speech existed from linguistic style.

- Keep one short invariant contract shared by all modes.
- Keep each mode's editing license separate and local.
- Prefer explicit principles over a catalogue of domain examples.
- Start with zero examples. Add at most one abstract example only when a frozen blind evaluation shows a general improvement.
- Never add a rule solely to fix one inspected sample. First identify a repeated failure class on unseen inputs.
- Preserve meaning before optimizing polish: facts, negation, uncertainty, perspective, quantities, names, technical spans, and language mix take priority over style.
- Do not require a smaller model to reproduce a larger model's style quality. Compare each supported model tier with its own baseline.

Demonstrations can teach format and input distribution rather than the intended reasoning rule, and their selection, number, order, and position can introduce spurious correlations. Multi-demonstration prompts can perform worse than a single demonstration, while long contexts can underuse information placed in the middle. These findings support keeping examples scarce and treating their effect as an empirical question, not a general benefit.

Sources: [Rethinking the Role of Demonstrations](https://aclanthology.org/2022.emnlp-main.759/), [How Many Demonstrations Do You Need?](https://aclanthology.org/2023.findings-emnlp.745/), [Lost in the Middle](https://arxiv.org/abs/2307.03172).

## Evaluation protocol

Natural-language refinement has no single mechanically correct output. Automation may verify execution, but it must not decide which wording is better.

### Dataset separation

Maintain three non-overlapping pools:

1. **Development**: visible cases used to understand failures and draft a prompt.
2. **Regression**: previously observed failures. They raise alerts but are not targets for sample-specific prompt patches.
3. **Blind holdout**: inputs not inspected while editing the prompt. Freeze the candidate before opening this pool; after it influences a change, retire it from blind use.

Cover each correction mode and representative slices: short and long speech, colloquial language, repairs, ambiguity, negation, uncertainty, numbers and times, names, code switching, technical spans, surrounding context, vocabulary hints, and multiple ASR hypotheses. Do not let one domain or syntactic template dominate a pool.

### Mechanical preflight

Scripts may report only objective runtime facts:

- request completed or failed;
- output parsed as the required JSON schema;
- context and output budgets were respected;
- latency and stop reason;
- possible protected-span or formatting changes for reviewer attention.

These signals never count as semantic correctness. A successful request, non-empty response, matching keyword, or automatic similarity score is not a pass.

### Manual semantic review

Every refine result used for a quality claim must be reviewed one sample at a time with the raw transcript, relevant ASR hypotheses, context, selected mode, and output visible. Record separate judgments for:

1. **Meaning preservation**: intent, facts, scope, negation, uncertainty, perspective, quantities, names, and language mix.
2. **Unsupported change**: additions, deletions, translation, inferred causes, or invented task state.
3. **Mode fit**: whether Clean, Polish+, Structure+, or Formal+ made an appropriate amount and kind of change.
4. **Naturalness**: readability and fluency after the first three criteria are satisfied.

Prefer blinded pairwise review of baseline versus candidate with randomized left/right order. Use `candidate better`, `equivalent`, or `candidate worse`, plus a short reason and severity. An intent description may guide review, but do not require an exact reference sentence.

Treat a changed fact, intent, scope, negation, uncertainty, quantity, name, protected span, or an unsupported addition as a serious semantic error. Treat conservative wording, weak mode realization, or suboptimal but faithful formatting as a quality weakness rather than the same class of failure.

Human review also needs a documented rubric; unstructured preference alone is not reproducible. Research on style transfer separates meaning preservation, style strength, and fluency, while work on LLM judges documents position and surface-form biases. Automated or model-based judges may triage results, but they do not replace manual review for release decisions.

Sources: [Best practices for human evaluation of generated text](https://aclanthology.org/W19-8643/), [Evaluating Style Transfer for Text](https://aclanthology.org/N19-1049/), [Judging the Judges](https://aclanthology.org/2025.ijcnlp-long.18/), [GDPval grading](https://openai.com/index/gdpval/).

### Release decision

- Do not require 100% correctness and do not require equal scores across model sizes.
- Compare each model and runtime against the current production baseline under the same harness.
- Prefer aggregate blinded human preference and serious semantic-regression rate over a single total score.
- Do not reject or patch a prompt because of one isolated sample. Look for a recurring failure class and confirm it on unseen cases.
- A candidate is ready only when manually reviewed holdout results improve overall without a material increase in serious semantic regressions.
- Report unreviewed samples as pending, never as correct.

## Next experiment order

1. Freeze the current production prompt as baseline.
2. Test the Qwen non-thinking transport and sampling profiles independently; do not alter prompt wording in that comparison.
3. Build and freeze development, regression, and blind-holdout pools.
4. Draft one compact, principle-led prompt without examples.
5. Run baseline and candidate on each supported model tier with identical parameters.
6. Perform per-sample manual review, then summarize pairwise preference and failure classes.
7. Change the prompt only for a demonstrated cross-sample failure class, and use a fresh holdout for the next decision.
