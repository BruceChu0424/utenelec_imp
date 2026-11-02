package com.uten.imp.features.companyfiles;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.history.ScopedRecordHistoryService;
import com.uten.imp.features.history.ScopedRecordHistoryService.*;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;

/** Real migrations and production ACL/password service; no business database is contacted. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ScopedRecordHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate db;
    static TransactionTemplate tx;
    UUID actor, employee, session;
    SecurityContextCurrentUser current;
    CompanyFileService files;
    ScopedRecordHistoryService history;
    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("scoped_record_history");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(source); tx=new TransactionTemplate(new DataSourceTransactionManager(source));
    }
    @AfterAll static void stop() throws Exception { if(database!=null) database.close(); }
    @BeforeEach void setup() {
        actor=UUID.randomUUID();employee=UUID.randomUUID();session=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                +"SELECT ?,?,?,'其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",
                employee,"HIST-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("历史测试人",employee));
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",actor,employee,"history-"+actor);
        current=mock(SecurityContextCurrentUser.class);
        files=new CompanyFileService(db,current,mock(AttachmentAccessPort.class),mock(AuditService.class),new CompanyFileUnlocks());
        history=new ScopedRecordHistoryService(db,new ObjectMapper(),current,files);
        login(false,Set.of("company_file:view"));
    }
    void login(boolean admin,Set<String> grants) {
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,employee,"history-test",grants,false,true,admin,false,null,session)));
    }
    <T>T run(Supplier<T> work) { return tx.execute(status->{
        db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
        return work.get();
    }); }
    void update(String sql,Object... args) { run(()->db.update(sql,args)); }
    UUID node(UUID parent,String name,String kind) {
        UUID id=UUID.randomUUID();
        update("INSERT INTO company_file_nodes(id,parent_id,kind,name,pending,created_by,updated_by) VALUES(?,?,?,?,?,?,?)",
                id,parent,kind,name,kind.equals("FILE"),actor,actor);return id;
    }
    Filters filters(UUID id,String keyword,int size,Long cursor) { return new Filters(null,id,cursor,null,null,keyword,null,null,null,null,size); }
    long creation(UUID id) { return db.queryForObject("SELECT min(id) FROM master_record_versions WHERE entity_type='company-files' AND record_id=?",Long.class,id); }
    void deny(UUID node) { update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'USER',?,'DENY',ARRAY['view'])",node,actor); }

    @Test void currentAclHidesCreationRecordsAndDirectDetailsForFoldersAndFiles() {
        UUID root=node(null,"hidden-"+UUID.randomUUID(),"FOLDER");
        UUID child=node(root,"secret-file-"+UUID.randomUUID(),"FILE"); long id=creation(child);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).hasSize(1);
        deny(root);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(root,null,50,null))).entries()).isEmpty();
        assertThatThrownBy(()->run(()->history.detail(Area.COMPANY_FILES,id))).isInstanceOf(ApiException.class);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(null,"secret-file",50,null))).entries()).isEmpty();
    }
    @Test void localDenyAndNonInheritingCutsAreIdenticalToExplorerVisibility() {
        UUID root=node(null,"cut-"+UUID.randomUUID(),"FOLDER"),child=node(root,"private-"+UUID.randomUUID(),"FILE");
        update("UPDATE company_file_nodes SET inherit_permissions=false WHERE id=?",child);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
        update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'USER',?,'ALLOW',ARRAY['view'])",child,actor);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isNotEmpty();
        deny(child);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
    }
    @Test void passwordLockCoversFolderHistoryAndDescendantsAndSessionExpiry() {
        UUID root=node(null,"locked-"+UUID.randomUUID(),"FOLDER"),child=node(root,"child-"+UUID.randomUUID(),"FILE");
        login(true,Set.of("company_file:view"));
        var protectedFolder=run(()->files.setPassword(root,new CompanyFileDtos.Password("test-history-password",0L)));
        login(false,Set.of("company_file:view"));
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(root,null,50,null))).entries()).isEmpty();
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
        run(()->files.unlock(root,new CompanyFileDtos.Unlock("test-history-password")));
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).hasSize(1);
        session=UUID.randomUUID();login(false,Set.of("company_file:view"));
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
        assertThat(protectedFolder.passwordProtected()).isTrue();
    }
    @Test void aclDetailsAndPasswordFactsRequireLocalManagementRightsAndNeverExposeHashes() {
        UUID root=node(null,"acl-"+UUID.randomUUID(),"FOLDER");
        update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'ALL',?,'ALLOW',ARRAY['view'])",root,CompanyFileService.EVERYONE_SUBJECT_ID);
        long acl=db.queryForObject("SELECT max(id) FROM master_record_versions WHERE record_id=?",Long.class,root);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(root,null,50,null))).entries()).hasSize(1);
        assertThatThrownBy(()->run(()->history.detail(Area.COMPANY_FILES,acl))).isInstanceOf(ApiException.class);
        login(true,Set.of("company_file:view"));
        assertThat(run(()->history.detail(Area.COMPANY_FILES,acl)).changes()).anyMatch(c->c.label().equals("访问规则"));
        String all=db.queryForObject("SELECT string_agg(coalesce(before_row::text,'')||coalesce(after_row::text,''),'') FROM master_record_versions WHERE record_id=?",String.class,root);
        assertThat(all).doesNotContain("password_hash","request_fingerprint","storage_key");
    }
    @Test void movedRecordDoesNotDiscloseItsNowHiddenPreviousFolder() {
        UUID old=node(null,"old-"+UUID.randomUUID(),"FOLDER"),now=node(null,"new-"+UUID.randomUUID(),"FOLDER"),child=node(old,"moved-"+UUID.randomUUID(),"FILE");
        update("UPDATE company_file_nodes SET parent_id=? WHERE id=?",now,child);
        long move=db.queryForObject("SELECT max(id) FROM master_record_versions WHERE record_id=?",Long.class,child);
        deny(old);
        assertThat(run(()->history.search(Area.COMPANY_FILES,filters(child,null,50,null))).entries()).isEmpty();
        assertThatThrownBy(()->run(()->history.detail(Area.COMPANY_FILES,move))).isInstanceOf(ApiException.class);
    }
    @Test void paginationSkipsMoreThanOneBatchOfHiddenFactsWithoutLeakingCountsOrCursors() {
        String prefix="pages-"+UUID.randomUUID();
        UUID first=node(null,prefix+"-first","FOLDER"),second=node(null,prefix+"-second","FOLDER"),hidden=node(null,prefix+"-hidden","FOLDER");
        deny(hidden);
        update("INSERT INTO company_file_nodes(id,parent_id,kind,name,created_by,updated_by) SELECT gen_random_uuid(),?,'FOLDER',?||i,?,? FROM generate_series(1,205)i",hidden,prefix,actor,actor);
        var page=run(()->history.search(Area.COMPANY_FILES,filters(null,prefix,1,null)));
        assertThat(page.entries()).singleElement().satisfies(e->assertThat(e.recordId()).isEqualTo(second));
        assertThat(page.nextCursor()).isEqualTo(page.entries().getFirst().id());
        var last=run(()->history.search(Area.COMPANY_FILES,filters(null,prefix,1,com.uten.imp.testsupport.FixtureNumbers.longInteger(page.nextCursor()))));
        assertThat(last.entries()).singleElement().satisfies(e->assertThat(e.recordId()).isEqualTo(first));
        assertThat(last.nextCursor()).isNull();
    }
    @Test void permissionHistoryRequiresBothAdministratorAndAuthorizationPermission() {
        login(false,Set.of("authorization:manage"));
        assertThatThrownBy(()->run(()->history.search(Area.PERMISSIONS,filters(null,null,50,null)))).isInstanceOf(ApiException.class);
        login(true,Set.of());
        assertThatThrownBy(()->run(()->history.search(Area.PERMISSIONS,filters(null,null,50,null)))).isInstanceOf(ApiException.class);
        login(true,Set.of("authorization:manage"));
        update("INSERT INTO audit_log(actor_id,action,target_type,target_id,after,event_source,result,risk_level,event_category) VALUES(?,'user_permission_override_change','users',?,?::jsonb,'business','success','high','authorization')",
                actor,actor.toString(),"{\"added\":[\"grant:goods:view\"],\"removed\":[\"revoke:client:view\"]}");
        var page=run(()->history.search(Area.PERMISSIONS,filters(actor,null,50,null)));
        assertThat(page.entries()).hasSize(1);
        var detail=run(()->history.detail(Area.PERMISSIONS,com.uten.imp.testsupport.FixtureNumbers.longInteger(page.entries().getFirst().id())));
        assertThat(detail.changes()).hasSize(2).anyMatch(c->c.label().contains("授予")&&c.afterValue().equals("已配置"))
                .anyMatch(c->c.label().contains("禁止")&&c.afterValue().equals("未配置"));
        assertThat(detail.canRestoreBefore()).isFalse();
        assertThat(detail.canRestoreAfter()).isFalse();
        update("INSERT INTO audit_log(actor_id,action,target_type,target_id,after,event_source,result,risk_level,event_category) VALUES(?,'permission_configuration_batch','users',?,?::jsonb,'business','success','high','authorization')",
                actor,actor.toString(),"{\"added\":[\"confirm_grant:goods:view\"],\"removed\":[]}");
        var batch=run(()->history.search(Area.PERMISSIONS,filters(actor,null,50,null)));
        assertThat(batch.entries()).hasSize(2);
        var confirmed=run(()->history.detail(Area.PERMISSIONS,com.uten.imp.testsupport.FixtureNumbers.longInteger(batch.entries().getFirst().id())));
        assertThat(confirmed.changes()).singleElement().satisfies(c->assertThat(c.label()).contains("重新确认","goods:view"));
        update("INSERT INTO audit_log(actor_id,action,target_type,target_id,after,event_source,result,risk_level,event_category) VALUES(?,'permission_configuration_import','permissions','configuration',?::jsonb,'business','success','high','authorization')",
                actor,"{\"added\":[\""+actor+"\"],\"removed\":[],\"userCount\":1}");
        var imports=run(()->history.search(Area.PERMISSIONS,new Filters("configuration",null,null,null,null,null,null,null,null,null,50)));
        var imported=run(()->history.detail(Area.PERMISSIONS,com.uten.imp.testsupport.FixtureNumbers.longInteger(imports.entries().getFirst().id())));
        assertThat(imported.changes()).anyMatch(c->c.label().startsWith("导入配置 · ")&&!c.label().contains(actor.toString()));
    }
    @Test void historyRollsBackWithBusinessMutationAndRemainsAppendOnly() {
        UUID root=UUID.randomUUID();
        assertThatThrownBy(()->run(()->{
            db.update("INSERT INTO company_file_nodes(id,kind,name,created_by,updated_by) VALUES(?,'FOLDER',?,?,?)",root,"rollback-"+root,actor,actor);
            throw new IllegalStateException("fixture rollback");
        })).isInstanceOf(IllegalStateException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM master_record_versions WHERE record_id=?",Long.class,root)).isZero();
        UUID retained=node(null,"immutable-"+UUID.randomUUID(),"FOLDER");
        assertThatThrownBy(()->update("DELETE FROM master_record_versions WHERE record_id=?",retained)).isInstanceOf(Exception.class);
    }
}
