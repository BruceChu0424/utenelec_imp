package com.uten.imp.features.companyfiles;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.PermissionDelegationPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.testsupport.TestFlyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Applies only the forward upgrade to nonempty V930 history, using private databases. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CompanyFileEntryMigrationPostgresTest {
    static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine");
    static DriverManagerDataSource source;
    static JdbcTemplate db;
    static UUID actor=UUID.randomUUID(),employee=UUID.randomUUID(),folder=UUID.randomUUID(),root=UUID.randomUUID(),child=UUID.randomUUID();
    static String folderFacts;
    static final String HASH=new org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder(12).encode("legacy-folder-password");
    @BeforeAll static void history() {
        POSTGRES.start();
        source=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());db=new JdbcTemplate(source);
        TestFlyway.configure().dataSource(source).locations("classpath:db/migration").target("930").load().migrate();
        com.uten.imp.support.HistoricalPermissionReaderSources.install(db);
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'迁移验证人','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"MIG-"+employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",actor,employee,"upgrade-"+actor);
        db.update("INSERT INTO company_file_nodes(id,kind,name,password_hash,password_revision,created_by,updated_by) VALUES(?,'FOLDER',?,?,7,?,?)",folder,"old-protected-folder",HASH,actor,actor);
        folderFacts=facts();
        db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code='company_file:view'",actor);
        db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",root,"MIG-"+root,"迁移独立部门");
        db.update("INSERT INTO departments(id,parent_id,code,name,level) VALUES(?,?,?,?,'二级班组')",child,root,"MIG-"+child,"迁移独立下级");
        assertThatThrownBy(()->pendingPassword(db)).isInstanceOf(DataIntegrityViolationException.class);
        // Three independent histories prove the conditional compatibility and fail-closed oracle.
        db.execute("CREATE DATABASE company_file_no_baseline TEMPLATE "+POSTGRES.getDatabaseName());
        db.execute("CREATE DATABASE company_file_altered_contract TEMPLATE "+POSTGRES.getDatabaseName());
        var outcome=TestFlyway.configure().dataSource(source).locations("classpath:db/migration").target("931").load().migrate();
        assertThat(outcome.migrationsExecuted).isEqualTo(1);
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    static String facts(){return db.queryForObject("SELECT to_jsonb(n)::text FROM company_file_nodes n WHERE id=?",String.class,folder);}
    static void pendingPassword(JdbcTemplate database){database.update("INSERT INTO company_file_nodes(id,kind,name,password_hash,pending,created_by,updated_by) VALUES(?,'FILE',?,?,true,?,?)",UUID.randomUUID(),UUID.randomUUID()+".txt",HASH,actor,actor);}
    static DriverManagerDataSource isolated(String name) {
        String url=POSTGRES.getJdbcUrl().replace("/"+POSTGRES.getDatabaseName(),"/"+name);
        return new DriverManagerDataSource(url,POSTGRES.getUsername(),POSTGRES.getPassword());
    }
    @Test void exactKindUpgradePreservesExistingPasswordAndEveryOtherPublicationInvariant() {
        assertThat(facts()).isEqualTo(folderFacts);pendingPassword(db);
        assertThat(new org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder().matches("legacy-folder-password",
                db.queryForObject("SELECT password_hash FROM company_file_nodes WHERE id=?",String.class,folder))).isTrue();
        for(String shape:List.of("'FOLDER',true,NULL","'FILE',false,NULL","'UNKNOWN',true,NULL")) {
            assertThatThrownBy(()->db.update("INSERT INTO company_file_nodes(id,kind,pending,attachment_id,name,created_by,updated_by) VALUES(?,"+shape+",?,?,?)",UUID.randomUUID(),UUID.randomUUID().toString(),actor,actor)).isInstanceOf(DataIntegrityViolationException.class);
        }
        assertThat(db.queryForObject("SELECT count(*) FROM pg_constraint WHERE conrelid='company_file_nodes'::regclass AND conname='company_file_nodes_kind_state_check'",Integer.class)).isEqualTo(1);
        assertThatThrownBy(()->db.update("UPDATE company_file_nodes SET kind='FILE',pending=true WHERE id=?",folder)).isInstanceOf(DataIntegrityViolationException.class);
    }
    @Test void entryBaselineBecomesConfigurableDepartmentsWithoutPersonalGrantOrRevokeLoss() {
        assertThat(db.queryForObject("SELECT baseline FROM permissions WHERE code='company_file:view'",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT grant_policy::text FROM permissions WHERE code='company_file:view'",String.class)).isEqualTo("{NORMAL}");
        assertThat(db.queryForObject("SELECT count(*) FROM departments d JOIN department_permissions p ON p.department_id=d.id JOIN permissions permission ON permission.id=p.permission_id WHERE NOT d.is_deleted AND permission.code='company_file:view'",Integer.class))
                .isEqualTo(db.queryForObject("SELECT count(*) FROM departments WHERE NOT is_deleted",Integer.class));
        assertThat(db.queryForList("SELECT effect FROM user_permission_overrides p JOIN permissions permission ON permission.id=p.permission_id WHERE p.user_id=? AND permission.code='company_file:view'",String.class,actor)).containsExactly("revoke");
        assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides p JOIN permissions permission ON permission.id=p.permission_id WHERE permission.code='company_file:view' AND effect='grant'",Integer.class)).isZero();
        UUID rootEmployee=UUID.randomUUID(),rootUser=departmentUser(root,rootEmployee),childUser=departmentUser(child,UUID.randomUUID());
        var resolver=new PermissionResolver(mock(PermissionRepository.class),mock(DepartmentPermissionRepository.class),
                mock(UserPermissionOverrideRepository.class),mock(EmployeeRepository.class),mock(EmployeeSecondaryDepartmentRepository.class),
                mock(UserAccountRepository.class),mock(DepartmentRepository.class),mock(ManagerPermissionDelegationRepository.class),
                mock(PermissionDelegationPolicy.class),mock(PermissionSurfaceRegistry.class),new PagePermissionDelegationFeatureGate(false),db);
        assertThat(resolver.usersGrantedAll(List.of(rootUser,childUser,actor),Set.of("company_file:view"))).containsExactly(rootUser,childUser);
        // Normal system ancestor inheritance still applies; revoking all actual sources removes entry.
        assertThat(configured(child)).isTrue();
        db.update("DELETE FROM department_permissions WHERE department_id=? AND permission_id=(SELECT id FROM permissions WHERE code='company_file:view')",child);
        assertThat(configured(child)).isTrue();
        assertThat(resolver.usersGrantedAll(List.of(rootUser,childUser,actor),Set.of("company_file:view"))).containsExactly(rootUser,childUser);
        db.update("DELETE FROM department_permissions WHERE department_id=? AND permission_id=(SELECT id FROM permissions WHERE code='company_file:view')",root);
        assertThat(configured(root)).isFalse();assertThat(configured(child)).isFalse();
        Map<UUID,Set<String>> actual=resolver.grantedPermissionsFor(List.of(rootUser,childUser,actor),Set.of("company_file:view"));
        com.uten.imp.support.HistoricalPermissionReaderSources.assertNoIndependentAssignments(db);
        assertThat(actual.getOrDefault(rootUser,Set.of())).isEmpty();assertThat(actual.getOrDefault(childUser,Set.of())).isEmpty();
        var current=mock(SecurityContextCurrentUser.class);
        var user=new AuthUser(rootUser,rootEmployee,"upgrade",actual.getOrDefault(rootUser,Set.of()),false,true,false,false,null,UUID.randomUUID());when(current.get()).thenReturn(Optional.of(user));
        var service=new CompanyFileService(db,current,mock(AttachmentAccessPort.class),mock(AuditService.class),new CompanyFileUnlocks());
        db.update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'USER',?,'ALLOW',ARRAY['view','download'])",folder,rootUser);
        var transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
        assertThatThrownBy(()->transactions.execute(status->service.detail(folder))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->transactions.execute(status->service.list(null,"","manual","asc",false,0,200))).isInstanceOf(ApiException.class);
    }
    static UUID departmentUser(UUID department,UUID employeeId) {
        UUID user=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'入口权限测试人','其他',?,current_date,'active','regular')",employeeId,"ENTRY-"+employeeId,department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",user,employeeId,"entry-"+user);
        return user;
    }
    static boolean configured(UUID department) {
        return db.queryForObject("""
            WITH RECURSIVE scope AS (SELECT id,parent_id FROM departments WHERE id=? UNION ALL
                SELECT p.id,p.parent_id FROM departments p JOIN scope c ON c.parent_id=p.id)
            SELECT EXISTS(SELECT 1 FROM scope s JOIN department_permissions p ON p.department_id=s.id
                JOIN permissions permission ON permission.id=p.permission_id WHERE permission.code='company_file:view')
            """,Boolean.class,department);
    }
    @Test void explicitlyDisabledOldBaselineDoesNotReseedDepartmentOrPersonalPermissions() {
        var other=isolated("company_file_no_baseline");var jdbc=new JdbcTemplate(other);
        jdbc.update("UPDATE permissions SET baseline=false WHERE code='company_file:view'");
        jdbc.update("DELETE FROM department_permissions WHERE permission_id=(SELECT id FROM permissions WHERE code='company_file:view')");
        assertThat(TestFlyway.configure().dataSource(other).locations("classpath:db/migration").target("931").load().migrate().migrationsExecuted).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM department_permissions p JOIN permissions permission ON permission.id=p.permission_id WHERE permission.code='company_file:view'",Integer.class)).isZero();
        assertThat(jdbc.queryForList("SELECT effect FROM user_permission_overrides p JOIN permissions permission ON permission.id=p.permission_id WHERE permission.code='company_file:view'",String.class)).containsExactly("revoke");
        pendingPassword(jdbc);
    }
    @Test void unexpectedOldConstraintFailsClosedAndRollsBackEntireUpgrade() {
        var other=isolated("company_file_altered_contract");var jdbc=new JdbcTemplate(other);
        String constraint=jdbc.queryForObject("SELECT conname FROM pg_constraint WHERE conrelid='company_file_nodes'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%password_hash%'",String.class);
        // Name came from PostgreSQL, quoted as a SQL identifier before use.
        jdbc.execute("ALTER TABLE company_file_nodes DROP CONSTRAINT \""+constraint.replace("\"","\"\"")+"\"");
        assertThatThrownBy(()->TestFlyway.configure().dataSource(other).locations("classpath:db/migration").target("931").load().migrate()).hasStackTraceContaining("Unreviewed company file kind-state constraint");
        assertThat(jdbc.queryForObject("SELECT baseline FROM permissions WHERE code='company_file:view'",Boolean.class)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history WHERE version='931'",Integer.class)).isZero();
    }
}
