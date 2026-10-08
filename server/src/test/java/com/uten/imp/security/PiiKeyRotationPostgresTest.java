package com.uten.imp.security;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Migrated PostgreSQL, real pgcrypto and row locks. No production connection or data. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class PiiKeyRotationPostgresTest {
    private static final String OLD_KEY="test-only-pgp-previous-key-0123456789abcdef";
    private static final String NEW_KEY="test-only-pgp-current-key-9876543210abcdef";
    private MigratedSchemaBaseline.ScopedDatabase lease;
    private JdbcTemplate db;
    private TransactionTemplate transaction;
    private PiiKeyRotationService service;
    private PiiCipherRewrapper cipher;
    private CryptoProperties keys;
    private UUID employee;

    @BeforeEach void open() throws Exception {
        lease=MigratedSchemaBaseline.openDatabase("pii_rotation");
        var dataSource=new DriverManagerDataSource(lease.getJdbcUrl(),lease.getUsername(),lease.getPassword());
        var connectionProperties=new java.util.Properties();
        connectionProperties.setProperty("options","-c log_parameter_max_length=0 -c log_parameter_max_length_on_error=0");
        dataSource.setConnectionProperties(connectionProperties);
        db=new JdbcTemplate(dataSource);transaction=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        UUID department=UUID.randomUUID(),actorId=UUID.randomUUID();employee=UUID.randomUUID();
        String tag=UUID.randomUUID().toString().substring(0,8);
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",department,"PR-"+tag,"rotation test");
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')
                """,employee,"PR-E-"+tag,"rotation actor",department);
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password,is_super_admin)
                VALUES(?,?,?,'test-only','active',FALSE,TRUE)
                """,actorId,employee,"rotation-"+tag);
        keys=new CryptoProperties();keys.setPgpKeyVersion("2");keys.setPgpMasterKey(NEW_KEY);keys.setPgpLegacyKeys(Map.of("1",OLD_KEY));
        cipher=new PiiCipherRewrapper(db,keys);
        var user=mock(SecurityContextCurrentUser.class);
        when(user.get()).thenReturn(Optional.of(new AuthUser(actorId,employee,"rotation-"+tag,
                Set.of("pii_key_rotation:manage"),false,true,true)));
        var tx=mock(TxSessionVars.class);
        doAnswer(call->{db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actorId.toString());return null;}).when(tx).bind();
        doAnswer(call->{db.queryForObject("SELECT set_config('app.profile_change_snapshot_codec','v1',true)",String.class);return null;})
                .when(tx).bindProfileChangeSnapshotCodecV1();
        service=new PiiKeyRotationService(db,cipher,user,tx,mock(AuditService.class),true,"local");
    }
    @AfterEach void close() throws Exception { if(lease!=null)lease.close(); }

    @Test void allPgpFieldsAreCataloguedAndFinancialOrAuditTablesAreExcluded() {
        Set<String> expected=new HashSet<>(db.queryForList("""
                SELECT table_name||'.'||column_name FROM information_schema.columns
                WHERE table_schema='public' AND right(column_name,4)='_enc'
                """,String.class));
        Set<String> actual=new HashSet<>();
        for(var target:PiiRotationCatalog.TARGETS)for(var column:target.columns())actual.add(target.table()+"."+column);
        assertEquals(expected,actual,"a new PGP column needs an explicit rotation and domain policy");
        assertEquals(27,actual.size());
        assertTrue(PiiRotationCatalog.TARGETS.stream().noneMatch(target->target.table().contains("audit")||target.table().contains("payroll")));
    }

    @Test void encryptedAndUnversionedValuesKeepTheirExactContentWhileCurrentCipherKeepsItsBytes() {
        String plain="测试内容\n  全角：🙂\tend ";
        String old=encrypt(plain,OLD_KEY);
        var converted=transaction.execute(status->cipher.rewrap("1:"+old,""));
        assertNotNull(converted);assertTrue(converted.changed());assertEquals(plain,decrypt(converted.cipher(),NEW_KEY));
        var unversioned=transaction.execute(status->cipher.rewrap(old,""));
        assertEquals(plain,decrypt(unversioned.cipher(),NEW_KEY));
        var unchanged=transaction.execute(status->cipher.rewrap(converted.cipher(),""));
        assertFalse(unchanged.changed());assertEquals(converted.cipher(),unchanged.cipher());
        assertThrows(IllegalStateException.class,()->transaction.execute(status->
                cipher.rewrap("1:"+old,"uten-profile-change-snapshot:v1:")),
                "ordinary ciphertext is not an approval snapshot even when its key is valid");
        keys.setPgpMasterKey(OLD_KEY);
        assertThrows(IllegalStateException.class,()->transaction.execute(status->cipher.rewrap(converted.cipher(),"")),
                "same-version key replacement must not be silently accepted");
    }

    @Test void unsafeDatabaseParameterLoggingBlocksBeforeCryptoAndCheckpointWrites() {
        UUID run=UUID.randomUUID();
        assertThrows(ApiException.class,()->transaction.execute(status->{
            db.queryForObject("SELECT set_config('log_parameter_max_length','-1',true)",String.class);
            return service.batch(run,"2",0,100);
        }));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM pii_key_rotation_runs WHERE id=?",Integer.class,run));
    }

    @Test void resumeReplaySnapshotDomainAndLateLegacyWritesRemainVisible() {
        String old="1:"+encrypt("private sample",OLD_KEY);
        db.update("INSERT INTO employee_sensitive(employee_id,email_enc) VALUES(?,?)",employee,old);
        UUID profile=UUID.randomUUID();String snapshot="1:"+encrypt("uten-profile-change-snapshot:v1:13800138000",OLD_KEY);
        transaction.executeWithoutResult(status->{
            db.queryForObject("SELECT set_config('app.profile_change_snapshot_codec','v1',true)",String.class);
            db.update("""
                    INSERT INTO profile_change_requests(id,employee_id,batch_id,field_code,field_label,field_group,
                        old_value_enc,new_value_enc,value_encoding,submitted_by,employee_version,idem_key)
                    VALUES(?,?,?,'phone','手机号','contact',?,?,'PGCRYPTO_V1',?,0,?)
                    """,profile,employee,UUID.randomUUID(),snapshot,snapshot,employee,UUID.randomUUID().toString());
        });
        String logicalBefore=db.queryForObject("SELECT (to_jsonb(p)-ARRAY['old_value_enc','new_value_enc','updated_at'])::text FROM profile_change_requests p WHERE id=?",String.class,profile);
        String auditBefore=db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id)::text,'[]') FROM audit_log a",String.class);
        long auditHigh=db.queryForObject("SELECT COALESCE(max(id),0) FROM audit_log",Long.class);
        UUID run=UUID.randomUUID();var first=batch(run,0,1);
        assertEquals(1,first.verifiedRows());assertEquals(1,first.rewrappedCells());
        String firstCipher=db.queryForObject("SELECT email_enc FROM employee_sensitive WHERE employee_id=?",String.class,employee);
        var replay=batch(run,0,1);assertEquals(first.nextSequence(),replay.nextSequence());
        assertEquals(firstCipher,db.queryForObject("SELECT email_enc FROM employee_sensitive WHERE employee_id=?",String.class,employee));
        var finished=finish(run,first.nextSequence());
        assertEquals("SCANNED",finished.status());assertFalse(finished.canRemoveOldKeys());assertTrue(finished.remainingByVersion().isEmpty());
        assertEquals(logicalBefore,db.queryForObject("SELECT (to_jsonb(p)-ARRAY['old_value_enc','new_value_enc','updated_at'])::text FROM profile_change_requests p WHERE id=?",String.class,profile));
        assertEquals("uten-profile-change-snapshot:v1:13800138000",decrypt(db.queryForObject("SELECT new_value_enc FROM profile_change_requests WHERE id=?",String.class,profile),NEW_KEY));
        assertEquals(auditBefore,db.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id)::text,'[]') FROM audit_log a WHERE id<=?",String.class,auditHigh));
        db.update("UPDATE employee_sensitive SET email_enc=? WHERE employee_id=?",old,employee);
        var late=transaction.execute(status->service.status(run));
        assertEquals("RESCAN_REQUIRED",late.status());assertEquals(1L,late.remainingByVersion().get("1"));
        assertFalse(late.canRemoveOldKeys());
    }

    @Test void unknownOrCorruptCipherRollsBackTheWholeBatchAndCheckpointThenCanResume() {
        String original="1:"+encrypt("original",OLD_KEY);
        db.update("INSERT INTO employee_sensitive(employee_id,email_enc,office_phone_enc) VALUES(?,?,?)",employee,original,"9:unreadable-test-only");
        UUID run=UUID.randomUUID();assertThrows(ApiException.class,()->batch(run,0,100));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM pii_key_rotation_runs WHERE id=?",Integer.class,run));
        assertEquals(original,db.queryForObject("SELECT email_enc FROM employee_sensitive WHERE employee_id=?",String.class,employee));
        db.update("UPDATE employee_sensitive SET office_phone_enc=? WHERE employee_id=?","1:broken-test-only",employee);
        assertThrows(ApiException.class,()->batch(run,0,100));
        db.update("UPDATE employee_sensitive SET office_phone_enc=? WHERE employee_id=?",original,employee);
        assertEquals("SCANNED",finish(run,0).status());
    }

    @Test void aConcurrentBusinessUpdateIsReadAfterTheRowLockWait() throws Exception {
        db.update("INSERT INTO employee_sensitive(employee_id,email_enc) VALUES(?,?)",employee,"1:"+encrypt("before",OLD_KEY));
        CountDownLatch locked=new CountDownLatch(1),release=new CountDownLatch(1);
        try(var executor=Executors.newFixedThreadPool(2)) {
            var writer=executor.submit(()->transaction.executeWithoutResult(status->{
                db.queryForObject("SELECT employee_id FROM employee_sensitive WHERE employee_id=? FOR UPDATE",UUID.class,employee);
                locked.countDown();try {assertTrue(release.await(5,TimeUnit.SECONDS));}catch(InterruptedException error){throw new RuntimeException(error);}
                db.update("UPDATE employee_sensitive SET email_enc=? WHERE employee_id=?","1:"+encrypt("business update",OLD_KEY),employee);
            }));
            assertTrue(locked.await(5,TimeUnit.SECONDS));
            var rotation=executor.submit(()->batch(UUID.randomUUID(),0,100));
            Thread.sleep(100);assertFalse(rotation.isDone());release.countDown();
            writer.get(10,TimeUnit.SECONDS);rotation.get(10,TimeUnit.SECONDS);
            assertEquals("business update",decrypt(db.queryForObject("SELECT email_enc FROM employee_sensitive WHERE employee_id=?",String.class,employee),NEW_KEY));
        } finally { release.countDown(); }
    }

    private PiiKeyRotationService.Progress batch(UUID run,long sequence,int limit){return transaction.execute(status->service.batch(run,"2",sequence,limit));}
    private PiiKeyRotationService.Progress finish(UUID run,long sequence) {
        for(int attempt=0;attempt<20;attempt++) {
            var result=batch(run,sequence,100);
            if(!"RUNNING".equals(result.status()))return result;
            sequence=result.nextSequence();
        }
        throw new AssertionError("rotation did not finish within its bounded table passes");
    }
    private String encrypt(String plain,String key){return db.queryForObject("SELECT encode(pgp_sym_encrypt(?,?),'base64')",String.class,plain,key);}
    private String decrypt(String stored,String key){return db.queryForObject("SELECT pgp_sym_decrypt(decode(?,'base64'),?)",String.class,stored.substring(stored.indexOf(':')+1),key);}
}
