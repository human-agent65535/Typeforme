#include <rime_api.h>
#include <stdio.h>

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

  api->setup(&traits);
  api->initialize(&traits);

  RimeSessionId session = api->create_session();
  if (!session) {
    fprintf(stderr, "error: failed to create Rime session\n");
    api->finalize();
    return 70;
  }
  if (!api->select_schema(session, schema_id)) {
    fprintf(stderr, "error: failed to select schema: %s\n", schema_id);
    api->finalize();
    return 70;
  }
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
