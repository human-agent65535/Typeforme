#!/usr/bin/env bash

typeforme_is_system_dep() {
    local dep="$1"
    [[ "$dep" == /usr/lib/* || "$dep" == /System/Library/* ]]
}

typeforme_is_relative_dep() {
    local dep="$1"
    [[ "$dep" == @rpath/* || "$dep" == @loader_path/* || "$dep" == @executable_path/* ]]
}

typeforme_strip_rpaths_to_loader_path() {
    local file="$1"
    while read -r rp; do
        [ -z "$rp" ] && continue
        install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || true
    done < <(otool -l "$file" 2>/dev/null | awk '/LC_RPATH/{getline; getline; print $2}')
    install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
}

typeforme_normalize_install_names() {
    local file="$1"
    local dir="$2"
    local base
    base="$(basename "$file")"
    if [[ "$file" == *.dylib ]]; then
        install_name_tool -id "@rpath/$base" "$file" 2>/dev/null || true
    fi

    while read -r dep; do
        [ -n "$dep" ] || continue
        typeforme_is_system_dep "$dep" && continue
        local dep_base
        dep_base="$(basename "$dep")"
        [ -f "$dir/$dep_base" ] || continue
        install_name_tool -change "$dep" "@rpath/$dep_base" "$file" 2>/dev/null || true
    done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
}

typeforme_copy_non_system_deps() {
    local dir="$1"
    local main_binary="$2"
    local queue=("$dir/$main_binary")
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] && queue+=("$dy")
    done

    local i=0
    while [ "$i" -lt "${#queue[@]}" ]; do
        local file="${queue[$i]}"
        i=$((i + 1))
        while read -r dep; do
            [ -n "$dep" ] || continue
            typeforme_is_relative_dep "$dep" && continue
            typeforme_is_system_dep "$dep" && continue
            if [ ! -f "$dep" ]; then
                echo "warn: non-system dylib not found: $dep (needed by $(basename "$file"))" >&2
                continue
            fi
            local base
            base="$(basename "$dep")"
            if [ ! -f "$dir/$base" ]; then
                cp "$dep" "$dir/$base"
                queue+=("$dir/$base")
            fi
        done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done
}

typeforme_bundle_non_system_deps() {
    local dir="$1"
    local main_binary="$2"

    typeforme_copy_non_system_deps "$dir" "$main_binary"

    typeforme_strip_rpaths_to_loader_path "$dir/$main_binary"
    typeforme_normalize_install_names "$dir/$main_binary" "$dir"
    for dy in "$dir"/*.dylib; do
        [ -e "$dy" ] || continue
        typeforme_strip_rpaths_to_loader_path "$dy"
        typeforme_normalize_install_names "$dy" "$dir"
    done
}
