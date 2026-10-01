package com.uten.imp.ops;

import com.uten.imp.application.port.BusinessAttachmentResetPreparationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.admin.systemtest.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.PlatformTransactionManager;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Current permanent policy: reset must preserve every native header, original and quantity fact. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessDataResetServicePostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;
    JdbcTemplate jdbc;BusinessDataResetService service;
    BusinessDataResetDrainGate drain;BusinessAttachmentResetPreparationPort files;
    UUID actor=UUID.randomUUID();
    @BeforeEach void open() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("permanent_reset_policy");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());jdbc=new JdbcTemplate(source);
        drain=mock(BusinessDataResetDrainGate.class);files=mock(BusinessAttachmentResetPreparationPort.class);
        service=new BusinessDataResetService(source,mock(PlatformTransactionManager.class),new BusinessDataResetFeatureGate(true),drain,mock(AuditService.class),files);
        UUID employee=UUID.randomUUID(),client=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'保留前置','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"RST-"+employee);
        jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients),?)",client,"RST-"+client,"原客户",employee);
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,status,client_id,owner_employee_id,maker_id) VALUES(?,'XD'||to_char(CURRENT_DATE,'YYYYMMDD')||'990001',CURRENT_DATE,0,?,?,?)",id,client,employee,employee);
    }
    @AfterEach void close() throws Exception {if(database!=null)database.close();}
    @Test void serviceRefusalKeepsNativeBusinessRowsAndAllCurrentQuantityState() {
        Map<String,String> before=digests();
        assertThatThrownBy(()->service.reset(actor,"retention-test",UUID.randomUUID())).isInstanceOf(ApiException.class).hasMessageContaining("永久保留");
        assertThat(digests()).isEqualTo(before);verifyNoInteractions(drain,files);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_orders",Long.class)).isPositive();
    }
    @Test void directSqlResetCannotBypassPolicyOrAdvanceEpochOrClearFacts() {
        Map<String,String> before=digests();
        assertThatThrownBy(()->jdbc.queryForMap("SELECT * FROM business_data_reset()"))
            .isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("PERMANENT_RETAIN");
        assertThat(digests()).isEqualTo(before);
    }
    @Test void blockedResetDoesNotTouchFilePreparationEvenWithPendingIntent() {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO attachment_object_outbox(id,operation,storage_key,dedupe_key,storage_provider) VALUES(?,'DELETE_FINAL','test-retained-key',?,'local')",id,id.toString());
        Map<String,String> before=digests();
        assertThatThrownBy(()->service.reset(actor,"retention-test")).isInstanceOf(ApiException.class).hasMessageContaining("归档");
        verifyNoInteractions(drain,files);assertThat(digests()).isEqualTo(before);
    }
    @Test void readOnlyInventoryOfPolicyAndCountsStillWorks() {
        assertThat(jdbc.queryForObject("SELECT fn_audit_retention_purge_mode()",String.class)).isEqualTo("PERMANENT_RETAIN");
        assertThat(jdbc.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class))
            .contains("PERMANENT_RETAIN prohibits business reset","('stock_movements', 'CLEAR')");
        assertThat(digests()).hasSize(6);
    }
    Map<String,String> digests(){
        var result=new LinkedHashMap<String,String>();
        for(String table:List.of("sales_orders","stock_balances","stock_movements","authorization_state","attachments","attachment_object_outbox"))
            result.put(table,jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(t)::text,'|' ORDER BY to_jsonb(t)::text),'')) FROM "+table+" t",String.class));
        return result;
    }
}
