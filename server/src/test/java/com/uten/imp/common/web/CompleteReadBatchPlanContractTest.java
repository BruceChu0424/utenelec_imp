package com.uten.imp.common.web;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Shared Dart/Java vectors: the client and the stream server place every batch identically. */
class CompleteReadBatchPlanContractTest {

    private static JsonNode vectors() throws Exception {
        var path = Path.of("../contracts/complete-read-batch-plan-v1.json");
        if (!Files.exists(path)) path = Path.of("contracts/complete-read-batch-plan-v1.json");
        return new ObjectMapper().readTree(Files.readString(path));
    }

    private static List<int[]> requests(CompleteReadBatchPlan plan, long total) {
        var requests = new ArrayList<int[]>();
        long offset = 0;
        do {
            int size = plan.sizeAt(offset);
            int page = plan.pageAt(offset);
            assertThat((long) (page - 1) * size).as("batch starts at the next unread row").isEqualTo(offset);
            requests.add(new int[] {page, size});
            offset += Math.min(size, Math.max(0, total - offset));
        } while (offset < total);
        return requests;
    }

    @Test
    void everySharedCaseProducesTheSameAlignedRequests() throws Exception {
        var root = vectors();
        assertThat(root.get("schema").asText()).isEqualTo("uten-complete-read-batch-plan-v1");
        var plans = root.get("plans");
        for (JsonNode raw : root.get("cases")) {
            var spec = plans.get(raw.get("plan").asText());
            var plan = new CompleteReadBatchPlan(spec.get("firstBatchSize").asInt(), spec.get("maxBatchSize").asInt());
            long total = raw.get("total").asLong();
            var actual = requests(plan, total);
            if (raw.has("requests")) {
                var expected = new ArrayList<int[]>();
                raw.get("requests").forEach(pair -> expected.add(new int[] {pair.get(0).asInt(), pair.get(1).asInt()}));
                assertThat(actual).as("%s total=%d", raw.get("plan").asText(), total).containsExactlyElementsOf(expected);
            } else {
                assertThat(actual).hasSize(raw.get("requestCount").asInt());
                var first = raw.get("firstRequests");
                for (int i = 0; i < first.size(); i++) {
                    assertThat(actual.get(i)).containsExactly(first.get(i).get(0).asInt(), first.get(i).get(1).asInt());
                }
                var last = actual.getLast();
                assertThat(last).containsExactly(raw.get("lastRequest").get(0).asInt(), raw.get("lastRequest").get(1).asInt());
                assertThat(total - (long) (last[0] - 1) * last[1]).isEqualTo(raw.get("lastRows").asLong());
            }
        }
    }

    @Test
    void theProgressivePlanIsTheSharedPageMaximum() {
        // 2026-11-09: the bounded maximum was raised 200→1000 with the user.
        assertThat(CompleteReadBatchPlan.PROGRESSIVE.firstBatchSize()).isEqualTo(50);
        assertThat(CompleteReadBatchPlan.PROGRESSIVE.maxBatchSize()).isEqualTo(1000);
        assertThat(Pageables.MAX_PAGE_SIZE).isEqualTo(1000);
        assertThat(Pageables.of(3, 500).getPageSize()).isEqualTo(500);
        assertThat(Pageables.of(3, 5000).getPageSize()).isEqualTo(1000);
        assertThat(Pageables.of(3, 200).getOffset()).isEqualTo(400);
    }

    @Test
    void invalidPlansAreRejected() {
        assertThatThrownBy(() -> new CompleteReadBatchPlan(0, 200)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new CompleteReadBatchPlan(300, 200)).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> CompleteReadBatchPlan.PROGRESSIVE.sizeAt(-1)).isInstanceOf(IllegalArgumentException.class);
    }
}
