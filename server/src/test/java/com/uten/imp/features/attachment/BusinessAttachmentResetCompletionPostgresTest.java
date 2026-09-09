package com.uten.imp.features.attachment;

import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import java.nio.charset.StandardCharsets;
import java.sql.DriverManager;
import static org.assertj.core.api.Assertions.assertThat;

/** Exercises the exact production SQL predicate; full V537 migration and HTTP flow have a separate test. */
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
            st.execute("""
                    INSERT INTO attachments VALUES
                      ('00000000-0000-0000-0000-000000000001','SALES_ORDER','00000000-0000-0000-0000-000000000010','CLEAN','internal','contract','v1'),
                      ('00000000-0000-0000-0000-000000000002','EMPLOYEE','00000000-0000-0000-0000-000000000020','CLEAN','internal','human','h1');
                    """);
            assertThat(blockers(st)).isEqualTo(1);
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
            try(var result=st.executeQuery("SELECT lifecycle_state FROM attachments WHERE owner_type='EMPLOYEE'")){
                result.next();assertThat(result.getString(1)).isEqualTo("CLEAN");
            }
        }
    }
    private static long blockers(java.sql.Statement statement)throws Exception {
        try(var result=statement.executeQuery("SELECT count(*) FROM fn_business_attachment_reset_blockers()")){result.next();return result.getLong(1);}
    }
}
