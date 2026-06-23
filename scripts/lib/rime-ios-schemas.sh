#!/usr/bin/env bash

typeforme_rime_generated_schema_variants() {
    cat <<'EOF'
typeforme_pinyin	typeforme_pinyin_no_correction	Typeforme Pinyin No Correction	false	true
typeforme_pinyin	typeforme_pinyin_no_learning	Typeforme Pinyin No Learning	true	false
typeforme_pinyin	typeforme_pinyin_no_correction_no_learning	Typeforme Pinyin No Correction No Learning	false	false
typeforme_pinyin_ext	typeforme_pinyin_ext_no_correction	Typeforme Pinyin Extended No Correction	false	true
typeforme_pinyin_ext	typeforme_pinyin_ext_no_learning	Typeforme Pinyin Extended No Learning	true	false
typeforme_pinyin_ext	typeforme_pinyin_ext_no_correction_no_learning	Typeforme Pinyin Extended No Correction No Learning	false	false
typeforme_pinyin_large	typeforme_pinyin_large_no_correction	Typeforme Pinyin Large No Correction	false	true
typeforme_pinyin_large	typeforme_pinyin_large_no_learning	Typeforme Pinyin Large No Learning	true	false
typeforme_pinyin_large	typeforme_pinyin_large_no_correction_no_learning	Typeforme Pinyin Large No Correction No Learning	false	false
EOF
}

typeforme_rime_required_schemas() {
    while IFS=$'\t' read -r source_schema target_schema _display_name _correction_enabled _learning_enabled; do
        printf '%s\n%s\n' "$source_schema" "$target_schema"
    done < <(typeforme_rime_generated_schema_variants) | awk '!seen[$0]++'
}
