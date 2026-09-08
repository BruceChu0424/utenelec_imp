package com.uten.imp.migration;

import java.sql.DriverManager;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import static org.junit.jupiter.api.Assertions.*;

@org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementConsiderationMigrationPostgresTest {
    @Test void upgradesTheCompleteCandidateWithoutRoundingInternalMoney() throws Exception {
        try(var pg=new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("iqc_consideration").withUsername("uten").withPassword("test-only")){
            pg.start();
            String candidate=System.getProperty("uten.test.iqc.migration.location","classpath:db/migration");
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                    .locations("filesystem:src/main/resources/db/migration").target("516").load().migrate();
            Flyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword())
                    .locations("filesystem:src/main/resources/db/migration",candidate).target("518").load().migrate();
            try(var c=DriverManager.getConnection(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());var s=c.createStatement()){
                try(var r=s.executeQuery("SELECT atttypmod,attnotnull FROM pg_attribute WHERE attrelid='procurement_iqc_credit_slices'::regclass AND attname='amount_original'")){
                    assertTrue(r.next());assertEquals(-1,r.getInt(1));assertFalse(r.getBoolean(2));
                }
                try(var r=s.executeQuery("SELECT count(*) FROM pg_trigger WHERE tgrelid='procurement_iqc_credit_case_allocations'::regclass AND tgenabled='A' AND NOT tgisinternal")){
                    assertTrue(r.next());assertEquals(3,r.getInt(1),"append-only, audit and deferred source proof must remain ALWAYS");
                }
                try(var r=s.executeQuery("SELECT fn_financial_amount_is_exact(0.000000000000000000000001),fn_financial_amount_is_exact(0.0000000000000000000000001)")){
                    assertTrue(r.next());assertTrue(r.getBoolean(1));assertFalse(r.getBoolean(2));
                }
                try(var r=s.executeQuery("SELECT position('(''procurement_iqc_credit_case_allocations'', ''CLEAR'')' IN pg_get_functiondef('business_data_reset()'::regprocedure))>0")){
                    assertTrue(r.next());assertTrue(r.getBoolean(1),"case-level actual allocations need an explicit reset policy");
                }
            }
        }
    }
}
