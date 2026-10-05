package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.UserPreferenceReadPort;
import com.uten.imp.application.port.UserPreferenceWritePort;
import org.springframework.stereotype.Component;

/**
 * ADR-152 the current account's AI chat settings. Stored with the account (user_preferences, feature-owned
 * key), so they follow the person to every device; a new account gets {@link AiChatSettings#DEFAULTS}.
 * Writes accept only whitelisted fields and values; the generic preference endpoint cannot write this key.
 */
@Component
public class AiChatSettingsService {
    private final UserPreferenceReadPort preferences;
    private final UserPreferenceWritePort writer;
    private final ObjectMapper json;

    public AiChatSettingsService(UserPreferenceReadPort preferences, UserPreferenceWritePort writer, ObjectMapper json) {
        this.preferences = preferences;
        this.writer = writer;
        this.json = json;
    }

    /** Current settings; anything missing or invalid in the stored value falls back to its default. */
    public AiChatSettings current() {
        return preferences.currentUserPreference(AiChatSettings.PREFERENCE_KEY)
                .map(AiChatSettings::fromStored).orElse(AiChatSettings.DEFAULTS);
    }

    /** Applies a validated change (one or more fields) and stores the complete, normalized settings. */
    public AiChatSettings update(JsonNode change) {
        AiChatSettings next = current().merge(change);
        writer.putOwnedPreference(AiChatSettings.PREFERENCE_KEY, json.valueToTree(next.toJson()));
        return next;
    }
}
