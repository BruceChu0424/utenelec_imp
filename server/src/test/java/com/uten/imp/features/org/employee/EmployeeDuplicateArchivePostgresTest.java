package com.uten.imp.features.org.employee;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeDuplicateArchivePostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;
    JdbcTemplate db;
    TransactionTemplate transaction;
    UUID source,retained,actor;
    @BeforeEach void seed() throws Exception {
        database=com.uten.imp.support.HistoricalEmployeeSchema.openDatabase("employee_duplicate_archive");
        var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(ds);transaction=new TransactionTemplate(new JdbcTransactionManager(ds));
        source=historicalEmployee();retained=historicalEmployee();actor=UUID.randomUUID();
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash) VALUES(?,?,?,'test-only')",actor,employee(),"archive-reviewer-"+actor);
        com.uten.imp.support.HistoricalEmployeeSchema.upgradeToCurrent(database);
    }
    @AfterEach void stop() throws Exception {if(database!=null)database.close();}
    UUID historicalEmployee(){return employee("同名核验人员",UUID.randomUUID());}
    UUID employee(){
        UUID id=UUID.randomUUID();
        return employee(com.uten.imp.support.SyntheticEmployeeIdentity.name("其他核验人员",id),id);
    }
    UUID employee(String name,UUID id){
        db.update("""
          INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
          SELECT ?,?,?,'其他',department_id,DATE '2020-01-01','active','regular' FROM employees WHERE code='ADMIN'
          """,id,"D"+id.toString().replace("-","").substring(0,15),name);return id;
    }
    @Test void currentGuardRemainsActiveAfterPreGuardHistoryIsMigrated(){
        assertEquals(2,db.queryForObject("SELECT count(*) FROM employees WHERE full_name='同名核验人员'",Integer.class));
        assertThrows(RuntimeException.class,this::historicalEmployee);
        assertEquals(2,db.queryForObject("SELECT count(*) FROM employees WHERE full_name='同名核验人员'",Integer.class));
    }
    void bind(){db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());db.queryForObject("SELECT set_config('app.actor_account','duplicate-review-fixture',true)",String.class);}
    UUID archive(int version){return transaction.execute(status->{bind();return db.queryForObject("SELECT fn_archive_verified_employee_duplicate(?,?,?,0,'已核对原始证件和入职记录','test-reviewed-evidence')",UUID.class,source,retained,version);});}
    void document(UUID employee,String hash,String check){db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,'historical-private-cipher',?,?)",employee,check,hash);}
    @Test void archivePreservesRawHistoryAndCurrentRecordCanClaimItsOwnHistoricalDocument(){
        UUID event=UUID.randomUUID();String hash="fixture-"+source;
        document(source,hash,"unreadable");
        db.update("INSERT INTO employment_history(id,employee_id,event_type,event_date) VALUES(?,?,'onboard',DATE '2010-01-01')",event,source);
        String before=db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,source);
        assertEquals(retained,archive(0));
        assertEquals(true,db.queryForObject("SELECT is_deleted FROM employees WHERE id=?",Boolean.class,source));
        assertEquals(retained,new EmployeeIdentityDirectory(db).canonicalEmployeeId(source));
        assertEquals(source,db.queryForObject("SELECT employee_id FROM employment_history WHERE id=?",UUID.class,event));
        assertEquals(before,db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,source));
        document(retained,hash,"valid");
        UUID other=employee();assertThrows(RuntimeException.class,()->document(other,hash,"valid"));
        String correctedHash="corrected-"+retained;
        db.update("UPDATE employee_sensitive SET id_card_hash=?,id_card_enc='corrected-current-cipher' WHERE employee_id=?",correctedHash,retained);
        assertThrows(RuntimeException.class,()->document(other,hash,"valid"));
        assertThrows(RuntimeException.class,()->document(other,correctedHash,"valid"));
        assertEquals(before,db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,source));
    }
    @Test void sameNameWithDifferentVerifiedDocumentsCannotBeArchived(){
        document(source,"source-"+source,"valid");document(retained,"retained-"+retained,"valid");
        assertThrows(RuntimeException.class,()->archive(0));
        assertEquals(false,db.queryForObject("SELECT is_deleted FROM employees WHERE id=?",Boolean.class,source));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM employee_identity_aliases WHERE alias_employee_id=?",Integer.class,source));
    }
    @Test void liveAccountAndStaleVersionsAreRejectedWithoutPartialArchive(){
        assertThrows(RuntimeException.class,()->archive(1));
        db.update("INSERT INTO users(employee_id,login_account,password_hash) VALUES(?,?,'test-only')",source,"dup-"+source);
        assertThrows(RuntimeException.class,()->archive(0));
        assertEquals(false,db.queryForObject("SELECT is_deleted FROM employees WHERE id=?",Boolean.class,source));
    }
    @Test void noActorCannotArchiveAndEveryArchiveHasPermanentEvidence(){
        assertThrows(RuntimeException.class,()->db.queryForObject("SELECT fn_archive_verified_employee_duplicate(?,?,0,0,'已核验证件和工号','review')",UUID.class,source,retained));
        archive(0);
        assertEquals(actor,db.queryForObject("SELECT created_by FROM employee_identity_aliases WHERE alias_employee_id=?",UUID.class,source));
        assertThrows(RuntimeException.class,()->db.update("DELETE FROM employee_identity_aliases WHERE alias_employee_id=?",source));
    }
    @Test void originalDocumentReviewUnblocksMisrecordedButFormatValidHistoricalNumbers(){
        document(source,"source-"+source,"valid");document(retained,"retained-"+retained,"valid");
        assertThrows(RuntimeException.class,()->archive(0));
        String before=db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,source);
        UUID archived=transaction.execute(status->{bind();return db.queryForObject("SELECT fn_archive_verified_employee_duplicate(?,?,0,0,'已对照原件确认旧档误录正确格式的他人号码','explicit-conflict-review',true)",UUID.class,source,retained);});
        assertEquals(retained,archived);
        assertEquals(before,db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,source));
        assertTrue(db.queryForObject("SELECT evidence_reference FROM employee_identity_aliases WHERE alias_employee_id=?",String.class,source).endsWith("#document-conflict-verified"));
    }
    @Test void concurrentDifferentPeopleCannotClaimTheSameDocumentAfterWaitingForHashLock() throws Exception {
        concurrentClaim(java.sql.Connection.TRANSACTION_READ_COMMITTED,"23505");
    }
    @Test void repeatableReadSnapshotCannotBypassTheIdentityClaimPrimaryKey() throws Exception {
        concurrentClaim(java.sql.Connection.TRANSACTION_REPEATABLE_READ,"40001");
    }
    private void concurrentClaim(int isolation,String expectedFailure) throws Exception {
        String hash="concurrent-"+source;
        try(var first=database.openConnection();var second=database.openConnection();var executor=java.util.concurrent.Executors.newSingleThreadExecutor()) {
            first.setAutoCommit(false);second.setAutoCommit(false);
            second.setTransactionIsolation(isolation);
            try(var q=second.createStatement();var rs=q.executeQuery("SELECT count(*) FROM employee_identity_document_claims")){rs.next();}
            try(var insert=first.prepareStatement("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,'cipher','valid',?)")) {
                insert.setObject(1,source);insert.setString(2,hash);insert.executeUpdate();
            }
            int pid;
            try(var query=second.createStatement();var rs=query.executeQuery("SELECT pg_backend_pid()")){rs.next();pid=rs.getInt(1);}
            var waiting=executor.submit(()->{
                try(var insert=second.prepareStatement("INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,id_card_hash) VALUES(?,'cipher','valid',?)")){
                    insert.setObject(1,retained);insert.setString(2,hash);insert.executeUpdate();second.commit();return "committed";
                }catch(java.sql.SQLException rejected){second.rollback();return rejected.getSQLState();}
            });
            awaitLock(pid);
            first.commit();
            assertEquals(expectedFailure,waiting.get(20,java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(1,db.queryForObject("SELECT count(*) FROM employee_sensitive WHERE id_card_hash=?",Integer.class,hash));
        }
    }
    @Test void accountCreationWaitsForArchiveAndCannotBindToTheArchivedAlias() throws Exception {
        try(var first=database.openConnection();var second=database.openConnection();var executor=java.util.concurrent.Executors.newSingleThreadExecutor()) {
            first.setAutoCommit(false);second.setAutoCommit(false);
            try(var bind=first.prepareStatement("SELECT set_config('app.actor_id',?,true),set_config('app.actor_account','fixture',true)")){bind.setString(1,actor.toString());bind.execute();}
            try(var archive=first.prepareStatement("SELECT fn_archive_verified_employee_duplicate(?,?,0,0,'已核对原始证件和入职记录','concurrent-evidence')")){archive.setObject(1,source);archive.setObject(2,retained);archive.execute();}
            int pid;try(var query=second.createStatement();var rs=query.executeQuery("SELECT pg_backend_pid()")){rs.next();pid=rs.getInt(1);}
            var waiting=executor.submit(()->{
                try(var insert=second.prepareStatement("INSERT INTO users(employee_id,login_account,password_hash) VALUES(?,?,'test-only')")){
                    insert.setObject(1,source);insert.setString(2,"racing-"+source);insert.executeUpdate();second.commit();return "committed";
                }catch(java.sql.SQLException rejected){second.rollback();return rejected.getSQLState();}
            });
            awaitLock(pid);first.commit();
            assertEquals("23514",waiting.get(20,java.util.concurrent.TimeUnit.SECONDS));
            assertEquals(0,db.queryForObject("SELECT count(*) FROM users WHERE employee_id=?",Integer.class,source));
        }
    }
    private void awaitLock(int pid) throws Exception {
        long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(10);
        while(System.nanoTime()<deadline){
            if(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND wait_event_type='Lock')",Boolean.class,pid)))return;
            Thread.sleep(20);
        }
        fail("the second writer did not wait on the real database lock");
    }
}
