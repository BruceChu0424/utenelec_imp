package com.uten.imp.common.platformcolumns;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Exact field versions and current scope/price masks against real migrations; no generic raw history read. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PlatformFieldHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;static JdbcTemplate jdbc;
    PlatformColumnService service;TestAdapter adapter;UUID actor,record,secret,calculated;
    @BeforeAll static void open() throws Exception {database=MigratedSchemaBaseline.openDatabase("platform_field_history");
        jdbc=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));}
    @AfterAll static void close() throws Exception {if(database!=null)database.close();}
    @BeforeEach void setup() {
        actor=UUID.randomUUID();record=UUID.randomUUID();secret=UUID.randomUUID();calculated=UUID.randomUUID();adapter=new TestAdapter(record);
        var current=mock(SecurityContextCurrentUser.class);when(current.requireId()).thenReturn(actor);
        service=new PlatformColumnService(List.of(adapter),new NamedParameterJdbcTemplate(jdbc),new ObjectMapper(),current,mock(TxSessionVars.class));
        jdbc.update("INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,definition_fingerprint,created_by) VALUES(?,'history_fixture','原敏感字段','原敏感字段','NUMBER',true,?,?)",secret,secret.toString().replace("-","")+"a".repeat(32),actor);
        String formula="{\"base\":{\"columnId\":\""+secret+"\"},\"steps\":[]}";
        jdbc.update("INSERT INTO platform_column_definitions(id,scope,name,normalized_name,value_type,price_protected,formula,definition_fingerprint,created_by) VALUES(?,'history_fixture','依赖字段','依赖字段','CALCULATED',false,CAST(? AS jsonb),?,?)",calculated,formula,calculated.toString().replace("-","")+"b".repeat(32),actor);
        jdbc.update("INSERT INTO platform_record_fields(scope,record_id,version,cells,created_by,updated_by) VALUES('history_fixture',?,1,CAST(? AS jsonb),?,?)",record,cells("120.30"),actor,actor);
    }
    @Test void updatesAndSameIdentityRecreationKeepEveryOriginalValueWithStableCursor() {
        jdbc.update("UPDATE platform_record_fields SET version=2,cells=CAST(? AS jsonb) WHERE scope='history_fixture' AND record_id=?",cells("999.99"),record);
        jdbc.update("DELETE FROM platform_record_fields WHERE scope='history_fixture' AND record_id=?",record);
        jdbc.update("INSERT INTO platform_record_fields(scope,record_id,version,cells,created_by,updated_by) VALUES('history_fixture',?,1,CAST(? AS jsonb),?,?)",record,cells("5.00"),actor,actor);
        adapter.price=true;var versions=service.history("history_fixture",record,null,20);
        assertThat(versions).hasSize(4);assertThat(versions.getFirst().row().cells().getFirst().value()).isEqualTo("5.00");
        assertThat(versions.getLast().row().cells().getFirst().value()).isEqualTo("120.30");
        assertThat(versions).allSatisfy(v->{assertThat(v.historyReadOnly()).isTrue();assertThat(v.row().canWrite()).isFalse();});
        assertThat(service.history("history_fixture",record,versions.get(1).id(),20)).hasSize(2);
    }
    @Test void currentPriceRevocationMasksDirectAndTransitiveSensitiveValuesAndFormula() {
        var versions=service.history("history_fixture",record,null,20);var row=versions.getFirst().row();
        assertThat(row.cells()).allSatisfy(cell->{assertThat(cell.masked()).isTrue();assertThat(cell.value()).isNull();});
        adapter.price=true;var visible=service.history("history_fixture",record,null,20).getFirst().row();
        assertThat(visible.cells().getFirst().value()).isEqualTo("120.30");
        assertThat(visible.cells().get(1).value()).isNull();assertThat(visible.cells().get(1).error()).contains("不能用当前业务数值重算");
        var audit=jdbc.queryForList("SELECT after::text FROM audit_log WHERE target_type='platform_record_field_versions' AND after->>'record_id'=?",String.class,record.toString());
        assertThat(audit).hasSize(1);assertThat(audit.getFirst()).contains("history_fixture","version","INSERT").doesNotContain("120.30","cells","payload","formula");
        assertThat(jdbc.queryForObject("SELECT cells::text FROM platform_record_field_versions WHERE record_id=?",String.class,record)).contains("120.30");
    }
    @Test void currentParentScopeRevocationRefusesHistoricalValuesAndImmutableStoreCannotBeChanged() {
        adapter.allowed=false;assertThatThrownBy(()->service.history("history_fixture",record,null,20)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->jdbc.update("UPDATE platform_record_field_versions SET cells='[]' WHERE record_id=?",record)).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update("DELETE FROM platform_record_field_versions WHERE record_id=?",record)).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.execute("TRUNCATE platform_record_field_versions")).isInstanceOf(org.springframework.dao.DataAccessException.class);
    }
    @Test void overwriteWithoutVersionIncrementRollsBackBothCurrentAndRetainedValues() {
        assertThatThrownBy(()->jdbc.update("UPDATE platform_record_fields SET cells=CAST(? AS jsonb) WHERE scope='history_fixture' AND record_id=?",cells("wrong"),record)).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(jdbc.queryForObject("SELECT cells::text FROM platform_record_fields WHERE scope='history_fixture' AND record_id=?",String.class,record)).contains("120.30");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM platform_record_field_versions WHERE scope='history_fixture' AND record_id=?",Integer.class,record)).isEqualTo(1);
    }
    @Test void immutableDefinitionAndVersionsCannotBeBypassedByReplicationOrTruncation() throws Exception {
        try(var connection=jdbc.getDataSource().getConnection()) {
            connection.setAutoCommit(true);
            var replica=new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            replica.execute("SET session_replication_role=replica");
            try {
                assertThat(replica.queryForObject("SHOW session_replication_role",String.class)).isEqualTo("replica");
                assertThatThrownBy(()->replica.update("UPDATE platform_column_definitions SET price_protected=false,name='普通说明' WHERE id=?",secret)).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("immutable");
                assertThatThrownBy(()->replica.update("DELETE FROM platform_column_definitions WHERE id=?",secret)).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("immutable");
                assertThatThrownBy(()->replica.execute("TRUNCATE platform_column_definitions CASCADE")).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("immutable");
                assertThatThrownBy(()->replica.update("UPDATE platform_record_field_versions SET cells='[]' WHERE record_id=?",record)).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("immutable");
                assertThatThrownBy(()->replica.execute("TRUNCATE platform_record_field_versions")).isInstanceOf(org.springframework.dao.DataAccessException.class).hasMessageContaining("immutable");
            } finally {replica.execute("SET session_replication_role=origin");}
        }
        adapter.price=true;
        assertThat(service.history("history_fixture",record,null,20).getFirst().row().cells().getFirst().value()).isEqualTo("120.30");
    }
    String cells(String value){return "[{\"columnId\":\""+secret+"\",\"value\":\""+value+"\"},{\"columnId\":\""+calculated+"\",\"value\":null}]";}
    static class TestAdapter implements PlatformColumnResourceAdapter {
        UUID record;boolean allowed=true,price;
        TestAdapter(UUID record){this.record=record;}
        public String scope(){return "history_fixture";}public String label(){return "历史测试";}
        public void requireDefinitionAccess(boolean write){}public boolean canWrite(){return false;}public boolean canViewPrice(){return price;}
        public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){return allowed&&ids.equals(Set.of(record))?Map.of(record,new RecordAccess(false,price,Map.of("qty",java.math.BigDecimal.valueOf(999)))):Map.of();}
    }
}
