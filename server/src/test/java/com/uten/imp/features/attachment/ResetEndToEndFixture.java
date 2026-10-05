package com.uten.imp.features.attachment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiJobHandler.AiJobInput;
import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.audit.AuditLog;
import com.uten.imp.audit.AuditLogRepository;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.storage.InternalStorageResetTestSupport;
import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.admin.systemtest.BusinessDataResetDrainGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetFeatureGate;
import com.uten.imp.features.admin.systemtest.BusinessDataResetService;
import com.uten.imp.features.admin.systemtest.BusinessDataResetTimings;
import com.uten.imp.features.ai.job.AiInputOriginalStore;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.postgresql.Driver;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SimpleDriverDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionManager;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * End-to-end wiring of "clear business data" for database tests (ADR-155): a private migrated
 * database, the JPA transaction manager and audit writer as in production, real internal storage
 * in a temp directory, the real {@link BusinessTestResetFiles} and {@link BusinessDataResetService}.
 * Only the current-user lookup used by the AI intake writer is a mock.
 */
public final class ResetEndToEndFixture implements AutoCloseable {
    public final MigratedSchemaBaseline.ScopedDatabase database;
    public final SimpleDriverDataSource dataSource;
    public final JdbcTemplate jdbc;
    public final JpaTransactionManager transactions;
    public final TransactionTemplate tx;
    public final AuditService audit;
    public final Path root;
    public final StorageProperties properties;
    public final InternalStorageService internal;
    public final StorageProviderRegistry registry;
    public final ImmutableDocumentStore documents;
    public final AttachmentObjectOutboxProcessor outboxWorker;
    public final BusinessDataResetDrainGate drain = new BusinessDataResetDrainGate();
    public final UUID admin;
    public final UUID adminEmployee;
    public final String adminAccount;
    public final UUID aiUser;
    public final AiInputOriginalStore aiOriginals;
    private final EntityManagerFactory entityManagerFactory;
    private int intakeCounter;

    private ResetEndToEndFixture(String label, Path files) throws Exception {
        database = MigratedSchemaBaseline.openDatabase(label);
        dataSource = new SimpleDriverDataSource(new Driver(), database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan(AuditLog.class.getPackageName());
        factory.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        factory.afterPropertiesSet();
        entityManagerFactory = factory.getObject();
        transactions = new JpaTransactionManager(entityManagerFactory);
        assertThat(transactions.getDataSource()).isSameAs(dataSource);
        tx = new TransactionTemplate(transactions);
        audit = auditService(entityManagerFactory, transactions);

        var existing = jdbc.queryForList("SELECT id,employee_id,login_account FROM users WHERE is_super_admin AND status='active' AND NOT is_deleted ORDER BY login_account LIMIT 1");
        if (existing.isEmpty()) {
            adminEmployee = UUID.randomUUID();
            admin = UUID.randomUUID();
            adminAccount = "reset-admin-" + admin;
            jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'测试清空操作人','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'", adminEmployee, "RST-" + adminEmployee);
            jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'test-only',false,'active',true)", admin, adminEmployee, adminAccount);
        } else {
            admin = (UUID) existing.getFirst().get("id");
            adminEmployee = (UUID) existing.getFirst().get("employee_id");
            adminAccount = (String) existing.getFirst().get("login_account");
        }
        UUID aiEmployee = UUID.randomUUID();
        aiUser = UUID.randomUUID();
        String aiAccount = "ai-intake-" + aiUser;
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'识别上传人','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'", aiEmployee, "AIU-" + aiEmployee);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,'test-only',false,'active')", aiUser, aiEmployee, aiAccount);

