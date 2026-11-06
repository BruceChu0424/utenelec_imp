package com.uten.imp.migration;

import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** SQL upgrade/retention only. Actual file policy and public transactions are tested separately. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceChartImportIntentUpgradePostgresTest {
    @Test void realPre1083RowsKeepAllOriginalSourceAndSuccessBytesWhileNewReviewAndStopProofsAreConstrained() {
        try(var pg=new PostgreSQLContainer("postgres:16-alpine")){
            pg.start();migrate(pg,"1082");var source=new DriverManagerDataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword());var db=new JdbcTemplate(source);
            UUID employee=UUID.randomUUID(),actor=UUID.randomUUID(),pending=UUID.randomUUID(),success=UUID.randomUUID();
            db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)VALUES(?,?,?,'其他',(SELECT id FROM departments WHERE code='DEPT_FIN'),CURRENT_DATE,'active','regular')",employee,"UP-"+employee,"匿名升级原人员");
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password,is_super_admin)VALUES(?,?,?,'test-only','active',false,false)",actor,employee,"chart-upgrade-"+actor);
            seed(db,pending,actor,"a","884001",false);seed(db,success,actor,"b","884002",true);
            db.update("INSERT INTO finance_chart_codes(code,name,currency_name,sort_order,source_row,source_import_id,classification,updated_by)VALUES('884002','匿名原字面科目','',1,2,?,'ASSET',?)",success,actor);
            String oldPending=row(db,pending),oldSuccess=row(db,success),oldCode=db.queryForObject("SELECT to_jsonb(c)::text FROM finance_chart_codes c WHERE code='884002'",String.class);
            String literalPending=db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,pending);
            String literalSuccess=db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,success);
            String result=db.queryForObject("SELECT applied_result::text FROM finance_chart_imports WHERE id=?",String.class,success);
            String originalAudit=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_chart_imports' AND target_id IN(?,?)",String.class,pending.toString(),success.toString());
            migrate(pg,"1083");
            for(UUID id:List.of(pending,success)){
                assertThat(db.queryForObject("SELECT parent_import_id IS NULL AND review_request_id IS NULL AND apply_receipt IS NULL AND cancelled_at IS NULL AND cancellation_result IS NULL FROM finance_chart_imports WHERE id=?",Boolean.class,id)).isTrue();
                assertThat(db.queryForObject("SELECT (to_jsonb(c)-ARRAY['parent_import_id','review_request_id','apply_receipt','cancelled_at','cancellation_result'])::text FROM finance_chart_imports c WHERE id=?",String.class,id)).isEqualTo(id.equals(pending)?oldPending:oldSuccess);
            }
            assertThat(db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,pending)).isEqualTo(literalPending);
            assertThat(db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,success)).isEqualTo(literalSuccess);
            assertThat(db.queryForObject("SELECT applied_result::text FROM finance_chart_imports WHERE id=?",String.class,success)).isEqualTo(result);
            assertThat(db.queryForObject("SELECT to_jsonb(c)::text FROM finance_chart_codes c WHERE code='884002'",String.class)).isEqualTo(oldCode);
            assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_chart_imports' AND target_id IN(?,?)",String.class,pending.toString(),success.toString())).isEqualTo(originalAudit);
            assertThatThrownBy(()->seed(db,UUID.randomUUID(),actor,"a","884003",false)).isInstanceOf(org.springframework.dao.DuplicateKeyException.class);
            assertThatThrownBy(()->seed(db,UUID.randomUUID(),actor,"c","884004",true)).hasMessageContaining("unapplied preview");
            String pendingAfterUpgrade=row(db,pending);
            assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET applied_at=now(),applied_result=jsonb_build_object('importId',id::text,'imported',1,'status','APPLIED') WHERE id=?",pending)).hasMessageContaining("bound original apply receipt");
            assertThat(row(db,pending)).isEqualTo(pendingAfterUpgrade);
            assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET applied_result='{}'::jsonb WHERE id=?",success)).hasMessageContaining("Terminal");
            assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET preview='{}'::jsonb WHERE id=?",pending)).hasMessageContaining("immutable");
            assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET storage_key='forged' WHERE id=?",pending)).hasMessageContaining("immutable");
            assertThatThrownBy(()->db.update("DELETE FROM finance_chart_imports WHERE id=?",pending)).hasMessageContaining("retained");
            db.update("""
                    UPDATE finance_chart_imports SET cancelled_at=now(),cancellation_result=jsonb_build_object(
                        'found',true,'requestId',id::text,'actorId',actor_id::text,'operation','CHART_IMPORT_APPLY','method','POST',
                        'path','/finance/chart/import-apply','requestBody',jsonb_build_object('importId',id::text),
                        'outcome','CANCELLED_UNWRITTEN','result',jsonb_build_object('cancelled',true)) WHERE id=?
                    """,pending);
            String stopped=row(db,pending);assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET cancelled_at=NULL,cancellation_result=NULL WHERE id=?",pending)).hasMessageContaining("Terminal");
            UUID child=UUID.randomUUID(),request=UUID.randomUUID();
            var transaction=new TransactionTemplate(new DataSourceTransactionManager(source));
            transaction.executeWithoutResult(status->{
                insertChild(db,child,request,pending);
                db.update("""
                        INSERT INTO finance_chart_manual_operations(request_id,actor_id,fingerprint,result)
                        SELECT ?,actor_id,encode(digest('CHART_IMPORT_REPREVIEW:/finance/chart/imports/'||id::text||'/repreview:'||
                            encode(digest('{"requestId":"'||?::text||'"}','sha256'),'hex'),'sha256'),'hex'),
                            jsonb_build_object('found',true,'requestId',?::text,'actorId',actor_id::text,
                                'operation','CHART_IMPORT_REPREVIEW','method','POST','path','/finance/chart/imports/'||id::text||'/repreview',
                                'requestBody',jsonb_build_object('requestId',?::text),'outcome','SUCCEEDED',
                                'result',jsonb_build_object('requestId',?::text,'importId',?::text,'parentImportId',id::text,'sourceImportId',id::text,'sha256',sha256,'status','PREVIEWED'))
                        FROM finance_chart_imports WHERE id=?
                        """,request,request,request,request,request,child,pending);
            });
            assertThat(db.queryForObject("SELECT parent_import_id FROM finance_chart_imports WHERE id=?",UUID.class,child)).isEqualTo(pending);
            assertThat(db.queryForObject("SELECT jsonb_build_array(source_name,sha256,storage_provider,storage_key,storage_version,storage_size)::text FROM finance_chart_imports WHERE id=?",String.class,child)).isEqualTo(db.queryForObject("SELECT jsonb_build_array(source_name,sha256,storage_provider,storage_key,storage_version,storage_size)::text FROM finance_chart_imports WHERE id=?",String.class,pending));
            UUID noProof=UUID.randomUUID();assertThatThrownBy(()->transaction.executeWithoutResult(status->{insertChild(db,noProof,UUID.randomUUID(),pending);db.execute("SET CONSTRAINTS ALL IMMEDIATE");})).isInstanceOf(RuntimeException.class);
            assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_imports WHERE id=?",Long.class,noProof)).isZero();
            assertThat(row(db,pending)).isEqualTo(stopped);assertThat(db.queryForObject("SELECT applied_result::text FROM finance_chart_imports WHERE id=?",String.class,success)).isEqualTo(result);
        }
    }
    private static void insertChild(JdbcTemplate db,UUID id,UUID request,UUID parent){
        db.update("""
                INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview,parent_import_id,review_request_id)
                SELECT ?,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,
                    jsonb_set(preview,'{importId}',to_jsonb(?::text)),id,? FROM finance_chart_imports WHERE id=?
                """,id,id,request,parent);
    }
    private static void seed(JdbcTemplate db,UUID id,UUID actor,String hash,String code,boolean applied){
        String preview="{\"importId\":\""+id+"\",\"sourceName\":\"anonymous-original.xlsx\",\"sha256\":\""+hash.repeat(64)+"\",\"rows\":[{\"code\":\""+code+"\",\"name\":\"匿名原字面科目\",\"currencyName\":\"\",\"sourceRow\":2,\"existingVersion\":null,\"classification\":\"ASSET\"}],\"issues\":[],\"applied\":false}";
        db.update("""
                INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview,applied_at,applied_result,created_at)
                VALUES(?,?,'anonymous-original.xlsx',?,'local',?,1,?::jsonb,CASE WHEN ? THEN TIMESTAMPTZ '2026-01-01 00:00:00Z' END,
                    CASE WHEN ? THEN jsonb_build_object('importId',?::text,'imported',1,'status','APPLIED') END,TIMESTAMPTZ '2026-01-01 00:00:00Z')
                """,id,actor,hash.repeat(64),"anonymous-retained-"+id,preview,applied,applied,id);
    }
    private static String row(JdbcTemplate db,UUID id){return db.queryForObject("SELECT to_jsonb(c)::text FROM finance_chart_imports c WHERE id=?",String.class,id);}
    private static void migrate(PostgreSQLContainer pg,String target){TestFlyway.configure().dataSource(pg.getJdbcUrl(),pg.getUsername(),pg.getPassword()).locations("classpath:db/migration").target(target).load().migrate();}
}
