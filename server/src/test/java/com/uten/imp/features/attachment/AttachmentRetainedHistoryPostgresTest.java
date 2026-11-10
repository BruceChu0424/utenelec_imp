package com.uten.imp.features.attachment;

import com.uten.imp.common.files.malware.MalwareScanner;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.audit.AuditActorDirectory;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real Flyway/JPA/queue and immutable files; private fixture database only. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class AttachmentRetainedHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    static JdbcTemplate jdbc;
    static AttachmentRepository repository;
    static TransactionTemplate transactions;
    static Path root;
    AttachmentService service;
    AttachmentObjectOutboxProcessor processor;
    LocalDiskStorageService storage;
    HistoryPolicy policy;
    SecurityContextCurrentUser current;
    UUID owner,actor;

    @BeforeAll static void start() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("attachment_retained_history");
        var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(ds);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(ds);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp.features.attachment");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none",
                "hibernate.physical_naming_strategy","org.hibernate.boot.model.naming.CamelCaseToUnderscoresNamingStrategy"));
        bean.afterPropertiesSet();factory=bean.getObject();
        var em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        repository=new JpaRepositoryFactory(em).getRepository(AttachmentRepository.class);
        transactions=new TransactionTemplate(new JpaTransactionManager(factory));
        root=Files.createTempDirectory("uten-attachment-retained-proof-");
    }
    @AfterAll static void stop() throws Exception {
        if(factory!=null){ factory.close(); }if(database!=null){ database.close(); }
        if(root!=null){assertThat(root.getFileName().toString()).startsWith("uten-attachment-retained-proof-");
            org.springframework.util.FileSystemUtils.deleteRecursively(root);}
    }
    @BeforeEach void setup() throws Exception {
        owner=UUID.randomUUID();actor=UUID.randomUUID();policy=new HistoryPolicy();
        current=mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"retention-proof",
                Set.of("attachment:view","attachment:download","attachment:delete","attachment:upload"),false,true,false)));
        var properties=new StorageProperties();properties.setLocalDir(root.toString());
        properties.getInternal().setMinFreeBytes(0);
        storage=new LocalDiskStorageService(properties);ReflectionTestUtils.invokeMethod(storage,"init");
        var providers=new StorageProviderRegistry(storage,properties);
        var actors=mock(AuditActorDirectory.class);
        when(actors.resolve(anyCollection(),anyCollection())).thenReturn(new AuditActorDirectory.Resolution(
                Map.of(actor,new AuditActorDirectory.ActorProfile("retention-proof","保全测试人",null,null)),Map.of()));
        var outbox=new AttachmentObjectOutboxStore(jdbc);
        service=new AttachmentService(storage,repository,properties,current,List.of(policy),mock(AttachmentUploadGrantService.class),
                mock(AuditService.class),mock(AttachmentConfirmTransaction.class),mock(AttachmentUploadSafetyGate.class),
                mock(AttachmentUploadSessionStore.class),mock(MalwareScanner.class),outbox,providers,
                new AttachmentDownloadVerifier(providers,properties),actors);
        processor=new AttachmentObjectOutboxProcessor(jdbc,providers,properties,mock(AttachmentPreviewEvictor.class),transactions.getTransactionManager());
    }

    @Test void logicalDeleteHidesDefaultListButHistoryKeepsActorExactOriginalAndRealQueueOutcome() throws Exception {
        byte[] bytes="历史合同 原始 PDF Excel 图像均不重新编码\n".repeat(1000).getBytes(StandardCharsets.UTF_8);
        Attachment row=create(bytes,AttachmentLifecycleState.CLEAN);
        assertThat(service.list("SALES_QUOTE",owner)).extracting(v->v.id()).containsExactly(row.getId());
        transactions.executeWithoutResult(status->service.delete(row.getId()));
        assertThat(processor.processNext()).isTrue();
        assertThat(service.list("SALES_QUOTE",owner)).isEmpty();
        var view=service.listVisibleHistory("SALES_QUOTE",owner).getFirst();
        assertThat(view.deleted()).isTrue();assertThat(view.historyReadOnly()).isTrue();
        assertThat(view.deletedBy()).isEqualTo(actor);assertThat(view.deletedAt()).isNotNull();
        assertThat(view.deletedByName()).contains("保全测试人");assertThat(view.deletedReason()).isEqualTo("USER_LOGICAL_DELETE");
        assertThat(view.originalAvailability()).isEqualTo("RETAINED");
        try(var input=service.openHistory(row.getId()).stream()){assertThat(input.readAllBytes()).isEqualTo(bytes);}
        assertThat(jdbc.queryForMap("SELECT status,completed_at FROM attachment_object_outbox WHERE attachment_id=?",row.getId()))
                .containsEntry("status","RETAINED_HISTORY").doesNotContainEntry("completed_at",null);
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,row.getId())).isEqualTo("RETAINED_HISTORY");
        assertThat(Files.readAllBytes(root.resolve("final").resolve(row.getStorageKey()))).isEqualTo(bytes);
        assertThatThrownBy(()->service.downloadGrant(row.getId())).isInstanceOf(ApiException.class)
                .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.NOT_FOUND));
    }
    @Test void deletedParentUsesHistoryAuthorizationWhileOrdinaryListAndWriteStayClosed() throws Exception {
        Attachment row=create("source".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.RETAINED_HISTORY);
        policy.parentDeleted=true;
        assertThatThrownBy(()->service.list("SALES_QUOTE",owner)).isInstanceOf(ApiException.class);
        assertThat(service.history(row.getId()).deleted()).isTrue();
        assertThat(service.list("SALES_QUOTE",owner,true,true)).hasSize(1);
        assertThatThrownBy(()->transactions.executeWithoutResult(s->service.delete(row.getId()))).isInstanceOf(ApiException.class);
        policy.historyDenied=true;
        assertThatThrownBy(()->service.history(row.getId())).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->service.openHistory(row.getId())).isInstanceOf(ApiException.class);
    }
    @Test void genericHistoryReadCannotBypassTheSensitiveOriginalPriceGate() throws Exception {
        Attachment row=create("price secret".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.RETAINED_HISTORY);
        policy.sensitiveDenied=true;
        assertThat(service.history(row.getId()).historyReadOnly()).isTrue();
        assertThatThrownBy(()->service.openHistory(row.getId())).isInstanceOf(ApiException.class)
                .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    @Test void historicalPhysicalLossIsExplicitUnavailableAndNeverAFabricatedDownload() throws Exception {
        Attachment row=create("historically lost".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.DELETED);
        Files.delete(root.resolve("final").resolve(row.getStorageKey()));
        var view=service.history(row.getId());
        assertThat(view.deleted()).isTrue();assertThat(view.originalAvailability()).isEqualTo("LEGACY_UNAVAILABLE");
        assertThat(view.historyDownloadUrl()).isNull();
        assertThatThrownBy(()->service.openHistory(row.getId())).isInstanceOf(ApiException.class);
    }
    @Test void corruptionAfterLogicalDeletionFailsClosedWithoutReturningPartialBytes() throws Exception {
        Attachment row=create("verified original".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.RETAINED_HISTORY);
        Files.write(root.resolve("final").resolve(row.getStorageKey()),"different content".getBytes(StandardCharsets.UTF_8));
        assertThatThrownBy(()->service.openHistory(row.getId())).isInstanceOf(ApiException.class)
                .satisfies(error->assertThat(((ApiException)error).getCode()).isEqualTo(ErrorCode.CONFLICT));
    }
    @Test void retainedRowsProtectOrphanScanAndCannotChangeIdentityDeleteOrTruncate() throws Exception {
        Attachment row=create("permanent pointer".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.RETAINED_HISTORY);
        assertThat(AttachmentReconciliationService.isReferenced(jdbc,"local","FINAL",row.getStorageKey(),null)).isTrue();
        assertThat(AttachmentReconciliationService.isReferenced(jdbc,"oss","FINAL",row.getStorageKey(),null)).isFalse();
        assertThatThrownBy(()->jdbc.update("UPDATE attachments SET storage_key=? WHERE id=?",UUID.randomUUID()+".txt",row.getId()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update("UPDATE attachments SET category='rewrite' WHERE id=?",row.getId()))
                .isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.update("DELETE FROM attachments WHERE id=?",row.getId())).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThatThrownBy(()->jdbc.execute("TRUNCATE attachments CASCADE")).isInstanceOf(org.springframework.dao.DataAccessException.class);
        assertThat(repository.findById(row.getId())).isPresent();
    }
    @Test void retainedHistoryStaysReferencedAfterOrdinaryDeletion() throws Exception {
        Attachment row=create("retained original".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.CLEAN);
        assertThat(referencedFinal(row)).isTrue();
        transactions.executeWithoutResult(status->service.delete(row.getId()));
        assertThat(referencedFinal(row)).isTrue();
        // The normal reconciliation reference remains after logical deletion and worker processing.
        assertThat(processor.processNext()).isTrue();assertThat(referencedFinal(row)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE attachment_id=? AND status='SUCCEEDED'",Integer.class,row.getId())).isZero();
        assertThat(jdbc.queryForObject("SELECT to_regprocedure('public.business_data_reset()')::text",String.class)).isNull();
        assertThat(repository.findById(row.getId())).isPresent();
        assertThat(Files.exists(root.resolve("final").resolve(row.getStorageKey()))).isTrue();
    }
    @Test void legacyPendingIntentRetainsTheSourceInsteadOfRepeatingPhysicalDeletion() throws Exception {
        Attachment row=create("old pending original".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.DELETE_PENDING);
        new AttachmentObjectOutboxStore(jdbc).enqueueFinal(row.getId(),row.getStorageKey(),null,"local");
        assertThat(processor.processNext()).isTrue();
        assertThat(service.history(row.getId()).originalAvailability()).isEqualTo("RETAINED");
        assertThat(Files.exists(root.resolve("final").resolve(row.getStorageKey()))).isTrue();
        assertThat(jdbc.queryForObject("SELECT delete_reason FROM attachments WHERE id=?",String.class,row.getId())).isEqualTo("LEGACY_DELETE_INTENT_RETAINED");
        Attachment alreadyReasoned=create("pending with prior reason".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.DELETE_PENDING);
        jdbc.update("UPDATE attachments SET delete_reason='OLDER_RECORDED_REASON' WHERE id=?",alreadyReasoned.getId());
        new AttachmentObjectOutboxStore(jdbc).enqueueFinal(alreadyReasoned.getId(),alreadyReasoned.getStorageKey(),null,"local");
        assertThat(processor.processNext()).isTrue();
        assertThat(jdbc.queryForObject("SELECT delete_reason FROM attachments WHERE id=?",String.class,alreadyReasoned.getId())).isEqualTo("OLDER_RECORDED_REASON");
    }
    @Test void nativeHistoryGetExposesExactStoredShaToViewOnlyReaderWithoutWrites() throws Exception {
        var mvc=org.springframework.test.web.servlet.setup.MockMvcBuilders.standaloneSetup(
                new AttachmentController(service,mock(AttachmentReconciliationService.class),
                        mock(AttachmentPreviewService.class),mock(com.uten.imp.audit.AuditDetailViewRecorder.class)))
                .setControllerAdvice(new com.uten.imp.common.web.GlobalExceptionHandler()).build();
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"view-only",
                Set.of("attachment:view"),false,true,false)));
        for (var state:List.of(AttachmentLifecycleState.CLEAN,AttachmentLifecycleState.RETAINED_HISTORY)) {
            owner=UUID.randomUUID();
            Attachment row=create(("proof-"+state).getBytes(StandardCharsets.UTF_8),state);
            String before=jdbc.queryForObject("SELECT to_jsonb(a)::text FROM attachments a WHERE id=?",String.class,row.getId());
            int sessions=jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions",Integer.class);
            int outbox=jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox",Integer.class);
            mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/attachments")
                            .param("ownerType","SALES_QUOTE").param("ownerId",owner.toString()).param("includeDeleted","true"))
                    .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isOk())
                    .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$[0].sha256").value(row.getSha256()))
                    .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$[0].storageKey").value(row.getStorageKey()))
                    .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$[0].uploadedBy").value(actor.toString()))
                    .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath("$[0].deleted").value(state==AttachmentLifecycleState.RETAINED_HISTORY));
            assertThat(jdbc.queryForObject("SELECT to_jsonb(a)::text FROM attachments a WHERE id=?",String.class,row.getId())).isEqualTo(before);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions",Integer.class)).isEqualTo(sessions);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox",Integer.class)).isEqualTo(outbox);
        }
        policy.historyDenied=true;
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/attachments")
                        .param("ownerType","SALES_QUOTE").param("ownerId",owner.toString()).param("includeDeleted","true"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isForbidden());
        policy.historyDenied=false;
        when(current.get()).thenReturn(Optional.of(new AuthUser(actor,UUID.randomUUID(),"no-view",Set.of(),false,true,false)));
        mvc.perform(org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get("/api/attachments")
                        .param("ownerType","SALES_QUOTE").param("ownerId",owner.toString()).param("includeDeleted","true"))
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers.status().isForbidden());
    }
    @Test void nativeHistoryKeepsMissingLegacyShaNullInsteadOfInventingProof() throws Exception {
        Attachment legacy=create("legacy-original".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.LEGACY_UNVERIFIED,false);
        var row=service.list("SALES_QUOTE",owner,true,false).getFirst();
        assertThat(row.id()).isEqualTo(legacy.getId());assertThat(row.sha256()).isNull();
        assertThat(service.history(legacy.getId()).sha256()).isNull();
    }

    @Test void downloadAndPreviewAdvanceUsageHeatOnTheAttachmentRowOncePerDayWithoutAuditNoise() throws Exception {
        var recorder=new AttachmentUsageRecorder(jdbc);
        ReflectionTestUtils.setField(service,"events",
                (org.springframework.context.ApplicationEventPublisher)event -> {
                    if (event instanceof AttachmentAccessedEvent accessed) recorder.onAccessed(accessed);
                });
        byte[] bytes="常用合同 冷热分层热度".getBytes(StandardCharsets.UTF_8);
        Attachment row=create(bytes,AttachmentLifecycleState.CLEAN);
        assertThat(lastUsed(row)).isNull();
        // The FULL row audit is live here: an ordinary column change is evidence...
        int audited=auditRows(row);
        jdbc.update("UPDATE attachments SET category='合同' WHERE id=?",row.getId());
        assertThat(auditRows(row)).isEqualTo(audited+1);
        audited=auditRows(row);

        try(var input=service.openRaw(row.getStorageKey()).stream()){assertThat(input.readAllBytes()).isEqualTo(bytes);}
        Instant first=lastUsed(row);
        assertThat(first).isNotNull();
        // ...while heat writes never become row audit events (last_used_at is an operational column).
        assertThat(auditRows(row)).isEqualTo(audited);
        // Same day: throttled, the attachment row is not written again.
        try(var input=service.openRaw(row.getStorageKey()).stream()){input.readAllBytes();}
        service.openPreviewSource(row.getId());
        assertThat(lastUsed(row)).isEqualTo(first);
        // Older than a day: preview and download-grant advance it again.
        jdbc.update("UPDATE attachments SET last_used_at=now()-interval '3 days' WHERE id=?",row.getId());
        service.openPreviewSource(row.getId());
        assertThat(lastUsed(row)).isAfter(Instant.now().minus(java.time.Duration.ofHours(1)));
        jdbc.update("UPDATE attachments SET last_used_at=now()-interval '3 days' WHERE id=?",row.getId());
        service.downloadGrant(row.getId());
        assertThat(lastUsed(row)).isAfter(Instant.now().minus(java.time.Duration.ofHours(1)));
        assertThat(auditRows(row)).isEqualTo(audited);

        // A row locked by another writer is skipped instead of making the download wait.
        jdbc.update("UPDATE attachments SET last_used_at=NULL WHERE id=?",row.getId());
        try(var holder=jdbc.getDataSource().getConnection()){
            holder.setAutoCommit(false);
            try(var lock=holder.prepareStatement("SELECT id FROM attachments WHERE id=? FOR UPDATE")){
                lock.setObject(1,row.getId());lock.executeQuery().close();
            }
            assertThat(new AttachmentUsageRecorder(jdbc).recordUse(row.getId())).isFalse();
            holder.rollback();
        }
        assertThat(lastUsed(row)).isNull();

        // Deleted history is immutable and never touched; the guard stays intact.
        Attachment retained=create("已删除历史".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.RETAINED_HISTORY);
        assertThat(new AttachmentUsageRecorder(jdbc).recordUse(retained.getId())).isFalse();
        assertThat(lastUsed(retained)).isNull();

        // A failing heat write never fails or replays the download itself; the
        // listener swallows the failure exactly as the inline path used to.
        var failingJdbc=mock(org.springframework.jdbc.core.JdbcTemplate.class);
        when(failingJdbc.update(anyString(),any(Object[].class))).thenThrow(new org.springframework.dao.QueryTimeoutException("heat write timed out"));
        var failing=new AttachmentUsageRecorder(failingJdbc);
        ReflectionTestUtils.setField(service,"events",
                (org.springframework.context.ApplicationEventPublisher)event -> {
                    if (event instanceof AttachmentAccessedEvent accessed) failing.onAccessed(accessed);
                });
        try(var input=service.openRaw(row.getStorageKey()).stream()){assertThat(input.readAllBytes()).isEqualTo(bytes);}
        assertThat(service.downloadGrant(row.getId())).isNotNull();
        verify(failingJdbc,times(2)).update(anyString(),any(Object[].class));
    }

    @Test void tieringSchedulerReadsHeatFromTheAttachmentRowWithinTheNinetyDayWindow() throws Exception {
        Attachment hot=create("近期用过".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.CLEAN);
        Attachment stale=create("久未使用".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.CLEAN);
        Attachment never=create("从未使用".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.CLEAN);
        assertThat(new AttachmentUsageRecorder(jdbc).recordUse(hot.getId())).isTrue();
        jdbc.update("UPDATE attachments SET last_used_at=now()-interval '91 days' WHERE id=?",stale.getId());
        var active=jdbc.queryForList(InternalStorageTieringScheduler.RECENTLY_USED_SQL,String.class,
                java.sql.Timestamp.from(Instant.now().minus(java.time.Duration.ofDays(InternalStorageTieringScheduler.RECENT_ACCESS_DAYS))));
        assertThat(active).contains(hot.getId().toString())
                .doesNotContain(stale.getId().toString(),never.getId().toString());
    }

    private Instant lastUsed(Attachment row){
        var value=jdbc.queryForObject("SELECT last_used_at FROM attachments WHERE id=?",java.sql.Timestamp.class,row.getId());
        return value==null?null:value.toInstant();
    }
    private int auditRows(Attachment row){
        return jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE target_id=?",Integer.class,row.getId().toString());
    }
    private boolean referencedFinal(Attachment row){return AttachmentReconciliationService.isReferenced(jdbc,row.getStorageProvider(),"FINAL",row.getStorageKey(),row.getStorageVersion());}
    private Attachment create(byte[] bytes,AttachmentLifecycleState state) throws Exception {
        return create(bytes,state,true);
    }
    private Attachment create(byte[] bytes,AttachmentLifecycleState state,boolean withDigest) throws Exception {
        String key=UUID.randomUUID().toString().replace("-","")+".txt";
        storage.store(key,new ByteArrayInputStream(bytes),bytes.length);storage.promoteToFinal(key,storage.describe(key));
        var row=new Attachment();row.setOwnerType("SALES_QUOTE");row.setOwnerId(owner);row.setStorageKey(key);row.setStorageProvider("local");
        row.setOriginalName("原始报价.txt");row.setContentType("text/plain");row.setSizeBytes(bytes.length);
        row.setSha256(withDigest?HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)):null);
        row.setStoredSizeBytes((long)bytes.length);row.setStorageEncoding("IDENTITY");row.setLifecycleState(state);
        row.setScanEngine("test-private-clean");row.setScannedAt(Instant.now());row.setPromotedAt(Instant.now());
        row.setCreatedAt(Instant.now());row.setUpdatedAt(Instant.now());row.setCreatedBy(actor);
        if(state!=AttachmentLifecycleState.CLEAN&&state!=AttachmentLifecycleState.LEGACY_UNVERIFIED){row.setDeleteRequestedAt(Instant.now());row.setDeleteRequestedBy(actor);
            row.setDeleteReason(state==AttachmentLifecycleState.DELETE_PENDING?null:"PRIVATE_FIXTURE_HISTORY");}
        transactions.executeWithoutResult(status->repository.saveAndFlush(row));return row;
    }
    static class HistoryPolicy implements AttachmentOwnerAccessPolicy {
        boolean parentDeleted,historyDenied,sensitiveDenied;
        @Override public String ownerType(){return "SALES_QUOTE";}
        @Override public void requireCanView(UUID id,AuthUser user){if(parentDeleted)throw new ApiException(ErrorCode.NOT_FOUND);}
        @Override public void requireCanManage(UUID id,AuthUser user){requireCanView(id,user);}
        @Override public void requireCanViewHistory(UUID id,AuthUser user){if(historyDenied)throw new ApiException(ErrorCode.FORBIDDEN);}
        @Override public void requireCanViewSensitiveOriginal(UUID id,AuthUser user){if(sensitiveDenied)throw new ApiException(ErrorCode.FORBIDDEN);requireCanView(id,user);}
        @Override public void requireCanViewSensitiveOriginalHistory(UUID id,AuthUser user){requireCanViewHistory(id,user);if(sensitiveDenied)throw new ApiException(ErrorCode.FORBIDDEN);}
    }
}
