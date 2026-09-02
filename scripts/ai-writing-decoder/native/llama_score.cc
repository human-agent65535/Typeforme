#include <llama.h>
#include <ggml-backend.h>
#include <nlohmann/json.hpp>
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <vector>

using json = nlohmann::json;

static std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text) {
  int n = llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), nullptr, 0, true, true);
  if (n >= 0) throw std::runtime_error("unexpected tokenizer sizing result");
  std::vector<llama_token> tokens(-n);
  n = llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), tokens.data(), tokens.size(), true, true);
  if (n < 0) throw std::runtime_error("tokenization failed");
  tokens.resize(n);
  return tokens;
}

static double log_probability(const float* logits, int target, std::vector<float>& work) {
  const int count = static_cast<int>(work.size());
  float maximum = 0;
  vDSP_maxv(logits, 1, &maximum, count);
  const float negative_maximum = -maximum;
  vDSP_vsadd(logits, 1, &negative_maximum, work.data(), 1, count);
  vvexpf(work.data(), work.data(), &count);
  // Accumulate in double precision after the vectorized exponentiation.
  const double denominator = std::accumulate(work.begin(), work.end(), 0.0);
  const double value = static_cast<double>(logits[target])-maximum-std::log(denominator);
  if (!std::isfinite(value) || value > 0.00001) throw std::runtime_error("invalid model probability");
  return value;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: batch_scorer MODEL.gguf LLAMA_BACKEND_DIRECTORY\n";
    return 64;
  }
  llama_log_set([](ggml_log_level level, const char* text, void*) {
    if (level >= GGML_LOG_LEVEL_WARN) std::cerr << text;
  }, nullptr);
  ggml_backend_load_all_from_path(argv[2]);
  llama_backend_init();
  auto model_params = llama_model_default_params();
  model_params.n_gpu_layers = -1;
  model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
  model_params.load_mtp = false;
  auto* model = llama_model_load_from_file(argv[1], model_params);
  if (!model) return 70;
  auto context_params = llama_context_default_params();
  constexpr int group_size = 8;
  context_params.n_ctx = 4096;
  context_params.n_batch = 1024;
  context_params.n_ubatch = 512;
  context_params.n_seq_max = group_size;
  context_params.n_threads = 8;
  context_params.n_threads_batch = 8;
  context_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
  auto* context = llama_init_from_model(model, context_params);
  if (!context) return 71;
  const auto* vocab = llama_model_get_vocab(model);
  const auto eos = llama_vocab_eos(vocab);
  const int vocabulary_size = llama_vocab_n_tokens(vocab);
  std::vector<float> work(vocabulary_size);
  auto batch = llama_batch_init(context_params.n_batch, 0, 1);
  std::cerr << "batch_scorer_ready\n";

  std::string line;
  while (std::getline(std::cin, line)) {
    const auto started = std::chrono::steady_clock::now();
    try {
      const auto request = json::parse(line);
      const auto prompt = request.at("prompt").get<std::string>();
      const auto candidates = request.at("candidates");
      if (candidates.empty() || candidates.size() > 128) throw std::runtime_error("candidate count outside limit");
      const auto prompt_tokens = tokenize(vocab, prompt);
      std::vector<std::vector<llama_token>> paths;
      size_t shared = prompt_tokens.size();
      for (const auto& candidate : candidates) {
        auto tokens = tokenize(vocab, prompt+candidate.at("text").get<std::string>());
        tokens.push_back(eos);
        if (tokens.size() > 512) throw std::runtime_error("candidate token count outside limit");
        size_t common = 0;
        while (common < shared && common < tokens.size() && tokens[common] == prompt_tokens[common]) ++common;
        shared = common;
        paths.push_back(std::move(tokens));
      }
      if (shared == 0) throw std::runtime_error("empty shared conditioning prefix");
      json scores = json::array();
      for (size_t first = 0; first < candidates.size();) {
        llama_memory_clear(llama_get_memory(context), true);
        batch.n_tokens = 0;
        std::vector<int> offsets;
        size_t end = first;
        size_t batch_tokens = 0;
        // Long drafts need smaller groups so the fixed batch allocation is
        // never exceeded. The score of each complete path stays unchanged.
        while (end < candidates.size() && end-first < group_size &&
               batch_tokens + paths[end].size()-1 <= context_params.n_batch) {
          batch_tokens += paths[end].size()-1;
          ++end;
        }
        for (size_t index = first; index < end; ++index) {
          offsets.push_back(batch.n_tokens);
          const auto& tokens = paths[index];
          // The final EOS is a scoring target, never part of the decoded input.
          for (size_t position = 0; position+1 < tokens.size(); ++position) {
            const int slot = batch.n_tokens++;
            batch.token[slot] = tokens[position];
            batch.pos[slot] = position;
            batch.n_seq_id[slot] = 1;
            batch.seq_id[slot][0] = index-first;
            batch.logits[slot] = position+1 >= shared;
          }
        }
        if (llama_decode(context, batch) != 0) throw std::runtime_error("model batch evaluation failed");
        for (size_t index = first; index < end; ++index) {
          const auto& tokens = paths[index];
          double total = 0;
          json token_scores = json::array();
          for (size_t position = shared; position < tokens.size(); ++position) {
            const auto* logits = llama_get_logits_ith(context, offsets[index-first]+position-1);
            if (!logits) throw std::runtime_error("missing model logits");
            const double logp = log_probability(logits, tokens[position], work);
            total += logp;
            token_scores.push_back({{"id", tokens[position]}, {"logprob", logp}});
          }
          scores.push_back({{"index", index}, {"text", candidates[index].at("text")},
                            {"logprob_sum", total}, {"tokens", token_scores}});
        }
        first = end;
      }
      const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-started).count();
      std::cout << json({{"scores", scores}, {"elapsed_ms", elapsed}, {"conditioning_tokens", shared},
                        {"vocabulary_size", vocabulary_size}, {"eos", eos}}).dump() << std::endl;
    } catch (const std::exception& error) {
      std::cout << json({{"error", error.what()}}).dump() << std::endl;
    }
  }
  llama_batch_free(batch);
  llama_free(context);
  llama_model_free(model);
  llama_backend_free();
}