        root = Files.createDirectories(files.resolve("internal"));
        properties = new StorageProperties();
        properties.setProvider("internal");
        properties.getInternal().setRoot(root.toRealPath().toString());
        properties.getInternal().setMinFreeBytes(0);
        internal = InternalStorageResetTestSupport.open(properties);
        registry = new StorageProviderRegistry(internal, properties);
        documents = new ImmutableDocumentStore(internal, registry);
        outboxWorker = new AttachmentObjectOutboxProcessor(jdbc, registry, properties, mock(AttachmentPreviewEvictor.class), transactions);
        SecurityContextCurrentUser aiCurrent = mock(SecurityContextCurrentUser.class);
        when(aiCurrent.get()).thenReturn(Optional.of(new AuthUser(aiUser, aiEmployee, aiAccount, Set.of("ai:use"), false, true, false)));
        when(aiCurrent.requireId()).thenReturn(aiUser);
        aiOriginals = new AiInputOriginalStore(new NamedParameterJdbcTemplate(dataSource), documents, internal, aiCurrent, audit, List.of());
    }

    /** A fresh migrated database and internal storage under {@code files}. */
    public static ResetEndToEndFixture open(String label, Path files) throws Exception {
        return new ResetEndToEndFixture(label, files);
    }

    /** The real file port over this fixture's storage registry. */
    public BusinessTestResetFiles files() {
        return files(jdbc, registry, properties, transactions, internal);
    }

    /** The real file port over another storage registry (test doubles that slow down, fail or pause deletes). */
    public BusinessTestResetFiles files(StorageProviderRegistry custom) {
        return files(jdbc, custom, properties, transactions, internal);
    }

    /** The real file port for tests that own their database: internal storage under {@code internalRoot}. */
    public static BusinessTestResetFiles files(DataSource dataSource, PlatformTransactionManager transactions, Path internalRoot)
            throws Exception {
        var storageProperties = new StorageProperties();
        storageProperties.setProvider("internal");
        storageProperties.getInternal().setRoot(Files.createDirectories(internalRoot).toRealPath().toString());
        storageProperties.getInternal().setMinFreeBytes(0);
        InternalStorageService storage = InternalStorageResetTestSupport.open(storageProperties);
        return files(new JdbcTemplate(dataSource), new StorageProviderRegistry(storage, storageProperties), storageProperties,
                transactions, storage);
    }

    private static BusinessTestResetFiles files(JdbcTemplate jdbc, StorageProviderRegistry registry, StorageProperties properties,
                                                PlatformTransactionManager transactions, InternalStorageService storage) {
        @SuppressWarnings("unchecked")
        ObjectProvider<InternalStorageService> provider = mock(ObjectProvider.class);
        when(provider.getIfAvailable()).thenReturn(storage);
        return new BusinessTestResetFiles(jdbc, registry, properties, transactions, provider);
    }

    public BusinessDataResetService service() {
        return service(files(), BusinessDataResetTimings.DEFAULT);
    }

    public BusinessDataResetService service(BusinessTestResetFilesPort port, BusinessDataResetTimings timings) {
        return new BusinessDataResetService(dataSource, transactions, new BusinessDataResetFeatureGate(true), drain, audit, port, timings);
    }

    /** JPA audit writer proxied with the same transaction manager, as in production. */
    public static AuditService auditService(EntityManagerFactory entityManagerFactory, JpaTransactionManager transactions) {
        var entityManager = SharedEntityManagerCreator.createSharedEntityManager(entityManagerFactory);
        AuditLogRepository repository = new JpaRepositoryFactory(entityManager).getRepository(AuditLogRepository.class);
        var proxy = new ProxyFactory(new AuditService(repository, new AuditDeviceContext(new ObjectMapper())));
        proxy.addAdvice(new TransactionInterceptor((TransactionManager) transactions, new AnnotationTransactionAttributeSource()));
        return (AuditService) proxy.getProxy();
    }

    public void bindAdmin() {
        jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)", String.class, admin.toString());
        jdbc.queryForObject("SELECT set_config('app.actor_account',?,true)", String.class, adminAccount);
        jdbc.queryForObject("SELECT set_config('app.audit_request_id',?,true)", String.class, UUID.randomUUID().toString());
    }

    public long generation() {
        return jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
    }

    public long objectCount() {
        return jdbc.queryForObject("SELECT count(*) FROM fn_business_test_reset_objects()", Long.class);
    }

    // ------------------------------------------------------------------ seeding that mimics production writers

    public record Intake(UUID job, String key, String version, long size, String sha, UUID outboxId) {}

    public record Stored(String key, String version, long size, String sha, long storedSize, String encoding, String name) {}

    /** AiJobService.submit order: capture (object + ai_input_originals + DELETE_STAGING outbox) then ai_jobs; no worker. */
    public Intake aiIntakeWithoutWorker(String name) {
        byte[] bytes = ("%PDF-1.4 live repro " + name + " #" + (++intakeCounter) + " " + UUID.randomUUID()).getBytes(StandardCharsets.UTF_8);
        String sha = ImmutableDocumentStore.digest(bytes);
        String kind = name.endsWith(".xlsx") ? "XLSX" : "PDF";
        String mime = name.endsWith(".xlsx") ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf";
        UUID job = UUID.randomUUID();
        tx.executeWithoutResult(status -> {
            aiOriginals.capture(job, aiUser, "SALES_DOCUMENT_INTAKE", new AiJobInput(name, mime, kind, bytes.length, bytes, sha));
            jdbc.update("""
                    INSERT INTO ai_jobs(id,kind,status,input_name,input_content_type,input_kind,input_size,input_sha256,input_bytes,submitted_by_user,submitted_auth_version)
                    VALUES(?,'SALES_DOCUMENT_INTAKE','PENDING',?,?,?,?,?,?,?,1)
                    """, job, name, mime, kind, bytes.length, sha, bytes, aiUser);
        });
        jdbc.update("UPDATE ai_jobs SET status='SUCCEEDED',input_bytes=NULL,finished_at=now(),result='{\"lines\":[]}'::jsonb WHERE id=?", job);
        var row = jdbc.queryForMap("SELECT storage_key,storage_version,storage_size,storage_sha256,storage_provider,availability,lifecycle_state FROM ai_input_originals WHERE job_id=?", job);
        assertThat(row).containsEntry("storage_provider", "internal").containsEntry("availability", "AVAILABLE").containsEntry("lifecycle_state", "AVAILABLE");
        String key = (String) row.get("storage_key");
        UUID outboxId = jdbc.queryForObject("SELECT id FROM attachment_object_outbox WHERE storage_key=? AND operation='DELETE_STAGING'", UUID.class, key);
        return new Intake(job, key, (String) row.get("storage_version"), ((Number) row.get("storage_size")).longValue(),
                (String) row.get("storage_sha256"), outboxId);
    }

    /** Same, plus the ordinary outbox worker run (the live row is SUCCEEDED and the staging copy is gone). */
    public Intake aiIntake(String name) {
        Intake intake = aiIntakeWithoutWorker(name);
        while (outboxWorker.processNext()) { }
        var ticket = jdbc.queryForMap("SELECT status,attachment_id,upload_session_id,storage_version,operation FROM attachment_object_outbox WHERE id=?", intake.outboxId());
        assertThat(ticket).containsEntry("status", "SUCCEEDED").containsEntry("operation", "DELETE_STAGING")
                .containsEntry("attachment_id", null).containsEntry("upload_session_id", null)
                .containsEntry("storage_version", intake.version());
        assertThat(internal.describe(intake.key()).exists()).as("staging deleted by ordinary worker").isFalse();
        return intake;
    }

    public Stored storeStaging(String category, String name) {
        byte[] bytes = ("business original " + name + " " + UUID.randomUUID()).getBytes(StandardCharsets.UTF_8);
        String key = internal.presignUpload(new StorageService.UploadRequest(category, name, "application/pdf", bytes.length)).storageKey();
        internal.store(key, new ByteArrayInputStream(bytes), bytes.length, "application/pdf");
        var staged = internal.describe(key);
        return new Stored(key, staged.versionId(), bytes.length, ImmutableDocumentStore.digest(bytes), staged.storedSize(), staged.encoding(), name);
    }

    public Stored storeFinal(String category, String name) {
        Stored staged = storeStaging(category, name);
        var promoted = internal.promoteToFinal(staged.key(), internal.describe(staged.key()));
        internal.deleteStaging(staged.key(), staged.version());
        return new Stored(staged.key(), promoted.versionId(), staged.size(), staged.sha(), promoted.storedSize(), promoted.encoding(), name);
    }

    public UUID attachment(String ownerType, Stored object, String state) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,storage_version,original_name,content_type,size_bytes,sha256,
                    storage_provider,stored_size_bytes,storage_encoding,lifecycle_state,scan_engine,scanned_at,promoted_at,delete_requested_at)
                VALUES(?,?,?,?,?,?,'application/pdf',?,?,'internal',?,?,?,'private-test-clean',now(),now(),now())
                """, id, ownerType, UUID.randomUUID(), object.key(), object.version(), object.name(), object.size(), object.sha(),
                object.storedSize(), object.encoding(), state);
        return id;
    }

    public void outbox(UUID attachment, String operation, Stored object, String status, int attempts) {
        jdbc.update("""
                INSERT INTO attachment_object_outbox(attachment_id,operation,storage_provider,storage_key,storage_version,dedupe_key,status,attempts,completed_at)
                VALUES(?,?,'internal',?,?,?,?,?,CASE WHEN ? IN('SUCCEEDED','RETAINED_HISTORY') THEN now() END)
                """, attachment, operation, object.key(), object.version(), "internal|" + operation + "|" + object.key() + "|" + object.version(),
                status, attempts, status);
    }

    public UUID session(String ownerType, Stored object, String status, Instant expires, String stagingVersion) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO attachment_upload_sessions(id,storage_key,owner_type,owner_id,user_id,original_name,content_type,expected_size_bytes,
                    expires_at,status,storage_provider,staging_version,sha256)
                VALUES(?,?,?,?,?,?,'application/pdf',?,?,?,'internal',?,NULL)
                """, id, object.key(), ownerType, UUID.randomUUID(), aiUser, object.name(), object.size(), Timestamp.from(expires), status, stagingVersion);
        return id;
    }

    /** Mirrors SalesQuoteTemplateStore.stage: private object + upsert candidate + self-contained DELETE_STAGING ticket. */
    public Stored stageCandidate(UUID job, String name, String fingerprintSeed) {
        byte[] bytes = ("PK template " + name + " " + UUID.randomUUID()).getBytes(StandardCharsets.UTF_8);
        Stored[] out = new Stored[1];
        tx.executeWithoutResult(status -> {
            bindAdmin();
            var ref = documents.save("SALES_QUOTE_TEMPLATE", "template.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", bytes);
            var named = new NamedParameterJdbcTemplate(jdbc);
            var args = new org.springframework.jdbc.core.namedparam.MapSqlParameterSource().addValue("job", job).addValue("actor", aiUser).addValue("name", name)
                    .addValue("fingerprint", ImmutableDocumentStore.digest(fingerprintSeed.getBytes(StandardCharsets.UTF_8)))
                    .addValue("provider", ref.provider()).addValue("key", ref.key()).addValue("objectVersion", ref.version())
                    .addValue("size", ref.size()).addValue("sha", ref.sha256());
            named.update("""
                    INSERT INTO sales_quote_template_candidates(job_id,actor_user_id,source_name,fingerprint,mapping,features,
                        storage_provider,storage_key,storage_version,storage_size,storage_sha256)
                    VALUES(:job,:actor,:name,:fingerprint,CAST('{}' AS jsonb),CAST('{}' AS jsonb),
                        :provider,:key,:objectVersion,:size,:sha)
                    ON CONFLICT(job_id) DO UPDATE SET workbook_bytes=NULL,mapping=EXCLUDED.mapping,
                        features=EXCLUDED.features,fingerprint=EXCLUDED.fingerprint,source_name=EXCLUDED.source_name,
                        storage_provider=EXCLUDED.storage_provider,storage_key=EXCLUDED.storage_key,
                        storage_version=EXCLUDED.storage_version,storage_size=EXCLUDED.storage_size,
                        storage_sha256=EXCLUDED.storage_sha256,expires_at=now()+interval '7 days'
                    """, args);
            named.update("""
                    INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                    VALUES('DELETE_STAGING',:provider,:key,:objectVersion,
                        :provider || '|DELETE_STAGING|' || :key || '|' || COALESCE(CAST(:objectVersion AS text),'<local>'))
                    ON CONFLICT(dedupe_key) DO NOTHING
                    """, args);
            out[0] = new Stored(ref.key(), ref.version(), ref.size(), ref.sha256(), 0, null, name);
        });
        return out[0];
    }

    public boolean finalExists(String key) {
        return internal.inspectObject(StorageService.ObjectLocation.FINAL, key).exists();
    }

    public boolean stagingExists(String key) {
        return internal.inspectObject(StorageService.ObjectLocation.STAGING, key).exists();
    }

    /** Files deleted by the most recent completed reset. */
    public long lastDeletedFiles(BusinessDataResetService service) {
        return service.lastResult().deletedAttachmentFiles();
    }

    @Override
    public void close() throws Exception {
        if (entityManagerFactory != null) entityManagerFactory.close();
        if (database != null) database.close();
    }
}
