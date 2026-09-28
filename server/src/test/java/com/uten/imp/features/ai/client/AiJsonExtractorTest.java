package com.uten.imp.features.ai.client;

import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class AiJsonExtractorTest {

    @Test
    void acceptsRawFencedAndEmbeddedObjects() {
        assertThat(AiJsonExtractor.extractObject("  {\"a\": 1}  ")).isEqualTo("{\"a\":1}");
        assertThat(AiJsonExtractor.extractObject("```json\n{\"a\": [1, 2]}\n```")).isEqualTo("{\"a\":[1,2]}");
        assertThat(AiJsonExtractor.extractObject("```\n{\"a\": true}\n```")).isEqualTo("{\"a\":true}");
        assertThat(AiJsonExtractor.extractObject("Sure! Here it is: {\"text\": \"has } brace and \\\" quote\"} done"))
                .isEqualTo("{\"text\":\"has } brace and \\\" quote\"}");
        assertThat(AiJsonExtractor.extractObject("prefix {\"outer\": {\"inner\": 1}} suffix {\"x\":2}"))
                .isEqualTo("{\"outer\":{\"inner\":1}}");
    }

    @Test
    void rejectsEmptyArraysAndGarbageAsInvalidResponse() {
        for (String content : new String[]{null, "", "   ", "[1,2]", "no json here", "{\"unterminated\": 1"}) {
            assertThatThrownBy(() -> AiJsonExtractor.extractObject(content))
                    .as(String.valueOf(content))
                    .isInstanceOf(AiCallException.class)
                    .extracting(error -> ((AiCallException) error).category())
                    .isEqualTo(AiErrorCategory.INVALID_RESPONSE);
        }
    }

    @Test
    void sanitizerStripsKeysTokensAndControlCharactersAndCapsLength() {
        String key = "sk-abcdefghijklmnopqrstuvwxyz0123";
        String sanitized = AiErrorMapper.sanitize("bad key " + key + "\u0000\n Bearer abcdefgh12345678 "
                + "token AbCdEfGhIjKlMnOpQrStUvWxYz01", key);

        assertThat(sanitized).doesNotContain(key).doesNotContain("abcdefgh12345678")
                .doesNotContain("AbCdEfGhIjKlMnOpQrStUvWxYz01").doesNotContain("\u0000").doesNotContain("\n");
        assertThat(AiErrorMapper.sanitize("x ".repeat(400), null).length()).isLessThanOrEqualTo(120);
        assertThat(AiErrorMapper.sanitize(null, key)).isEmpty();
    }

    @Test
    void providerMessageComesOnlyFromTheErrorMessageField() {
        assertThat(AiErrorMapper.providerMessage(
                "{\"error\":{\"message\":\"model not found\",\"param\":\"secret-internal\"}}".getBytes(), null))
                .isEqualTo("model not found");
        assertThat(AiErrorMapper.providerMessage("{\"message\":\"quota\"}".getBytes(), null)).isEqualTo("quota");
        assertThat(AiErrorMapper.providerMessage("<html>internal stack trace</html>".getBytes(), null)).isEmpty();
        assertThat(AiErrorMapper.fromStatus(307, new byte[0], null).category()).isEqualTo(AiErrorCategory.NETWORK);
    }
}
