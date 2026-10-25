package com.uten.imp.features.companyfiles;

import com.uten.imp.support.MigratedSchemaBaseline;
import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.UUID;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.Map;
import java.time.Instant;
import java.util.function.Supplier;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real migrated PostgreSQL: no host application/database is used or mutated. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CompanyFileLibraryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static JdbcTemplate db;
    static TransactionTemplate transactions;
    UUID actor,employee,session;
    SecurityContextCurrentUser current;
    AttachmentAccessPort attachments;
    CompanyFileService service;
    AuthUser principal;
    static final Set<String> ALL=Set.of("company_file:view","company_file:download","company_file:upload","company_file:create",
            "company_file:edit","company_file:move","company_file:delete","company_file:restore","company_file:manage_permissions",
            "attachment:view","attachment:upload","attachment:download");

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("company_file_library_security");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        db=new JdbcTemplate(source);
        transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
    }
    @AfterAll static void stop() throws Exception {if(database!=null)database.close();}
    @BeforeEach void actor() {
        actor=UUID.randomUUID();employee=UUID.randomUUID();session=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                +"SELECT ?,?,'资料库测试人','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"LIB-"+employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) "
                +"VALUES(?,?,?,'test-only','active',false)",actor,employee,"library-"+actor);
        current=mock(SecurityContextCurrentUser.class);attachments=mock(AttachmentAccessPort.class);
        service=new CompanyFileService(db,current,attachments,mock(AuditService.class),new CompanyFileUnlocks());
        login(ALL,session);
    }
    <T>T run(Supplier<T> operation) {
        return transactions.execute(status->{
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            return operation.get();
        });
    }
    UUID folder(UUID parent,String name) {
        UUID id=UUID.randomUUID();
        run(()->db.update("INSERT INTO company_file_nodes(id,parent_id,kind,name,created_by,updated_by) VALUES(?,?,'FOLDER',?,?,?)",id,parent,name,actor,actor));
        return id;
    }
    void update(String sql,Object... arguments){run(()->db.update(sql,arguments));}
    void login(Set<String> permissions,UUID sessionId){
        principal=new AuthUser(actor,employee,"library-security",permissions,false,true,false,false,null,sessionId);
        when(current.get()).thenReturn(Optional.of(principal));
    }
    Entry create(UUID parent,String name){return run(()->service.createFolder(new Create(parent,name,null)));}
    Entry file(UUID parent,String name){
        Entry pending=run(()->service.reserveFile(new Create(parent,name,null)));
        UUID attachment=UUID.randomUUID();
        update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_provider,storage_key,original_name,
                    content_type,size_bytes,sha256,lifecycle_state,stored_size_bytes,storage_encoding,scan_engine,scanned_at,promoted_at)
                VALUES(?,'COMPANY_FILE',?,'local',?,?,'text/plain',12,repeat('a',64),'CLEAN',12,'IDENTITY','private-fixture',now(),now())
                """,attachment,pending.id(),UUID.randomUUID()+".txt",name);
        when(attachments.listVisible(CompanyFileService.OWNER_TYPE,pending.id())).thenReturn(List.of(
                new AttachmentAccessPort.AttachmentView(attachment,CompanyFileService.OWNER_TYPE,pending.id(),"test-only",name,"text/plain",12,Instant.now(),actor,null,null,false)));
        return run(()->service.complete(pending.id(),new Complete(attachment,pending.version())));
    }

    @Test void detailMetadataNeedsOnlyViewAndAuditsTheViewerRatherThanTheCreator() {
        Entry parent=create(null,"detail-parent-"+UUID.randomUUID());
        Entry original=file(parent.id(),"私密客户报价及工资.txt");
        UUID viewer=UUID.randomUUID(),viewerEmployee=UUID.randomUUID();
        String account="detail-viewer-"+viewer;
        update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                +"SELECT ?,?,'只读资料查看人','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",
                viewerEmployee,"DETAIL-"+viewerEmployee);
        update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) "
                +"VALUES(?,?,?,'test-only','active',false)",viewer,viewerEmployee,account);
        AuthUser reader=new AuthUser(viewer,viewerEmployee,account,Set.of("company_file:view"),
                false,true,false,false,null,UUID.randomUUID());
        when(current.get()).thenReturn(Optional.of(reader));
        AuditService detailAudit=mock(AuditService.class);
        CompanyFileController controller=new CompanyFileController(service,new AuditDetailViewRecorder(detailAudit,current));

        Entry resolved=run(()->controller.detail(original.id()));

        assertThat(resolved.id()).isEqualTo(original.id());
        assertThat(resolved.allowedActions()).containsExactly("view");
        assertThat(viewer).isNotEqualTo(actor);
        verify(detailAudit).logSuccessfulDetailView(viewer,account,"view_company_file_detail",
                "company_file_nodes",original.id(),"公司资料",null,null);
        verifyNoMoreInteractions(detailAudit);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(original.id(),reader);return null;}))
                .isInstanceOf(ApiException.class);
    }

    @Test void detailAuditDoesNotRecordAuthenticationPermissionOrMissingObjectRejections() {
        Entry available=create(null,"detail-rejected-"+UUID.randomUUID());
        AuditService detailAudit=mock(AuditService.class);
        CompanyFileController controller=new CompanyFileController(service,new AuditDetailViewRecorder(detailAudit,current));
        login(Set.of("company_file:view"),session);
        assertThatThrownBy(()->run(()->controller.detail(UUID.randomUUID()))).isInstanceOf(ApiException.class);
        login(Set.of(),session);
        assertThatThrownBy(()->run(()->controller.detail(available.id()))).isInstanceOf(ApiException.class);
        when(current.get()).thenReturn(Optional.empty());
        assertThatThrownBy(()->run(()->controller.detail(available.id()))).isInstanceOf(ApiException.class);
        verifyNoInteractions(detailAudit);
    }

    @Test void deniedAncestorStopsDetailBeforeAnySuccessfulAuditCanBeRecorded() {
        Entry parent=create(null,"detail-acl-"+UUID.randomUUID());
        Entry child=create(parent.id(),"secret-descendant");
        run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(
                new Rule("USER",actor,null,"DENY",List.of("view"))),parent.version())));
        login(Set.of("company_file:view"),session);
        AuditService detailAudit=mock(AuditService.class);
        CompanyFileController controller=new CompanyFileController(service,new AuditDetailViewRecorder(detailAudit,current));

        assertThatThrownBy(()->run(()->controller.detail(parent.id()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->controller.detail(child.id()))).isInstanceOf(ApiException.class);

        verifyNoInteractions(detailAudit);
    }

    @Test void lockedFolderMetadataIsAuditedButItsDescendantsRequireTheCurrentSessionUnlock() {
        Entry parent=create(null,"detail-password-"+UUID.randomUUID());
        Entry child=file(parent.id(),"secret-content.txt");
        run(()->service.setPassword(parent.id(),new Password("detail-password",parent.version())));
        login(Set.of("company_file:view"),session);
        AuditService detailAudit=mock(AuditService.class);
        CompanyFileController controller=new CompanyFileController(service,new AuditDetailViewRecorder(detailAudit,current));

        Entry locked=run(()->controller.detail(parent.id()));
        assertThat(locked.locked()).isTrue();
        verify(detailAudit).logSuccessfulDetailView(actor,"library-security","view_company_file_detail",
                "company_file_nodes",parent.id(),"公司资料",null,null);
        clearInvocations(detailAudit);
        assertThatThrownBy(()->run(()->controller.detail(child.id()))).isInstanceOf(ApiException.class);
        verifyNoInteractions(detailAudit);

        run(()->service.unlock(parent.id(),new Unlock("detail-password")));
        assertThat(run(()->controller.detail(child.id())).allowedActions()).containsExactly("view");
        verify(detailAudit).logSuccessfulDetailView(actor,"library-security","view_company_file_detail",
                "company_file_nodes",child.id(),"公司资料",null,null);
        clearInvocations(detailAudit);
        login(Set.of("company_file:view"),UUID.randomUUID());
        assertThatThrownBy(()->run(()->controller.detail(child.id()))).isInstanceOf(ApiException.class);
        verifyNoInteractions(detailAudit);
    }

    @Test void actualCatalogContainsIndependentActionsAndOneSynchronizedSurface() {
        assertThat(db.queryForList("SELECT code FROM permissions WHERE code LIKE 'company_file:%' ORDER BY code",String.class))
                .containsExactly("company_file:create","company_file:delete","company_file:download","company_file:edit",
                        "company_file:manage_permissions","company_file:move","company_file:restore","company_file:upload","company_file:view");
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions p JOIN permission_surfaces s ON s.id=p.surface_id "
                +"WHERE s.surface_key='common.company-files'",Integer.class)).isEqualTo(9);
        assertThat(db.queryForObject("SELECT baseline FROM permissions WHERE code='company_file:view'",Boolean.class)).isFalse();
        assertThat(db.queryForObject("SELECT baseline FROM permissions WHERE code='company_file:manage_permissions'",Boolean.class)).isFalse();
    }

    @Test void databaseRejectsCyclesAndMovingIntoFileEvenOutsideTheController() {
        UUID root=folder(null,"cycle-"+UUID.randomUUID());UUID child=folder(root,"child");
        assertThatThrownBy(()->update("UPDATE company_file_nodes SET parent_id=? WHERE id=?",child,root))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        UUID pending=UUID.randomUUID();
        update("INSERT INTO company_file_nodes(id,parent_id,kind,name,pending,created_by,updated_by) VALUES(?,?,'FILE','pending.docx',true,?,?)",pending,root,actor,actor);
        assertThatThrownBy(()->folder(pending,"unreachable"))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }

    @Test void activeNamesAreCaseInsensitiveAndRestoreCannotSilentlyReplaceAnotherFile() {
        UUID root=folder(null,"names-"+UUID.randomUUID());UUID item=folder(root,"Templates");
        assertThatThrownBy(()->folder(root,"templates")).isInstanceOf(org.springframework.dao.DuplicateKeyException.class);
        UUID batch=UUID.randomUUID();
        update("UPDATE company_file_nodes SET deleted=true,deleted_at=now(),deleted_by=?,deletion_batch=? WHERE id=?",actor,batch,item);
        folder(root,"Templates");
        assertThatThrownBy(()->update("UPDATE company_file_nodes SET deleted=false,deleted_at=null,deleted_by=null,deletion_batch=null WHERE id=?",item))
                .isInstanceOf(org.springframework.dao.DuplicateKeyException.class);
        assertThat(db.queryForObject("SELECT deleted FROM company_file_nodes WHERE id=?",Boolean.class,item)).isTrue();
    }

    @Test void maximumHierarchyDepthIsEnforcedAtTheDatabaseBoundary() {
        UUID parent=folder(null,"depth-"+UUID.randomUUID());
        for(int depth=0;depth<31;depth++)parent=folder(parent,"level-"+depth);
        UUID deepest=parent;
        assertThatThrownBy(()->folder(deepest,"too-deep")).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }

    @Test void movingADeepSubtreeCannotBypassTheDatabaseDepthLimit() {
        UUID source=folder(null,"deep-source-"+UUID.randomUUID());folder(source,"descendant");
        UUID destination=folder(null,"deep-target-"+UUID.randomUUID());
        for(int level=0;level<30;level++)destination=folder(destination,"level-"+level);
        UUID deepest=destination;
        assertThatThrownBy(()->update("UPDATE company_file_nodes SET parent_id=? WHERE id=?",deepest,source))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThat(db.queryForObject("SELECT parent_id FROM company_file_nodes WHERE id=?",UUID.class,source)).isNull();
    }

    @Test void passwordHashIsExcludedFromRealTriggerAudit() {
        UUID root=folder(null,"password-"+UUID.randomUUID());String secretHash="$2a$12$private-hash-test-marker";
        update("UPDATE company_file_nodes SET password_hash=?,password_revision=password_revision+1 WHERE id=?",secretHash,root);
        String audit=db.queryForObject("SELECT string_agg(to_jsonb(a)::text,' ') FROM audit_log a WHERE target_type='company_file_nodes' AND target_id=?",String.class,root.toString());
        assertThat(audit).isNotBlank().doesNotContain(secretHash);
    }

    @Test void aclActionsAndNodeIdentityCannotBeRewrittenIntoAnInvalidShape() {
        UUID root=folder(null,"immutable-"+UUID.randomUUID());
        assertThatThrownBy(()->update("UPDATE company_file_nodes SET kind='FILE',pending=true WHERE id=?",root))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThatThrownBy(()->update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'USER',?,'ALLOW',ARRAY['execute-arbitrary'])",root,actor))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        assertThatThrownBy(()->update("UPDATE company_file_nodes SET name='../escape' WHERE id=?",root))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }

    @Test void deniedAncestorCannotBeBypassedByChildAllowOrKnownIdentifiers() {
        Entry parent=create(null,"denied-"+UUID.randomUUID());Entry child=create(parent.id(),"child");
        run(()->service.setPermissions(child.id(),new Permissions(false,List.of(new Rule("USER",actor,null,"ALLOW",List.copyOf(CompanyFileService.ACTIONS))),child.version())));
        run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("view"))),parent.version())));
        assertThat(run(()->service.list(null,"","manual","asc",false,0,200)).entries()).extracting(Entry::id).doesNotContain(parent.id());
        assertThatThrownBy(()->run(()->service.detail(child.id()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.createFolder(new Create(child.id(),"bypass",null)))).isInstanceOf(ApiException.class);
    }

    @Test void isolatedFolderNeedsExplicitActionAllowInAdditionToModulePermission() {
        Entry folder=create(null,"restricted-"+UUID.randomUUID());
        run(()->service.setPermissions(folder.id(),new Permissions(false,List.of(new Rule("USER",actor,null,"ALLOW",List.of("view"))),folder.version())));
        assertThat(run(()->service.detail(folder.id())).allowedActions()).containsExactly("view");
        assertThatThrownBy(()->run(()->service.createFolder(new Create(folder.id(),"no-create",null)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.reserveFile(new Create(folder.id(),"no-upload.txt",null)))).isInstanceOf(ApiException.class);
    }

    @Test void passwordUnlockIsBoundToSessionAndKnownDescendantCannotLeakProtectedMetadata() {
        Entry folder=create(null,"protected-"+UUID.randomUUID());Entry child=create(folder.id(),"secret-child-name");Entry file=file(folder.id(),"secret.txt");
        run(()->service.setPassword(folder.id(),new Password("strong-passphrase",folder.version())));
        assertThat(run(()->service.list(folder.id(),"","manual","asc",false,0,200)).entries()).isEmpty();
        assertThatThrownBy(()->run(()->service.detail(child.id()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->service.list(child.id(),"","manual","asc",false,0,200))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
        run(()->service.unlock(folder.id(),new Unlock("strong-passphrase")));
        assertThat(run(()->service.detail(child.id())).name()).isEqualTo("secret-child-name");
        run(()->{service.requireAttachmentDownload(file.id(),principal);return null;});
        login(ALL,UUID.randomUUID());
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
        login(ALL,session);
        run(()->{service.requireAttachmentDownload(file.id(),principal);return null;});
        run(()->{service.lock(folder.id());return null;});
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
    }

    @Test void passwordCapabilityDoesNotSurviveAclRevocationOrPasswordRotation() {
        Entry folder=create(null,"revoke-"+UUID.randomUUID());Entry file=file(folder.id(),"original.txt");
        Entry protectedFolder=run(()->service.setPassword(folder.id(),new Password("first-password",folder.version())));
        run(()->service.unlock(folder.id(),new Unlock("first-password")));
        Entry changed=run(()->service.setPassword(folder.id(),new Password("second-password",protectedFolder.version())));
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
        run(()->service.unlock(folder.id(),new Unlock("second-password")));
        run(()->service.setPermissions(folder.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("download"))),changed.version())));
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
    }

    @Test void attachmentReadCannotBorrowUploadPermissionAndPublishedOriginalCannotBeReplaced() {
        Entry folder=create(null,"actions-"+UUID.randomUUID());Entry file=file(folder.id(),"official.txt");
        login(Set.of("company_file:view","company_file:upload","attachment:view","attachment:upload"),session);
        run(()->{service.requireAttachmentView(file.id(),principal);return null;});
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentUpload(file.id(),principal,true);return null;})).isInstanceOf(ApiException.class);
    }

    @Test void moduleActionsNeverInventMissingGenericAttachmentPermissions() {
        Entry folder=create(null,"generic-dependencies-"+UUID.randomUUID());Entry file=file(folder.id(),"dependency.txt");
        login(Set.of("company_file:view","company_file:upload","company_file:download"),session);
        assertThatThrownBy(()->run(()->service.reserveFile(new Create(folder.id(),"no-generic-upload.txt",null)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.requireAttachmentDownload(file.id(),principal);return null;})).isInstanceOf(ApiException.class);
        assertThat(run(()->service.detail(file.id())).allowedActions()).doesNotContain("upload","download");
    }

    @Test void deletingSubtreeIsAtomicWhenAnyDescendantDeniesDeletion() {
        Entry folder=create(null,"atomic-"+UUID.randomUUID());Entry child=create(folder.id(),"cannot-delete");
        run(()->service.setPermissions(child.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("delete"))),child.version())));
        assertThatThrownBy(()->run(()->{service.delete(folder.id(),folder.version());return null;})).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM company_file_nodes WHERE id IN (?,?) AND deleted",Integer.class,folder.id(),child.id())).isZero();
    }

    @Test void restorationOnlyRestoresTheCurrentDeletionBatchAndKeepsOriginalReference() {
        Entry folder=create(null,"recycle-"+UUID.randomUUID());Entry child=create(folder.id(),"already-deleted");Entry file=file(folder.id(),"retained.txt");
        run(()->{service.delete(child.id(),child.version());return null;});
        run(()->{service.delete(folder.id(),folder.version());return null;});
        Entry deleted=run(()->service.detail(folder.id()));
        run(()->service.restore(folder.id(),new Version(deleted.version())));
        assertThat(run(()->service.detail(child.id())).deleted()).isTrue();
        assertThat(run(()->service.detail(file.id())).attachmentId()).isEqualTo(file.attachmentId());
        assertThat(db.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,file.attachmentId())).isEqualTo("CLEAN");
    }

    @Test void moveChecksBothDestinationPermissionAndCycleWithoutPartialWrites() {
        Entry folder=create(null,"move-source-"+UUID.randomUUID());Entry child=create(folder.id(),"child");Entry destination=create(null,"move-target-"+UUID.randomUUID());
        assertThatThrownBy(()->run(()->service.move(folder.id(),new Move(child.id(),folder.version())))).isInstanceOf(ApiException.class);
        run(()->service.setPermissions(destination.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("create"))),destination.version())));
        assertThatThrownBy(()->run(()->service.move(child.id(),new Move(destination.id(),child.version())))).isInstanceOf(ApiException.class);
        assertThat(run(()->service.detail(child.id())).parentId()).isEqualTo(folder.id());
    }

    @Test void staleVersionAndPartialReorderNeverOverwriteConcurrentWork() {
        Entry parent=create(null,"concurrent-"+UUID.randomUUID());Entry first=create(parent.id(),"first");Entry second=create(parent.id(),"second");
        run(()->service.edit(first.id(),new Edit("first-updated",null,first.version())));
        assertThatThrownBy(()->run(()->service.edit(first.id(),new Edit("lost-update",null,first.version())))).isInstanceOf(ApiException.class);
        long position=run(()->service.detail(second.id())).position();
        assertThatThrownBy(()->run(()->{service.reorder(new Reorder(parent.id(),List.of(second.id())));return null;})).isInstanceOf(ApiException.class);
        assertThat(run(()->service.detail(first.id())).name()).isEqualTo("first-updated");
        assertThat(run(()->service.detail(second.id())).position()).isEqualTo(position);
    }

    @Test void completeReorderUsesEveryExpectedVersionAndRejectsStaleFullDragState() {
        Entry parent=create(null,"reorder-"+UUID.randomUUID());Entry first=create(parent.id(),"first");Entry second=create(parent.id(),"second");
        Reorder command=new Reorder(parent.id(),List.of(second.id(),first.id()),Map.of(first.id(),first.version(),second.id(),second.version()));
        run(()->{service.reorder(command);return null;});
        assertThat(run(()->service.detail(second.id())).position()).isLessThan(run(()->service.detail(first.id())).position());
        long after=run(()->service.detail(second.id())).version();
        assertThatThrownBy(()->run(()->{service.reorder(command);return null;})).isInstanceOf(ApiException.class);
        assertThat(run(()->service.detail(second.id())).version()).isEqualTo(after);
    }

    @Test void lostCreateResponseCanReuseOneRequestIdWithoutDuplicatingIdentity() {
        Entry parent=create(null,"idempotency-"+UUID.randomUUID());UUID requestId=UUID.randomUUID();
        Create request=new Create(parent.id(),"once.txt",null,requestId);
        Entry first=run(()->service.reserveFile(request));Entry replay=run(()->service.reserveFile(request));
        assertThat(replay.id()).isEqualTo(first.id());
        assertThat(db.queryForObject("SELECT count(*) FROM company_file_nodes WHERE parent_id=? AND name='once.txt'",Integer.class,parent.id())).isEqualTo(1);
        assertThatThrownBy(()->run(()->service.reserveFile(new Create(parent.id(),"different.txt",null,requestId)))).isInstanceOf(ApiException.class);
    }

    @Test void savingTheSameAclIsANoOpWithoutInventingAnotherVersion() {
        Entry folder=create(null,"acl-noop-"+UUID.randomUUID());
        Rule rule=new Rule("USER",actor,null,"ALLOW",List.of("view","create","manage_permissions"));
        Entry changed=run(()->service.setPermissions(folder.id(),new Permissions(false,List.of(rule),folder.version())));
        Entry same=run(()->service.setPermissions(folder.id(),new Permissions(false,List.of(rule),changed.version())));
        assertThat(same.version()).isEqualTo(changed.version());
        assertThat(db.queryForObject("SELECT count(*) FROM company_file_acl WHERE node_id=?",Integer.class,folder.id())).isEqualTo(1);
    }

    @Test void restorePermissionDoesNotBorrowUploadOrCreatePermissionForRetainedBytes() {
        Entry folder=create(null,"restore-independent-"+UUID.randomUUID());Entry file=file(folder.id(),"retained-original.txt");
        run(()->{service.delete(file.id(),file.version());return null;});
        login(Set.of("company_file:view","company_file:restore","attachment:view"),session);
        Entry restored=run(()->service.restore(file.id(),new Version(file.version()+1)));
        assertThat(restored.deleted()).isFalse();assertThat(restored.attachmentId()).isEqualTo(file.attachmentId());
        assertThat(restored.allowedActions()).doesNotContain("upload","create","download");
    }

    @Test void ordinaryAuthorizedLibraryManagerCanRecycleAnInactiveCreatorsPendingReservationWithoutBypassingAclOrPassword() {
        UUID inactiveCreator=actor;Entry parent=create(null,"abandoned-"+UUID.randomUUID());
        Entry pending=run(()->service.reserveFile(new Create(parent.id(),"abandoned.txt",null)));
        db.update("UPDATE users SET status='disabled' WHERE id=?",inactiveCreator);
        actor=UUID.randomUUID();employee=UUID.randomUUID();session=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                +"SELECT ?,?,'授权资料管理员','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"MGR-"+employee);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) "
                +"VALUES(?,?,?,'test-only','active',false)",actor,employee,"library-manager-"+actor);
        login(Set.of("company_file:view","company_file:delete"),session);
        assertThatThrownBy(()->run(()->service.detail(pending.id()))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->run(()->{service.delete(pending.id(),pending.version());return null;})).isInstanceOf(ApiException.class);
        login(Set.of("company_file:view","company_file:manage_permissions"),session);
        assertThatThrownBy(()->run(()->service.detail(pending.id()))).isInstanceOf(ApiException.class);
        login(ALL,session);assertThat(principal.isSuperAdmin()).isFalse();
        assertThat(run(()->service.detail(pending.id())).allowedActions()).contains("view","delete").doesNotContain("upload","download","edit","move");
        Entry denied=run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("delete"))),parent.version())));
        assertThatThrownBy(()->run(()->service.detail(pending.id()))).isInstanceOf(ApiException.class);
        Entry open=run(()->service.setPermissions(parent.id(),new Permissions(true,List.of(),denied.version())));
        Entry locked=run(()->service.setPassword(parent.id(),new Password("pending-cleanup-password",open.version())));
        assertThatThrownBy(()->run(()->service.detail(pending.id()))).isInstanceOf(ApiException.class);
        run(()->service.unlock(parent.id(),new Unlock("pending-cleanup-password")));
        run(()->{service.delete(pending.id(),pending.version());return null;});
        assertThat(db.queryForObject("SELECT deleted FROM company_file_nodes WHERE id=?",Boolean.class,pending.id())).isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM attachments WHERE owner_id=?",Integer.class,pending.id())).isZero();
        Entry replacement=run(()->service.reserveFile(new Create(parent.id(),"abandoned.txt",null)));
        assertThat(replacement.id()).isNotEqualTo(pending.id());assertThat(locked.passwordProtected()).isTrue();
    }

    @Test void deletedPasswordFolderCanBeUnlockedAndRestoredFromANewSession() {
        Entry folder=create(null,"encrypted-trash-"+UUID.randomUUID());Entry child=create(folder.id(),"child");
        Entry protectedFolder=run(()->service.setPassword(folder.id(),new Password("recovery-password",folder.version())));
        run(()->service.unlock(folder.id(),new Unlock("recovery-password")));
        run(()->{service.delete(folder.id(),protectedFolder.version());return null;});
        login(ALL,UUID.randomUUID());
        assertThatThrownBy(()->run(()->service.restore(folder.id(),new Version(protectedFolder.version()+1)))).isInstanceOf(ApiException.class);
        run(()->service.unlock(folder.id(),new Unlock("recovery-password")));
        Entry restored=run(()->service.restore(folder.id(),new Version(protectedFolder.version()+1)));
        assertThat(restored.deleted()).isFalse();assertThat(run(()->service.detail(child.id())).deleted()).isFalse();
    }

    @Test void fileRenameKeepsTheOriginalFinalExtensionAndCannotCreateAnExecutableDownloadAlias() {
        Entry parent=create(null,"safe-file-names-"+UUID.randomUUID());Entry published=file(parent.id(),"clean.txt");
        for(String candidate:List.of("run.cmd","run.BAT","run.exe","run.com","run.ps1","run.vbs","run.js","run.url",
                "run.lnk","run.scr","run.hta","run.desktop","clean.txt.exe",".cmd","no-extension","different.pdf")) {
            assertThatThrownBy(()->run(()->service.edit(published.id(),new Edit(candidate,null,published.version()))))
                    .as("unsafe format change to %s",candidate).isInstanceOf(ApiException.class)
                    .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED));
        }
        assertThat(run(()->service.detail(published.id())).name()).isEqualTo("clean.txt");
        assertThat(run(()->service.detail(published.id())).version()).isEqualTo(published.version());
        Entry renamed=run(()->service.edit(published.id(),new Edit("中文模板.2026.TXT",null,published.version())));
        assertThat(renamed.name()).isEqualTo("中文模板.2026.TXT");
        assertThat(db.queryForObject("SELECT original_name FROM attachments WHERE id=?",String.class,published.attachmentId())).isEqualTo("clean.txt");
        Entry pending=run(()->service.reserveFile(new Create(parent.id(),"pending.txt",null)));
        assertThatThrownBy(()->run(()->service.edit(pending.id(),new Edit("pending.bat",null,pending.version())))).isInstanceOf(ApiException.class);
        Entry folderRenamed=run(()->service.edit(parent.id(),new Edit("templates.cmd",null,parent.version())));
        assertThat(folderRenamed.kind()).isEqualTo("FOLDER");
    }

    @Test void cleanTextOriginalCannotPublishThroughAPendingExecutableAlias() {
        Entry pending=run(()->service.reserveFile(new Create(null,"reserved-"+UUID.randomUUID()+".exe",null)));
        UUID original=UUID.randomUUID();
        update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_provider,storage_key,original_name,
                    content_type,size_bytes,sha256,lifecycle_state,stored_size_bytes,storage_encoding,scan_engine,scanned_at,promoted_at)
                VALUES(?,'COMPANY_FILE',?,'local',?,'clean.txt','text/plain',12,repeat('a',64),'CLEAN',12,'IDENTITY','private-fixture',now(),now())
                """,original,pending.id(),UUID.randomUUID()+".txt");
        when(attachments.listVisible(CompanyFileService.OWNER_TYPE,pending.id())).thenReturn(List.of(
                new AttachmentAccessPort.AttachmentView(original,CompanyFileService.OWNER_TYPE,pending.id(),"test-only","clean.txt","text/plain",12,Instant.now(),actor,null,null,false)));
        assertThatThrownBy(()->run(()->service.complete(pending.id(),new Complete(original,pending.version()))))
                .isInstanceOf(ApiException.class)
                .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED));
        Entry unchanged=run(()->service.detail(pending.id()));
        assertThat(unchanged.pending()).isTrue();assertThat(unchanged.attachmentId()).isNull();assertThat(unchanged.version()).isEqualTo(pending.version());
        assertThat(db.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,original)).isEqualTo("CLEAN");
    }

    @SuppressWarnings("unchecked")
    @Test void authorizationSnapshotHoldsSharedLockAcrossNodeAndAclReadsSoTwoDeniedStatesCannotMixIntoAnAllow()throws Exception {
        Entry folder=create(null,"acl-read-fence-"+UUID.randomUUID());
        update("INSERT INTO company_file_acl(node_id,subject_type,subject_id,effect,actions) VALUES(?,'USER',?,'DENY',ARRAY['view'])",folder.id(),actor);
        assertThatThrownBy(()->run(()->service.detail(folder.id()))).isInstanceOf(ApiException.class);
        var nodeLoaded=new CountDownLatch(1);var finishAclRead=new CountDownLatch(1);var writerAttempted=new CountDownLatch(1);
        var pausedOnce=new AtomicBoolean();var fencedJdbc=spy(db);
        doAnswer(invocation->{
            Object result=invocation.callRealMethod();
            if(pausedOnce.compareAndSet(false,true)){
                nodeLoaded.countDown();
                if(!finishAclRead.await(10,TimeUnit.SECONDS))throw new AssertionError("authorization reader was not released");
            }
            return result;
        }).when(fencedJdbc).query(eq("SELECT * FROM company_file_nodes WHERE id=?"),any(org.springframework.jdbc.core.RowMapper.class),eq(folder.id()));
        var readerService=new CompanyFileService(fencedJdbc,current,attachments,mock(AuditService.class),new CompanyFileUnlocks());
        var readerProxy=new org.springframework.aop.framework.ProxyFactory(readerService);readerProxy.setProxyTargetClass(true);
        var readerInterceptor=new org.springframework.transaction.interceptor.TransactionInterceptor();
        readerInterceptor.setTransactionManager(transactions.getTransactionManager());
        readerInterceptor.setTransactionAttributeSource(new org.springframework.transaction.annotation.AnnotationTransactionAttributeSource(false));
        readerProxy.addAdvice(readerInterceptor);
        CompanyFileService transactionalReader=(CompanyFileService)readerProxy.getProxy();
        var executor=Executors.newFixedThreadPool(2);
        try{
            Future<Boolean> reader=executor.submit(()->{
                try{transactionalReader.detail(folder.id());return true;}catch(ApiException denied){return false;}
            });
            assertThat(nodeLoaded.await(5,TimeUnit.SECONDS)).isTrue();
            Future<Boolean> writer=executor.submit(()->run(()->{
                db.execute("SET LOCAL lock_timeout='5s'");db.execute("SET LOCAL statement_timeout='8s'");
                writerAttempted.countDown();db.queryForObject("SELECT pg_advisory_xact_lock(925,1)",Object.class);
                db.update("UPDATE company_file_nodes SET inherit_permissions=false,version=version+1 WHERE id=?",folder.id());
                db.update("DELETE FROM company_file_acl WHERE node_id=?",folder.id());return true;
            }));
            assertThat(writerAttempted.await(5,TimeUnit.SECONDS)).isTrue();
            long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);int waiting=0;
            while(System.nanoTime()<deadline){
                waiting=db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=925 AND objid=1 "
                        +"AND database=(SELECT oid FROM pg_database WHERE datname=current_database()) AND NOT granted",Integer.class);
                if(waiting>0)break;Thread.sleep(10);
            }
            assertThat(waiting).as("ACL writer must wait for the actual authorization read transaction").isPositive();
            assertThat(writer.isDone()).isFalse();finishAclRead.countDown();
            assertThat(reader.get(5,TimeUnit.SECONDS)).as("old inherit=true plus DENY view remains denied").isFalse();
            assertThat(writer.get(5,TimeUnit.SECONDS)).isTrue();
            assertThat(db.queryForObject("SELECT inherit_permissions FROM company_file_nodes WHERE id=?",Boolean.class,folder.id())).isFalse();
            assertThat(db.queryForObject("SELECT count(*) FROM company_file_acl WHERE node_id=?",Integer.class,folder.id())).isZero();
            assertThatThrownBy(()->run(()->service.detail(folder.id()))).as("new inherit=false plus empty ACL remains denied").isInstanceOf(ApiException.class);
        }finally{
            finishAclRead.countDown();executor.shutdownNow();assertThat(executor.awaitTermination(10,TimeUnit.SECONDS)).isTrue();
        }
    }
}
