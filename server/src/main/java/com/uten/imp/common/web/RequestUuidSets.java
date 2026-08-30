package com.uten.imp.common.web;

import com.uten.imp.common.validation.RequestLimits;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.UUID;

/** Bounded request-parameter parsing for comma-separated UUID sets. */
public final class RequestUuidSets {

    private RequestUuidSets() {
    }

    public static Set<UUID> commaSeparated(String raw, String fieldLabel) {
        if (raw == null || raw.isBlank()) return Set.of();
        String[] tokens = raw.split(",", -1);
        if (tokens.length > RequestLimits.DOCUMENT_LINES) {
            throw validation(fieldLabel + "数量超过上限");
        }
        Set<UUID> result = new LinkedHashSet<>();
        for (String token : tokens) {
            String value = token.trim();
            if (value.isEmpty()) continue;
            try {
                result.add(UUID.fromString(value));
            } catch (IllegalArgumentException ex) {
                throw validation(fieldLabel + "包含非法 UUID");
            }
        }
        return Set.copyOf(result);
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }
}
