package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.AiCompletionPort.AiReasoningEffort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * ADR-152 per-account AI chat settings, stored server-side in {@code user_preferences} under
 * {@link #PREFERENCE_KEY} so they follow the account across devices. Every value is an enumerated
 * choice validated here; none of them widens what is read, sent or allowed: page reading can only be
 * switched off, the memory length is capped, and sensitive fields stay withheld whatever is chosen.
 */
public record AiChatSettings(Detail detail, Reasoning reasoning, boolean pageAware, boolean showSources,
                             int memoryTurns, Language replyLanguage, SendKey sendKey, Style explanationStyle,
                             boolean showSuggestions) {
    public static final String PREFERENCE_KEY = "ai.chat.settings";
    /** Allowed numbers of earlier turns the model sees (0 = no conversation memory). */
    public static final List<Integer> MEMORY_CHOICES = List.of(0, 3, 6, 10);

    /** How much an answer unfolds by default; the user's own words in one question override it for that turn. */
    public enum Detail { COMPREHENSIVE, STANDARD, CONCISE }

    /** How deeply the model thinks; mapped to the provider-neutral reasoning effort. */
    public enum Reasoning { FAST, STANDARD, DEEP }

    /** Reply language; AUTO follows the interface language sent with each question. */
    public enum Language { AUTO, ZH, EN, KO }

    /** Composer key that sends: Enter (Shift+Enter = new line) or Ctrl/Cmd+Enter. */
    public enum SendKey { ENTER, CTRL_ENTER }

    /** Wording: plain words that explain terms (new staff) or concise business terminology (experienced staff). */
    public enum Style { PLAIN, PROFESSIONAL }

    /**
     * Defaults of an account that never changed a setting. Thinking depth defaults to FAST (ADR-153 revision): everyday
     * rule and page questions are answered in seconds; a question that asks for a careful analysis thinks deeper for
     * that answer (see AiChatJobHandler.effort), and an account may choose a deeper default.
     */
    public static final AiChatSettings DEFAULTS = new AiChatSettings(Detail.STANDARD, Reasoning.FAST, true, true, 6,
            Language.AUTO, SendKey.ENTER, Style.PLAIN, true);

    private static final Set<String> FIELDS = Set.of("detail", "reasoning", "pageAware", "showSources", "memoryTurns",
            "replyLanguage", "sendKey", "explanationStyle", "showSuggestions");

    public AiChatSettings {
        if (detail == null || reasoning == null || replyLanguage == null || sendKey == null || explanationStyle == null
                || !MEMORY_CHOICES.contains(memoryTurns)) {
            throw new IllegalArgumentException("Incomplete AI chat settings");
        }
    }

    /** Provider-neutral thinking depth: fast = no extended thinking, standard = moderate, deep = high. */
    public AiReasoningEffort effort() {
        return switch (reasoning) {
            case FAST -> AiReasoningEffort.OFF;
            case STANDARD -> AiReasoningEffort.MEDIUM;
            case DEEP -> AiReasoningEffort.HIGH;
        };
    }

    /**
     * Stored value: every field independently falls back to its default when it is absent or not one of
     * the allowed values (a hand-edited or outdated row never breaks the assistant or widens anything).
     */
    public static AiChatSettings fromStored(JsonNode node) {
        if (node == null || !node.isObject()) return DEFAULTS;
        return new AiChatSettings(
                choice(node.get("detail"), Detail.class, DEFAULTS.detail),
                choice(node.get("reasoning"), Reasoning.class, DEFAULTS.reasoning),
                flag(node.get("pageAware"), DEFAULTS.pageAware),
                flag(node.get("showSources"), DEFAULTS.showSources),
                node.get("memoryTurns") != null && node.get("memoryTurns").isInt()
                        && MEMORY_CHOICES.contains(node.get("memoryTurns").intValue())
                        ? node.get("memoryTurns").intValue() : DEFAULTS.memoryTurns,
                choice(node.get("replyLanguage"), Language.class, DEFAULTS.replyLanguage),
                choice(node.get("sendKey"), SendKey.class, DEFAULTS.sendKey),
                choice(node.get("explanationStyle"), Style.class, DEFAULTS.explanationStyle),
                flag(node.get("showSuggestions"), DEFAULTS.showSuggestions));
    }

    /**
     * Client change: a non-empty object holding only known fields, each with an allowed value of the
     * right type, applied over these settings. Anything else is rejected as a whole (422).
     */
    public AiChatSettings merge(JsonNode patch) {
        if (patch == null || !patch.isObject() || patch.isEmpty() || patch.size() > FIELDS.size()) throw invalid();
        Iterator<String> names = patch.fieldNames();
        while (names.hasNext()) if (!FIELDS.contains(names.next())) throw invalid();
        return new AiChatSettings(
                strictChoice(patch, "detail", Detail.class, detail),
                strictChoice(patch, "reasoning", Reasoning.class, reasoning),
                strictFlag(patch, "pageAware", pageAware),
                strictFlag(patch, "showSources", showSources),
                strictMemory(patch, memoryTurns),
                strictChoice(patch, "replyLanguage", Language.class, replyLanguage),
                strictChoice(patch, "sendKey", SendKey.class, sendKey),
                strictChoice(patch, "explanationStyle", Style.class, explanationStyle),
                strictFlag(patch, "showSuggestions", showSuggestions));
    }

    public Map<String, Object> toJson() {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("detail", detail.name());
        value.put("reasoning", reasoning.name());
        value.put("pageAware", pageAware);
        value.put("showSources", showSources);
        value.put("memoryTurns", memoryTurns);
        value.put("replyLanguage", replyLanguage.name());
        value.put("sendKey", sendKey.name());
        value.put("explanationStyle", explanationStyle.name());
        value.put("showSuggestions", showSuggestions);
        return value;
    }

    private static <E extends Enum<E>> E choice(JsonNode raw, Class<E> type, E fallback) {
        if (raw == null || !raw.isTextual()) return fallback;
        try { return Enum.valueOf(type, raw.asText()); }
        catch (IllegalArgumentException unknown) { return fallback; }
    }

    private static boolean flag(JsonNode raw, boolean fallback) {
        return raw != null && raw.isBoolean() ? raw.booleanValue() : fallback;
    }

    private static <E extends Enum<E>> E strictChoice(JsonNode patch, String field, Class<E> type, E current) {
        JsonNode raw = patch.get(field);
        if (raw == null) return current;
        if (!raw.isTextual() || !raw.asText().equals(raw.asText().toUpperCase(Locale.ROOT))) throw invalid();
        try { return Enum.valueOf(type, raw.asText()); }
        catch (IllegalArgumentException unknown) { throw invalid(); }
    }

    private static boolean strictFlag(JsonNode patch, String field, boolean current) {
        JsonNode raw = patch.get(field);
        if (raw == null) return current;
        if (!raw.isBoolean()) throw invalid();
        return raw.booleanValue();
    }

    private static int strictMemory(JsonNode patch, int current) {
        JsonNode raw = patch.get("memoryTurns");
        if (raw == null) return current;
        if (!raw.isInt() || !MEMORY_CHOICES.contains(raw.intValue())) throw invalid();
        return raw.intValue();
    }

    private static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "设置值不对，请重新选择。");
    }
}
