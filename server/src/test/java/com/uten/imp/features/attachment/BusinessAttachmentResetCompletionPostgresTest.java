package com.uten.imp.features.attachment;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.nio.charset.StandardCharsets;
import java.sql.DriverManager;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Exercises the forward corrections (V539, V549) without changing the already-applied V537 migration.
 * V549 widens the protected owner set to GOODS; the Java constant must name the same set.
 */
@Testcontainers(disabledWithoutDocker=true)
class BusinessAttachmentResetCompletionPostgresTest {
    @Container static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    @Test void onlyCompletedExactPhysicalDeletionProofsPermitReset() throws Exception {
        try(var c=DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());var st=c.createStatement()) {
            st.execute("""
                    CREATE TABLE attachments(id UUID,owner_type TEXT,owner_id UUID,lifecycle_state TEXT,
                        storage_provider TEXT,storage_key TEXT,storage_version TEXT);
                    CREATE TABLE attachment_upload_sessions(id UUID,owner_type TEXT,owner_id UUID,status TEXT,
                        expires_at TIMESTAMPTZ,storage_provider TEXT,storage_key TEXT,staging_version TEXT,final_version TEXT,
                        last_failure_code TEXT);
                    CREATE TABLE attachment_object_outbox(id UUID,attachment_id UUID,upload_session_id UUID,
                        operation TEXT,storage_provider TEXT,storage_key TEXT,storage_version TEXT,status TEXT,completed_at TIMESTAMPTZ);
                    """);
            try(var input=getClass().getResourceAsStream("/db/migration/V537__business_attachment_reset_completion_proof.sql")){
                String migration=new String(input.readAllBytes(),StandardCharsets.UTF_8);
                st.execute(migration.substring(0,migration.indexOf("DO $reset_attachment_guard$")));
            }
            try(var input=getClass().getResourceAsStream("/db/migration/V539__attachment_reset_completion_guards_forward.sql")){
                assertThat(input).isNotNull();
                st.execute(new String(input.readAllBytes(),StandardCharsets.UTF_8));
            }
            String masterOwnerGuard;
            try(var input=getClass().getResourceAsStream("/db/migration/V549__attachment_reset_master_owner_guard.sql")){
                assertThat(input).isNotNull();
                masterOwnerGuard=new String(input.readAllBytes(),StandardCharsets.UTF_8);
                st.execute(masterOwnerGuard);
            }
            assertThat(protectedOwnerTypesIn(masterOwnerGuard))
                    .as("V549 protected owner set must equal BusinessAttachmentResetPreparation.PROTECTED_OWNER_TYPES")
                    .isEqualTo(new TreeSet<>(BusinessAttachmentResetPreparation.PROTECTED_OWNER_TYPES));
            st.execute("""
                    INSERT INTO attachments VALUES
                      ('00000000-0000-0000-0000-000000000001','SALES_ORDER','00000000-0000-0000-0000-000000000010','CLEAN','internal','contract','v1'),
                      ('00000000-0000-0000-0000-000000000002','EMPLOYEE','00000000-0000-0000-0000-000000000020','CLEAN','internal','human','h1'),
                      ('00000000-0000-0000-0000-00000000000a','GOODS','00000000-0000-0000-0000-0000000000a0','CLEAN','local','drawing','g1'),
                      ('00000000-0000-0000-0000-00000000000b',' goods ','00000000-0000-0000-0000-0000000000b0','CLEAN','oss','photo',NULL);
                    """);
            assertThat(blockers(st)).as("GOODS (any case/whitespace, any provider) is a preserved master owner").isEqualTo(1);
            st.execute("""
                    INSERT INTO attachment_upload_sessions VALUES('00000000-0000-0000-0000-00000000000c','GOODS',
                      '00000000-0000-0000-0000-0000000000a0','PENDING',now()+interval '1 hour','internal','drawing-upload','s1',NULL,NULL)
                    """);
            assertThat(blockers(st)).as("GOODS upload sessions are protected too").isEqualTo(1);
            st.execute("DELETE FROM attachment_upload_sessions WHERE owner_type='GOODS'");
            st.execute("UPDATE attachments SET lifecycle_state='DELETED' WHERE owner_type='SALES_ORDER'");
            assertThat(blockers(st)).as("DELETED without any deletion intention").isEqualTo(1);
            st.execute("""
                    INSERT INTO attachment_object_outbox VALUES('00000000-0000-0000-0000-000000000003',
                      '00000000-0000-0000-0000-000000000001',NULL,'DELETE_FINAL','internal','contract','v1','FAILED',NULL)
                    """);
            assertThat(blockers(st)).isPositive();
            st.execute("UPDATE attachment_object_outbox SET status='SUCCEEDED'");
            assertThat(blockers(st)).as("SUCCEEDED without completed_at is not proof").isPositive();
            st.execute("UPDATE attachment_object_outbox SET completed_at=now(),storage_provider='local'");
            assertThat(blockers(st)).as("another provider cannot discharge the original").isEqualTo(1);
            st.execute("UPDATE attachment_object_outbox SET storage_provider='internal',storage_version='wrong-version'");
            assertThat(blockers(st)).isEqualTo(1);
            st.execute("UPDATE attachment_object_outbox SET storage_version='v1'");
            assertThat(blockers(st)).isZero();
            st.execute("""
                    INSERT INTO attachment_upload_sessions VALUES('00000000-0000-0000-0000-000000000004','SALES_ORDER',
                      '00000000-0000-0000-0000-000000000010','PROMOTED',now()+interval '1 hour','internal','contract','v1','v1',NULL)
                    """);
            assertThat(blockers(st)).as("unexpired upload cannot be skipped").isEqualTo(1);
            st.execute("UPDATE attachment_upload_sessions SET expires_at=now()-interval '1 second'");
            assertThat(blockers(st)).as("staging deletion is still required").isEqualTo(1);
            st.execute("""
                    INSERT INTO attachment_object_outbox VALUES('00000000-0000-0000-0000-000000000005',NULL,
                      '00000000-0000-0000-0000-000000000004','DELETE_STAGING','internal','contract','v1','SUCCEEDED',now())
                    """);
            assertThat(blockers(st)).isZero();
            st.execute("""
                    INSERT INTO attachment_upload_sessions VALUES('00000000-0000-0000-0000-000000000006','SALES_ORDER',
                      '00000000-0000-0000-0000-000000000010','EXPIRED',now()-interval '1 second','internal','unconfirmed',NULL,NULL,'NO_STAGING_OBJECT')
                    """);
            assertThat(blockers(st)).as("NO_STAGING_OBJECT is not a final-object absence proof").isEqualTo(1);
            st.execute("""
                    INSERT INTO attachment_object_outbox VALUES
                      ('00000000-0000-0000-0000-000000000007',NULL,'00000000-0000-0000-0000-000000000006','DELETE_STAGING','internal','unconfirmed',NULL,'SUCCEEDED',now()),
                      ('00000000-0000-0000-0000-000000000008',NULL,'00000000-0000-0000-0000-000000000006','DELETE_FINAL','internal','unconfirmed',NULL,'SUCCEEDED',now())
                    """);
            assertThat(blockers(st)).isZero();
            st.execute("UPDATE attachment_upload_sessions SET staging_version='v2' WHERE id='00000000-0000-0000-0000-000000000004'");
            assertThat(blockers(st)).as("another staging version cannot prove deletion").isEqualTo(1);
            st.execute("UPDATE attachment_object_outbox SET storage_version='v2' WHERE id='00000000-0000-0000-0000-000000000005'");
            assertThat(blockers(st)).isZero();
            st.execute("""
                    INSERT INTO attachment_object_outbox VALUES
                      ('00000000-0000-0000-0000-000000000009',NULL,NULL,'DELETE_FINAL','internal','orphan','v1','SUCCEEDED',NULL)
                    """);
            assertThat(blockers(st)).as("an unlinked successful operation still needs its completion time").isEqualTo(1);
            st.execute("UPDATE attachment_object_outbox SET completed_at=now() WHERE id='00000000-0000-0000-0000-000000000009'");
            assertThat(blockers(st)).isZero();
            try(var result=st.executeQuery("SELECT lifecycle_state FROM attachments WHERE owner_type='EMPLOYEE'")){
                result.next();assertThat(result.getString(1)).isEqualTo("CLEAN");
            }
            try(var result=st.executeQuery("SELECT count(*) FROM attachments WHERE upper(btrim(owner_type))='GOODS' AND lifecycle_state='CLEAN'")){
                result.next();assertThat(result.getLong(1)).as("goods master attachments untouched").isEqualTo(2);
            }
        }
    }
    /** Every {@code upper(btrim(owner_type)) NOT IN (...)} list in the migration, as one normalized set. */
    private static Set<String> protectedOwnerTypesIn(String migration) {
        Matcher lists=Pattern.compile("upper\\(btrim\\(owner_type\\)\\) NOT IN \\(([^)]*)\\)").matcher(migration);
        Set<String> owners=null;
        while(lists.find()){
            Set<String> current=new TreeSet<>();
            Matcher names=Pattern.compile("'([^']+)'").matcher(lists.group(1));
            while(names.find()) current.add(names.group(1));
            if(owners==null) owners=current; else assertThat(current).as("both CTE guards share one set").isEqualTo(owners);
        }
        assertThat(owners).as("migration must declare the protected owner set").isNotNull();
        return owners;
    }
    private static long blockers(java.sql.Statement statement)throws Exception {
        try(var result=statement.executeQuery("SELECT count(*) FROM fn_business_attachment_reset_blockers()")){result.next();return result.getLong(1);}
    }
}
