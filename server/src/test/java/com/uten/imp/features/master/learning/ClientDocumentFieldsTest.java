package com.uten.imp.features.master.learning;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ClientDocumentFieldsTest {

    @Test
    void normalizesWhitespaceDropsBlanksAndKeepsDeclaredOrder() {
        Map<String, String> raw = new LinkedHashMap<>();
        raw.put("website", "www.sunas.com.ng");
        raw.put("email", " Sunas.Inv40@Gmail.com ");
        raw.put("address", "  Plot 5,\n  Alaba   Market ");
        raw.put("linkman", "   ");
        raw.put("nameEn", "SUNAS ELECTRICAL RESOURCE LTD.");

        Map<String, String> out = ClientDocumentFields.normalizeAndValidate(raw);

        assertThat(out).containsExactly(
                Map.entry("nameEn", "SUNAS ELECTRICAL RESOURCE LTD."),
                Map.entry("email", "Sunas.Inv40@Gmail.com"),
                Map.entry("address", "Plot 5, Alaba Market"),
                Map.entry("website", "www.sunas.com.ng"));
    }

    @Test
    void rejectsUnknownKeysBadEmailBadPhoneBadWebsiteAndOverlongValuesWithoutEchoingTheValue() {
        assertInvalid(Map.of("bankAccount", "6222 0000 1111"));
        assertInvalid(Map.of("email", "not-an-email"));
        assertInvalid(Map.of("email", "a@b"));
        assertInvalid(Map.of("phone", "call me"));
        assertInvalid(Map.of("mobile", "12"));
        assertInvalid(Map.of("website", "http://exa mple"));
        assertInvalid(Map.of("taxId", "9".repeat(65)));
        ApiException failure = catchInvalid(Map.of("email", "secret-value-not-an-email"));
        assertThat(failure.getMessage()).doesNotContain("secret-value");
    }

    @Test
    void acceptsCommonPhoneAndWebsiteShapes() {
        Map<String, String> raw = new HashMap<>();
        raw.put("phone", "+962 (2) 739-5151 ext. 12");
        raw.put("mobile", "+234 803 123 4567");
        raw.put("website", "https://www.example.com/contact");
        raw.put("taxId", "300002203");
        assertThat(ClientDocumentFields.normalizeAndValidate(raw)).hasSize(4);
    }

    @Test
    void labelsListFieldNamesOnly() {
        assertThat(ClientDocumentFields.labels(List.of("email", "address", "unknown"))).isEqualTo("邮箱, 地址");
    }

    @Test
    void cleanRemovesZeroWidthAndControlCharacters() {
        assertThat(ClientDocumentFields.clean("\u200BACME\tTRADING\u0007 ")).isEqualTo("ACME TRADING");
        assertThat(ClientDocumentFields.clean("\u3000")).isNull();
    }

    private static void assertInvalid(Map<String, String> raw) {
        catchInvalid(raw);
    }

    private static ApiException catchInvalid(Map<String, String> raw) {
        Throwable thrown = org.assertj.core.api.Assertions.catchThrowable(
                () -> ClientDocumentFields.normalizeAndValidate(raw));
        assertThat(thrown).isInstanceOf(ApiException.class);
        ApiException failure = (ApiException) thrown;
        assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        return failure;
    }

    @Test
    void nullOrEmptyInputIsNothingToApply() {
        assertThat(ClientDocumentFields.normalizeAndValidate(null)).isEmpty();
        assertThat(ClientDocumentFields.normalizeAndValidate(Map.of())).isEmpty();
        assertThatThrownBy(() -> ClientDocumentFields.normalizeAndValidate(Map.of("nameEn", "x".repeat(256))))
                .isInstanceOf(ApiException.class);
    }
}
