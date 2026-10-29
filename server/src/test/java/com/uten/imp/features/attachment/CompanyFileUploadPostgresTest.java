package com.uten.imp.features.attachment;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditActorDirectory;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.files.malware.MalwareScanner;
import com.uten.imp.common.files.malware.MalwareScanUnavailableException;
import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.companyfiles.*;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.features.attachment.dto.*;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManagerFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.data.jpa.repository.support.JpaRepositoryFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.env.MockEnvironment;
import org.springframework.orm.jpa.*;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;
import java.io.ByteArrayOutputStream;
import java.util.concurrent.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.AdditionalAnswers.delegatesTo;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Full upload protocol through real controllers/services/PG/immutable development-disk objects.
 * Scanner is an explicit bounded deterministic fixture; this does not certify installed ClamAV.
 * MockMvc tests owner enforcement inside services; JWT/filter/step-up have separate contract tests.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class CompanyFileUploadPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory entityFactory;
    static JdbcTemplate db;
    static PlatformTransactionManager transactions;
    static AttachmentRepository actualRepository;
    @TempDir Path directory;
    final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    SecurityContextCurrentUser current;
    CompanyFileService library;
    AttachmentService attachmentService;
    MalwareScanner scanner;
    MockMvc mvc;
    UUID actor,employee,session;
    AuthUser user;
    static final Set<String> ALL=Set.of("company_file:view","company_file:download","company_file:upload","company_file:create",
            "company_file:edit","company_file:move","company_file:delete","company_file:restore","company_file:manage_permissions",
            "attachment:view","attachment:upload","attachment:download","attachment:delete");

    @BeforeAll static void start()throws Exception {
        database=MigratedSchemaBaseline.openDatabase("company_file_upload_protocol");
        var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        var connectionProperties=new Properties();
        connectionProperties.setProperty("options","-c lock_timeout=3000 -c statement_timeout=10000");
        source.setConnectionProperties(connectionProperties);
        db=new JdbcTemplate(source);
        var bean=new LocalContainerEntityManagerFactoryBean();bean.setDataSource(source);
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());bean.setPackagesToScan("com.uten.imp.features.attachment");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto","none",
                "hibernate.physical_naming_strategy","org.hibernate.boot.model.naming.CamelCaseToUnderscoresNamingStrategy"));
        bean.afterPropertiesSet();entityFactory=bean.getObject();
        actualRepository=new JpaRepositoryFactory(SharedEntityManagerCreator.createSharedEntityManager(entityFactory)).getRepository(AttachmentRepository.class);
        transactions=new JpaTransactionManager(entityFactory);
    }
    @AfterAll
    static void stop() throws Exception {
        if (entityFactory != null) {
            entityFactory.close();
        }
        if (database != null) {
            database.close();
        }
    }
    @SuppressWarnings("unchecked") static <T>T transactional(T target) {
        var factory=new ProxyFactory(target);factory.setProxyTargetClass(true);
        var interceptor=new TransactionInterceptor();interceptor.setTransactionManager(transactions);
        interceptor.setTransactionAttributeSource(new AnnotationTransactionAttributeSource(false));
        factory.addAdvice(interceptor);
        return (T)factory.getProxy();
    }
    @BeforeEach void setup()throws Exception {
        actor=UUID.randomUUID();employee=UUID.randomUUID();session=UUID.randomUUID();
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) "
                +"SELECT ?,?,?,'其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",employee,"UP-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("文件上传测试人",employee));
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',false)",actor,employee,"upload-"+actor);
        current=mock(SecurityContextCurrentUser.class);login(ALL,session);
        var properties=new StorageProperties();properties.setProvider("local");properties.setLocalDir(directory.toString());properties.setUploadsEnabled(true);
        properties.getInternal().setMinFreeBytes(0);properties.getMalwareScan().setProvider("test-only");
        var storage=new LocalDiskStorageService(properties);ReflectionTestUtils.invokeMethod(storage,"init");
        var providers=new StorageProviderRegistry(storage,properties);
        scanner=mock(MalwareScanner.class);when(scanner.provider()).thenReturn("test-only");when(scanner.probe()).thenReturn(true);
        when(scanner.scan(any(),anyLong())).thenAnswer(invocation->{
            try(var input=(java.io.InputStream)invocation.getArgument(0)) {
                byte[] content=input.readAllBytes();
                if(content.length!=(long)invocation.getArgument(1))throw new MalwareScanUnavailableException("fixture length mismatch");
                boolean eicar=new String(content,StandardCharsets.ISO_8859_1).contains("EICAR-STANDARD-ANTIVIRUS-TEST-FILE");
                return new MalwareScanner.ScanResult(eicar?MalwareScanner.Verdict.INFECTED:MalwareScanner.Verdict.CLEAN,"test-only",eicar?"EICAR-Test-Signature":"test-clean");
            }
        });
        var audit=mock(AuditService.class);var access=mock(AttachmentAccessPort.class);
        var crypto=new CryptoProperties();crypto.setHmacKey("company-file-isolated-test-hmac-key-that-is-never-used-in-production");
        library=transactional(new CompanyFileService(db,current,access,audit,new CompanyFileUnlocks(),new CompanyFileCreationFingerprint(crypto)));
        var policy=transactional(new CompanyFileAttachmentAccessPolicy(library));
        var sessions=transactional(new AttachmentUploadSessionStore(db,properties));var outbox=new AttachmentObjectOutboxStore(db);
        var repository=mock(AttachmentRepository.class,delegatesTo(actualRepository));
        // Explicit auditing fixture in this small JPA context; production uses JpaAuditingConfig.
        doAnswer(invocation->{Attachment value=invocation.getArgument(0);if(value.isNew()){
                value.setCreatedAt(Instant.now());value.setCreatedBy(user.getId());}
            value.setUpdatedAt(Instant.now());value.setUpdatedBy(user.getId());return actualRepository.saveAndFlush(value);
        }).when(repository).saveAndFlush(any());
        var confirms=transactional(new AttachmentConfirmTransaction(repository,sessions,outbox,db));
        var gate=new AttachmentUploadSafetyGate(properties,storage,scanner,new MockEnvironment().withProperty("spring.profiles.active","dev"));
        gate.validateConfiguration();
        attachmentService=transactional(new AttachmentService(storage,repository,properties,current,List.of(policy),
                new AttachmentUploadGrantService(json,crypto),audit,confirms,gate,sessions,scanner,outbox,providers,
                new AttachmentDownloadVerifier(providers,properties),mock(AuditActorDirectory.class)));
        when(access.listVisible(anyString(),any(UUID.class))).thenAnswer(invocation->attachmentService.listVisible(invocation.getArgument(0),invocation.getArgument(1)));
        mvc=MockMvcBuilders.standaloneSetup(new AttachmentController(attachmentService,mock(AttachmentReconciliationService.class),
                        mock(AttachmentPreviewService.class),mock(com.uten.imp.audit.AuditDetailViewRecorder.class)),
                        new CompanyFileController(library,new com.uten.imp.audit.AuditDetailViewRecorder(audit,current)))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }
    void login(Set<String> permissions,UUID sid) {
        user=new AuthUser(actor,employee,"file-protocol-test",permissions,false,true,false,false,null,sid);
        when(current.get()).thenReturn(Optional.of(user));
    }
    Entry folder(){return library.createFolder(new Create(null,"protocol-"+UUID.randomUUID(),null));}
    Entry reserve(UUID parent,String name){return library.reserveFile(new Create(parent,name,null));}
    AttachmentPresignResponse presign(Entry entry,String type,byte[] bytes)throws Exception {
        String body=mvc.perform(post("/api/attachments/presign").contentType("application/json")
                .content(json.writeValueAsBytes(new AttachmentPresignRequest("COMPANY_FILE",entry.id(),entry.name(),type,(long)bytes.length))))
                .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readValue(body,AttachmentPresignResponse.class);
    }
    void raw(AttachmentPresignResponse grant,String type,byte[] bytes)throws Exception {
        mvc.perform(put("/api/attachments/raw/"+grant.storageKey()).header("X-Uten-Attachment-Upload-Token",grant.confirmToken())
                .contentType(type).content(bytes)).andExpect(status().isNoContent());
    }
    AttachmentConfirmRequest request(Entry entry,AttachmentPresignResponse grant,String type,byte[] bytes) {
        return new AttachmentConfirmRequest(grant.storageKey(),grant.confirmToken(),"COMPANY_FILE",entry.id(),entry.name(),type,(long)bytes.length,null,null);
    }
    AttachmentDto confirm(Entry entry,AttachmentPresignResponse grant,String type,byte[] bytes)throws Exception {
        String body=mvc.perform(post("/api/attachments/confirm").contentType("application/json")
                .content(json.writeValueAsBytes(request(entry,grant,type,bytes)))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readValue(body,AttachmentDto.class);
    }
    Entry publish(Entry entry,AttachmentDto original)throws Exception {
        String body=mvc.perform(post("/api/company-files/"+entry.id()+"/complete").contentType("application/json")
                .content(json.writeValueAsBytes(new Complete(original.id(),entry.version())))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
        return json.readValue(body,Entry.class);
    }

    @Test void initialPrivateFilePasswordPreservesStandardUploadAndProtectsEveryPublishedReadPath()throws Exception {
        UUID requestId=UUID.randomUUID();
        var create=new Create(null,"受保护模板.txt",null,requestId,new InitialAccess(false,List.of(),"initial-file-password"));
        String reserved=mvc.perform(post("/api/company-files/files").contentType("application/json")
                .content(json.writeValueAsBytes(create))).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
        Entry entry=json.readValue(reserved,Entry.class);byte[] bytes="protected original\n".repeat(30).getBytes(StandardCharsets.UTF_8);
        var grant=presign(entry,"text/plain",bytes);raw(grant,"text/plain",bytes);
        var original=confirm(entry,grant,"text/plain",bytes);
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isForbidden());
        assertThatThrownBy(()->attachmentService.openPreviewSource(original.id())).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        Entry published=publish(entry,original);assertThat(published.locked()).isTrue();
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isForbidden());
        mvc.perform(get("/api/attachments/"+original.id()+"/download-grant")).andExpect(status().isForbidden());
        mvc.perform(get("/api/attachments/"+original.id()+"/history/download")).andExpect(status().isForbidden());
        assertThatThrownBy(()->attachmentService.openPreviewSource(original.id())).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        library.unlock(published.id(),new Unlock("initial-file-password"));
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk()).andExpect(content().bytes(bytes));
        try(var source=attachmentService.openPreviewSource(original.id()).open()) {assertThat(source.readAllBytes()).isEqualTo(bytes);}
        Entry rotated=library.setPassword(published.id(),new Password("rotated-file-password",published.version()));
        Entry replay=library.reserveFile(create);assertThat(replay.id()).isEqualTo(published.id());assertThat(replay.locked()).isTrue();
        assertThat(replay.version()).isEqualTo(rotated.version());
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isForbidden());
        library.unlock(published.id(),new Unlock("rotated-file-password"));
        library.setPermissions(published.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("download"))),rotated.version()));
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isForbidden());
        assertThatThrownBy(()->attachmentService.openPreviewSource(original.id())).isInstanceOf(com.uten.imp.common.web.ApiException.class);
    }

    @Test void chineseTextWordAndExcelTemplatesRoundTripWithIdenticalBytesAndDigest()throws Exception {
        Entry parent=folder();
        var cases=List.of(new Document("中文模板.txt","text/plain","中文模板原件，不能被缩图或重新编码\n".repeat(300).getBytes(StandardCharsets.UTF_8)),
                new Document("工作说明.docx","application/vnd.openxmlformats-officedocument.wordprocessingml.document",wordTemplate()),
                new Document("登记表.xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",excelTemplate()));
        for(Document document:cases){
            Entry entry=reserve(parent.id(),document.name);var grant=presign(entry,document.type,document.bytes);raw(grant,document.type,document.bytes);
            AttachmentDto original=confirm(entry,grant,document.type,document.bytes);Entry published=publish(entry,original);
            assertThat(published.pending()).isFalse();assertThat(published.attachmentId()).isEqualTo(original.id());
            assertThat(original.sha256()).isEqualTo(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(document.bytes)));
            mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk())
                    .andExpect(header().string("Cache-Control","private, no-store")).andExpect(header().string("X-Content-Type-Options","nosniff"))
                    .andExpect(content().bytes(document.bytes));
            assertThat(db.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,grant.storageKey())).isEqualTo("PROMOTED");
        }
    }

    @Test void eicarIsQuarantinedAndCannotBePublishedOrDownloaded()throws Exception {
        Entry entry=reserve(folder().id(),"安全测试.txt");byte[] bytes="EICAR-STANDARD-ANTIVIRUS-TEST-FILE".getBytes(StandardCharsets.US_ASCII);
        var grant=presign(entry,"text/plain",bytes);raw(grant,"text/plain",bytes);
        mvc.perform(post("/api/attachments/confirm").contentType("application/json").content(json.writeValueAsBytes(request(entry,grant,"text/plain",bytes))))
                .andExpect(status().isUnprocessableContent());
        assertThat(db.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,grant.storageKey())).isEqualTo("REJECTED");
        assertThat(db.queryForObject("SELECT count(*) FROM attachments WHERE owner_id=?",Integer.class,entry.id())).isZero();
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isNotFound());
        assertThat(library.detail(entry.id()).pending()).isTrue();
    }

    @Test void arbitraryDesignModelAndExtensionlessOriginalsUseTheCompleteProtocolWithoutConversion()throws Exception {
        Entry parent=folder();
        byte[] bytes=new byte[]{'R','I','F','F',0,1,2,3,'C','D','R','X',0,(byte)0xff,0x7f};
        for(String name:List.of("设计原件.CDR","机械部件.step","装配.sldasm","工程.blend","无扩展名","storage-only.docx")) {
            Entry entry=reserve(parent.id(),name);var grant=presign(entry,"application/octet-stream",bytes);
            raw(grant,"application/octet-stream",bytes);var original=confirm(entry,grant,"application/octet-stream",bytes);
            assertThat(confirm(entry,grant,"application/octet-stream",bytes).id()).isEqualTo(original.id());
            Entry published=publish(entry,original);
            assertThat(published.pending()).isFalse();
            assertThat(original.contentType()).isEqualTo("application/octet-stream");
            assertThat(original.sha256()).isEqualTo(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)));
            mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk())
                    .andExpect(header().string("Content-Type","application/octet-stream"))
                    .andExpect(header().string("Content-Disposition",org.hamcrest.Matchers.startsWith("attachment;")))
                    .andExpect(header().string("X-Content-Type-Options","nosniff"))
                    .andExpect(content().bytes(bytes));
            assertThatThrownBy(()->attachmentService.openPreviewSource(original.id()))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                    .hasMessageContaining("下载原件");
        }
    }

    @Test void opaqueFilesStillFailClosedWhenMalwareIsFoundOrTheScannerIsUnavailable()throws Exception {
        Entry infected=reserve(folder().id(),"扫描测试.cdr");
        byte[] eicar="\u0000EICAR-STANDARD-ANTIVIRUS-TEST-FILE".getBytes(StandardCharsets.US_ASCII);
        var infectedGrant=presign(infected,"application/octet-stream",eicar);raw(infectedGrant,"application/octet-stream",eicar);
        mvc.perform(post("/api/attachments/confirm").contentType("application/json")
                .content(json.writeValueAsBytes(request(infected,infectedGrant,"application/octet-stream",eicar))))
                .andExpect(status().isUnprocessableContent());
        assertThat(db.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,infectedGrant.storageKey())).isEqualTo("REJECTED");
        assertThat(db.queryForObject("SELECT count(*) FROM attachments WHERE owner_id=?",Integer.class,infected.id())).isZero();
        mvc.perform(get("/api/attachments/raw/"+infectedGrant.storageKey())).andExpect(status().isNotFound());

        Entry waiting=reserve(folder().id(),"稍后确认.step");byte[] bytes={0,1,2,3,4};
        var waitingGrant=presign(waiting,"application/octet-stream",bytes);raw(waitingGrant,"application/octet-stream",bytes);
        doThrow(new MalwareScanUnavailableException("isolated fixture unavailable")).when(scanner).scan(any(),anyLong());
        mvc.perform(post("/api/attachments/confirm").contentType("application/json")
                .content(json.writeValueAsBytes(request(waiting,waitingGrant,"application/octet-stream",bytes))))
                .andExpect(status().isBadRequest());
        assertThat(db.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,waitingGrant.storageKey())).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT count(*) FROM attachments WHERE owner_id=?",Integer.class,waiting.id())).isZero();
    }

    @Test void mediaOriginalsRetainTheirVerifiedContainerTypeAndOriginalBytes()throws Exception {
        Entry entry=reserve(folder().id(),"培训录像.mp4");
        byte[] bytes={0,0,0,24,'f','t','y','p','i','s','o','m',0,0,0,0,'m','p','4','2',0,0,0,0};
        var grant=presign(entry,"video/mp4",bytes);raw(grant,"video/mp4",bytes);
        var original=confirm(entry,grant,"video/mp4",bytes);publish(entry,original);
        assertThat(original.contentType()).isEqualTo("video/mp4");
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk())
                .andExpect(header().string("Content-Type","video/mp4"))
                .andExpect(content().bytes(bytes));
    }

    @Test void libraryFormatsDoNotWidenBusinessAttachmentIntakeOrSkipTheSizeLimit()throws Exception {
        for(String type:List.of("application/octet-stream","video/mp4","audio/mpeg")) {
            mvc.perform(post("/api/attachments/presign").contentType("application/json")
                    .content(json.writeValueAsBytes(new AttachmentPresignRequest(
                            "SALES_ORDER",UUID.randomUUID(),"business-file.cdr",type,10L))))
                    .andExpect(status().isUnprocessableContent());
        }
        Entry entry=reserve(folder().id(),"超额原件.cdr");
        mvc.perform(post("/api/attachments/presign").contentType("application/json")
                .content(json.writeValueAsBytes(new AttachmentPresignRequest(
                        "COMPANY_FILE",entry.id(),entry.name(),"application/octet-stream",25L*1024*1024+1))))
                .andExpect(status().is(413));
        assertThat(db.queryForObject("SELECT count(*) FROM attachment_upload_sessions WHERE owner_id=?",Integer.class,entry.id())).isZero();
    }

    @Test void unsupportedMediaVariantsArchiveAsOpaqueAndKeepTheSignedDeclarationIdempotent()throws Exception {
        var originals=List.of(
                new Document("legacy.mov","video/quicktime",new byte[]{0,0,0,8,'w','i','d','e',0,0,0,16,'m','d','a','t',0,1,2,3,4,5,6,7}),
                new Document("av1.mp4","video/mp4",new byte[]{0,0,0,24,'f','t','y','p','a','v','0','1',0,0,0,0,'a','v','0','1','i','s','o','m'}),
                new Document("unrecognized.wav","audio/wav",new byte[]{0,1,2,3,4,5}));
        Entry parent=folder();
        for(var document:originals) {
            Entry entry=reserve(parent.id(),document.name());var grant=presign(entry,document.type(),document.bytes());
            raw(grant,document.type(),document.bytes());var original=confirm(entry,grant,document.type(),document.bytes());
            assertThat(original.contentType()).isEqualTo("application/octet-stream");
            assertThat(original.sha256()).isEqualTo(HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(document.bytes())));
            assertThat(confirm(entry,grant,document.type(),document.bytes()).id()).isEqualTo(original.id());
            assertThat(db.queryForObject("SELECT content_type FROM attachment_upload_sessions WHERE storage_key=?",String.class,grant.storageKey())).isEqualTo(document.type());
            // Replaying a different declaration with the same token must still fail before identity reconciliation.
            mvc.perform(post("/api/attachments/confirm").contentType("application/json")
                    .content(json.writeValueAsBytes(request(entry,grant,"application/octet-stream",document.bytes()))))
                    .andExpect(status().isForbidden());
            Entry published=publish(entry,original);
            assertThat(published.contentType()).isEqualTo("application/octet-stream");
            mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk())
                    .andExpect(header().string("Content-Type","application/octet-stream"))
                    .andExpect(header().string("Content-Disposition",org.hamcrest.Matchers.startsWith("attachment;")))
                    .andExpect(header().string("X-Content-Type-Options","nosniff"))
                    .andExpect(content().bytes(document.bytes()));
            assertThatThrownBy(()->attachmentService.openPreviewSource(original.id()))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("下载原件");
        }
        verify(scanner,times(originals.size())).scan(any(),anyLong());
    }

    @Test void scannerUnavailableNeverPublishesAndKeepsTheSameReservationRetryable()throws Exception {
        Entry entry=reserve(folder().id(),"retry.txt");byte[] bytes="retry same original".getBytes(StandardCharsets.UTF_8);
        var grant=presign(entry,"text/plain",bytes);raw(grant,"text/plain",bytes);
        doThrow(new MalwareScanUnavailableException("isolated fixture unavailable")).when(scanner).scan(any(),anyLong());
        mvc.perform(post("/api/attachments/confirm").contentType("application/json").content(json.writeValueAsBytes(request(entry,grant,"text/plain",bytes))))
                .andExpect(status().isBadRequest());
        assertThat(db.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,grant.storageKey())).isEqualTo("PENDING");
        assertThat(db.queryForObject("SELECT count(*) FROM attachments WHERE owner_id=?",Integer.class,entry.id())).isZero();
        doAnswer(invocation->{try(var input=(java.io.InputStream)invocation.getArgument(0)){input.readAllBytes();}
            return new MalwareScanner.ScanResult(MalwareScanner.Verdict.CLEAN,"test-only","recovered");}).when(scanner).scan(any(),anyLong());
        assertThat(publish(entry,confirm(entry,grant,"text/plain",bytes)).pending()).isFalse();
    }

    @Test void changedOwnerAndRevokedAclBlockTheOldUploadTokenBeforeBytesReachStorage()throws Exception {
        Entry parent=folder();Entry entry=reserve(parent.id(),"old-token.txt");byte[] bytes="authorized bytes".getBytes(StandardCharsets.UTF_8);
        var grant=presign(entry,"text/plain",bytes);
        library.setPermissions(parent.id(),new Permissions(true,List.of(new Rule("USER",actor,null,"DENY",List.of("upload"))),parent.version()));
        mvc.perform(put("/api/attachments/raw/"+grant.storageKey()).header("X-Uten-Attachment-Upload-Token",grant.confirmToken()).contentType("text/plain").content(bytes))
                .andExpect(status().isForbidden());
        assertThat(java.nio.file.Files.exists(directory.resolve("staging").resolve(grant.storageKey()))).isFalse();
        Entry other=reserve(folder().id(),"other.txt");
        var forged=new AttachmentConfirmRequest(grant.storageKey(),grant.confirmToken(),"COMPANY_FILE",other.id(),entry.name(),"text/plain",(long)bytes.length,null,null);
        mvc.perform(post("/api/attachments/confirm").contentType("application/json").content(json.writeValueAsBytes(forged))).andExpect(status().isForbidden());
    }

    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.ValueSource(strings={"text/plain","application/octet-stream"})
    void passwordRevocationAndRecycleAreEnforcedOnGenericRawAndHistoryDownloadRoutes(String type)throws Exception {
        Entry parent=folder();Entry entry=reserve(parent.id(),type.equals("text/plain")?"confidential.txt":"confidential.cdr");byte[] bytes="confidential".getBytes(StandardCharsets.UTF_8);
        var grant=presign(entry,type,bytes);raw(grant,type,bytes);var original=confirm(entry,grant,type,bytes);Entry published=publish(entry,original);
        Entry locked=library.setPassword(parent.id(),new Password("private-folder-password",parent.version()));
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isNotFound());
        mvc.perform(get("/api/attachments/"+original.id()+"/history/download")).andExpect(status().isNotFound());
        library.unlock(parent.id(),new Unlock("private-folder-password"));
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk()).andExpect(content().bytes(bytes));
        login(ALL,UUID.randomUUID());
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isNotFound());
        login(ALL,session);
        library.delete(published.id(),published.version());
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isNotFound());
        mvc.perform(get("/api/attachments/"+original.id()+"/history/download")).andExpect(status().isNotFound());
        assertThat(db.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,original.id())).isEqualTo("CLEAN");
        library.restore(published.id(),new Version(published.version()+1));
        mvc.perform(get("/api/attachments/raw/"+grant.storageKey())).andExpect(status().isOk()).andExpect(content().bytes(bytes));
        assertThat(locked.passwordProtected()).isTrue();
    }

    @Test void simultaneousGenericConfirmsReleaseReadAuthorizationBeforeExclusivePersistenceAndDoNotDeadlock()throws Exception {
        Entry parent=folder();byte[] firstBytes="first concurrent original".getBytes(StandardCharsets.UTF_8);
        byte[] secondBytes="second concurrent original".getBytes(StandardCharsets.UTF_8);
        Entry first=reserve(parent.id(),"first.txt"),second=reserve(parent.id(),"second.txt");
        var firstGrant=presign(first,"text/plain",firstBytes);var secondGrant=presign(second,"text/plain",secondBytes);
        raw(firstGrant,"text/plain",firstBytes);raw(secondGrant,"text/plain",secondBytes);
        var start=new CountDownLatch(1);var executor=Executors.newFixedThreadPool(2);
        try{
            Future<Entry> firstResult=executor.submit(()->{start.await();return publish(first,confirm(first,firstGrant,"text/plain",firstBytes));});
            Future<Entry> secondResult=executor.submit(()->{start.await();return publish(second,confirm(second,secondGrant,"text/plain",secondBytes));});
            start.countDown();
            Entry firstPublished=firstResult.get(15,TimeUnit.SECONDS),secondPublished=secondResult.get(15,TimeUnit.SECONDS);
            assertThat(firstPublished.pending()).isFalse();assertThat(secondPublished.pending()).isFalse();
            mvc.perform(get("/api/attachments/raw/"+firstGrant.storageKey())).andExpect(status().isOk()).andExpect(content().bytes(firstBytes));
            mvc.perform(get("/api/attachments/raw/"+secondGrant.storageKey())).andExpect(status().isOk()).andExpect(content().bytes(secondBytes));
        }finally{
            start.countDown();executor.shutdownNow();assertThat(executor.awaitTermination(15,TimeUnit.SECONDS)).isTrue();
        }
    }

    static byte[] wordTemplate()throws Exception {
        try(var document=new org.apache.poi.xwpf.usermodel.XWPFDocument();var bytes=new ByteArrayOutputStream()){
            document.createParagraph().createRun().setText("公司内部工作说明模板");document.write(bytes);return bytes.toByteArray();
        }
    }
    static byte[] excelTemplate()throws Exception {
        try(var workbook=new org.apache.poi.xssf.usermodel.XSSFWorkbook();var bytes=new ByteArrayOutputStream()){
            var sheet=workbook.createSheet("登记表");sheet.createRow(0).createCell(0).setCellValue("姓名");
            sheet.createRow(1).createCell(0).setCellValue("模板示例");workbook.write(bytes);return bytes.toByteArray();
        }
    }
    record Document(String name,String type,byte[] bytes){}
}
