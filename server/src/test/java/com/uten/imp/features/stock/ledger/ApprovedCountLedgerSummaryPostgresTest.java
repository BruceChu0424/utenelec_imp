package com.uten.imp.features.stock.ledger;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ApprovedCountLedgerSummaryPostgresTest {
    @Test void approvedPositiveAndNegativeDeltasAppearOnTheirOwnSideWithoutBeingReversals() {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")) {
            pg.start();var db=new NamedParameterJdbcTemplate(new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()));
            com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db.getJdbcTemplate(),
                    "stock_balances", "stock_movements", "stock_weight_adjustments");
            UUID goods=UUID.randomUUID(),warehouse=UUID.randomUUID();
            db.getJdbcTemplate().update("INSERT INTO stock_balances(goods_id,warehouse_id,color_id,qty,weight) VALUES (?,?,NULL,80,80)",goods,warehouse);
            db.getJdbcTemplate().update("""
                    INSERT INTO stock_movements(id,goods_id,warehouse_id,transaction_date,ledger_seq,movement_type,
                      direction,source_doc_type,source_doc_id,qty,weight,weight_source)
                    VALUES(gen_random_uuid(),?,?,now()-interval '1 day',1,23,1,'APPROVED_COUNT',gen_random_uuid(),100,100,'MEASURED'),
                          (gen_random_uuid(),?,?,now(),2,23,-1,'APPROVED_COUNT',gen_random_uuid(),20,20,'MEASURED')
                    """,goods,warehouse,goods,warehouse);
            var q=new StockLedgerQuery(goods,Set.of(warehouse),null,false,null,null,List.of(),false,null,false,50,0);
            var total=db.queryForMap(StockLedgerSql.summary(q),StockLedgerSql.params(q));
            assertEquals(0,new BigDecimal("100").compareTo((BigDecimal)total.get("in_qty")));
            assertEquals(0,new BigDecimal("20").compareTo((BigDecimal)total.get("out_qty")));
            assertEquals(0,new BigDecimal("80").compareTo((BigDecimal)total.get("qty_now")));
        }
    }
}
