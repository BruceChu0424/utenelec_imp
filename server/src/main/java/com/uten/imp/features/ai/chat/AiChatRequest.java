package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.util.UUID;

/**
 * One chat turn. {@code conversationId} ties the turn to the owner's conversation (ADR-152; absent = the
 * server starts a new conversation and returns its id in the result): the server
 * reads the earlier turns itself (owner-only, identity-checked, bounded by the account's memory setting),
 * the client never sends history. {@code locale} is the interface language (zh/en/ko) a reply follows when
 * the account's reply language is "follow interface". {@code pageContext} is present only while page
 * reading is on; its snapshot is the bounded, sanitized view of the top-most page (ADR-150) and is never
 * retained after the job ends.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record AiChatRequest(@NotBlank @Size(max = 2000) String message, UUID conversationId,
                            @Valid PageContext pageContext, @Pattern(regexp = "PAGE_HELP") String intentHint,
                            @Pattern(regexp = "zh|en|ko") String locale) {
    public AiChatRequest(String message, UUID conversationId, PageContext pageContext) {
        this(message, conversationId, pageContext, null, null);
    }

    public AiChatRequest(String message, UUID conversationId, PageContext pageContext, String intentHint) {
        this(message, conversationId, pageContext, intentHint, null);
    }

    /** The same turn in the given conversation. */
    AiChatRequest withConversation(UUID id) {
        return new AiChatRequest(message, id, pageContext, intentHint, locale);
    }

    /** The same turn without anything read from the page (page reading switched off). */
    AiChatRequest withoutPage() {
        return new AiChatRequest(message, conversationId, null, null, locale);
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    public record PageContext(@NotBlank @Size(max = 200) String route, @Size(max = 80) String fieldKey,
                              AiChatPageSnapshot snapshot) {
        public PageContext(String route, String fieldKey) { this(route, fieldKey, null); }
    }
}
