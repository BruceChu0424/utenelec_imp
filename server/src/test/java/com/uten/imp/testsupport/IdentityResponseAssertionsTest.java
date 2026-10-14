package com.uten.imp.testsupport;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;

import java.util.List;

import static com.uten.imp.testsupport.IdentityResponseAssertions.assertNoIdentityDigits;
import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class IdentityResponseAssertionsTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    // Deliberately synthetic numbers; the suffix reproduces the CI timestamp collision.
    private static final String IDENTITY = "123456789012347407";
    private static final String YEAR_IDENTITY = "123456789012342026";
    private static final String LEASE = "2026-10-15T06:20:59.797407Z";
    private static final String UUID_WITH_TAIL = "00000000-0000-4000-8000-000000007407";
    private static final List<String> SECTIONS = List.of("confirmToday", "confirmUpcoming", "confirmOverdue",
            "birthdayToday", "birthdayUpcoming", "anniversaryToday", "newHires", "identityReview");

    @Test
    void validTypedSummaryMetadataCanCoincidentallyContainTheTail() {
        assertTrue(LEASE.contains(IDENTITY.substring(14)), "fixture must reproduce the old false positive");
        ObjectNode response = JSON.createObjectNode().put("generatedAt", "2026-10-14");
        for (String section : SECTIONS) {
            response.putArray(section).addObject()
                    .put("employeeId", UUID_WITH_TAIL).put("date", "2026-10-13")
                    .put("claimLeaseUntil", LEASE).put("name", "合法姓名").put("note", "需要核对");
        }
        assertDoesNotThrow(() -> assertNoIdentityDigits(response.toString(), IDENTITY, YEAR_IDENTITY));
    }

    @Test
    void timestampsAndUuidsInHumanOrUnknownFieldsStillFail() {
        for (String field : List.of("note", "name", "reason", "claimedByName", "unknown", "idNumber")) {
            ObjectNode response = JSON.createObjectNode();
            response.putArray("identityReview").addObject().put(field, LEASE);
            assertRejected(response, IDENTITY);
        }
        for (String field : List.of("claimLeaseUntil", "employeeId", "date")) {
            ObjectNode wrongRoot = JSON.createObjectNode().put(field,
                    "employeeId".equals(field) ? UUID_WITH_TAIL : "date".equals(field) ? "2026-10-14" : LEASE);
            assertRejected(wrongRoot, IDENTITY, YEAR_IDENTITY);
        }
        ObjectNode unknownSection = JSON.createObjectNode();
        unknownSection.putArray("otherTasks").addObject().put("claimLeaseUntil", LEASE);
        assertRejected(unknownSection, IDENTITY);
        ObjectNode wrongContainer = JSON.createObjectNode();
        wrongContainer.putObject("identityReview").putObject("0").put("claimLeaseUntil", LEASE);
        assertRejected(wrongContainer, IDENTITY);
        assertRejected(JSON.createObjectNode().put("identityReview/0/claimLeaseUntil", LEASE), IDENTITY);
    }

    @Test
    void invalidMetadataCannotHideBehindARecognizedFieldName() {
        for (String value : List.of("not-a-time-7407", "2026-02-30T06:20:59.797407Z",
                "2026-10-15T06:20:59.797407", LEASE + " trailing")) {
            ObjectNode response = JSON.createObjectNode();
            response.putArray("identityReview").addObject().put("claimLeaseUntil", value);
            assertRejected(response, IDENTITY);
        }
        for (String field : List.of("employeeId", "date", "claimLeaseUntil")) {
            ObjectNode response = JSON.createObjectNode();
            response.putArray("identityReview").addObject().put(field, 7407);
            assertRejected(response, IDENTITY);
        }
        assertRejected(JSON.createObjectNode().put("generatedAt", "2026-02-30"), IDENTITY);
        ObjectNode malformedUuid = JSON.createObjectNode();
        malformedUuid.putArray("identityReview").addObject().put("employeeId", "0-0-4-8-7407");
        assertRejected(malformedUuid, IDENTITY);
        assertThrows(AssertionError.class, () -> assertNoIdentityDigits(
                "{\"safe\":true}{\"note\":\"7407\"}", IDENTITY));
        assertThrows(AssertionError.class, () -> assertNoIdentityDigits(
                "{\"note\":\"7407\",\"note\":\"safe\"}", IDENTITY));
    }

    @Test
    void fullNumbersPrefixesAndTailsRemainRejectedInKeysAndValues() {
        for (String leaked : List.of(IDENTITY, IDENTITY.substring(0, 17), IDENTITY.substring(14))) {
            assertRejected(JSON.createObjectNode().put("note", "masked:" + leaked), IDENTITY);
            assertRejected(JSON.createObjectNode().put("unknown-" + leaked, "safe"), IDENTITY);
        }
        for (String leaked : List.of(IDENTITY, IDENTITY.substring(0, 17))) {
            ObjectNode response = JSON.createObjectNode();
            response.putArray("identityReview").addObject().put("claimLeaseUntil", leaked);
            AssertionError error = assertThrows(AssertionError.class,
                    () -> assertNoIdentityDigits(response.toString(), IDENTITY));
            assertTrue(error.getMessage().contains("full identity"), "global guard precedes metadata exemption");
            assertTrue(!error.getMessage().contains(leaked), "failure messages must not repeat sensitive values");
        }
    }

    @Test
    void nullableMetadataDoesNotChangeReadinessOrHumanReasonChecks() {
        ObjectNode summary = JSON.createObjectNode().put("generatedAt", "2026-10-14");
        summary.putArray("identityReview").addObject().put("employeeId", UUID_WITH_TAIL)
                .putNull("date").putNull("claimLeaseUntil").put("note", "档案里的证件号码读取不出来");
        assertDoesNotThrow(() -> assertNoIdentityDigits(summary.toString(), IDENTITY));
        ObjectNode readiness = JSON.createObjectNode().put("hasPhone", true);
        readiness.putObject("idNumberIssue").put("kind", "unchecked").put("reason", "档案里的证件号码读取不出来");
        assertDoesNotThrow(() -> assertNoIdentityDigits(readiness.toString(), IDENTITY));
        ((ObjectNode) readiness.path("idNumberIssue")).put("reason", LEASE);
        assertRejected(readiness, IDENTITY);
    }

    private static void assertRejected(ObjectNode response, String... identities) {
        assertThrows(AssertionError.class, () -> assertNoIdentityDigits(response.toString(), identities));
    }
}
