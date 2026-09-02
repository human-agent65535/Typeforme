#include <rime_api.h>
#include <rime/algo/syllabifier.h>
#include <rime/dict/corrector.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/prism.h>
#include <rime/dict/table.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <sstream>

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

struct PathReading {
  std::vector<size_t> stops{0};
  Code code;
  double cost = 0;
  int abbreviations = 0;
  int corrections = 0;
};

static std::string reading(Dictionary& dict, const Code& code) {
  std::vector<std::string> words;
  if (!dict.Decode(code, &words)) return "";
  std::string result;
  for (const auto& word : words) {
    if (!result.empty()) result += ' ';
    result += word;
  }
  return result;
}

static std::vector<PathReading> paths(const SyllableGraph& graph) {
  std::map<size_t, std::vector<PathReading>> beam;
  beam[0].push_back(PathReading());
  for (const auto& [start, ends] : graph.edges) {
    auto current = beam.find(start);
    if (current == beam.end()) continue;
    auto source = current->second;
    std::sort(source.begin(), source.end(), [](const auto& a, const auto& b) { return a.cost < b.cost; });
    if (source.size() > 8) source.resize(8);
    for (const auto& [end, spellings] : ends) {
      if (end <= start) continue;
      for (const auto& [id, props] : spellings) {
        for (const auto& prefix : source) {
          auto next = prefix;
          next.stops.push_back(end);
          next.code.push_back(id);
          next.abbreviations += props.type == kAbbreviation;
          next.corrections += props.is_correction;
          next.cost += (props.type == kAbbreviation ? 4. : 0.)
                     + (props.is_correction ? 6. : 0.)
                     + std::max(0., -props.credibility) + 0.01;
          beam[end].push_back(std::move(next));
        }
      }
      auto& target = beam[end];
      if (target.size() > 24) {
        std::stable_sort(target.begin(), target.end(), [](const auto& a, const auto& b) { return a.cost < b.cost; });
        target.resize(24);
      }
    }
  }
  auto result = beam[graph.interpreted_length];
  std::stable_sort(result.begin(), result.end(), [](const auto& a, const auto& b) { return a.cost < b.cost; });
  if (result.size() > 3) result.resize(3);
  return result;
}

int main(int argc, char** argv) {
  if (argc != 3) return 64;
  const std::string shared = argv[1], scratch = argv[2];
  const std::string prebuilt = shared + "/build";
  RimeApi* api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = shared.c_str();
  traits.user_data_dir = scratch.c_str();
  traits.prebuilt_data_dir = prebuilt.c_str();
  traits.staging_dir = scratch.c_str();
  traits.app_name = "rime.typeforme.ablation";
  traits.min_log_level = 2;
  traits.log_dir = "";
  api->setup(&traits);
  api->initialize(&traits);
  auto table = New<Table>(rime::path(std::filesystem::path(prebuilt + "/typeforme_pinyin.table.bin")));
  auto prism = New<Prism>(rime::path(std::filesystem::path(prebuilt + "/typeforme_pinyin.prism.bin")));
  Dictionary dict("typeforme_pinyin", {}, {table}, prism);
  if (!dict.Load()) return 70;
  NearSearchCorrector corrector;

  std::string line;
  while (std::getline(std::cin, line)) {
    auto started = std::chrono::steady_clock::now();
    if (line.size() < 3 || line[1] != '\t') continue;
    const char mode = line[0];
    const std::string input = line.substr(2);
    if (input.empty() || input.size() > 96) continue;
    Syllabifier syllabifier(" '", false, false);
    if (mode == 'C') syllabifier.EnableCorrection(&corrector);
    SyllableGraph graph;
    syllabifier.BuildSyllableGraph(input, *prism, &graph);
    auto readings = paths(graph);
    std::ostringstream output;
    output << "{\"input\":" << quote(input) << ",\"interpreted\":" << graph.interpreted_length << ",\"paths\":[";
    bool first = true;
    for (const auto& path : readings) {
      if (!first) output << ',';
      first = false;
      output << "{\"reading\":" << quote(reading(dict, path.code))
             << ",\"abbreviations\":" << path.abbreviations
             << ",\"corrections\":" << path.corrections << ",\"stops\":[";
      for (size_t i = 0; i < path.stops.size(); ++i) {
        if (i) output << ',';
        output << path.stops[i];
      }
      output << "]}";
    }
    output << "],\"words\":[";
    if (mode != 'G') {
      first = true;
      size_t total = 0;
      for (const auto& [start, ends] : graph.edges) {
        auto words = dict.Lookup(graph, start);
        if (!words) continue;
        for (auto& [end, entries] : *words) {
          if (end <= start || end - start > 28) continue;
          int count = 0;
          while (!entries.exhausted() && count < 7 && total < 240) {
            auto entry = entries.Peek();
            if (!entry) break;
            if (entry->code.size() <= 5) {
              if (!first) output << ',';
              first = false;
              output << "{\"start\":" << start << ",\"end\":" << end
                     << ",\"text\":" << quote(entry->text)
                     << ",\"reading\":" << quote(reading(dict, entry->code))
                     << ",\"weight\":" << entry->weight << '}';
              ++count; ++total;
            }
            entries.Next();
          }
        }
      }
    }
    auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    output << "],\"elapsed_ms\":" << elapsed << ",\"engine_version\":" << quote(api->get_version()) << '}';
    std::cout << output.str() << std::endl;
  }
  // dict/table/prism handles are local to this diagnostic process.
  return 0;
}
