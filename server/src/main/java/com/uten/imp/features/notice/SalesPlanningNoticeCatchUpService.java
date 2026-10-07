package com.uten.imp.features.notice;

import com.uten.imp.application.port.SalesPlanningNoticeReadPort;
import org.springframework.stereotype.Service;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.UUID;

/** Fair keyset sweep; one order per transaction, at most 100 orders per invocation. */
@Service
@lombok.extern.slf4j.Slf4j
public class SalesPlanningNoticeCatchUpService {
    private final SalesPlanningNoticeReadPort sources;
    private final ChainNoticeService notices;
    private final TransactionTemplate transaction;
    private final JdbcTemplate jdbc;
    private UUID cursor;

    public SalesPlanningNoticeCatchUpService(SalesPlanningNoticeReadPort sources, ChainNoticeService notices,
            PlatformTransactionManager transactionManager, JdbcTemplate jdbc) {
        this.sources = sources;
        this.notices = notices;
        this.jdbc = jdbc;
        this.transaction = new TransactionTemplate(transactionManager);
        this.transaction.setPropagationBehavior(org.springframework.transaction.TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.transaction.setTimeout(10);
    }

    public synchronized int runBatch() {
        long deadline = System.nanoTime() + java.time.Duration.ofSeconds(10).toNanos();
        var orders = transaction.execute(status -> sources.initialHandoffOrdersAfter(cursor, 100));
        if (orders == null) return 0;
        if (orders.isEmpty()) { cursor = null; return 0; }
        int queued = 0;
        boolean completed = true;
        for (UUID order : orders) {
            if (System.nanoTime() >= deadline) { completed = false; break; }
            try {
                if (Boolean.TRUE.equals(transaction.execute(status -> {
                    jdbc.queryForObject("SELECT set_config('lock_timeout','2s',true)", String.class);
                    return notices.enqueueSalesPlanningCatchUp(order);
                }))) queued++;
            } catch (RuntimeException error) {
                // Keep other orders moving; a complete keyset sweep revisits this item. Do not log document/PII content.
                log.warn("计划接手提醒本轮跳过一笔，错误类型 {}，后续轮次继续", error.getClass().getSimpleName());
            }
            cursor = order;
        }
        if (completed && orders.size() < 100) cursor = null;
        return queued;
    }
}
