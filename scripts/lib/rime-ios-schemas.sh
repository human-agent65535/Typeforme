#!/usr/bin/env bash

typeforme_rime_no_correction_schema_variants() {
    cat <<'EOF'
typeforme_pinyin	typeforme_pinyin_no_correction	Typeforme Pinyin No Correction
typeforme_pinyin_ext	typeforme_pinyin_ext_no_correction	Typeforme Pinyin Extended No Correction
typeforme_pinyin_large	typeforme_pinyin_large_no_correction	Typeforme Pinyin Large No Correction
EOF
}

typeforme_rime_required_schemas() {
    while IFS=$'\t' read -r source_schema target_schema _display_name; do
        printf '%s\n%s\n' "$source_schema" "$target_schema"
    done < <(typeforme_rime_no_correction_schema_variants)
}
