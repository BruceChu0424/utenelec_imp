package com.uten.imp.features.attachment;

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
        if(factory!=null)factory.close();if(database!=null)database.close();
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
                mock(AttachmentUploadSessionStore.class),mock(AttachmentMalwareScanner.class),outbox,providers,
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
    @Test void retainedHistoryStaysInTheTestFileListUntilTheExplicitResetDeletesIt() throws Exception {
        Attachment row=create("keep across explicit reset".getBytes(StandardCharsets.UTF_8),AttachmentLifecycleState.CLEAN);
        assertThat(listedFinal(row)).isEqualTo(1);
        transactions.executeWithoutResult(status->service.delete(row.getId()));
        assertThat(listedFinal(row)).isEqualTo(1);
        // Ordinary deletion retains history and never proves physical deletion: the file stays listed.
        assertThat(processor.processNext()).isTrue();assertThat(listedFinal(row)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE attachment_id=? AND status='SUCCEEDED'",Integer.class,row.getId())).isZero();
        String reset=jdbc.queryForObject("SELECT pg_get_functiondef('business_data_reset()'::regprocedure)",String.class);
        for(String table:List.of("attachments","attachment_upload_sessions","attachment_object_outbox","attachment_reconciliation_findings"))
            assertThat(reset).contains("('"+table+"', 'PRESERVE')");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM fn_business_data_reset_refusals() WHERE reason_code='UNSUPPORTED_STORAGE'",Long.class)).isZero();
        // A delete task on storage the system cannot delete becomes refusal rule 20.
        jdbc.update("UPDATE attachment_object_outbox SET storage_provider='oss' WHERE attachment_id=?",row.getId());
        assertThat(jdbc.queryForObject("SELECT item_count FROM fn_business_data_reset_refusals() WHERE reason_code='UNSUPPORTED_STORAGE'",Long.class)).isEqualTo(1);
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

    private long listedFinal(Attachment row){return jdbc.queryForObject("SELECT count(*) FROM fn_business_test_reset_objects() WHERE object_provider=? AND object_location='FINAL' AND object_key=?",Long.class,row.getStorageProvider(),row.getStorageKey());}
    private Attachment create(byte[] bytes,AttachmentLifecycleState state) throws Exception {
        return create(bytes,state,true);
    }
    private Attachment create(byte[] bytes,AttachmentLifecycleState state,boolean withDigest) throws Exception {
        String key=UUID.randomUUID().toString().replace("-","")+".txt";
        storage.store(key,new ByteArrayInputStream(bytes),bytes.length,"text/plain");storage.promoteToFinal(key,storage.describe(key));
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
        public String ownerType(){return "SALES_QUOTE";}
        public void requireCanView(UUID id,AuthUser user){if(parentDeleted)throw new ApiException(ErrorCode.NOT_FOUND);}
        public void requireCanManage(UUID id,AuthUser user){requireCanView(id,user);}
        public void requireCanViewHistory(UUID id,AuthUser user){if(historyDenied)throw new ApiException(ErrorCode.FORBIDDEN);}
        public void requireCanViewSensitiveOriginal(UUID id,AuthUser user){if(sensitiveDenied)throw new ApiException(ErrorCode.FORBIDDEN);requireCanView(id,user);}
        public void requireCanViewSensitiveOriginalHistory(UUID id,AuthUser user){requireCanViewHistory(id,user);if(sensitiveDenied)throw new ApiException(ErrorCode.FORBIDDEN);}
    }
}
