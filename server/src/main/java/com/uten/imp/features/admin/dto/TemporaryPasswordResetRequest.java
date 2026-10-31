package com.uten.imp.features.admin.dto;

import com.fasterxml.jackson.annotation.JsonAnySetter;
import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import com.uten.imp.security.PasswordPolicy;
import jakarta.validation.constraints.AssertTrue;

/** Missing/null selects the existing generator; a supplied value is preserved verbatim. */
public record TemporaryPasswordResetRequest(
        @JsonProperty(access = JsonProperty.Access.WRITE_ONLY)
        @JsonDeserialize(using = ExactPasswordString.class) String temporaryPassword) {
    /** Credential input must never be coerced from a number, boolean, list or object. */
    public static final class ExactPasswordString extends com.fasterxml.jackson.databind.JsonDeserializer<String> {
        @Override
        public String deserialize(com.fasterxml.jackson.core.JsonParser parser,
                com.fasterxml.jackson.databind.DeserializationContext context) throws java.io.IOException {
            if (!parser.hasToken(com.fasterxml.jackson.core.JsonToken.VALUE_STRING)) {
                throw com.fasterxml.jackson.databind.JsonMappingException.from(parser, "临时密码必须为字符串或 null");
            }
            return parser.getText();
        }
    }

    @JsonIgnore
    @AssertTrue(message = "密码不能为空")
    public boolean isTemporaryPasswordValid() {
        return temporaryPassword == null || PasswordPolicy.hasContent(temporaryPassword);
    }

    @JsonAnySetter
    public void rejectUnknown(String ignoredKey, JsonNode ignoredValue) {
        // Neither unknown values nor keys belong in credential diagnostics.
        throw new IllegalArgumentException("临时密码请求包含不支持的字段");
    }

    @Override public String toString() { return "TemporaryPasswordResetRequest[credentials=REDACTED]"; }
}
