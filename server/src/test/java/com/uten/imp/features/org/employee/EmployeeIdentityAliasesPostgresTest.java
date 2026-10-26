package com.uten.imp.features.org.employee;

import com.uten.imp.audit.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.support.JdbcTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.mock;

/** Real V937 guards and the same organization read port used by HR and audit. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeIdentityAliasesPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate db;
    static TransactionTemplate transaction;
    static EntityManagerFactory factory;
    EmployeeIdentityDirectory directory;
    UUID canonical,alias,second;

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("employee_identity_aliases");
        var dataSource=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(dataSource); transaction=new TransactionTemplate(new JdbcTransactionManager(dataSource));
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(dataSource);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none"));bean.afterPropertiesSet();factory=bean.getObject();
    }
    @AfterAll static void stop() throws Exception {if(factory!=null)factory.close();if(database!=null)database.close();}
    @BeforeEach void seed() {
        directory=new EmployeeIdentityDirectory(db);
        canonical=employee(false);alias=employee(true);second=employee(true);
    }
    UUID employee(boolean archived) {
        UUID id=UUID.randomUUID();
        int created=db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted)
                SELECT ?,?,'同名测试员工','其他',department_id,DATE '2020-01-01','active','regular',?
                FROM employees WHERE code='ADMIN'
                """,id,"I"+id.toString().replace("-", "").substring(0,15),archived);
        assertEquals(1,created);return id;
    }
    void verified(UUID source,UUID target) {
        transaction.executeWithoutResult(ignored -> {
            db.queryForObject("SELECT set_config('app.actor_account','identity-fixture',true)",String.class);
            db.queryForObject("SELECT set_config('app.employee_identity_merge_evidence','verified-fixture',true)",String.class);
            db.update("INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference) VALUES(?,?,'核验证据一致','verified-fixture')",source,target);
        });
    }
    @Test void verifiedMembersPreserveRawPiiEducationAndHistoryKeys() {
        UUID education=UUID.randomUUID(),event=UUID.randomUUID();
        String retainedHash=alias.toString().replace("-","").repeat(2);
        db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,phone_enc,id_card_check,id_card_hash) VALUES(?,'archived-private-cipher','archived-phone-cipher','unreadable',?)",alias,retainedHash);
        db.update("INSERT INTO employee_education(id,employee_id,school) VALUES(?,?,'原历史学校')",education,alias);
        db.update("INSERT INTO employment_history(id,employee_id,event_type,event_date) VALUES(?,?,'onboard',DATE '2010-01-01')",event,alias);
        String before=db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,alias);
        verified(alias,canonical);verified(second,canonical);
        assertEquals(canonical,directory.canonicalEmployeeId(alias));
        assertEquals(Set.of(canonical,alias,second),Set.copyOf(directory.employeeIdentityMembers(second)));
        assertEquals(before,db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,alias));
        assertEquals(alias,db.queryForObject("SELECT employee_id FROM employee_education WHERE id=?",UUID.class,education));
        assertEquals(alias,db.queryForObject("SELECT employee_id FROM employment_history WHERE id=?",UUID.class,event));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?",Integer.class,canonical));
        // Alias verification does not declare the old document number correct or relax global uniqueness.
        assertThrows(RuntimeException.class,()->db.update("INSERT INTO employee_sensitive(employee_id,id_card_enc,phone_enc,id_card_check,id_card_hash) VALUES(?,'new-cipher','new-phone','unchecked',?)",canonical,retainedHash));
        assertEquals(before,db.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,alias));
        try(var em=factory.createEntityManager()) {
            var repository=new org.springframework.data.jpa.repository.support.JpaRepositoryFactory(em)
                    .getRepository(EmployeeSensitiveRepository.class);
            var tx=mock(com.uten.imp.security.TxSessionVars.class);
            org.mockito.Mockito.when(tx.hmac("fixture-document")).thenReturn(retainedHash);
            var writer=new EmployeePiiWriter(tx,repository);writer.setEmployeeIdentities(directory);
            var error=assertThrows(com.uten.imp.common.web.ApiException.class,
                    ()->writer.applyIdentity(new EmployeeSensitive(),canonical,"护照","fixture-document"));
            assertEquals(com.uten.imp.common.web.ErrorCode.CONFLICT,error.getCode());
            assertEquals(EmployeePiiWriter.HISTORICAL_IDENTITY_MESSAGE,error.getMessage());
            UUID anotherPerson=employee(false);
            var crossPerson=assertThrows(com.uten.imp.common.web.ApiException.class,
                    ()->writer.applyIdentity(new EmployeeSensitive(),anotherPerson,"护照","fixture-document"));
            assertEquals(EmployeePiiWriter.DUPLICATE_IDENTITY_MESSAGE,crossPerson.getMessage());
            org.mockito.Mockito.verify(tx,org.mockito.Mockito.never()).encrypt(org.mockito.ArgumentMatchers.anyString());
        }
    }
    @Test void displayNameAloneAndAliasChainsNeverCreateIdentityMembership() {
        assertEquals(List.of(alias),directory.employeeIdentityMembers(alias));
        assertThrows(RuntimeException.class,()->db.update("INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference) VALUES(?,?,'同名','verified-fixture')",alias,canonical));
        verified(alias,canonical);
        assertThrows(RuntimeException.class,()->verified(second,alias));
        assertThrows(RuntimeException.class,()->verified(canonical,second));
    }
    @Test void aliasesCannotBeRevivedOrReboundAndCanonicalIdentityCannotBeArchived() {
        verified(alias,canonical);
        assertThrows(RuntimeException.class,()->db.update("UPDATE employees SET is_deleted=false WHERE id=?",alias));
        assertThrows(RuntimeException.class,()->db.update("UPDATE employees SET is_deleted=true WHERE id=?",canonical));
        assertThrows(RuntimeException.class,()->db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted) VALUES(?,?,?,'fixture-password-hash','disabled',false)",UUID.randomUUID(),alias,"identity-"+UUID.randomUUID()));
        assertEquals(Boolean.TRUE,db.queryForObject("SELECT is_deleted FROM employees WHERE id=?",Boolean.class,alias));
        assertEquals(Boolean.FALSE,db.queryForObject("SELECT is_deleted FROM employees WHERE id=?",Boolean.class,canonical));
    }
    @Test void evidenceRowsAreAppendOnlyAndAccountBoundEmployeesCannotBecomeAliases() {
        UUID live=employee(false);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,is_deleted) VALUES(?,?,?,'fixture-password-hash','disabled',false)",UUID.randomUUID(),live,"identity-"+UUID.randomUUID());
        db.update("UPDATE employees SET is_deleted=true WHERE id=?",live);
        assertThrows(RuntimeException.class,()->verified(live,canonical));
        verified(alias,canonical);
        assertThrows(RuntimeException.class,()->db.update("UPDATE employee_identity_aliases SET reason='改写证据' WHERE alias_employee_id=?",alias));
        assertThrows(RuntimeException.class,()->db.update("DELETE FROM employee_identity_aliases WHERE alias_employee_id=?",alias));
        assertThrows(RuntimeException.class,()->db.execute("TRUNCATE employee_identity_aliases"));
        assertNull(db.queryForObject("SELECT to_regprocedure('public.fn_business_reset_table_policy()')::text",String.class));
    }
    @Test void auditEmployeeTargetProjectionExpandsAliasesWithoutRewritingActorOrRawTargets() {
        verified(alias,canonical);verified(second,canonical); UUID actor=UUID.randomUUID(),other=UUID.randomUUID();
        // Mirror the server's actual historical type mixture: employee=5, employees=3, sensitive=2.
        for(int i=0;i<5;i++) audit(i<2?actor:other,"employee",List.of(canonical,alias,second).get(i%3));
        for(int i=0;i<3;i++) audit(i==0?actor:other,"employees",List.of(canonical,alias,second).get(i));
        audit(actor,"employee_sensitive",alias);audit(other,"employee_sensitive",canonical);
        audit(other,"goods",alias); // Same UUID in another domain must not expand.
        audit(other,"employee_compensation",alias);
        audit(other,"employees",UUID.randomUUID()); // Outside this verified identity.
        var service=new AuditQueryService(mock(AuditLogRepository.class),new AuditEventInterpreter(),mock(AuditActorDirectory.class),null,directory);
        assertEquals(8,auditRows(service,"employee",canonical,null).size());
        assertEquals(8,auditRows(service,"employees",canonical,null).size());
        assertEquals(8,auditRows(service,"api/employees",canonical,null).size());
        var privateRows=auditRows(service,"employee_sensitive",canonical,null);
        assertEquals(2,privateRows.size());assertTrue(privateRows.stream().allMatch(row->row.getTargetType().equals("employee_sensitive")));
        var rows=new ArrayList<>(auditRows(service,"employees",canonical,actor));
        rows.addAll(auditRows(service,"employee_sensitive",canonical,actor));
        assertEquals(4,rows.size());assertTrue(rows.stream().allMatch(row->actor.equals(row.getActorId())));
        assertTrue(rows.stream().anyMatch(row->row.getTargetId().equals(alias.toString())));
        assertEquals(0,auditRows(service,"goods",canonical,null).size());
        assertEquals(1,auditRows(service,"employee_compensation",canonical,null).size());
    }
    void audit(UUID actor,String type,UUID target) {
        db.update("INSERT INTO audit_log(actor_id,actor_account,action,target_type,target_id,event_source,result,risk_level,event_category) VALUES(?,'identity-fixture','identity_projection',?,?,'business','success','low','business')",actor,type,target.toString());
    }
    List<AuditLog> auditRows(AuditQueryService service,String type,UUID target,UUID actor) {
        var criteria=new AuditSearchCriteria("identity_projection",null,null,null,null,null,null,type,target.toString(),null,null,null,null,null,null,actor,false);
        @SuppressWarnings("unchecked") Specification<AuditLog> spec=ReflectionTestUtils.invokeMethod(service,"specification",criteria);
        try(var em=factory.createEntityManager()) {
            var cb=em.getCriteriaBuilder();var query=cb.createQuery(AuditLog.class);var root=query.from(AuditLog.class);
            query.where(spec.toPredicate(root,query,cb));return em.createQuery(query).getResultList();
        }
    }
}
