package com.uten.imp.responsibility.dto;

/** One stable, user-readable group in the handover preview. */
public record DataHandoverPreviewItem(
        String key,
        String label,
        String scope,
        long count,
        DataHandoverAction action
) {
}
