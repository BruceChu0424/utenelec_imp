package com.uten.imp.features.attachment;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Heat rule of the nightly cold-tier pass: age alone never archives an
 * attachment that someone actually downloaded or previewed recently, and
 * company-library rows never reach the SQL candidate list at all.
 */
class InternalStorageTieringSchedulerTest {

    private static Map<String, Object> row(UUID id, String key) {
        return Map.of("id", id, "storage_key", key);
    }

    @Test
    void recentlyDownloadedAttachmentsStayOnTheHotRoot() {
        var downloaded = UUID.randomUUID();
        var previewed = UUID.randomUUID();
        var cold = UUID.randomUUID();
        var candidates = List.of(
                row(downloaded, "aaa.pdf"),
                row(previewed, "bbb.pdf"),
                row(cold, "ccc.pdf"));
        var active = Set.of(downloaded.toString(), previewed.toString());
        assertEquals(List.of("ccc.pdf"), InternalStorageTieringScheduler.selectColdKeys(candidates, active));
    }

    @Test
    void rowsWithoutIdentitiesAreNotTreatedAsActive() {
        var pinned = UUID.randomUUID();
        var other = UUID.randomUUID();
        var candidates = List.<Map<String, Object>>of(
                Map.of("storage_key", "no-id.pdf"),
                row(pinned, "pinned.pdf"),
                row(other, "cold.pdf"));
        assertEquals(List.of("no-id.pdf", "cold.pdf"),
                InternalStorageTieringScheduler.selectColdKeys(candidates, Set.of(pinned.toString())));
    }

    @Test
    void emptyCandidatesOrAllActiveProduceNothingToMove() {
        assertEquals(List.of(),
                InternalStorageTieringScheduler.selectColdKeys(List.of(), Set.of()));
        var id = UUID.randomUUID();
        assertEquals(List.of(), InternalStorageTieringScheduler.selectColdKeys(
                List.of(row(id, "hot.pdf")), Set.of(id.toString())));
    }
}
