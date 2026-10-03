package com.uten.imp.ops;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import com.uten.imp.features.admin.systemtest.BusinessDataResetFeatureGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

/** Actual forward schema: ordinary retention and explicit testing destruction must coexist. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class TestResetHistoryExceptionPostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private DriverManagerDataSource source;
    private JdbcTemplate jdbc;
    @BeforeEach void open() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("test_reset_history_exception");
        source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(source);
    }
    @AfterEach void close() throws Exception {if(database!=null)database.close();}

    @Test void ordinaryDeleteRetainsItsOriginalWhileUntrustedFlagsCannotDestroyHistory() throws Exception {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_quotes(id,bill_no,bill_date,status) VALUES(?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991001',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,0)",id);
        jdbc.update("DELETE FROM sales_quotes WHERE id=?",id);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history WHERE source_table='sales_quotes' AND source_id=?",Integer.class,id.toString())).isEqualTo(1);
        assertThatThrownBy(()->jdbc.update("TRUNCATE business_record_history")).hasMessageContaining("Retained business history");
        assertThatThrownBy(()->jdbc.update("TRUNCATE production_daily_report_commands")).hasMessageContaining("append-only");
        try(var connection=source.getConnection();var statement=connection.createStatement()) {
            String role="reset_scope_"+UUID.randomUUID().toString().replace("-","");
            statement.execute("CREATE ROLE "+role+" NOLOGIN");
            statement.execute("GRANT USAGE ON SCHEMA public TO "+role);
            statement.execute("GRANT SELECT,DELETE,TRUNCATE ON business_record_history TO "+role);
            statement.execute("GRANT SELECT,UPDATE ON authorization_state TO "+role);
            try {
                statement.execute("SET ROLE "+role);
                statement.execute("SET app.test_business_reset='CLEAR_TEST_BUSINESS_WITH_HISTORY'");
                try(var result=statement.executeQuery("SELECT fn_business_test_reset_active()")) {
                    assertThat(result.next()).isTrue();assertThat(result.getBoolean(1)).isFalse();
                }
                assertThatThrownBy(()->statement.execute("TRUNCATE business_record_history")).hasMessageContaining("Retained business history");
                assertThatThrownBy(()->statement.execute("UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1"))
                        .hasMessageContaining("Only an explicit test reset");
            } finally {
                statement.execute("RESET ROLE");statement.execute("RESET app.test_business_reset");
                statement.execute("REVOKE ALL ON business_record_history,authorization_state FROM "+role);
                statement.execute("REVOKE ALL ON SCHEMA public FROM "+role);
                statement.execute("DROP ROLE "+role);
            }
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history WHERE source_id=?",Integer.class,id.toString())).isEqualTo(1);
    }

    @Test void explicitResetClearsBusinessFieldsVersionsAndOldAuditButKeepsMastersAndControlReceipts() {
        UUID actor=UUID.randomUUID(),masterColumn=UUID.randomUUID(),businessColumn=UUID.randomUUID();
        UUID master=UUID.randomUUID(),business=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,definition_fingerprint,created_by,usage_count,last_used_at)
                VALUES(?,'goods','主档说明','主档说明','TEXT',repeat('a',64),?,3,now()),
                      (?,'sales_shipment_item','业务说明','业务说明','TEXT',repeat('b',64),?,5,now())
                """,masterColumn,actor,businessColumn,actor);
        jdbc.update("""
                INSERT INTO platform_record_fields(scope,record_id,cells,retain_on_reset,created_by,updated_by)
                VALUES('goods',?,jsonb_build_array(jsonb_build_object('columnId',CAST(? AS text),'value','current master value')),true,?,?),
                      ('sales_shipment_item',?,jsonb_build_array(jsonb_build_object('columnId',CAST(? AS text),'value','old test business value')),false,?,?)
                """,master,masterColumn,actor,actor,business,businessColumn,actor,actor);
        jdbc.update("INSERT INTO platform_column_usage(user_id,definition_id,usage_count) VALUES(?,?,3),(?,?,5)",actor,masterColumn,actor,businessColumn);
        UUID control=UUID.randomUUID(),oldAudit=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO audit_log(actor_account,action,target_type,target_id,result,event_source,risk_level,event_category,device_capture_status)
                VALUES('test','business_data_reset','system_test',?,'complete','business','low','system','missing'),
                      ('test','old_test_change','sales_quotes',?,'old','business','low','business','missing')
                """,control.toString(),oldAudit.toString());
        jdbc.queryForMap("SELECT * FROM business_data_reset()");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform_record_fields WHERE NOT retain_on_reset",Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT cells->0->>'value' FROM platform_record_fields WHERE scope='goods' AND record_id=?",String.class,master)).isEqualTo("current master value");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform_record_field_versions",Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform_column_usage",Integer.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform_column_definitions WHERE id IN(?,?) AND usage_count=0 AND last_used_at IS NULL",Integer.class,masterColumn,businessColumn)).isEqualTo(2);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_id=?",Integer.class,oldAudit.toString())).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_id=?",Integer.class,control.toString())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT fn_business_test_reset_active()",Boolean.class)).isFalse();
        assertThatThrownBy(()->jdbc.update("TRUNCATE audit_log"))
                .satisfies(error->assertThat(org.springframework.core.NestedExceptionUtils.getMostSpecificCause(error))
                        .isInstanceOf(java.sql.SQLException.class).hasMessageContaining("审计记录只能追加"));
    }

    @Test void generationChangesOnlyForCommittedResetAndFailureRestoresTheWholeDataset() {
        long before=jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class);
        jdbc.update("UPDATE authorization_state SET epoch=epoch+1 WHERE singleton_id=1");
        assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before);
        assertThatThrownBy(()->jdbc.update("UPDATE authorization_state SET business_reset_generation=business_reset_generation+1 WHERE singleton_id=1"))
                .hasMessageContaining("Only an explicit test reset");
        jdbc.update("INSERT INTO business_record_history(source_table,source_id,payload,operation) VALUES('sales_orders','rollback-evidence','{\"original\":\"kept\"}','DELETE')");
        long epoch=jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        new TransactionTemplate(new DataSourceTransactionManager(source)).executeWithoutResult(status->{
            jdbc.queryForMap("SELECT * FROM business_data_reset()");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history",Integer.class)).isZero();
            assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before+1);
            status.setRollbackOnly();
        });
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history WHERE source_id='rollback-evidence' AND payload->>'original'='kept'",Integer.class)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(epoch);
        assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before);
        assertThat(jdbc.queryForObject("SELECT fn_business_test_reset_active()",Boolean.class)).isFalse();
        jdbc.queryForMap("SELECT * FROM business_data_reset()");
        assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1",Long.class)).isEqualTo(before+1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM business_record_history",Integer.class)).isZero();
    }

    @Test void archivedControlReceiptsRemainReadableForTheirOriginalActorAfterAnotherReset() {
        jdbc.queryForObject("SELECT fn_audit_ensure_partition('audit_log_archive',DATE '1998-01-01')",String.class);
        UUID actor=UUID.randomUUID(),complete=UUID.randomUUID(),failed=UUID.randomUUID(),pending=UUID.randomUUID();
        String instance=org.springframework.test.util.ReflectionTestUtils.getField(BusinessDataResetService.class,"SERVER_INSTANCE_ID").toString();
        jdbc.update("""
                INSERT INTO audit_log_archive(actor_id,actor_account,action,target_type,target_id,result,created_at,event_source,risk_level,event_category,device_capture_status)
                VALUES(?, 'old-test-admin','business_data_reset_received','system_test',?,?,'1998-01-02 00:00:00+00','business','low','system','missing'),
                      (?, 'old-test-admin','business_data_reset','system_test',?,'cleared_tables=3,cleared_rows=12,preserved_tables=5,epoch=7,deleted_attachment_files=2','1998-01-02 00:01:00+00','business','low','system','missing'),
                      (?, 'old-test-admin','business_data_reset_received','system_test',?,?,'1998-01-03 00:00:00+00','business','low','system','missing'),
                      (?, 'old-test-admin','business_data_reset_failed','system_test',?,'failed,code=CONFLICT,message=old exact refusal','1998-01-03 00:01:00+00','business','low','system','missing'),
                      (?, 'old-test-admin','business_data_reset_received','system_test',?,?,'1998-01-04 00:00:00+00','business','low','system','missing')
                """,actor,complete.toString(),"received,server="+instance,actor,complete.toString(),
                     actor,failed.toString(),"received,server="+instance,actor,failed.toString(),
                     actor,pending.toString(),"received,server="+instance);
        var service=new BusinessDataResetService(source,new DataSourceTransactionManager(source),
                new BusinessDataResetFeatureGate(true),new BusinessDataResetDrainGate(),mock(AuditService.class),mock(BusinessAttachmentResetPreparationPort.class));
        var done=service.lastResult(actor,complete);
        assertThat(done.available()).isTrue();assertThat(done.attemptReceived()).isTrue();
        assertThat(done.clearedRows()).isEqualTo(12);assertThat(done.authorizationEpochAfter()).isEqualTo(7);
        assertThat(done.deletedAttachmentFiles()).isEqualTo(2);
        var rejected=service.lastResult(actor,failed);
        assertThat(rejected.available()).isFalse();assertThat(rejected.attemptReceived()).isTrue();
        assertThat(rejected.attemptFailed()).isTrue();assertThat(rejected.attemptFailureMessage()).isEqualTo("old exact refusal");
        var waiting=service.lastResult(actor,pending);
        assertThat(waiting.attemptReceived()).isTrue();assertThat(waiting.attemptReceivedByCurrentServer()).isTrue();
        assertThat(waiting.available()).isFalse();assertThat(waiting.attemptFailed()).isFalse();
        var wrong=service.lastResult(UUID.randomUUID(),complete);
        assertThat(wrong.available()).isFalse();assertThat(wrong.attemptReceived()).isFalse();
        jdbc.queryForMap("SELECT * FROM business_data_reset()");
        var after=service.lastResult(actor,complete);
        assertThat(after.available()).isTrue();assertThat(after.attemptReceived()).isTrue();
        assertThat(after.clearedRows()).isEqualTo(12);assertThat(after.authorizationEpochAfter()).isEqualTo(7);
        assertThat(service.lastResult(actor,failed).attemptFailureMessage()).isEqualTo("old exact refusal");
        assertThat(service.lastResult(actor,pending).attemptReceived()).isTrue();
    }
}
