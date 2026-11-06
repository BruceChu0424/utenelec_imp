package com.uten.imp.common.readsnapshot;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.Objects;

/** Metadata-only compaction; never takes or waits for a business-row lock. */
@Component
@Profile("!cloud")
public class SummaryReadMarkerCompactor {
    private final JdbcTemplate jdbc;
    private final TransactionTemplate transaction;
    public SummaryReadMarkerCompactor(JdbcTemplate jdbc,PlatformTransactionManager manager) {
        this.jdbc=jdbc;transaction=new TransactionTemplate(manager);
        transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        transaction.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }
    @Scheduled(fixedDelayString="${uten.read-summary.compact-delay-ms:60000}")
    public void compact() {
        // One bounded delete per domain/tick. UUID epoch+compacted count maintain the exact logical revision.
        for(String domain:jdbc.queryForList("SELECT domain FROM summary_read_domains ORDER BY domain",String.class))
            compactDomain(domain);
    }
    public int compactDomain(String domain) {
        return Objects.requireNonNull(transaction.execute(status -> {
            Integer count=jdbc.queryForObject("SELECT public.fn_compact_summary_read_domain(?)",Integer.class,domain);
            return count==null?0:count;
        }));
    }
}
