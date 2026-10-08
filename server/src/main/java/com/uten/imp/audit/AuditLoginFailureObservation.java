package com.uten.imp.audit;

import com.uten.imp.application.port.LoginFailureObservationPort;
import com.uten.imp.common.util.HashUtil;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;

@Component
@RequiredArgsConstructor
public class AuditLoginFailureObservation implements LoginFailureObservationPort {
    private final JdbcTemplate jdbc;

    @Override
    @Transactional(readOnly = true, timeout = 10)
    public List<FailureWindow> recentFailures(Instant since) {
        return jdbc.query("""
                SELECT ip,count(*) AS attempts FROM audit_log
                WHERE action='login_failed' AND created_at>=?
                  AND ip IS NOT NULL AND ip<>''
                GROUP BY ip HAVING count(*)>=10 ORDER BY count(*) DESC,ip LIMIT 100
                """, (row, index) -> new FailureWindow(HashUtil.sha256(row.getString(1)), row.getLong(2)),
                Timestamp.from(since));
    }
}
