package com.uten.imp.features.suggestion.dto;

import java.time.Instant;

/** 建议回复出参。 */
public record SuggestionReplyDto(
        String id,
        String replier,
        String replierRole,
        String content,
        Instant repliedAt) {
}
