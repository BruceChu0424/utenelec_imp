package com.uten.imp.features.companyfiles;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import java.time.Instant;
import java.util.*;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real database/trigger/transaction tests of initial independent file and folder access. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CompanyFileEntryAccessPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate db; static TransactionTemplate transactions;
    static final Set<String> ALL=CompanyFileLibraryPostgresTest.ALL;
    UUID actor,employee,session,department;
    AuthUser principal;
    SecurityContextCurrentUser current;
    AttachmentAccessPort attachments;
    AuditService audit;
    CompanyFileService service;
    @BeforeAll static void start()throws Exception {
        database=MigratedSchemaBaseline.openDatabase("company_file_entry_access");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(source);transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
    }
    @AfterAll static void stop()throws Exception {if(database!=null)database.close();}
    @BeforeEach void setup() {
        actor=UUID.randomUUID();employee=UUID.randomUUID();session=UUID.randomUUID();
        department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
        insertUser(actor,employee,department);
        current=mock(SecurityContextCurrentUser.class);attachments=mock(AttachmentAccessPort.class);audit=mock(AuditService.class);
        var crypto=new CryptoProperties();crypto.setHmacKey("isolated-entry-access-test-key");
        service=new CompanyFileService(db,current,attachments,audit,new CompanyFileUnlocks(),new CompanyFileCreationFingerprint(crypto));
        login(actor,employee,ALL,session);
    }
    void insertUser(UUID id,UUID employeeId,UUID departmentId) {
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,current_date,'active','regular')",employeeId,"EA-"+employeeId,com.uten.imp.support.SyntheticEmployeeIdentity.name("资料访问测试人",employeeId),departmentId);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",id,employeeId,"entry-"+id);
    }
    void login(UUID id,UUID employeeId,Set<String> permissions,UUID sid) {
        principal=new AuthUser(id,employeeId,"entry-access",permissions,false,true,false,false,null,sid);
        when(current.get()).thenReturn(Optional.of(principal));
    }
    <T>T run(Supplier<T> op){return transactions.execute(status->{
        db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,principal.getId().toString());return op.get();});}
    InitialAccess access(boolean inherit,String password,Rule... rules){return new InitialAccess(inherit,List.of(rules),password);}
    Rule allow(UUID user){return new Rule("USER",user,null,"ALLOW",List.of("view","download"));}
    Entry folder(UUID parent,InitialAccess access){return run(()->service.createFolder(new Create(parent,"entry-"+UUID.randomUUID(),null,UUID.randomUUID(),access)));}
    Entry reserve(UUID parent,InitialAccess access){return run(()->service.reserveFile(new Create(parent,"entry-"+UUID.randomUUID()+".txt",null,UUID.randomUUID(),access)));}
    Entry publish(Entry pending) {
        UUID attachment=UUID.randomUUID();
        run(()->db.update("""
            INSERT INTO attachments(id,owner_type,owner_id,storage_provider,storage_key,original_name,content_type,
                size_bytes,sha256,lifecycle_state,stored_size_bytes,storage_encoding,scan_engine,scanned_at,promoted_at)
            VALUES(?,'COMPANY_FILE',?,'local',?,?,'text/plain',12,repeat('a',64),'CLEAN',12,'IDENTITY','fixture',now(),now())
            """,attachment,pending.id(),UUID.randomUUID()+".txt",pending.name()));
        when(attachments.listVisible(CompanyFileService.OWNER_TYPE,pending.id())).thenReturn(List.of(
            new AttachmentAccessPort.AttachmentView(attachment,CompanyFileService.OWNER_TYPE,pending.id(),"fixture",pending.name(),"text/plain",12,Instant.now(),actor,null,null,false)));
        return run(()->service.complete(pending.id(),new Complete(attachment,pending.version())));
    }
    @Test void createOnlyEmployeeCanConfigureReadersWithoutGainingSystemManagement() {
        UUID viewer=UUID.randomUUID(),viewerEmployee=UUID.randomUUID();insertUser(viewer,viewerEmployee,department);
        login(actor,employee,Set.of("company_file:view","company_file:create"),session);
        assertThat(run(()->service.principals("USER",""))).isNotEmpty();
        Entry created=folder(null,access(false,null,allow(viewer)));
        assertThat(created.allowedActions()).containsExactly("view","create");
        assertThatThrownBy(()->run(()->service.permissions(created.id()))).isInstanceOf(ApiException.class);
        // 只有入口的阅读人按目录 ACL 取得可见性，拿不到任何写动作。
        login(viewer,viewerEmployee,Set.of("company_file:view"),UUID.randomUUID());
        assertThat(run(()->service.detail(created.id())).allowedActions()).containsExactly("view");
        assertThatThrownBy(()->run(()->service.createFolder(new Create(created.id(),"not-authorized",null)))).isInstanceOf(ApiException.class);
        login(viewer,viewerEmployee,Set.of("company_file:download"),UUID.randomUUID());
        assertThatThrownBy(()->run(()->service.detail(created.id()))).isInstanceOf(ApiException.class);
    }
    @Test void revokedSystemEntryRejectsCreationBeforePrincipalValidationOrIdempotencyDifferences() {
        UUID requestId=UUID.randomUUID();Create original=new Create(null,"gate-"+requestId+".txt",null,requestId,access(true,null));
        run(()->service.reserveFile(original));clearInvocations(audit);
        for(Set<String> permissions:List.of(Set.of("company_file:create"),Set.of("company_file:upload","attachment:view","attachment:upload"))) {
            login(actor,employee,permissions,session);
            for(Create request:List.of(original,
                    new Create(null,"changed.txt",null,requestId,access(true,"other-password")),
                    new Create(null,"invalid-reader.txt",null,null,access(false,null,allow(UUID.randomUUID()))),
                    new Create(null,"invalid-inherit.txt",null,null,new InitialAccess(null,List.of(),null)))) {
                assertThatThrownBy(()->run(()->permissions.contains("company_file:create")?service.createFolder(request):service.reserveFile(request)))
                        .isInstanceOf(ApiException.class).satisfies(failure->assertThat(((ApiException)failure).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
            }
        }
        verifyNoInteractions(audit);
        assertThat(db.queryForObject("SELECT count(*) FROM company_file_nodes WHERE created_by=?",Integer.class,actor)).isEqualTo(1);
    }
    @Test void privateCreationRetainsRealCreatorCapabilitiesButNeverBorrowsDeniedParentAction() {
        Entry root=folder(null,access(false,null));
        assertThat(root.allowedActions()).contains("delete","edit","manage_permissions");
        assertThat(run(()->service.permissions(root.id())).rules()).singleElement().satisfies(r->assertThat(r.actions()).contains("download"));
        Entry parent=folder(null,null);
        Entry restricted=run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("delete","download"))),parent.version())));
        Entry child=folder(restricted.id(),access(false,null));
        assertThat(child.allowedActions()).contains("create","upload","edit","manage_permissions").doesNotContain("delete","download");
        assertThat(run(()->service.permissions(child.id())).rules()).filteredOn(r->r.subjectId().equals(actor))
                .allSatisfy(r->assertThat(r.actions()).doesNotContain("delete","download"));
    }
    @Test void departmentReadersAndExplicitDenialAreIndependentFromSystemEntryPermission() {
        UUID reader=UUID.randomUUID(),readerEmployee=UUID.randomUUID();insertUser(reader,readerEmployee,department);
        UUID denied=UUID.randomUUID(),deniedEmployee=UUID.randomUUID();insertUser(denied,deniedEmployee,department);
        Entry privateFolder=folder(null,access(false,null,
            new Rule("DEPARTMENT",department,null,"ALLOW",List.of("view","download")),
            new Rule("USER",denied,null,"DENY",List.of("view","download"))));
        login(reader,readerEmployee,ALL,UUID.randomUUID());assertThat(run(()->service.detail(privateFolder.id())).id()).isEqualTo(privateFolder.id());
        login(denied,deniedEmployee,ALL,UUID.randomUUID());
        assertThatThrownBy(()->run(()->service.detail(privateFolder.id()))).isInstanceOf(ApiException.class);
        assertThat(run(()->service.list(null,"","manual","asc",false,0,200)).entries()).extracting(Entry::id).doesNotContain(privateFolder.id());
    }
    @Test void invalidOrSelfDenyingInitialSettingsRollbackMetadataAclAndAuditAtomically() {
        for(InitialAccess access:List.of(access(false,"short"),access(false,null,new Rule("USER",actor,null,"DENY",List.of("view"))),
                access(false,null,new Rule("USER",UUID.randomUUID(),null,"ALLOW",List.of("view"))),
                access(false,null,new Rule("USER",actor,null,"ALLOW",List.of("manage_permissions"))))) {
            UUID requestId=UUID.randomUUID();String name="rollback-"+requestId;
            assertThatThrownBy(()->run(()->service.createFolder(new Create(null,name,null,requestId,access)))).isInstanceOf(ApiException.class);
            assertThat(db.queryForObject("SELECT count(*) FROM company_file_nodes WHERE request_id=?",Integer.class,requestId)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM audit_log WHERE target_type='company_file_nodes' AND \"after\"->>'name'=?",Integer.class,name)).isZero();
        }
        verifyNoInteractions(audit);
    }
    @Test void initialFilePasswordAllowsOnlyOriginalPendingOwnerUploadThenProtectsPublishedContent() {
        Entry pending=reserve(null,access(false,"file-password"));
        assertThat(pending.passwordProtected()).isTrue();assertThat(pending.locked()).isTrue();
        assertThat(pending.allowedActions()).contains("upload","delete");
        run(()->{service.requireAttachmentView(pending.id(),principal);service.requireAttachmentUpload(pending.id(),principal,true);return null;});
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(pending.id(),principal);return null;})).isInstanceOf(ApiException.class);
        Entry published=publish(pending);assertThat(published.pending()).isFalse();assertThat(published.locked()).isTrue();
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(published.id(),principal);return null;})).isInstanceOf(ApiException.class);
        run(()->service.unlock(published.id(),new Unlock("file-password")));
        run(()->{service.requireAttachmentDownload(published.id(),principal);return null;});
        assertThat(run(()->service.permissions(published.id())).rules()).isNotEmpty();
        login(actor,employee,ALL,UUID.randomUUID());
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(published.id(),principal);return null;})).isInstanceOf(ApiException.class);
    }
    @Test void pendingOwnerExceptionNeverSkipsAncestorPasswordOrRevokedAcl() {
        Entry parent=folder(null,null);Entry pending=reserve(parent.id(),access(false,"file-password"));
        Entry locked=run(()->service.setPassword(parent.id(),new Password("ancestor-password",parent.version())));
        assertThatThrownBy(()->run(()->{service.requireAttachmentUpload(pending.id(),principal,true);return null;})).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.unlock(pending.id(),new Unlock("file-password")))).isInstanceOf(ApiException.class);
        run(()->service.unlock(parent.id(),new Unlock("ancestor-password")));
        run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("upload"))),locked.version())));
        assertThatThrownBy(()->run(()->{service.requireAttachmentUpload(pending.id(),principal,true);return null;})).isInstanceOf(ApiException.class);
    }
    @Test void anotherUploaderCannotBorrowThePendingOwnersPasswordExceptionOrCompleteTheirFile() {
        Entry pending=reserve(null,access(true,"pending-file-password"));
        UUID other=UUID.randomUUID(),otherEmployee=UUID.randomUUID();insertUser(other,otherEmployee,department);
        login(other,otherEmployee,ALL,UUID.randomUUID());
        assertThatThrownBy(()->run(()->{service.requireAttachmentUpload(pending.id(),principal,true);return null;})).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.complete(pending.id(),new Complete(UUID.randomUUID(),pending.version())))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(pending.id(),principal);return null;})).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT pending FROM company_file_nodes WHERE id=?",Boolean.class,pending.id())).isTrue();
    }
    @Test void eligibleCleanupManagerCanUnlockPendingFileButCannotBorrowUploadOrDownload() {
        Entry pending=reserve(null,access(true,"abandoned-file-password"));
        UUID manager=UUID.randomUUID(),managerEmployee=UUID.randomUUID();insertUser(manager,managerEmployee,department);
        login(manager,managerEmployee,ALL,UUID.randomUUID());
        Entry locked=run(()->service.detail(pending.id()));assertThat(locked.locked()).isTrue();assertThat(locked.allowedActions()).containsExactly("view");
        assertThatThrownBy(()->run(()->{service.delete(pending.id(),pending.version());return null;})).isInstanceOf(ApiException.class);
        run(()->service.unlock(pending.id(),new Unlock("abandoned-file-password")));
        assertThat(run(()->service.detail(pending.id())).allowedActions()).containsExactly("view","delete");
        assertThatThrownBy(()->run(()->{service.requireAttachmentUpload(pending.id(),principal,true);return null;})).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(pending.id(),principal);return null;})).isInstanceOf(ApiException.class);
        run(()->{service.delete(pending.id(),pending.version());return null;});
        assertThat(db.queryForObject("SELECT deleted FROM company_file_nodes WHERE id=?",Boolean.class,pending.id())).isTrue();
    }
    @Test void superadminCanRecoverAbandonedPrivatePendingAccessWithoutAcquiringTheOriginal() {
        Entry pending=reserve(null,access(false,"private-abandoned-password"));
        UUID admin=UUID.randomUUID(),adminEmployee=UUID.randomUUID();insertUser(admin,adminEmployee,department);
        principal=new AuthUser(admin,adminEmployee,"recovery-admin",ALL,false,true,true,false,null,UUID.randomUUID());when(current.get()).thenReturn(Optional.of(principal));
        assertThatThrownBy(()->run(()->service.detail(pending.id()))).isInstanceOf(ApiException.class);
        Permissions old=run(()->service.permissions(pending.id()));
        Entry cleared=run(()->service.setPassword(pending.id(),new Password(null,pending.version())));
        assertMinimalReceipt(cleared,pending.id(),pending.version()+1);
        run(()->service.setPermissions(pending.id(),new Permissions(false,List.of(new Rule("USER",admin,null,"ALLOW",List.copyOf(CompanyFileService.ACTIONS))),cleared.version())));
        assertThat(old.rules()).isNotEmpty();
        assertThatThrownBy(()->run(()->service.complete(pending.id(),new Complete(UUID.randomUUID(),cleared.version()+1)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(pending.id(),principal);return null;})).isInstanceOf(ApiException.class);
        run(()->{service.delete(pending.id(),cleared.version()+1);return null;});
        assertThat(db.queryForObject("SELECT deleted FROM company_file_nodes WHERE id=?",Boolean.class,pending.id())).isTrue();
        verify(audit).logCommitted(admin,"recovery-admin","company_file_password_clear","company_file_nodes",pending.id().toString(),"success");
    }
    @Test void passwordRecoveryAndNoopOrChangedAclReturnNoMetadataWithoutView() {
        Entry reserved=run(()->service.reserveFile(new Create(null,"敏感文件名称.txt","敏感文件说明",null,access(false,null))));
        Entry original=publish(reserved);
        UUID admin=UUID.randomUUID(),adminEmployee=UUID.randomUUID();insertUser(admin,adminEmployee,department);
        principal=new AuthUser(admin,adminEmployee,"metadata-recovery-admin",ALL,false,true,true,false,null,UUID.randomUUID());when(current.get()).thenReturn(Optional.of(principal));
        assertThatThrownBy(()->run(()->service.detail(original.id()))).isInstanceOf(ApiException.class);
        Permissions existing=run(()->service.permissions(original.id()));
        Entry noop=run(()->service.setPermissions(original.id(),existing));
        assertMinimalReceipt(noop,original.id(),original.version());
        Entry password=run(()->service.setPassword(original.id(),new Password("recovery-password",noop.version())));
        assertMinimalReceipt(password,original.id(),noop.version()+1);
        Entry changed=run(()->service.setPermissions(original.id(),new Permissions(false,List.of(new Rule("USER",admin,null,"DENY",List.of("view"))),password.version())));
        assertMinimalReceipt(changed,original.id(),password.version()+1);
        Entry cleared=run(()->service.setPassword(original.id(),new Password(null,changed.version())));
        assertMinimalReceipt(cleared,original.id(),changed.version()+1);
        assertThatThrownBy(()->run(()->service.detail(original.id()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(original.id(),principal);return null;})).isInstanceOf(ApiException.class);
    }
    @Test void everyoneMarkerOpensViewAndDownloadForAnyEntrantAndDenyStillCarvesExceptions() {
        UUID stranger=UUID.randomUUID(),strangerEmployee=UUID.randomUUID();insertUser(stranger,strangerEmployee,department);
        Entry publicFolder=folder(null,access(true,null,new Rule("ALL",CompanyFileService.EVERYONE_SUBJECT_ID,"所有人","ALLOW",List.of("view","download"))));
        Entry pending=reserve(publicFolder.id(),access(true,null));
        Entry denied=run(()->service.setPermissions(pending.id(),new Permissions(true,List.of(
                new Rule("USER",stranger,null,"DENY",List.of("download"))),pending.version())));
        Entry published=publish(denied);
        login(stranger,strangerEmployee,Set.of("company_file:view"),UUID.randomUUID());
        assertThat(run(()->service.detail(publicFolder.id())).allowedActions()).containsExactly("view");
        assertThat(run(()->service.detail(published.id())).allowedActions()).containsExactly("view");
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(published.id(),principal);return null;}))
                .isInstanceOf(ApiException.class);
        // 没有拒绝例外时，可见即可下载。（清规则回到创建人身份执行。）
        login(actor,employee,ALL,session);
        run(()->service.setPermissions(published.id(),new Permissions(true,List.<Rule>of(),published.version())));
        login(stranger,strangerEmployee,Set.of("company_file:view"),UUID.randomUUID());
        assertThat(run(()->service.detail(published.id())).allowedActions()).containsExactly("view","download");
        run(()->{service.requireAttachmentDownload(published.id(),principal);return null;});
    }

    @Test void folderAclGrantsWriteActionsWithoutAnyGlobalAdministrationCode() {
        UUID stranger=UUID.randomUUID(),strangerEmployee=UUID.randomUUID();insertUser(stranger,strangerEmployee,department);
        login(actor,employee,Set.of("company_file:view","company_file:create","company_file:manage_permissions"),session);
        Entry managed=folder(null,null);
        Entry open=folder(null,access(true,null));
        run(()->service.setPermissions(managed.id(),new Permissions(true,List.of(new Rule("USER",stranger,null,"ALLOW",
                List.of("view","download","create","upload","edit","delete","restore","move","manage_permissions"))),managed.version())));
        login(stranger,strangerEmployee,Set.of("company_file:view"),UUID.randomUUID());
        Entry strangerFolder=run(()->service.createFolder(new Create(managed.id(),"stranger-"+UUID.randomUUID(),null)));
        Entry renamed=run(()->service.edit(strangerFolder.id(),new Edit("renamed-"+strangerFolder.id(),null,strangerFolder.version())));
        assertThat(renamed.name()).startsWith("renamed-");
        run(()->{service.delete(strangerFolder.id(),renamed.version());return null;});
        // 同一人在未授予写动作的开放目录仍只能看和下载。
        assertThat(run(()->service.detail(open.id())).allowedActions()).containsExactly("view");
        assertThatThrownBy(()->run(()->service.createFolder(new Create(open.id(),"not-granted",null))))
                .isInstanceOf(ApiException.class);
        // 根目录没有目录 ACL，只有全局管理码能建。
        assertThatThrownBy(()->run(()->service.createFolder(new Create(null,"not-at-root",null))))
                .isInstanceOf(ApiException.class);
    }

    @Test void denyRuleStillOverridesGlobalAdministrationCodes() {
        UUID admin=UUID.randomUUID(),adminEmployee=UUID.randomUUID();insertUser(admin,adminEmployee,department);
        Entry shared=folder(null,access(true,null));
        run(()->service.setPermissions(shared.id(),new Permissions(true,List.of(
                new Rule("USER",admin,null,"DENY",List.of("delete"))),shared.version())));
        login(admin,adminEmployee,Set.of("company_file:view","company_file:delete","company_file:edit"),UUID.randomUUID());
        assertThat(run(()->service.detail(shared.id())).allowedActions()).contains("view","edit").doesNotContain("delete");
        assertThatThrownBy(()->run(()->{service.delete(shared.id(),shared.version());return null;}))
                .isInstanceOf(ApiException.class);
    }

    @Test void everyoneSubjectOnlyEverAllowsViewAndDownload() {
        Rule denyEveryone=new Rule("ALL",CompanyFileService.EVERYONE_SUBJECT_ID,null,"DENY",List.of("view"));
        Rule editEveryone=new Rule("ALL",CompanyFileService.EVERYONE_SUBJECT_ID,null,"ALLOW",List.of("view","edit"));
        Rule wrongId=new Rule("ALL",UUID.randomUUID(),null,"ALLOW",List.of("view","download"));
        for(Rule rule:List.of(denyEveryone,editEveryone,wrongId)) {
            assertThatThrownBy(()->run(()->service.createFolder(
                    new Create(null,"invalid-everyone-"+UUID.randomUUID(),null,UUID.randomUUID(),access(true,null,rule)))))
                    .isInstanceOf(ApiException.class);
        }
        // 读出的规则把「所有人」还原成可读名称。
        Entry publicFolder=folder(null,access(true,null,
                new Rule("ALL",CompanyFileService.EVERYONE_SUBJECT_ID,"所有人","ALLOW",List.of("view","download"))));
        assertThat(run(()->service.permissions(publicFolder.id())).rules())
                .singleElement()
                .satisfies(rule->{
                    assertThat(rule.subjectName()).isEqualTo("所有人");
                    assertThat(rule.actions()).containsExactly("download","view");
                });
    }

    void assertMinimalReceipt(Entry receipt,UUID id,long version) {
        assertThat(receipt.id()).isEqualTo(id);assertThat(receipt.version()).isEqualTo(version);
        assertThat(receipt.name()).isEmpty();assertThat(receipt.description()).isNull();assertThat(receipt.kind()).isEmpty();
        assertThat(receipt.parentId()).isNull();assertThat(receipt.position()).isZero();
        assertThat(receipt.attachmentId()).isNull();assertThat(receipt.sizeBytes()).isNull();assertThat(receipt.contentType()).isNull();
        assertThat(receipt.createdAt()).isNull();assertThat(receipt.updatedAt()).isNull();assertThat(receipt.deletedAt()).isNull();
        assertThat(receipt.createdByName()).isEmpty();assertThat(receipt.updatedByName()).isEmpty();assertThat(receipt.allowedActions()).isEmpty();
        assertThat(receipt.passwordProtected()).isFalse();assertThat(receipt.pending()).isFalse();assertThat(receipt.deleted()).isFalse();
    }
    @Test void creationReplayNeverRestoresOldPasswordAclOrUnlockAfterPublication() {
        UUID requestId=UUID.randomUUID();Create request=new Create(null,"replay-"+requestId+".txt",null,requestId,access(false,"initial-password"));
        Entry pending=run(()->service.reserveFile(request));Entry published=publish(pending);
        run(()->service.unlock(published.id(),new Unlock("initial-password")));
        Entry changed=run(()->service.setPassword(published.id(),new Password("rotated-password",published.version())));
        Entry replay=run(()->service.reserveFile(request));
        assertThat(replay.id()).isEqualTo(published.id());assertThat(replay.version()).isEqualTo(changed.version());assertThat(replay.locked()).isTrue();
        assertThatThrownBy(()->run(()->service.unlock(replay.id(),new Unlock("initial-password")))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.reserveFile(new Create(null,request.name(),null,requestId,access(false,"other-password"))))).isInstanceOf(ApiException.class);
        String evidence=db.queryForObject("SELECT request_fingerprint FROM company_file_nodes WHERE id=?",String.class,pending.id());
        assertThat(evidence).matches("v2:[0-9a-f]{64}");
        String history=db.queryForObject("SELECT string_agg(to_jsonb(a)::text,' ') FROM audit_log a WHERE target_type='company_file_nodes' AND target_id=?",String.class,pending.id().toString());
        assertThat(history).doesNotContain("initial-password","rotated-password","$2a$","$2b$");
        run(()->service.unlock(replay.id(),new Unlock("rotated-password")));
        Entry denied=run(()->service.setPermissions(replay.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("view"))),changed.version())));
        assertThat(denied.allowedActions()).isEmpty();
        assertThatThrownBy(()->run(()->service.reserveFile(request))).isInstanceOf(ApiException.class);
    }
    @Test void committedCreationRetryDoesNotRehashOrConsumeAnotherPasswordHashPermit() {
        CompanyFileUnlocks counting=spy(new CompanyFileUnlocks());
        var crypto=new CryptoProperties();crypto.setHmacKey("isolated-entry-access-test-key");
        service=new CompanyFileService(db,current,attachments,audit,counting,new CompanyFileCreationFingerprint(crypto));
        UUID requestId=UUID.randomUUID();
        Create request=new Create(null,"hash-replay-"+requestId,null,requestId,access(true,"initial-password"));
        Entry created=run(()->service.createFolder(request));
        Entry replay=run(()->service.createFolder(request));
        assertThat(replay.id()).isEqualTo(created.id());
        verify(counting,times(1)).hash("initial-password");
    }
    @SuppressWarnings("unchecked")
    @Test void readingAndValidatingAclSubjectsUsesOneBatchPerTypeAndStillRejectsInactiveSubjects() {
        JdbcTemplate counted=spy(db);
        var crypto=new CryptoProperties();crypto.setHmacKey("isolated-entry-access-test-key");
        service=new CompanyFileService(counted,current,attachments,audit,new CompanyFileUnlocks(),new CompanyFileCreationFingerprint(crypto));
        InitialAccess access=access(true,null,
                new Rule("USER",actor,null,"ALLOW",List.of("view")),
                new Rule("USER",actor,null,"DENY",List.of("download")),
                new Rule("DEPARTMENT",department,null,"ALLOW",List.of("view")),
                new Rule("DEPARTMENT",department,null,"DENY",List.of("download")));
        Entry created=folder(null,access);
        verify(counted,times(1)).query(contains("AND NOT u.is_deleted AND u.status='active'"),any(org.springframework.jdbc.core.RowMapper.class),any(Object[].class));
        verify(counted,times(1)).query(startsWith("SELECT id,name,code detail FROM departments WHERE id IN ("),any(org.springframework.jdbc.core.RowMapper.class),any(Object[].class));
        clearInvocations(counted);
        Permissions permissions=run(()->service.permissions(created.id()));
        assertThat(permissions.rules()).hasSize(4).allSatisfy(rule->assertThat(rule.subjectName()).isNotBlank());
        verify(counted,times(1)).query(contains("AND NOT u.is_deleted AND u.status='active'"),any(org.springframework.jdbc.core.RowMapper.class),any(Object[].class));
        verify(counted,times(1)).query(startsWith("SELECT id,name,code detail FROM departments WHERE id IN ("),any(org.springframework.jdbc.core.RowMapper.class),any(Object[].class));
        UUID inactive=UUID.randomUUID(),inactiveEmployee=UUID.randomUUID();insertUser(inactive,inactiveEmployee,department);
        db.update("UPDATE users SET status='disabled' WHERE id=?",inactive);
        assertThatThrownBy(()->run(()->service.setPermissions(created.id(),new Permissions(true,List.of(allow(inactive)),created.version())))).isInstanceOf(ApiException.class);
        assertThat(run(()->service.permissions(created.id())).rules()).hasSize(4);
    }
    @Test void matchingRulesAreCanonicalForRetriesAndUnknownRequestNeverPublishesTwice() {
        UUID id=UUID.randomUUID();Rule first=new Rule("USER",actor,null,"ALLOW",List.of("download","view"));
        Create request=new Create(null,"canonical-"+id,null,id,access(true,null,first));
        Entry created=run(()->service.createFolder(request));
        Create reordered=new Create(null,request.name(),null,id,access(true,null,allow(actor)));
        assertThat(run(()->service.createFolder(reordered)).id()).isEqualTo(created.id());
        assertThat(db.queryForObject("SELECT count(*) FROM company_file_nodes WHERE request_id=?",Integer.class,id)).isEqualTo(1);
    }
}
