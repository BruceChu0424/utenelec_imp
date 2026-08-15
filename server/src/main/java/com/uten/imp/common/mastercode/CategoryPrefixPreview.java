package com.uten.imp.common.mastercode;

import java.util.List;
import java.util.UUID;

/** Read-only impact preview shown before a category prefix is changed. */
public record CategoryPrefixPreview(
        UUID categoryId,
        String currentPrefix,
        String requestedPrefix,
        String resultingEffectivePrefix,
        long affectedRecords,
        long customOrLegacyRecords,
        long descendantOverrides,
        long conflicts,
        List<String> conflictSamples) {

    public CategoryPrefixPreview {
        conflictSamples = conflictSamples == null ? List.of() : List.copyOf(conflictSamples);
    }
}
