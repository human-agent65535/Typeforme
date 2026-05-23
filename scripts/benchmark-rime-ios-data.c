#include <rime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static long long monotonic_ns(void) {
  struct timespec ts = {0};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int env_int(const char* name, int fallback) {
  const char* raw = getenv(name);
  if (!raw || raw[0] == '\0') {
    return fallback;
  }
  char* end = NULL;
  long value = strtol(raw, &end, 10);
  if (!end || *end != '\0' || value <= 0) {
    return fallback;
  }
  return (int)value;
}

static void print_context(RimeApi* api, RimeSessionId session) {
  RIME_STRUCT(RimeContext, context);
  if (!api->get_context(session, &context)) {
    printf("  context: <unavailable>\n");
    return;
  }

  printf("  preedit: %s\n",
         context.composition.preedit ? context.composition.preedit : "");
  printf("  preview: %s\n",
         context.commit_text_preview ? context.commit_text_preview : "");
  printf("  page: size=%d no=%d last=%s total=%d\n",
         context.menu.page_size,
         context.menu.page_no,
         context.menu.is_last_page ? "true" : "false",
         context.menu.num_candidates);
  api->free_context(&context);
}

static void print_candidates(RimeApi* api, RimeSessionId session, int limit) {
  RimeCandidateListIterator iterator = {0};
  if (!api->candidate_list_begin(session, &iterator)) {
    printf("  candidates: <none>\n");
    return;
  }

  int count = 0;
  while (count < limit && api->candidate_list_next(&iterator)) {
    const char* text = iterator.candidate.text ? iterator.candidate.text : "";
    const char* comment = iterator.candidate.comment ? iterator.candidate.comment : "";
    if (comment[0] != '\0') {
      printf("  %2d. %s\t%s\n", count + 1, text, comment);
    } else {
      printf("  %2d. %s\n", count + 1, text);
    }
    ++count;
  }
  if (count == 0) {
    printf("  candidates: <none>\n");
  }
  api->candidate_list_end(&iterator);
}

static void process_input(RimeApi* api, RimeSessionId session, const char* input) {
  api->clear_composition(session);
  const unsigned char* cursor = (const unsigned char*)input;
  while (*cursor) {
    api->process_key(session, (int)*cursor, 0);
    ++cursor;
  }
}

static int capture_state(RimeApi* api, RimeSessionId session, int limit) {
  int captured = 0;
  RIME_STRUCT(RimeContext, context);
  if (api->get_context(session, &context)) {
    api->free_context(&context);
  }

  RimeCandidateListIterator iterator = {0};
  if (api->candidate_list_begin(session, &iterator)) {
    while (captured < limit && api->candidate_list_next(&iterator)) {
      ++captured;
    }
    api->candidate_list_end(&iterator);
  }
  return captured;
}

static int process_input_with_state(RimeApi* api, RimeSessionId session, const char* input, int candidate_limit) {
  int key_count = 0;
  api->clear_composition(session);
  const unsigned char* cursor = (const unsigned char*)input;
  while (*cursor) {
    api->process_key(session, (int)*cursor, 0);
    capture_state(api, session, candidate_limit);
    ++key_count;
    ++cursor;
  }
  return key_count;
}

