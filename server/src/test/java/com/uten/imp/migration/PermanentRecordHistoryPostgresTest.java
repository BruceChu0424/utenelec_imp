package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.UUID;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import static org.assertj.core.api.Assertions.*;

/** Real PostgreSQL: permanent originals are independent of active projections and transaction rollback. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PermanentRecordHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    Connection db;
    @BeforeAll static void schema() throws Exception { database=MigratedSchemaBaseline.openDatabase("record_history"); }
    @AfterAll static void closeSchema() throws Exception { if(database!=null)database.close(); }
    @BeforeEach void start() throws Exception {
        db=database.openConnection();db.setAutoCommit(false);
        sql("CREATE TABLE history_parent(id uuid PRIMARY KEY,is_deleted boolean NOT NULL DEFAULT false,deleted_at timestamptz,remark text)");
        sql("CREATE TABLE history_child(id uuid PRIMARY KEY,parent_id uuid NOT NULL REFERENCES history_parent(id),qty numeric NOT NULL,extra_columns jsonb NOT NULL)");
        sql("SELECT fn_register_record_retention('history_parent')");
        sql("SELECT fn_register_record_retention('history_child','history_parent','parent_id')");
    }
    @AfterEach void rollback() throws Exception { if(db!=null){db.rollback();db.close();} }
    @Test void replacementKeepsExactOriginalAndCurrentQuantityDoesNotDouble() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);
        sql("DELETE FROM history_child WHERE id='"+child+"'");
        sql("INSERT INTO history_child VALUES(gen_random_uuid(),'"+parent+"',7,'{}')");
        assertThat(number("SELECT sum(qty) FROM history_child")).isEqualTo(7);
        assertThat(number("SELECT count(*) FROM business_record_history WHERE parent_table='history_parent' AND parent_id='"+parent+"' AND payload->>'id'='"+child+"' AND payload->>'qty'='3' AND payload->'extra_columns'->>'保留条款'='原文' AND operation='DELETE'")).isEqualTo(1);
    }
    @Test void softDeletionKeepsBusinessStatusAndOriginalActorAndDoesNotRepeat() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID(),actor=UUID.randomUUID();seed(parent,child);
        sql("SELECT set_config('app.actor_id','"+actor+"',true),set_config('app.actor_account','原操作人',true)");
        sql("UPDATE history_parent SET is_deleted=true,deleted_at=now() WHERE id='"+parent+"'");
        sql("UPDATE history_parent SET is_deleted=true WHERE id='"+parent+"'");
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_table='history_parent' AND source_id='"+parent+"' AND actor_id='"+actor+"' AND actor_name='原操作人' AND payload->>'remark'='完整原文' AND operation='SOFT_DELETE'")).isEqualTo(1);
        assertThat(number("SELECT count(*) FROM history_child WHERE id='"+child+"'")).isEqualTo(1);
    }
    @Test void ordinaryUpdatesDoNotAddDeletionCopiesOrRestoreOldBalance() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);
        sql("UPDATE history_parent SET remark='修订' WHERE id='"+parent+"'");
        sql("UPDATE history_child SET qty=9 WHERE id='"+child+"'");
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_table IN ('history_parent','history_child')")).isZero();
        assertThat(number("SELECT qty FROM history_child")).isEqualTo(9);
    }
    @Test void failedTransactionRollsBackBothOriginalChangeAndHistory() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);var savepoint=db.setSavepoint();
        sql("DELETE FROM history_child WHERE id='"+child+"'");
        assertThatThrownBy(()->sql("INSERT INTO history_child VALUES(gen_random_uuid(),'"+parent+"',NULL,'{}')")).isInstanceOf(SQLException.class);
        db.rollback(savepoint);
        assertThat(number("SELECT count(*) FROM history_child WHERE id='"+child+"'")).isEqualTo(1);
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_id='"+child+"'")).isZero();
    }
    @Test void retainedHistoryRejectsMutationDeletionAndTruncation() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);sql("DELETE FROM history_child");
        for(String operation:new String[]{"UPDATE business_record_history SET actor_name='伪造'","DELETE FROM business_record_history","TRUNCATE business_record_history"}) {
            var point=db.setSavepoint();assertThatThrownBy(()->sql(operation)).isInstanceOf(SQLException.class).hasMessageContaining("cannot be modified or destroyed");db.rollback(point);
        }
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_id='"+child+"'")).isEqualTo(1);
    }
    @Test void truncatePreservesRegisteredRowsAndCompositeIdentity() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);
        sql("CREATE TABLE history_link(parent_id uuid NOT NULL,item_no integer NOT NULL,body text,PRIMARY KEY(parent_id,item_no))");
        sql("SELECT fn_register_record_retention('history_link','history_parent','parent_id')");
        sql("INSERT INTO history_link VALUES('"+parent+"',2,'关系原文')");
        sql("TRUNCATE history_child,history_link,history_parent");
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_table IN ('history_parent','history_child','history_link')")).isEqualTo(3);
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_table='history_link' AND source_id::jsonb->>'item_no'='2' AND payload->>'body'='关系原文'")).isEqualTo(1);
    }
    @Test void captureRemainsEnabledForRollingWritersAndReplicaSessions() throws Exception {
        UUID parent=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);
        sql("SET LOCAL session_replication_role=replica");sql("DELETE FROM history_child");
        assertThat(number("SELECT count(*) FROM business_record_history WHERE source_id='"+child+"'")).isEqualTo(1);
    }
    @Test void aRetainedChildCannotMoveOrReuseItsIdentityUnderAnotherParentInTheSameTransaction() throws Exception {
        UUID parent=UUID.randomUUID(),other=UUID.randomUUID(),child=UUID.randomUUID();seed(parent,child);
        sql("INSERT INTO history_parent(id) VALUES('"+other+"')");
        var point=db.setSavepoint();
        assertThatThrownBy(()->sql("UPDATE history_child SET parent_id='"+other+"' WHERE id='"+child+"'"))
                .isInstanceOf(SQLException.class).hasMessageContaining("cannot move to another parent");
        db.rollback(point);
        sql("DELETE FROM history_child WHERE id='"+child+"'");point=db.setSavepoint();
        assertThatThrownBy(()->sql("INSERT INTO history_child VALUES('"+child+"','"+other+"',9,'{}')"))
                .isInstanceOf(SQLException.class).hasMessageContaining("cannot move to another parent");
        db.rollback(point);
        sql("INSERT INTO history_child VALUES('"+child+"','"+parent+"',7,'{}')");
        assertThat(number("SELECT sum(qty) FROM history_child")).isEqualTo(7);
        assertThat(number("SELECT count(*) FROM business_record_history WHERE parent_id='"+other+"'")).isZero();
        assertThat(number("SELECT count(*) FROM business_record_identities WHERE source_table='history_child' AND source_id='"+child+"' AND parent_id='"+parent+"'")).isEqualTo(1);
    }
    @Test void concurrentOldRowRetirementCannotLetAnOldSnapshotRebindItsIdentity() throws Exception {
        try(var isolated=MigratedSchemaBaseline.openDatabase("history_race");var writer=isolated.openConnection()) {
            UUID parent=UUID.randomUUID(),other=UUID.randomUUID(),child=UUID.randomUUID();
            try(var statement=writer.createStatement()) {
                statement.execute("CREATE TABLE history_race_parent(id uuid PRIMARY KEY)");
                statement.execute("CREATE TABLE history_race_child(id uuid PRIMARY KEY,parent_id uuid NOT NULL)");
                statement.execute("INSERT INTO history_race_parent VALUES('"+parent+"'),('"+other+"')");
                // This row predates registration, as real migration input does.
                statement.execute("INSERT INTO history_race_child VALUES('"+child+"','"+parent+"')");
                statement.execute("SELECT fn_register_record_retention('history_race_child','history_race_parent','parent_id')");
            }
            writer.setAutoCommit(false);
            try(var statement=writer.createStatement()){statement.execute("DELETE FROM history_race_child WHERE id='"+child+"'");}
            var ready=new java.util.concurrent.CountDownLatch(1);
            var proceed=new java.util.concurrent.CountDownLatch(1);
            try(var executor=java.util.concurrent.Executors.newSingleThreadExecutor()) {
                var attempted=executor.submit(()->{
                    try(var connection=isolated.openConnection()) {
                        connection.setTransactionIsolation(Connection.TRANSACTION_REPEATABLE_READ);
                        connection.setAutoCommit(false);
                        try(var statement=connection.createStatement()) {
                            statement.executeQuery("SELECT count(*) FROM business_record_identities").close();
                            ready.countDown();proceed.await(10,java.util.concurrent.TimeUnit.SECONDS);
                            try {
                                statement.execute("INSERT INTO history_race_child VALUES('"+child+"','"+other+"')");
                                connection.commit();return "UNSAFE_SUCCESS";
                            } catch(SQLException expected) {connection.rollback();return expected.getSQLState();}
                        }
                    }
                });
                assertThat(ready.await(10,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
                writer.commit();proceed.countDown();
                assertThat(attempted.get(20,java.util.concurrent.TimeUnit.SECONDS)).isIn("40001","23514");
            }
            try(var statement=writer.createStatement();var result=statement.executeQuery("SELECT count(*) FROM business_record_history WHERE source_table='history_race_child' AND parent_id='"+parent+"'")) {
                assertThat(result.next()).isTrue();assertThat(result.getInt(1)).isEqualTo(1);
            }
            writer.rollback();
        }
    }
    @Test void realCommercialTablesAreRegisteredWithoutCredentialsAndResetPreservesHistory() throws Exception {
        assertThat(number("SELECT count(*) FROM business_record_retention_registry WHERE source_table IN ('sales_order_items','sales_quote_items','purchase_order_items','subcontract_order_items','finance_payment_lines','expense_claims','expense_claim_items','expense_claim_invoices')")).isEqualTo(8);
        assertThat(number("SELECT count(*) FROM business_record_retention_registry WHERE source_table IN ('users','refresh_tokens','password_history','business_record_history')")).isZero();
        assertThat(number("SELECT count(*) FROM information_schema.columns WHERE table_name='expense_claims' AND column_name IN ('is_deleted','deleted_at')")).isEqualTo(2);
        assertThat(number("SELECT CASE WHEN pg_get_functiondef('business_data_reset()'::regprocedure) LIKE '%(''business_record_history'', ''PRESERVE'')%' THEN 1 ELSE 0 END")).isEqualTo(1);
    }
    private void seed(UUID parent,UUID child)throws Exception {
        sql("INSERT INTO history_parent(id,remark) VALUES('"+parent+"','完整原文')");
        sql("INSERT INTO history_child VALUES('"+child+"','"+parent+"',3,'{\"保留条款\":\"原文\"}')");
    }
    private void sql(String sql)throws SQLException {try(var statement=db.createStatement()){statement.execute(sql);}}
    private long number(String sql)throws SQLException {try(var statement=db.createStatement();var result=statement.executeQuery(sql)){assertThat(result.next()).isTrue();return result.getLong(1);}}
}
