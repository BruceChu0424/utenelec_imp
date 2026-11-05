package com.uten.imp.features.master.goods;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Shared with V739's manual ownership trigger and learning publisher. Lock all parent rows first. */
@Component
@RequiredArgsConstructor
public class GoodsBomGraphLock implements com.uten.imp.application.port.BomGraphLockPort {
    private final JdbcTemplate db;

    @Override
    public void acquire() {
        db.queryForObject("""
                SELECT count(*) FROM (
                    SELECT pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0))
                ) acquired
                """, Long.class);
    }
}
