package com.uten.imp.features.attachment;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;
import java.sql.DriverManager;
import java.nio.charset.StandardCharsets;
import static org.assertj.core.api.Assertions.*;

/** Exact old protected SQL -> new783 function semantics, independent of Root's complete real-copy reset rehearsal. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MasterStagingProtectionForwardPostgresTest {
    @Test void allMasterFamiliesProtectStagingDifferentVersionsButFinalStillRequiresItsOwnIdentity()throws Exception {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();try(var connection=DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword());var sql=connection.createStatement()) {
                setup(sql);old(sql);
                sql.execute("INSERT INTO attachments VALUES('GOODS','internal','goods-key','final-g'),('EMPLOYEE','internal','person-key','final-e'),('EMPLOYEE_CONTRACT','internal','contract-key','final-c'); INSERT INTO sales_quote_template_versions VALUES('internal','template-key','final-t'); INSERT INTO goods_cost_imports VALUES('internal','cost-key','final-cost')");
                for(String key:new String[]{"goods-key","person-key","contract-key","template-key","cost-key"})assertThat(protectedObject(sql,"internal","STAGING",key,"different-staging")).isFalse();
                forward(sql);
                for(String key:new String[]{"goods-key","person-key","contract-key","template-key","cost-key"}) {
                    assertThat(protectedObject(sql,"internal","STAGING",key,"different-staging")).isTrue();
                    assertThat(protectedObject(sql,"internal","FINAL",key,"different-final")).isFalse();
                    assertThat(protectedObject(sql,"local","STAGING",key,"different-staging")).isFalse();
                }
                assertThat(protectedObject(sql,"internal","FINAL","cost-key","final-cost")).isTrue();
                assertThat(protectedObject(sql,"internal","STAGING","unclassified-key","any")).isFalse();
                sql.execute("INSERT INTO goods_cost_imports VALUES('internal','legacy-cost',NULL),('legacy_unknown','uncertain-cost',NULL)");
                assertThat(protectedObject(sql,"internal","FINAL","legacy-cost","any")).isTrue();assertThat(protectedObject(sql,"internal","STAGING","uncertain-cost","any")).isTrue();
            }
        }
    }
    @Test void completedMasterStagingFactIsPreservedAndUnknownSuccessfulTaskIsNotExempted()throws Exception {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();try(var connection=DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword());var sql=connection.createStatement()) {
                setup(sql);old(sql);
                sql.execute("INSERT INTO goods_cost_imports VALUES('local','master-original',NULL); INSERT INTO attachment_object_outbox VALUES('11111111-1111-1111-1111-111111111111','DELETE_STAGING','local','master-original',NULL,'SUCCEEDED','permanent-master-fact','UNKNOWN',NULL),('22222222-2222-2222-2222-222222222222','DELETE_STAGING','local','unknown-key',NULL,'SUCCEEDED','unknown-fact','UNKNOWN',NULL)");
                assertThat(protectedObject(sql,"local","STAGING","master-original",null)).isFalse();forward(sql);
                String before;try(var row=sql.executeQuery("SELECT to_jsonb(o)::text FROM attachment_object_outbox o WHERE storage_key='master-original'")){row.next();before=row.getString(1);}
                assertThat(protectedObject(sql,"local","STAGING","master-original",null)).isTrue();assertThat(protectedObject(sql,"local","STAGING","unknown-key",null)).isFalse();
                // Execute only the fixed mixed metadata helper: actual auth/full-reset/byte proof is exercised by Root's copy test.
                sql.execute("SELECT fn_clear_business_test_object_metadata()");
                try(var row=sql.executeQuery("SELECT to_jsonb(o)::text FROM attachment_object_outbox o WHERE storage_key='master-original'")){assertThat(row.next()).isTrue();assertThat(row.getString(1)).isEqualTo(before);}
            }
        }
    }
    @Test void knownBusinessQueueMetadataRetiresWithoutRestrictFailureWhileSharedMasterIsProtected()throws Exception {
        try(var database=new PostgreSQLContainer<>("postgres:16-alpine")) {
            database.start();try(var connection=DriverManager.getConnection(database.getJdbcUrl(),database.getUsername(),database.getPassword());var sql=connection.createStatement()) {
                setup(sql);old(sql);forward(sql);
                sql.execute("INSERT INTO goods_cost_imports VALUES('local','shared-master',NULL); INSERT INTO business_parent VALUES('33333333-3333-3333-3333-333333333333'); INSERT INTO attachment_object_outbox VALUES('44444444-4444-4444-4444-444444444444','DELETE_STAGING','local','shared-master',NULL,'SUCCEEDED','business-task','SALES_QUOTE','33333333-3333-3333-3333-333333333333')");
                assertThat(protectedObject(sql,"local","STAGING","shared-master",null)).isTrue();
                sql.execute("SELECT fn_clear_business_test_object_metadata()");
                try(var result=sql.executeQuery("SELECT count(*) FROM business_parent")){result.next();assertThat(result.getLong(1)).isZero();}
                try(var result=sql.executeQuery("SELECT count(*) FROM attachment_object_outbox")){result.next();assertThat(result.getLong(1)).isZero();}
                try(var result=sql.executeQuery("SELECT count(*) FROM goods_cost_imports")){result.next();assertThat(result.getLong(1)).isEqualTo(1);}
            }
        }
    }
    private void setup(java.sql.Statement sql)throws Exception {
        sql.execute("CREATE TABLE attachments(owner_type text,storage_provider text,storage_key text,storage_version text); CREATE TABLE attachment_upload_sessions(owner_type text,storage_provider text,storage_key text); CREATE TABLE sales_quote_template_versions(storage_provider text,storage_key text,storage_version text); CREATE TABLE goods_cost_imports(storage_provider text,storage_key text,storage_version text); CREATE TABLE business_parent(id uuid PRIMARY KEY); CREATE TABLE attachment_object_outbox(id uuid,operation text,storage_provider text,storage_key text,storage_version text,status text,history_note text,owner_type text,parent_id uuid REFERENCES business_parent(id) ON DELETE RESTRICT); CREATE VIEW v_business_test_object_sources AS SELECT 'DELETE_OPERATION'::text source_type,id::text source_id,owner_type FROM attachment_object_outbox");
        sql.execute("CREATE FUNCTION fn_clear_business_test_object_metadata() RETURNS void LANGUAGE plpgsql AS $f$ BEGIN DELETE FROM public.attachment_object_outbox operation WHERE EXISTS(SELECT 1 FROM v_business_test_object_sources s WHERE s.source_type='DELETE_OPERATION' AND s.source_id=operation.id::text); DELETE FROM business_parent; END $f$");
    }
    private void old(java.sql.Statement sql)throws Exception {
        try(var input=getClass().getResourceAsStream("/db/migration/V782__explicit_test_business_reset_with_history.sql")) {
            assertThat(input).isNotNull();String source=new String(input.readAllBytes(),StandardCharsets.UTF_8);int start=source.indexOf("CREATE FUNCTION public.fn_business_test_object_protected(");int end=source.indexOf("CREATE FUNCTION public.fn_business_test_object_sources()",start);
            assertThat(start).isGreaterThanOrEqualTo(0);assertThat(end).isGreaterThan(start);sql.execute(source.substring(start,end));
        }
    }
    private void forward(java.sql.Statement sql)throws Exception {try(var input=getClass().getResourceAsStream("/db/migration/V783__protect_master_staging_cleanup_lineage.sql")){assertThat(input).isNotNull();sql.execute(new String(input.readAllBytes(),StandardCharsets.UTF_8));}}
    private boolean protectedObject(java.sql.Statement sql,String provider,String location,String key,String version)throws Exception {
        String query="SELECT fn_business_test_object_protected('"+provider+"','"+location+"','"+key+"',"+(version==null?"NULL":"'"+version+"'")+")";
        try(var result=sql.executeQuery(query)){assertThat(result.next()).isTrue();return result.getBoolean(1);}
    }
}