int main(int argc, char** argv) {
  if (argc < 6) {
    fprintf(stderr, "usage: %s <shared> <user> <prebuilt> <staging> <schema> [inputs...]\n", argv[0]);
    return 64;
  }

  const char* shared_dir = argv[1];
  const char* user_dir = argv[2];
  const char* prebuilt_dir = argv[3];
  const char* staging_dir = argv[4];
  const char* schema_id = argv[5];

  RimeApi* api = rime_get_api();
  RimeTraits traits = {0};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = shared_dir;
  traits.user_data_dir = user_dir;
  traits.prebuilt_data_dir = prebuilt_dir;
  traits.staging_dir = staging_dir;
  traits.distribution_name = "Typeforme";
  traits.distribution_code_name = "typeforme";
  traits.distribution_version = "benchmark";
  traits.app_name = "rime.typeforme.benchmark";
  traits.min_log_level = 2;
  traits.log_dir = "";

  long long setup_start_ns = monotonic_ns();
  api->setup(&traits);
  api->initialize(&traits);
  long long setup_elapsed_ns = monotonic_ns() - setup_start_ns;

  long long session_start_ns = monotonic_ns();
  RimeSessionId session = api->create_session();
  long long session_elapsed_ns = monotonic_ns() - session_start_ns;
  if (!session) {
    fprintf(stderr, "error: failed to create Rime session\n");
    api->finalize();
    return 70;
  }
  long long select_start_ns = monotonic_ns();
  if (!api->select_schema(session, schema_id)) {
    fprintf(stderr, "error: failed to select schema: %s\n", schema_id);
    api->finalize();
    return 70;
  }
  long long select_elapsed_ns = monotonic_ns() - select_start_ns;
  api->set_option(session, "ascii_mode", False);
  api->set_option(session, "ascii_punct", False);

  const char* defaults[] = {
    "nihao",
    "nih",
    "shiyishi",
    "shangfang",
    "shangfan",
    "shangfand",
    "jianpan",
    "shurufa",
    "xian'sheng'hao",
  };
  int default_count = (int)(sizeof(defaults) / sizeof(defaults[0]));

  int input_count = argc > 6 ? argc - 6 : default_count;

  const char* perf = getenv("RIME_PERF");
  if (perf && strcmp(perf, "1") == 0) {
    int iterations = env_int("RIME_PERF_ITERATIONS", 200);
    int warmup = env_int("RIME_PERF_WARMUP", 20);
    int candidate_limit = env_int("RIME_PERF_CANDIDATE_LIMIT", 60);

    int keys_per_pass = 0;
    for (int i = 0; i < input_count; ++i) {
      const char* input = argc > 6 ? argv[i + 6] : defaults[i];
      keys_per_pass += process_input_with_state(api, session, input, candidate_limit);
    }
    for (int i = 1; i < warmup; ++i) {
      for (int j = 0; j < input_count; ++j) {
        const char* input = argc > 6 ? argv[j + 6] : defaults[j];
        process_input_with_state(api, session, input, candidate_limit);
      }
    }

    long long start_ns = monotonic_ns();
    int total_keys = 0;
    for (int i = 0; i < iterations; ++i) {
      for (int j = 0; j < input_count; ++j) {
        const char* input = argc > 6 ? argv[j + 6] : defaults[j];
        total_keys += process_input_with_state(api, session, input, candidate_limit);
      }
    }
    long long elapsed_ns = monotonic_ns() - start_ns;
    double total_ms = (double)elapsed_ns / 1000000.0;
    double pass_ms = total_ms / (double)iterations;
    double key_us = (double)elapsed_ns / (double)total_keys / 1000.0;

    printf(
      "schema=%s setup_ms=%.3f session_ms=%.3f select_ms=%.3f inputs=%d keys_per_pass=%d iterations=%d total_ms=%.3f pass_ms=%.3f key_us=%.3f candidate_limit=%d\n",
      schema_id,
      (double)setup_elapsed_ns / 1000000.0,
      (double)session_elapsed_ns / 1000000.0,
      (double)select_elapsed_ns / 1000000.0,
      input_count,
      keys_per_pass,
      iterations,
      total_ms,
      pass_ms,
      key_us,
      candidate_limit
    );
    api->finalize();
    return 0;
  }

  for (int i = 0; i < input_count; ++i) {
    const char* input = argc > 6 ? argv[i + 6] : defaults[i];
    process_input(api, session, input);
    printf("input: %s\n", input);
    print_context(api, session);
    print_candidates(api, session, 12);
    printf("\n");
  }

  api->finalize();
  return 0;
}
