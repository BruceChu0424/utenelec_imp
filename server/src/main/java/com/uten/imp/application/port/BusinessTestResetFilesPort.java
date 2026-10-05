package com.uten.imp.application.port;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Test files of the workbench "clear business data" (ADR-155): checking, deleting and the
 * post-reset scratch cleanup. The object list comes only from {@code fn_business_test_reset_objects()}.
 */
public interface BusinessTestResetFilesPort {
    record Actor(UUID id, String account) {}

    /** Files of one source kind (distinct storage keys). */
    record KindCount(String label, long files) {}

    /** Dead background events (stopped retrying) of one category; cleared by the reset. */
    record DeadEvents(String label, long events) {}

    /** code = reason code; count = items or files involved; message = full text for people (may name files). */
    record Refusal(String code, long count, String message) {}

    /**
     * locations = storage locations; presentFiles = still stored and will be deleted;
     * absentFiles = already gone (including recorded deletions); inspectedObjects/inspectionComplete =
     * progress of the time-limited storage check; inspectionSkipped = the storage was not checked at all
     * because a refusal already makes the reset impossible (the counts are then 0 and say nothing about
     * the files, inspectionComplete is false); allListedMissing = files are listed but none was found.
     */
    record Check(long locations, long presentFiles, long absentFiles, long inspectedObjects, boolean inspectionComplete,
                 boolean inspectionSkipped, boolean allListedMissing, List<KindCount> kinds,
                 List<DeadEvents> deadBackgroundEvents, List<Refusal> refusals) {
        public Check {
            kinds = List.copyOf(kinds);
            deadBackgroundEvents = List.copyOf(deadBackgroundEvents);
            refusals = List.copyOf(refusals);
        }

        public boolean refused() { return !refusals.isEmpty(); }
    }

    record Purge(String fingerprint, long deletedFiles, long deadBackgroundEvents) {}

    /** Refusal or interruption: the HTTP text is {@link #getMessage()}; receipts use only {@link #reasons()}. */
    class ResetFilesFailure extends ApiException {
        private final List<Refusal> reasons;

        public ResetFilesFailure(ErrorCode code, String message, List<Refusal> reasons) {
            super(code, message);
            this.reasons = List.copyOf(reasons);
        }

        public List<Refusal> reasons() { return reasons; }
    }

    /** Storage check refusals; when joined they share one heading line. */
    Set<String> STORAGE_CHECK_CODES = Set.of("STORAGE_UNAVAILABLE", "LOCAL_NOT_CONFIGURED", "INTERNAL_NOT_CONFIGURED",
            "VERSION_MISMATCH", "NOT_A_FILE", "LOCAL_LEGACY_LAYOUT", "KEY_INVALID", "READ_FAILED");

    String STORAGE_CHECK_HEADING = "以下测试文件现在无法确认或无法删除，本次没有删除任何文件，也没有清空数据：";

    /** The complete text of several refusals, one per line; storage check lines follow one heading. */
    static String text(List<Refusal> refusals) {
        List<String> lines = new ArrayList<>();
        boolean headed = false;
        for (Refusal refusal : refusals) {
            if (STORAGE_CHECK_CODES.contains(refusal.code()) && !headed) {
                lines.add(STORAGE_CHECK_HEADING);
                headed = true;
            }
            lines.add(refusal.message());
        }
        return String.join("\n", lines);
    }

    /** A refusal before anything was deleted: 409 with the complete text. */
    static ResetFilesFailure refused(List<Refusal> refusals) {
        return new ResetFilesFailure(ErrorCode.CONFLICT, text(refusals), refusals);
    }

    /**
     * Read only: caller identity + database refusals + storage check (at most {@code inspectionBudget});
     * deletes nothing. Shared by the dialog preview and the check before draining.
     */
    Check check(Actor actor, Duration inspectionBudget);

    /**
     * Must run inside the caller's reset transaction (same connection; audit identity bound and
     * timeouts set): lock the sources, read refusals/list/fingerprint, check every object (any
     * problem throws {@link ResetFilesFailure} before anything is deleted), then delete and confirm
     * each one. {@code deleted} is incremented as soon as a delete returns (before the confirming read),
     * so a caller knows how many were deleted on failure.
     */
    Purge purge(Instant deadline, AtomicLong deleted);

    /** After a successful reset, removes abandoned internal-storage scratch files. */
    int cleanupAbandonedScratch();
}
