package com.uten.imp.migration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.*;

import static org.assertj.core.api.Assertions.*;

/** Genuine1084 ->1085 forward: original audit bytes/facts/guards stay, only new UPDATE metadata gains identity. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinancialCompositeAuditLocatorUpgradePostgresTest {
    private static final ObjectMapper JSON=new ObjectMapper();

    @Test void actualSameMonthClientsAndChangedCompositeKeysKeepPrivateValuesOutAndOldRowsUntouched() throws Exception {
        try(var database=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("financial_locator_upgrade")
                .withUsername("locator_fixture").withPassword("anonymous-locator-only")){
            database.start();migrate(database,"1084");
            var db=new JdbcTemplate(new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()));
            UUID actor=actor(db),a=client(db,"A"),b=client(db,"B"),unit=UUID.randomUUID();String period="2026-09";
            String marker="ANONYMOUS-PRIVATE-"+UUID.randomUUID(),number="123.123456789012345678901234";
            db.update("INSERT INTO units(id,code,name,status)VALUES(?,?,?,'使用')",unit,"LOCATOR-"+unit,"Unit-Before");
            for(UUID id:List.of(a,b))db.update("INSERT INTO finance_sales_cost_inputs(period,client_id,freight_local,source_reference,updated_by)VALUES(?,?,1,?,?)",period,id,marker,actor);
            long oldUpdateAnchor=lastId(db);
            changeClients(db,period,a,b,actor,marker+"-OLD-CHANGE",number);
            var oldUpdates=updates(db,"finance_sales_cost_inputs",oldUpdateAnchor);
            assertThat(oldUpdates).hasSize(2);
            for(var event:oldUpdates){
                assertThat(event.path("target_id").asText()).isEqualTo(period);
                assertThat(event.path("before").has("client_id")).isFalse();
                assertThat(event.path("after").has("client_id")).isFalse();
                assertPrivateChangedKeys(event,marker,number);
            }
            db.update("UPDATE finance_procurement_ap_policy SET source_reference=?,row_version=row_version+1,updated_by=? WHERE singleton",marker,actor);
            JsonNode oldSingle=lastUpdate(db,"finance_procurement_ap_policy");
            db.update("UPDATE units SET name='Unit-After' WHERE id=?",unit);
            JsonNode oldNonfinance=lastUpdate(db,"units");
            db.update("UPDATE units SET name='Unit-Before' WHERE id=?",unit);
            long originalMaximum=lastId(db);
            String originalAudits=auditRowsThrough(db,originalMaximum);
            String originalFacts=db.queryForObject("SELECT jsonb_agg(to_jsonb(value) ORDER BY client_id)::text FROM finance_sales_cost_inputs value WHERE period=?",String.class,period);
            String triggers=allTriggers(db);String constraints=allConstraints(db);
            long writerOid=db.queryForObject("SELECT 'public.fn_audit()'::regprocedure::oid::bigint",Long.class);
            String redactor=db.queryForObject("SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)",String.class);
            migrate(database,"1085");
            assertThat(db.queryForObject("SELECT max(version::numeric)::int FROM flyway_schema_history WHERE success AND version IS NOT NULL",Integer.class)).isEqualTo(1085);
            assertThat(auditRowsThrough(db,originalMaximum)).isEqualTo(originalAudits);
            assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(value) ORDER BY client_id)::text FROM finance_sales_cost_inputs value WHERE period=?",String.class,period)).isEqualTo(originalFacts);
            assertThat(allTriggers(db)).isEqualTo(triggers);assertThat(allConstraints(db)).isEqualTo(constraints);
            assertThat(db.queryForObject("SELECT 'public.fn_audit()'::regprocedure::oid::bigint",Long.class)).isEqualTo(writerOid);
            assertThat(db.queryForObject("SELECT pg_get_functiondef('public.fn_audit_redact_row(text,jsonb)'::regprocedure)",String.class)).isEqualTo(redactor);

            String nextNumber=new java.math.BigDecimal(number).add(java.math.BigDecimal.ONE).toPlainString();
            long afterAnchor=lastId(db);changeClients(db,period,a,b,actor,marker+"-NEW-CHANGE",nextNumber);
            var events=updates(db,"finance_sales_cost_inputs",afterAnchor);assertThat(events).hasSize(2);
            var actual=new HashSet<String>();
            for(var event:events){
                assertThat(event.path("target_id").asText()).isEqualTo(period);
                assertThat(event.path("before").path("period").asText()).isEqualTo(period);
                assertThat(event.path("after").path("period").asText()).isEqualTo(period);
                String client=event.path("before").path("client_id").asText();
                assertThat(event.path("after").path("client_id").asText()).isEqualTo(client);actual.add(client);
                assertPrivateChangedKeys(event,marker,nextNumber);
            }
            assertThat(actual).containsExactlyInAnyOrder(a.toString(),b.toString());
            for(UUID id:List.of(a,b))assertThat(db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='finance_sales_cost_inputs' AND action='update' AND id>? AND before->>'client_id'=? AND after->>'client_id'=?",Integer.class,afterAnchor,id.toString(),id.toString())).isEqualTo(1);

            db.update("UPDATE finance_procurement_ap_policy SET source_reference=?,row_version=row_version+1,updated_by=? WHERE singleton",marker+"-OTHER",actor);
            JsonNode single=lastUpdate(db,"finance_procurement_ap_policy");
            assertThat(single.path("target_id")).isEqualTo(oldSingle.path("target_id"));
            assertThat(single.path("before")).isEqualTo(oldSingle.path("before"));assertThat(single.path("after")).isEqualTo(oldSingle.path("after"));
            db.update("UPDATE units SET name='Unit-After' WHERE id=?",unit);
            JsonNode nonfinance=lastUpdate(db,"units");
            assertThat(nonfinance.path("target_id")).isEqualTo(oldNonfinance.path("target_id"));
            assertThat(nonfinance.path("before")).isEqualTo(oldNonfinance.path("before"));assertThat(nonfinance.path("after")).isEqualTo(oldNonfinance.path("after"));
            changedPrimaryKeysKeepOldAndNewParts(db,period,actor,marker);
            assertThat(auditRowsThrough(db,originalMaximum)).isEqualTo(originalAudits);
        }
    }

    private static void changedPrimaryKeysKeepOldAndNewParts(JdbcTemplate db,String period,UUID actor,String marker) throws Exception {
        long anchor=lastId(db);
        db.update("INSERT INTO finance_operating_report_notes(period,line_key,remark,variance_reason,updated_by)VALUES(?,'LOCATOR_OLD',?,?,?)",period,marker,marker,actor);
        JsonNode noteInsert=lastEvent(db,"finance_operating_report_notes","insert");
        assertThat(noteInsert.path("before").isNull()).isTrue();
        assertThat(noteInsert.path("after").properties().stream().map(Map.Entry::getKey).toList()).containsExactlyInAnyOrder("period","line_key","updated_by");
        db.update("UPDATE finance_operating_report_notes SET line_key='LOCATOR_NEW',row_version=row_version+1 WHERE period=? AND line_key='LOCATOR_OLD'",period);
        JsonNode note=lastUpdate(db,"finance_operating_report_notes");
        assertThat(note.path("target_id").asText()).isEqualTo(period);
        assertThat(note.path("before").path("period").asText()).isEqualTo(period);assertThat(note.path("after").path("period").asText()).isEqualTo(period);
        assertThat(note.path("before").path("line_key").asText()).isEqualTo("LOCATOR_OLD");assertThat(note.path("after").path("line_key").asText()).isEqualTo("LOCATOR_NEW");
        db.update("DELETE FROM finance_operating_report_notes WHERE period=? AND line_key='LOCATOR_NEW'",period);
        JsonNode noteDelete=lastEvent(db,"finance_operating_report_notes","delete");
        assertThat(noteDelete.path("after").isNull()).isTrue();
        assertThat(noteDelete.path("before").properties().stream().map(Map.Entry::getKey).toList()).containsExactlyInAnyOrder("period","line_key","updated_by");
        UUID style=UUID.randomUUID();String code="1900099";
        db.update("INSERT INTO payment_styles(id,code,name,category,level,status)VALUES(?,?,?,'ACCOUNT',0,'使用')",style,"LOCATOR-"+style,"匿名定位对应科目");
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by)VALUES(?,'匿名三键定位','',?,'ASSET','MANUAL','匿名来源',1,1,?)",code,currency,actor);
        db.update("INSERT INTO finance_chart_owned_bindings(code,style_id,line_key)VALUES(?,?,'LOCATOR_OLD')",code,style);
        db.update("UPDATE finance_chart_owned_bindings SET line_key='LOCATOR_NEW' WHERE code=? AND style_id=? AND line_key='LOCATOR_OLD'",code,style);
        JsonNode binding=lastUpdate(db,"finance_chart_owned_bindings");
        assertThat(binding.path("target_id").asText()).isEqualTo(code);
        for(String side:List.of("before","after")){
            assertThat(binding.path(side).path("code").asText()).isEqualTo(code);
            assertThat(binding.path(side).path("style_id").asText()).isEqualTo(style.toString());
        }
        assertThat(binding.path("before").path("line_key").asText()).isEqualTo("LOCATOR_OLD");assertThat(binding.path("after").path("line_key").asText()).isEqualTo("LOCATOR_NEW");
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE id>?",String.class,anchor)).doesNotContain(marker);
    }
    private static void assertPrivateChangedKeys(JsonNode event,String marker,String number){
        assertThat(event.toString()).doesNotContain(marker,number);
        var keys=new HashSet<String>();event.path("after").path("_redacted_changes").forEach(value->keys.add(value.asText()));
        assertThat(keys).contains("freight_local","source_reference");
    }
    private static void changeClients(JdbcTemplate db,String period,UUID a,UUID b,UUID actor,String reference,String number){
        for(UUID id:List.of(a,b))assertThat(db.update("UPDATE finance_sales_cost_inputs SET source_reference=?,freight_local=?::numeric,row_version=row_version+1,updated_by=? WHERE period=? AND client_id=?",reference,number,actor,period,id)).isEqualTo(1);
    }
    private static List<JsonNode> updates(JdbcTemplate db,String table,long after) throws Exception {
        var result=new ArrayList<JsonNode>();for(String value:db.queryForList("SELECT to_jsonb(a)::text FROM audit_log a WHERE target_type=? AND action='update' AND id>? ORDER BY id",String.class,table,after))result.add(FinancialJsonResults.tree(JSON,value));return result;
    }
    private static JsonNode lastUpdate(JdbcTemplate db,String table) throws Exception {return lastEvent(db,table,"update");}
    private static JsonNode lastEvent(JdbcTemplate db,String table,String action) throws Exception {return FinancialJsonResults.tree(JSON,db.queryForObject("SELECT to_jsonb(a)::text FROM audit_log a WHERE target_type=? AND action=? ORDER BY id DESC LIMIT 1",String.class,table,action));}
    private static long lastId(JdbcTemplate db){return db.queryForObject("SELECT coalesce(max(id),0) FROM audit_log",Long.class);}
    private static String auditRowsThrough(JdbcTemplate db,long id){return db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE id<=?",String.class,id);}
    private static String allTriggers(JdbcTemplate db){return db.queryForObject("SELECT jsonb_agg(jsonb_build_array(c.relname,t.tgname,t.tgenabled,t.tgfoid::bigint,pg_get_triggerdef(t.oid)) ORDER BY c.relname,t.tgname)::text FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal",String.class);}
    private static String allConstraints(JdbcTemplate db){return db.queryForObject("SELECT jsonb_agg(jsonb_build_array(c.relname,k.conname,pg_get_constraintdef(k.oid)) ORDER BY c.relname,k.conname)::text FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid WHERE c.relnamespace='public'::regnamespace",String.class);}
    private static UUID actor(JdbcTemplate db){
        UUID employee=UUID.randomUUID(),actor=UUID.randomUUID();UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"LOCATOR-"+employee,"匿名审计员工-"+employee,department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status)VALUES(?,?,?,'unused-test-only',false,'active')",actor,employee,"locator-"+actor);return actor;
    }
    private static UUID client(JdbcTemplate db,String label){UUID id=UUID.randomUUID();db.update("INSERT INTO clients(id,code,name,status,code_sequence)VALUES(?,?,?,'使用',(SELECT coalesce(max(code_sequence),0)+1 FROM clients))",id,"LOCATOR-"+id,"匿名定位客户-"+label);return id;}
    private static void migrate(PostgreSQLContainer database,String target){TestFlyway.configure().dataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword()).locations("classpath:db/migration").target(target).load().migrate();}
}
