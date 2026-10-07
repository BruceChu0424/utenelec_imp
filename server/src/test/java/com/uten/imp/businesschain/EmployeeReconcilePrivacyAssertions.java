package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** PII assertions follow the reconcile DTO paths; unrelated UUID digits are not identity evidence. */
final class EmployeeReconcilePrivacyAssertions {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final Pattern ITEM = Pattern.compile("/rows/\\d+/items/\\d+");
    private static final Pattern VALUE = Pattern.compile("(/rows/\\d+/items/\\d+)/(oldValue|newValue|candidates/\\d+/value)");
    private static final Pattern UUID_VALUE = Pattern.compile("(?i)[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}");
    private static final Pattern UUID_PATH = Pattern.compile("/(?:id|planId)|/rows/\\d+/employee/id");
    private static final Pattern TIME_PATH = Pattern.compile("/(?:createdAt|expiresAt)|/rows/\\d+/claim/leaseUntil");
    private static final Pattern DATE_PATH = Pattern.compile("/rows/\\d+/employee/hireDate");
    private static final Pattern PROBABILITY_PATH = Pattern.compile("/rows/\\d+/items/\\d+/(?:probability|candidates/\\d+/probability)");

    private EmployeeReconcilePrivacyAssertions() { }

    static void assertNoIdentityDigits(String responseBody, String... identities) {
        JsonNode root;
        try {
            root = JSON.readTree(responseBody);
        } catch (Exception invalidJson) {
            throw new AssertionError("reconcile privacy assertion requires valid JSON", invalidJson);
        }
        assertTrue(root != null, "reconcile privacy assertion requires a JSON document");
        inspect(root, root, "", identities);
    }

    private static void inspect(JsonNode root, JsonNode node, String path, String[] identities) {
        if (node.isObject()) {
            if (ITEM.matcher(path).matches() && "idNumber".equals(node.path("field").asText())
                    && !root.path("capabilities").path("viewPii").asBoolean()) {
                for (String hidden : new String[]{"candidates", "diffPositions", "suspectPositions"}) {
                    assertTrue(node.path(hidden).isArray() && node.path(hidden).isEmpty(),
                            "PII-hidden response must not expose " + path + "/" + hidden);
                }
            }
            node.properties().forEach(entry -> inspect(root, entry.getValue(), path + "/" + entry.getKey(), identities));
            return;
        }
        if (node.isArray()) {
            for (int index = 0; index < node.size(); index++) inspect(root, node.get(index), path + "/" + index, identities);
            return;
        }
        if (node.isNull() || node.isBoolean()) return;
        var value = VALUE.matcher(path);
        if (value.matches() && "idNumber".equals(root.at(value.group(1)).path("field").asText())) {
            if (root.path("capabilities").path("viewPii").asBoolean()) return;
            assertTrue(!value.group(2).startsWith("candidates/") && node.isTextual()
                            && node.textValue().matches("\\*{4}.{4}"),
                    "PII-hidden identity must contain only its masked last four characters at " + path);
            return;
        }
        if (metadata(node, path)) return;
        String text = node.asText();
        for (String identity : identities) {
            String compact = identity.replace(" ", "");
            assertTrue(!text.contains(compact) && !text.contains(identity),
                    "identity plaintext outside authorized value fields at " + path);
            if (compact.length() >= 18) {
                assertTrue(!text.contains(compact.substring(0, 17)), "identity prefix leaked at " + path);
            }
            assertTrue(!text.contains(compact.substring(compact.length() - 4)), "identity suffix leaked at " + path);
        }
    }

    private static boolean metadata(JsonNode node, String path) {
        if (node.isTextual()) {
            if (UUID_PATH.matcher(path).matches()) return UUID_VALUE.matcher(node.textValue()).matches();
            try {
                if (TIME_PATH.matcher(path).matches()) {
                    OffsetDateTime.parse(node.textValue());
                    return true;
                }
                if (DATE_PATH.matcher(path).matches()) {
                    LocalDate.parse(node.textValue());
                    return true;
                }
            } catch (DateTimeParseException invalidMetadata) {
                return false;
            }
        }
        return PROBABILITY_PATH.matcher(path).matches() && node.isNumber()
                && node.decimalValue().signum() >= 0 && node.decimalValue().compareTo(java.math.BigDecimal.ONE) <= 0;
    }
}
