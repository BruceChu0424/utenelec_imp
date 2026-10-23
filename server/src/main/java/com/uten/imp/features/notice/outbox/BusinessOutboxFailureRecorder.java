package com.uten.imp.features.notice.outbox;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;
import java.util.Optional;
import java.time.Instant;
import java.time.OffsetDateTime;

/**
 * 业务 outbox 投递失败记录（{@link Propagation#REQUIRES_NEW} 独立事务）：
 * 累加 attempts、按 {@code power(2, attempts)} 秒退避（封顶 300s），
 * 达 {@value #MAX_ATTEMPTS} 次标记为死信（status=2）。
 */
@Service
public class BusinessOutboxFailureRecorder {

    static final int MAX_ATTEMPTS = 8;

    private final JdbcTemplate jdbc;

    public BusinessOutboxFailureRecorder(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public Optional<FailureRecording> record(UUID eventId, Throwable error) {
        String message = BusinessOutboxDeliveryDiagnostics.describe(error).persistedDescription();
        Optional<FailureRecording> updated = jdbc.query("""
                UPDATE business_outbox
                SET attempts = attempts + 1,
                    status = CASE WHEN attempts + 1 >= ? THEN 2 ELSE 0 END,
                    available_at = CASE
                        WHEN attempts + 1 >= ? THEN available_at
                        ELSE now() + make_interval(
                            secs => LEAST(300, CAST(power(2, attempts) AS integer))
                        )
                    END,
                    last_error = ?
                WHERE id = ? AND status = 0
                RETURNING status, attempts, available_at, now() AS recorded_at
                """,
                (row, index) -> new FailureRecording(row.getInt("status"), row.getInt("attempts"),
                        row.getObject("available_at", OffsetDateTime.class).toInstant(),
                        row.getObject("recorded_at", OffsetDateTime.class).toInstant(), null, true),
                MAX_ATTEMPTS, MAX_ATTEMPTS, message, eventId).stream().findFirst();
        if (updated.isPresent()) return updated;

        // The failed delivery released its row lock when its transaction rolled back.
        // A different consumer can commit that same event before this REQUIRES_NEW
        // recorder runs. Read its actual state in a new statement, after UPDATE's
        // wait/recheck, and keep that row stable until this transaction completes.
        // A missing row or an unconfirmed terminal state never means success.
        return jdbc.query("""
                SELECT status, attempts, available_at, processed_at, now() AS observed_at
                FROM business_outbox WHERE id = ? FOR UPDATE
                """, (row, index) -> {
                    OffsetDateTime processedAt = row.getObject("processed_at", OffsetDateTime.class);
                    return new FailureRecording(row.getInt("status"), row.getInt("attempts"),
                            row.getObject("available_at", OffsetDateTime.class).toInstant(),
                            row.getObject("observed_at", OffsetDateTime.class).toInstant(),
                            processedAt == null ? null : processedAt.toInstant(), false);
                }, eventId).stream().findFirst();
    }

    /** Distinguishes a new failure update from the durable state observed after a lost race. */
    public record FailureRecording(int status, int attempts, Instant availableAt, Instant observedAt,
                                   Instant processedAt, boolean recorded) {
        boolean alreadyDelivered() { return !recorded && status == 1 && processedAt != null; }
        boolean deferred() { return recorded && status == 0 && attempts > 0 && attempts < MAX_ATTEMPTS && availableAt.isAfter(observedAt); }
        boolean exhausted() { return status == 2; }
    }
}
