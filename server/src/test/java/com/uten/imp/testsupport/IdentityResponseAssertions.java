package com.uten.imp.testsupport;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.DeserializationFeature;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

/** Test-only leakage checks for HR summary and account-readiness responses. */
public final class IdentityResponseAssertions {
    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
    private static final Pattern ITEM_METADATA = Pattern.compile(
            "/(confirmToday|confirmUpcoming|confirmOverdue|birthdayToday|birthdayUpcoming|"
                    + "anniversaryToday|newHires|identityReview)/([0-9]+)/(employeeId|date|claimLeaseUntil)");
    private static final Pattern OFFSET_TIME = Pattern.compile(
            "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
                    + "(?:\\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})");

    private IdentityResponseAssertions() {}

    public static void assertNoIdentityDigits(String body, String... identities) {
        for (String identity : identities) {
            assertTrue(identity != null && identity.length() == 18,
                    "identity assertion requires an eighteen-character fixture");
        }
        assertNoFullIdentity(body, identities);
        JsonNode response;
        try {
            response = JSON.readTree(body);
        } catch (JsonProcessingException exception) {
            fail("identity assertion requires a valid JSON response");
            return;
        }
        assertTrue(response != null && response.isObject(), "identity assertion requires a JSON object");
        // Check decoded JSON too, so escapes cannot hide a full number or prefix.
        assertNoFullIdentity(response.toString(), identities);
        inspect(response, response, "", identities);
    }

    private static void assertNoFullIdentity(String value, String[] identities) {
        for (String identity : identities) {
            assertFalse(value.contains(identity) || value.contains(identity.substring(0, 17)),
                    "response must not carry a full identity or its seventeen-character prefix");
        }
    }

    private static void inspect(JsonNode root, JsonNode node, String path, String[] identities) {
        String metadata = "/generatedAt".equals(path) ? "date" : null;
        Matcher item = ITEM_METADATA.matcher(path);
        if (item.matches()) {
            JsonNode section = root.path(item.group(1));
            if (section.isArray()) {
                int index = Integer.parseInt(item.group(2));
                if (index < section.size() && section.get(index).isObject()) metadata = item.group(3);
            }
        }
        if (metadata != null) {
            boolean nullable = !"/generatedAt".equals(path) && !"employeeId".equals(metadata);
            assertTrue(validMetadata(node, metadata, nullable), "response metadata has an invalid type or value");
            return;
        }
        if (node.isObject()) {
            for (Map.Entry<String, JsonNode> field : node.properties()) {
                assertNoTail(field.getKey(), identities);
                String pointer = field.getKey().replace("~", "~0").replace("/", "~1");
                inspect(root, field.getValue(), path + "/" + pointer, identities);
            }
        } else if (node.isArray()) {
            for (int index = 0; index < node.size(); index++) {
                inspect(root, node.get(index), path + "/" + index, identities);
            }
        } else if (!node.isNull()) {
            assertNoTail(node.asText(), identities);
        }
    }

    private static boolean validMetadata(JsonNode node, String kind, boolean nullable) {
        if (node.isNull()) return nullable;
        if (!node.isTextual()) return false;
        String value = node.textValue();
        try {
            return switch (kind) {
                case "employeeId" -> UUID.fromString(value).toString().equals(value);
                case "date" -> LocalDate.parse(value).toString().equals(value);
                case "claimLeaseUntil" -> OFFSET_TIME.matcher(value).matches()
                        && OffsetDateTime.parse(value) != null;
                default -> false;
            };
        } catch (IllegalArgumentException | DateTimeParseException exception) {
            return false;
        }
    }

    private static void assertNoTail(String value, String[] identities) {
        for (String identity : identities) {
            assertFalse(value.contains(identity.substring(14)), "response must not carry identity digits");
        }
    }
}
