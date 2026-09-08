package com.uten.imp.features.stock.valuation;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Whole preceding schema, including its real view/trigger dependencies. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryValueAuthorityMigrationPostgresTest {
    @Test void exactValueExtensionPreservesOldRowsAndKeepsLegacyAmountsUnverified()throws Exception{
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")){
            pg.start();var ds=new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());
            Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("516").load().migrate();var db=new JdbcTemplate(ds);
            db.update("INSERT INTO units(id,code,name) VALUES ('00500509-0000-0000-0000-000000000001','VALUE-UNIT','value unit')");
            db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES ('00500509-0000-0000-0000-000000000002','VALUE-GOODS','value goods','00500509-0000-0000-0000-000000000001',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))");
            db.update("INSERT INTO warehouses(id,code,name) VALUES ('00500509-0000-0000-0000-000000000003','VALUE-WAREHOUSE','value warehouse')");
            db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local) VALUES ('00500509-0000-0000-0000-000000000004','00500509-0000-0000-0000-000000000003','00500509-0000-0000-0000-000000000002',7,999)");
            db.update("INSERT INTO stock_value_pools(id,warehouse_id,goods_id,state,legacy_qty,legacy_amount_local) VALUES ('00500509-0000-0000-0000-000000000005','00500509-0000-0000-0000-000000000003','00500509-0000-0000-0000-000000000002','LEGACY_UNVERIFIED',7,999)");
            List<String> tables=db.queryForList("SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename<>'flyway_schema_history' ORDER BY tablename",String.class);
            var before=digest(db,tables);
            db.execute(Files.readString(Path.of("../.codex-tmp/valuation-positions/V517__inventory_value_custody_positions.sql")));
            assertThat(digest(db,tables)).isEqualTo(before);
            for(String table:List.of("stock_value_acquisition_sources","stock_value_position_transfers","stock_value_production_cost_objects",
                    "stock_value_production_cost_inputs","stock_value_production_cost_outputs","stock_value_production_cost_revisions",
                    "stock_value_production_cost_tasks","stock_value_production_cost_shares","stock_value_production_cost_dirty")){
                assertThat(db.queryForObject("SELECT count(*) FROM "+table,Long.class)).isZero();
                assertThat(db.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class)).contains("('"+table+"', 'CLEAR')");
            }
            assertThat(db.queryForObject("SELECT state FROM stock_value_pools WHERE id='00500509-0000-0000-0000-000000000005'",String.class)).isEqualTo("LEGACY_UNVERIFIED");
            assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE NOT t.tgisinternal AND c.relname LIKE 'stock_value_%' AND t.tgenabled<>'A'",Integer.class)).isZero();
        }
    }
    private static Map<String,String> digest(JdbcTemplate db,List<String> tables){
        Map<String,String> result=new LinkedHashMap<>();
        for(String table:tables){if(!table.matches("[a-z_0-9]+"))throw new IllegalArgumentException(table);
            result.put(table,db.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(row)::text,',' ORDER BY to_jsonb(row)::text),'')) FROM "+table+" row",String.class));}
        return result;
    }
}
