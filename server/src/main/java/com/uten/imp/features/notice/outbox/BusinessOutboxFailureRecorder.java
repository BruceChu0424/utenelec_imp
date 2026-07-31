package com.uten.imp.features.notice.outbox;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class BusinessOutboxFailureRecorder {

    static final int MAX_ATTEMPTS = 8;

    private final JdbcTemplate jdbc;

    public BusinessOutboxFailureRecorder(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void record(UUID eventId, Throwable error) {
        String message = rootMessage(error);
        jdbc.update("""
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
                """,
                MAX_ATTEMPTS,
                MAX_ATTEMPTS,
                message,
                eventId);
    }

    private String rootMessage(Throwable error) {
        Throwable current = error;
        while (current.getCause() != null) {
            current = current.getCause();
        }
        String value = current.getClass().getSimpleName() + ": " + current.getMessage();
        return value.length() <= 1000 ? value : value.substring(0, 1000);
    }
}
