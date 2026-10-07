package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.TextNode;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class EmployeeReconcilePrivacyAssertionsTest {
    private static final String IDENTITY = "442000199003074271";
    private static final String COLLIDING_UUID = "457e4d0a-4ca8-47f0-8906-17c944271105";
    private static final ObjectMapper JSON = new ObjectMapper();

    @Test
    void deterministic4271CollisionInEmployeeUuidIsMetadataNotPii() throws Exception {
        JsonNode plan = plan(true);
        assertDoesNotThrow(() -> check(plan));
    }

    @Test
    void fullPrefixAndSuffixLeaksFailAtEveryHumanReadablePath() throws Exception {
        for (String path : List.of("/readOnlyReason", "/summary", "/rows/0/reason",
                "/rows/0/notices/0/message", "/rows/0/result/message", "/rows/0/items/0/notes/0",
                "/rows/0/items/0/outcome/message", "/rows/0/items/0/basis/label",
                "/rows/0/items/0/permissionLabel")) {
            for (String leaked : List.of(IDENTITY, IDENTITY.substring(0, 17), "4271")) {
                JsonNode plan = plan(true);
                set(plan, path, "请核对 " + leaked);
                AssertionError failure = assertThrows(AssertionError.class, () -> check(plan));
                assertTrue(failure.getMessage().contains(path), "failure identifies the leaking field path");
            }
        }
    }

    @Test
    void uuidOrDateInsideHumanTextDoesNotReceiveMetadataExemption() throws Exception {
        for (String text : List.of(COLLIDING_UUID, "4271-01-01T00:00:00Z")) {
            JsonNode plan = plan(true);
            set(plan, "/rows/0/reason", text);
            assertThrows(AssertionError.class, () -> check(plan));
        }
    }

    @Test
    void unrelatedValueFieldsAndMalformedMetadataDoNotHideDigits() throws Exception {
        for (String path : List.of("/value", "/rows/0/employee/id")) {
            JsonNode plan = plan(true);
            set(plan, path, IDENTITY);
            assertThrows(AssertionError.class, () -> check(plan));
        }
    }

    @Test
    void noPiiPermissionAllowsOnlyMaskedIdentityAndNoCandidates() throws Exception {
        JsonNode plan = plan(false);
        set(plan, "/rows/0/items/0/oldValue", "****4271");
        set(plan, "/rows/0/items/0/newValue", "****4271");
        assertDoesNotThrow(() -> check(plan));
        set(plan, "/rows/0/items/0/oldValue", IDENTITY);
        assertThrows(AssertionError.class, () -> check(plan));
        set(plan, "/rows/0/items/0/oldValue", "****4271");
        ((ArrayNode) plan.at("/rows/0/items/0/candidates")).addObject().put("value", IDENTITY);
        assertThrows(AssertionError.class, () -> check(plan));
    }

    private static JsonNode plan(boolean viewPii) throws Exception {
        return JSON.readTree("""
                {"id":"%s","capabilities":{"viewPii":%s},"createdAt":"2026-10-07T00:00:00.4271Z",
                 "rows":[{"employee":{"id":"%s","hireDate":"2026-01-01"},"notices":[{"message":"请核对"}],
                 "result":{"message":"待处理"},"items":[{"field":"idNumber","oldValue":"%s","newValue":"%s",
                 "probability":0.4271,"candidates":[],"diffPositions":[],"suspectPositions":[],
                 "notes":["请核对"],"outcome":{"message":"待处理"},"basis":{"label":"修复建议"}}]}]}
                """.formatted(COLLIDING_UUID, viewPii, COLLIDING_UUID, IDENTITY, IDENTITY));
    }

    private static void check(JsonNode plan) {
        EmployeeReconcilePrivacyAssertions.assertNoIdentityDigits(plan.toString(), IDENTITY);
    }

    private static void set(JsonNode root, String path, String value) {
        int separator = path.lastIndexOf('/');
        JsonNode parent = root.at(path.substring(0, separator));
        String key = path.substring(separator + 1);
        if (parent instanceof ObjectNode object) object.put(key, value);
        else ((ArrayNode) parent).set(Integer.parseInt(key), TextNode.valueOf(value));
    }
}
