#include <rime_api.h>
#include <rime/algo/syllabifier.h>
#include <rime/config.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/prism.h>
#include <rime/dict/table.h>
#include <rime/gear/grammar.h>
#include <rime/gear/poet.h>
#include <algorithm>
#include <chrono>
#include <iostream>
#include <set>
#include <sstream>
#include <dlfcn.h>

using namespace rime;

static std::string quote(const std::string& text) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c == '\n') out << "\\n";
    else if (c == '\r') out << "\\r";
    else if (c == '\t') out << "\\t";
    else if (c >= 32) out << c;
  }
  out << '"';
  return out.str();
}

static std::string reading(Dictionary& dict, const Code& code) {
  std::vector<std::string> syllables;
  if (!dict.Decode(code, &syllables)) return "";
  std::string result;
  for (const auto& syllable : syllables) {
    if (!result.empty()) result += ' ';
    result += syllable;
  }
  return result;
}

static std::string letters(std::string value) {
  value.erase(std::remove_if(value.begin(), value.end(),
                            [](char c) { return c == ' ' || c == '\''; }),
              value.end());
  return value;
}

struct Result {
  std::string text;
  std::string reading;
  double weight;
  std::vector<DictEntry> words;
  std::vector<size_t> stops;
};

int main(int argc, char** argv) {
  if (argc != 3 && argc != 5) return 64;
  const std::string shared = argv[1], scratch = argv[2];
  const std::string prebuilt = shared + "/build";
  const bool use_grammar = argc == 5;
  const std::string grammar_name = use_grammar ? argv[3] : "";
  if (use_grammar && (!std::filesystem::exists(scratch + "/" + grammar_name + ".gram") ||
                      !dlopen(argv[4], RTLD_NOW | RTLD_GLOBAL))) {
    std::cerr << "Cannot load requested grammar resource or plugin\n";
    return 71;
  }
  RimeApi* api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared.c_str();
  traits.user_data_dir = scratch.c_str();
  traits.prebuilt_data_dir = prebuilt.c_str();
  traits.staging_dir = scratch.c_str();
  traits.app_name = "rime.typeforme.rerank";
  traits.min_log_level = 2;
  traits.log_dir = "";
  const char* modules[] = {"core", "dict", "gears", "levers", "octagram", nullptr};
  if (use_grammar) traits.modules = modules;
  api->setup(&traits);
  api->initialize(&traits);
  auto table = New<Table>(rime::path(std::filesystem::path(prebuilt + "/typeforme_pinyin.table.bin")));
  auto prism = New<Prism>(rime::path(std::filesystem::path(prebuilt + "/typeforme_pinyin.prism.bin")));
  Dictionary dict("typeforme_pinyin", {}, {table}, prism);
  if (!dict.Load()) return 70;
  Config config;
  std::unique_ptr<Grammar> grammar;
  if (use_grammar) {
    config.SetString("grammar/language", grammar_name);
    config.SetInt("grammar/collocation_max_length", 6);
    config.SetInt("grammar/collocation_min_length", 3);
    config.SetDouble("grammar/collocation_penalty", -14);
    config.SetDouble("grammar/non_collocation_penalty", -6);
    config.SetDouble("grammar/weak_collocation_penalty", -100);
    config.SetDouble("grammar/rear_penalty", -20);
    auto component = Grammar::Require("grammar");
    if (!component || !(grammar = std::unique_ptr<Grammar>(component->Create(&config)))) return 72;
    std::cerr << "grammar_probe=" << grammar->Query("中文", "输入法", true) << '\n';
  }
  Poet poet(nullptr, &config);

  std::string input;
  while (std::getline(std::cin, input)) {
    const auto started = std::chrono::steady_clock::now();
    std::string context;
    if (auto separator = input.find('\t'); separator != std::string::npos) {
      context = input.substr(separator + 1);
      input.resize(separator);
    }
    if (input.empty() || input.size() > 96) {
      std::cout << "{\"error\":\"invalid_input_length\"}" << std::endl;
      continue;
    }
    Syllabifier syllabifier(" '", false, false);
    SyllableGraph graph;
    syllabifier.BuildSyllableGraph(input, *prism, &graph);
    WordGraph words;
    size_t word_count = 0;
    for (const auto& [start, ends] : graph.edges) {
      auto lookup = dict.Lookup(graph, start);
      if (!lookup) continue;
      for (auto& [end, entries] : *lookup) {
        if (end <= start || end > input.size()) continue;
        const auto raw = letters(input.substr(start, end - start));
        std::set<std::pair<std::string, std::string>> seen;
        size_t scanned = 0;
        while (!entries.exhausted() && scanned++ < 120 && seen.size() < 16) {
          auto entry = entries.Peek();
          if (!entry) break;
          auto phonetic = reading(dict, entry->code);
          if (letters(phonetic) == raw && seen.emplace(entry->text, phonetic).second) {
            words[start][end].push_back(New<DictEntry>(*entry));
            ++word_count;
          }
          entries.Next();
        }
      }
    }
    std::vector<Result> candidates;
    // Poet excludes full-input dictionary phrases; score those with the same
    // grammar instance and context used for composed sentence paths.
    for (const auto& entry : words[0][input.size()]) {
      candidates.push_back({entry->text, reading(dict, entry->code),
          Grammar::Evaluate(context, entry->text, entry->weight, true, grammar.get()),
          {*entry}, {0, input.size()}});
    }
    for (const auto& sentence : poet.MakeSentences(words, input.size(), context, 80, 100.0)) {
      Result result{sentence->text(), reading(dict, sentence->code()),
                    sentence->weight(), sentence->components(), {0}};
      size_t end = 0;
      for (auto length : sentence->word_lengths()) {
        end += length;
        result.stops.push_back(end);
      }
      if (end == input.size() && letters(result.reading) == letters(input))
        candidates.push_back(std::move(result));
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) {
      return a.weight > b.weight;
    });
    std::set<std::string> emitted;
    std::ostringstream output;
    output << "{\"input\":" << quote(input) << ",\"interpreted\":" << graph.interpreted_length
           << ",\"word_count\":" << word_count << ",\"candidates\":[";
    bool first = true;
    for (const auto& candidate : candidates) {
      if (!emitted.insert(candidate.text).second) continue;
      if (emitted.size() > 80) break;
      if (!first) output << ',';
      first = false;
      output << "{\"text\":" << quote(candidate.text) << ",\"reading\":" << quote(candidate.reading)
             << ",\"score\":" << candidate.weight << ",\"words\":[";
      for (size_t i = 0; i < candidate.words.size(); ++i) {
        if (i) output << ',';
        output << "{\"start\":" << candidate.stops[i] << ",\"end\":" << candidate.stops[i + 1]
               << ",\"text\":" << quote(candidate.words[i].text)
               << ",\"reading\":" << quote(reading(dict, candidate.words[i].code)) << '}';
      }
      output << "]}";
    }
    const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    output << "],\"elapsed_ms\":" << elapsed << ",\"grammar\":" << quote(grammar_name)
           << ",\"engine_version\":" << quote(api->get_version()) << '}';
    std::cout << output.str() << std::endl;
  }
  return 0;
}
