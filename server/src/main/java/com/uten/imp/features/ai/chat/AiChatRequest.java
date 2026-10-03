package com.uten.imp.features.ai.chat;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.util.UUID;

public record AiChatRequest(@NotBlank @Size(max = 2000) String message, UUID previousJobId,
                            UUID attachmentJobId, @Valid PageContext pageContext) {
    public record PageContext(@NotBlank @Size(max = 200) String route, @Size(max = 80) String fieldKey) {}
}
