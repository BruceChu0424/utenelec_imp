package com.uten.imp.features.ai.usage;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler;
import java.util.Map;
import java.util.regex.Pattern;

/** An audit projection of the user's own question; never capture a document, system prompt or reply. */
public record AiQuestionPreview(String question, String state) {
    private static final Pattern LABELLED = Pattern.compile("(?i)[\"']?(api[ _-]?key|authorization|password|passwd|secret|access[ _-]?token|token|密码|密钥|口令)[\"']?\\s*(?:[:=：]|是|为|\\bis\\b)\\s*(?:\"[^\"]*\"|'[^']*'|“[^”]*”|[^\\s,，;；]+)");
    private static final Pattern CREDENTIAL = Pattern.compile("(?i)\\bBearer\\s+[A-Za-z0-9._~+/-]+=*|\\bsk-[A-Za-z0-9_-]+|\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+|[A-Za-z0-9_+/=-]{32,}");

    public static AiQuestionPreview capture(String kind, Map<String,String> params, AiJobHandler.AiJobInput input, ObjectMapper json) {
        String text = params.get("message");
        if ("ERP_CHAT".equals(kind) && "JSON".equals(input.kind())) {
            try {
                var message = json.readTree(input.bytes()).path("request").path("message");
                if (!message.isTextual()) return new AiQuestionPreview(null, "UNAVAILABLE");
                text = message.textValue();
            } catch (java.io.IOException malformed) { return new AiQuestionPreview(null, "UNAVAILABLE"); }
        }
        if (text == null || text.isBlank()) return new AiQuestionPreview(null, "NOT_APPLICABLE");
        // Redact before shortening so a credential at the boundary cannot survive as a partial key.
        String safe = LABELLED.matcher(text).replaceAll("$1=[已隐藏]");
        safe = CREDENTIAL.matcher(safe).replaceAll("[已隐藏]");
        boolean redacted = !safe.equals(text);
        safe = safe.replaceAll("[\\p{Cc}\\p{Cf}]+", " ").strip();
        if (safe.length() > 2000) {
            int end = Character.isHighSurrogate(safe.charAt(1999)) ? 1999 : 2000;
            safe = safe.substring(0, end);
        }
        return new AiQuestionPreview(safe, redacted ? "REDACTED" : "CAPTURED");
    }
}
