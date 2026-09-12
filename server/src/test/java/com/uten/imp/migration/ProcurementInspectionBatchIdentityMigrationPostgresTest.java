package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** The forward metadata addition cannot rewrite old IQC facts or weaken their ALWAYS guard. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementInspectionBatchIdentityMigrationPostgresTest {
    @Test void v557PreservesHistoricalRowsAndOnlyAllowsImmutableLowerHexHashes()throws Exception {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();flyway(database,"556").migrate();
            try(Connection connection=DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword())) {
                UUID goods=UUID.randomUUID(),warehouse=UUID.randomUUID(),inspection=UUID.randomUUID(),event=UUID.randomUUID();
                execute(connection,"INSERT INTO goods(id,code,name,code_sequence) VALUES('"+goods+"','QB-G-"+goods+"','Historical IQC fixture',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))");
                execute(connection,"INSERT INTO warehouses(id,code,name) VALUES('"+warehouse+"','QB-W-"+warehouse+"','Historical IQC fixture')");
                execute(connection,"INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,unit_rate,received_base_qty) VALUES('"+inspection+"','PURCHASE','"+UUID.randomUUID()+"','"+UUID.randomUUID()+"','"+warehouse+"','"+goods+"',1,8)");
                execute(connection,"INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty) VALUES('"+event+"','"+inspection+"','RECEIVED',8)");
                String old=digest(connection,false),heap=scalar(connection,"SELECT pg_relation_filenode('procurement_inspection_events')::text");
                String indexes=scalar(connection,"SELECT string_agg(indexdef,E'\n' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public' AND tablename='procurement_inspection_events'");
                String guard=scalar(connection,"SELECT pg_get_functiondef('fn_reject_procurement_inspection_event_mutation()'::regprocedure)");
                String history=scalar(connection,"SELECT md5(string_agg(to_jsonb(row)::text,E'\n' ORDER BY installed_rank)) FROM flyway_schema_history row");
                assertEquals(1,flyway(database,"557").migrate().migrationsExecuted);
                flyway(database,"557").validate();
                assertEquals(old,digest(connection,true));
                assertEquals(heap,scalar(connection,"SELECT pg_relation_filenode('procurement_inspection_events')::text"));
                assertEquals(indexes,scalar(connection,"SELECT string_agg(indexdef,E'\n' ORDER BY indexname) FROM pg_indexes WHERE schemaname='public' AND tablename='procurement_inspection_events'"));
                assertEquals(guard,scalar(connection,"SELECT pg_get_functiondef('fn_reject_procurement_inspection_event_mutation()'::regprocedure)"));
                assertEquals(history,scalar(connection,"SELECT md5(string_agg(to_jsonb(row)::text,E'\n' ORDER BY installed_rank)) FROM flyway_schema_history row WHERE version<>'557'"));
                assertEquals("0",scalar(connection,"SELECT count(*)::text FROM procurement_inspection_events WHERE batch_request_hash IS NOT NULL"));
                assertEquals("A",scalar(connection,"SELECT tgenabled::text FROM pg_trigger WHERE tgrelid='procurement_inspection_events'::regclass AND tgname='trg_00_reject_procurement_inspection_event_mutation'"));
                for(String hash:new String[]{"", "a".repeat(63),"A".repeat(64),"g".repeat(64),"a".repeat(65)}) {
                    String sql="INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,batch_request_hash) VALUES('"+UUID.randomUUID()+"','"+inspection+"','RECEIVED',8,'"+hash+"')";
                    SQLException invalid=assertThrows(SQLException.class,()->execute(connection,sql));
                    assertEquals("23514",invalid.getSQLState());
                    assertTrue(invalid.getMessage().contains("procurement_inspection_events_batch_hash_chk"));
                }
                connection.setAutoCommit(false);
                try {
                    String hash="0123456789abcdef".repeat(4);
                    execute(connection,"INSERT INTO procurement_inspection_events(id,inspection_item_id,action,base_qty,batch_request_hash) VALUES('"+UUID.randomUUID()+"','"+inspection+"','RECEIVED',8,'"+hash+"')");
                    assertEquals(hash,scalar(connection,"SELECT batch_request_hash FROM procurement_inspection_events WHERE batch_request_hash IS NOT NULL"));
                } finally {connection.rollback();connection.setAutoCommit(true);}
                for(String change:new String[]{"UPDATE procurement_inspection_events SET batch_request_hash='"+"a".repeat(64)+"' WHERE id='"+event+"'",
                        "DELETE FROM procurement_inspection_events WHERE id='"+event+"'"}) {
                    connection.setAutoCommit(false);
                    try {
                        execute(connection,"SET LOCAL session_replication_role='replica'");
                        assertEquals("55000",assertThrows(SQLException.class,()->execute(connection,change)).getSQLState());
                    } finally {connection.rollback();connection.setAutoCommit(true);}
                }
                assertEquals(old,digest(connection,true));
            }
        }
    }
    private static String digest(Connection connection,boolean migrated)throws SQLException {
        return scalar(connection,"SELECT md5(string_agg((to_jsonb(event)"+(migrated?"-'batch_request_hash'":"")+")::text,E'\n' ORDER BY id)) FROM procurement_inspection_events event");
    }
    private static Flyway flyway(PostgreSQLContainer<?> database,String version){return Flyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()).locations("classpath:db/migration").target(version).cleanDisabled(true).load();}
    private static void execute(Connection connection,String sql)throws SQLException{try(var statement=connection.createStatement()){statement.execute(sql);}}
    private static String scalar(Connection connection,String sql)throws SQLException{try(var statement=connection.createStatement();var result=statement.executeQuery(sql)){assertTrue(result.next());return result.getString(1);}}
}
