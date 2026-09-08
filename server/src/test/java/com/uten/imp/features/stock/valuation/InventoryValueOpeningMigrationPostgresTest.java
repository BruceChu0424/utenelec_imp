package com.uten.imp.features.stock.valuation;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

/** Full prior schema and nonempty legacy evidence; no migration-stage quantity/value/GL adoption. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryValueOpeningMigrationPostgresTest {
    @Test void forwardOpeningSchemaPreservesEveryExistingRowAndRegistersOnlyBusinessFacts()throws Exception{
        try(var postgres=new PostgreSQLContainer<>("postgres:16-alpine")){
            postgres.start();
            var ds=new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());
            Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("505").load().migrate();
            var db=new JdbcTemplate(ds);
            db.update("INSERT INTO units(id,code,name) VALUES ('00500506-0000-0000-0000-000000000001','OPENING-UNIT','opening piece')");
            db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES ('00500506-0000-0000-0000-000000000002','OPENING-GOODS','opening material','00500506-0000-0000-0000-000000000001',(SELECT COALESCE(max(code_sequence),0)+1 FROM goods))");
            db.update("INSERT INTO warehouses(id,code,name) VALUES ('00500506-0000-0000-0000-000000000003','OPENING-WAREHOUSE','opening warehouse')");
            db.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,qty,amount_local) VALUES ('00500506-0000-0000-0000-000000000004','00500506-0000-0000-0000-000000000003','00500506-0000-0000-0000-000000000002',7,999)");
            db.update("INSERT INTO stock_value_pools(id,warehouse_id,goods_id,state,legacy_balance_id,legacy_qty,legacy_amount_local) VALUES ('00500506-0000-0000-0000-000000000005','00500506-0000-0000-0000-000000000003','00500506-0000-0000-0000-000000000002','LEGACY_UNVERIFIED','00500506-0000-0000-0000-000000000004',7,999)");
            List<String> tables=db.queryForList("SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename<>'flyway_schema_history' ORDER BY tablename",String.class);
            Map<String,String> before=digest(db,tables);
            Flyway.configure().dataSource(ds).locations("classpath:db/migration").target("506").load().migrate();
            assertThat(digest(db,tables)).isEqualTo(before);
            for(String added:List.of("stock_value_openings","stock_value_legacy_balance_cases","stock_value_legacy_balance_case_events")){
                assertThat(db.queryForObject("SELECT count(*) FROM "+added,Integer.class)).isZero();
                assertThat(db.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class))
                        .contains("('"+added+"', 'CLEAR')");
            }
            assertThat(db.queryForObject("""
                    SELECT count(*) FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid
                    WHERE NOT trigger.tgisinternal AND trigger.tgenabled<>'A'
                      AND (relation.relname LIKE 'stock_value_%' OR trigger.tgname='trg_stock_balance_managed_value')
                    """,Integer.class)).isZero();
            assertThat(db.queryForObject("SELECT state FROM stock_value_pools WHERE id='00500506-0000-0000-0000-000000000005'",String.class)).isEqualTo("LEGACY_UNVERIFIED");
        }
    }

    private static Map<String,String> digest(JdbcTemplate db,List<String> tables){
        Map<String,String> hashes=new LinkedHashMap<>();
        for(String table:tables){
            if(!table.matches("[a-z_0-9]+"))throw new IllegalArgumentException("Unexpected schema identifier");
            hashes.put(table,db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(row)::text,',' ORDER BY to_jsonb(row)::text),'')) FROM "+table+" row",String.class));
        }
        return hashes;
    }
}
