package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.time.LocalDate;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class FinanceAssetReviewRevisionServiceTest {
    private final ObjectMapper mapper = new ObjectMapper();
    private final FinanceAssetReviewRevisionService revisions = new FinanceAssetReviewRevisionService(null, mapper);

    @Test
    void latestTwoSubmittedFactsAreComparedWithinEachWorkflow() throws Exception {
        var result = revisions.project(List.of(
                recognition("first", "100.00"), recognition("second", "80.00"),
                new Object[]{"DISPOSAL_REQUESTED", "{\"proceedsAmount\":\"12.30\",\"evidenceReference\":\"D1\"}", LocalDate.of(2026,9,24), "处置原因"},
                new Object[]{"REJECTED", "{\"workflow\":\"DISPOSAL\"}", null, "拒绝处置"},
                recognition("third", "100.00")));
        assertThat(result).hasSize(2);
        assertThat(result.getFirst().workflowType()).isEqualTo("RECOGNITION");
        assertThat(result.getFirst().resubmission()).isTrue();
        assertThat(mapper.readTree(result.getFirst().previousSnapshot()).path("name").asText()).isEqualTo("second");
        assertThat(mapper.readTree(result.getFirst().submissionSnapshot()).path("name").asText()).isEqualTo("third");
        assertThat(result.get(1).workflowType()).isEqualTo("DISPOSAL");
        assertThat(result.get(1).resubmission()).isFalse();
        assertThat(result.get(1).previousSnapshot()).isNull();
    }

    @Test
    void missingLegacySubmissionIsNotReconstructedFromTheNewestCard() throws Exception {
        var result = revisions.project(List.of(new Object[]{"SUBMITTED", "{}", null, null}, recognition("new", "200.00")));
        assertThat(result.getFirst().resubmission()).isTrue();
        assertThat(result.getFirst().previousSnapshot()).isNull();
        assertThat(mapper.readTree(result.getFirst().submissionSnapshot()).path("originalValue").asText()).isEqualTo("200.00");
    }

    @Test
    void rejectionMayRetainTheFrozenLegacySubmissionButCannotReplaceAnExistingSnapshot() throws Exception {
        var recovery = recognition("frozen", "123.45"); recovery[0] = "REJECTED";
        var result = revisions.project(List.of(new Object[]{"SUBMITTED", "{}", null, null}, recovery, recognition("new", "150.00")));
        assertThat(mapper.readTree(result.getFirst().previousSnapshot()).path("name").asText()).isEqualTo("frozen");
        var retained = revisions.project(List.of(recognition("original", "100.00"), recovery, recognition("new", "150.00")));
        assertThat(mapper.readTree(retained.getFirst().previousSnapshot()).path("name").asText()).isEqualTo("original");
    }

    @Test
    void disposalPrecisionAndUnknownPayloadsArePreservedWithoutInventedZeroes() throws Exception {
        var result = revisions.project(List.of(
                new Object[]{"DISPOSAL_REQUESTED", "{}", LocalDate.of(2026,9,23), "old"},
                new Object[]{"DISPOSAL_REQUESTED", "{\"proceedsAmount\":9999999999999999.99,\"evidenceReference\":\"proof\",\"reviewRevision\":12}", LocalDate.of(2026,9,24), "new"}));
        assertThat(result.getFirst().previousSnapshot()).isNull();
        var snapshot = mapper.readTree(result.getFirst().submissionSnapshot());
        assertThat(snapshot.path("proceedsAmount").asText()).isEqualTo("9999999999999999.99");
        assertThat(snapshot.path("reason").asText()).isEqualTo("new");
        assertThat(snapshot.has("reviewRevision")).isFalse();
    }

    private static Object[] recognition(String name, String value) {
        return new Object[]{"SUBMITTED", "{\"workflow\":\"RECOGNITION\",\"submissionSnapshot\":{\"schemaVersion\":1,\"name\":\""
                + name + "\",\"originalValue\":\"" + value + "\"}}", null, null};
    }
}
