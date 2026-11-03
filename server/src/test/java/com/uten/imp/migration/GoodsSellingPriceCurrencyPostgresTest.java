package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Upgrade compatibility: nullable selling currency and old history lineage tokens. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsSellingPriceCurrencyPostgresTest {
    @Test void upgradeKeepsPriceAndImmutableEvidenceWhileMaintainingOldUndoTokens() throws Exception {
        try(var database = new PostgreSQLContainer("postgres:16-alpine")) {
            database.start();
            var db = new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            db.execute("CREATE TABLE currencies(id uuid PRIMARY KEY,is_base_currency boolean NOT NULL DEFAULT false)");
            db.execute("CREATE TABLE goods(id uuid PRIMARY KEY,price numeric(18,4),is_deleted boolean NOT NULL DEFAULT false)");
            db.execute("CREATE TABLE goods_operation_history_rows(table_name text,before_row jsonb,after_row jsonb,expected_row jsonb,before_token jsonb,after_token jsonb)");
            UUID id=UUID.randomUUID();
            db.update("INSERT INTO goods(id,price) VALUES (?,1234.5678)",id);
            db.execute("INSERT INTO goods_operation_history_rows VALUES ('goods','{\"price\":1}','{\"price\":2}','{\"version\":3}','{\"version\":1}','{\"version\":2}'),('colors','{}','{}','{}','{}',NULL)");
            try(var input=Objects.requireNonNull(getClass().getResourceAsStream("/db/migration/V995__goods_selling_price_currency.sql"))) {
                db.execute(new String(input.readAllBytes(), StandardCharsets.UTF_8));
            }
            assertEquals("1234.5678",db.queryForObject("SELECT price::text FROM goods WHERE id=?",String.class,id));
            assertNull(db.queryForObject("SELECT currency_id FROM goods WHERE id=?",UUID.class,id));
            assertFalse(db.queryForObject("SELECT before_row ? 'currency_id' OR after_row ? 'currency_id' FROM goods_operation_history_rows WHERE table_name='goods'",Boolean.class));
            assertFalse(db.queryForObject("SELECT expected_row ? 'currency_id' OR before_token ? 'currency_id' OR after_token ? 'currency_id' FROM goods_operation_history_rows WHERE table_name='goods'",Boolean.class));
            assertTrue(db.queryForObject("SELECT fn_goods_bom_history_schema(expected_row,'goods')->'currency_id'='null'::jsonb FROM goods_operation_history_rows WHERE table_name='goods'",Boolean.class));
            assertEquals("true",db.queryForObject("SELECT (fn_goods_bom_history_schema('{\"currency_id\":\"known-later-value\"}'::jsonb,'goods')->>'currency_id'='known-later-value')::text",String.class));
            assertFalse(db.queryForObject("SELECT expected_row ? 'currency_id' FROM goods_operation_history_rows WHERE table_name='colors'",Boolean.class));
            UUID currency=UUID.randomUUID(); db.update("INSERT INTO currencies(id) VALUES (?)",currency);
            db.update("UPDATE goods SET currency_id=? WHERE id=?",currency,id);
            assertEquals(currency,db.queryForObject("SELECT currency_id FROM goods WHERE id=?",UUID.class,id));
            String defaults="SELECT "+com.uten.imp.common.finance.SellingPriceCurrency.forBaseCurrencySql("g")+" FROM goods g WHERE g.id=?";
            assertNull(db.queryForObject(defaults,java.math.BigDecimal.class,id),"An explicit foreign price is never a base-currency default");
            db.update("UPDATE currencies SET is_base_currency=true WHERE id=?",currency);
            assertEquals(new java.math.BigDecimal("1234.5678"),db.queryForObject(defaults,java.math.BigDecimal.class,id));
            db.update("UPDATE goods SET currency_id=NULL WHERE id=?",id);
            assertEquals(new java.math.BigDecimal("1234.5678"),db.queryForObject(defaults,java.math.BigDecimal.class,id),"Unregistered historical prices preserve the prior default behavior");
            assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                    () -> db.update("UPDATE goods SET currency_id=? WHERE id=?",UUID.randomUUID(),id));
        }
    }
}
