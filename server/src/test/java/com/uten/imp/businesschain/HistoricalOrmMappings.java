package com.uten.imp.businesschain;

import org.springframework.jdbc.core.JdbcTemplate;

import static org.junit.jupiter.api.Assertions.assertEquals;

/** Hibernate mapping resources for tests that deliberately boot older Flyway catalogs. */
final class HistoricalOrmMappings {
    static final String BEFORE_V1113 = "migration/orm-before-v1113.xml";
    static final String BEFORE_V1097 = "migration/orm-before-v1097.xml," + BEFORE_V1113;

    private HistoricalOrmMappings() {}

    static void requireOriginalSchema(JdbcTemplate jdbc, int version) {
        assertEquals(Integer.toString(version), jdbc.queryForObject("""
                SELECT version FROM flyway_schema_history
                WHERE success AND version IS NOT NULL
                ORDER BY installed_rank DESC LIMIT 1
                """, String.class));
        assertEquals(version < 1097 ? 0 : 1, jdbc.queryForObject("""
                SELECT count(*) FROM information_schema.columns
                WHERE table_schema='public' AND table_name='subcontract_receipt_items'
                  AND column_name='material_consumption_version'
                """, Integer.class));
        assertEquals(0, jdbc.queryForObject("""
                SELECT count(*) FROM information_schema.columns
                WHERE table_schema='public' AND table_name='production_daily_report_items'
                  AND column_name IN ('weight_entry_mode','unit_weight_kg','weight_quantity_scale','weight_quantity_rounding')
                """, Integer.class));
    }
}
