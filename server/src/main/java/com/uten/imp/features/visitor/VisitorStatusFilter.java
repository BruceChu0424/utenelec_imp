package com.uten.imp.features.visitor;

import java.util.Arrays;
import java.util.List;

/** Shared status sets for paged visitor lists and their full-scope facets. */
final class VisitorStatusFilter {
    private VisitorStatusFilter() {}

    static List<String> parse(String raw, List<String> defaults) {
        if (raw == null || raw.isBlank()) return defaults;
        return Arrays.stream(raw.split(","))
                .map(String::trim)
                .filter(value -> !value.isEmpty())
                .distinct()
                .toList();
    }
}
