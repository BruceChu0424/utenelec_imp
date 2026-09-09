package com.uten.imp.common.storage;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.AttachmentObjectOutboxProcessor;
import com.uten.imp.features.attachment.AttachmentReconciliationService;
import com.uten.imp.features.org.employee.EmployeeAttachmentAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.containers.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.assertThat;

/** Actual HTTP/authorization/JPA/Flyway/queue flow; native fsync is proved separately on Linux. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.storage.provider=local","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.storage.outbox.poll-delay-millis=60000",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.jwt.secret=internal-attachment-pipeline-test-only-jwt-0123456789",
        "uten.crypto.pgp-master-key=internal-attachment-pipeline-test-only-pgp-0123456789",
        "uten.crypto.hmac-key=internal-attachment-pipeline-test-only-hmac-0123456789",
        "uten.bootstrap.admin-login=internal-attachment-test",
        "uten.bootstrap.admin-password=InternalAttachmentInitial-1!"})
@Import(InternalAttachmentLifecyclePostgresTest.StoreConfiguration.class)
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners=InternalAttachmentLifecyclePostgresTest.Cleanup.class,
        mergeMode=TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class InternalAttachmentLifecyclePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    private static final Path ROOT=temporaryRoot();
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        POSTGRES.start();registry.add("spring.datasource.url",POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username",POSTGRES::getUsername);registry.add("spring.datasource.password",POSTGRES::getPassword);
        registry.add("uten.storage.local-dir",()->ROOT.resolve("development-local").toString());
        registry.add("uten.storage.internal.root",()->ROOT.toString());registry.add("uten.storage.internal.min-free-bytes",()->0);
    }
    @TestConfiguration(proxyBeanMethods=false)
    static class StoreConfiguration {
        @Bean @Primary InternalStorageService testInternalStorage(StorageProperties properties) {
            // Real codec/files/limits; only the OS directory-sync syscall is
            // injected for Windows. No production property can select this callback.
            return new InternalStorageService(properties,path->{});
        }
    }
    @Autowired TestRestTemplate http;
    @Autowired JdbcTemplate jdbc;
    @Autowired AttachmentObjectOutboxProcessor outbox;
    @Autowired AttachmentReconciliationService reconciliation;
    @Autowired StorageService storage;
    @Autowired StorageProperties properties;
    @MockitoSpyBean EmployeeAttachmentAccessPolicy ownerPolicy;
    private String token,refresh,password="InternalAttachmentInitial-1!",employee;

    @BeforeEach void login() {
        var response=http.postForEntity("/api/auth/login",Map.of("loginAccount","internal-attachment-test","password",password),JsonNode.class);
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        token=response.getBody().path("accessToken").asText();refresh=response.getBody().path("refreshToken").asText();
        var profile=json(HttpMethod.GET,"/api/auth/me",null,HttpStatus.OK);
        if(profile.path("mustChangePassword").asBoolean()) {
            String replacement="InternalAttachmentChanged-2!";
            var changed=json(HttpMethod.POST,"/api/auth/change-password",Map.of("oldPassword",password,"newPassword",replacement),HttpStatus.OK);
            token=changed.path("accessToken").asText();refresh=changed.path("refreshToken").asText();password=replacement;
            profile=json(HttpMethod.GET,"/api/auth/me",null,HttpStatus.OK);
        }
        employee=profile.path("employeeId").asText();assertThat(employee).isNotBlank();
    }
    @AfterEach void logout() {
        http.postForEntity("/api/auth/logout",Map.of("refreshToken",refresh),Void.class);token=null;refresh=null;
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder()-1; }
        @Override public void afterTestClass(TestContext ignored) throws Exception {
            // afterTestClass listeners run in reverse order: Spring closes its
            // context first, then its owned database and private files stop.
            POSTGRES.stop();
            assertThat(ROOT.getFileName().toString()).startsWith("uten-internal-pipeline-");
            org.springframework.util.FileSystemUtils.deleteRecursively(ROOT);
        }
    }

    @Test void realUploadConfirmationDownloadAndDeletionPreserveOriginalMetadata() throws Exception {
        byte[] bytes="原始文件 不转换不裁剪 abcdefghijklmnopqrstuvwxyz\n".repeat(4000).getBytes(StandardCharsets.UTF_8);
        Upload upload=upload("原始文件.txt","text/plain",bytes);
        UUID id=UUID.fromString(upload.attachment.path("id").asText());
        assertThat(upload.attachment.path("originalName").asText()).isEqualTo("原始文件.txt");
        assertThat(upload.attachment.path("sizeBytes").asLong()).isEqualTo(bytes.length);
        var stored=jdbc.queryForMap("SELECT size_bytes,stored_size_bytes,storage_provider,storage_encoding,sha256,lifecycle_state FROM attachments WHERE id=?",id);
        assertThat(stored).containsEntry("storage_provider","internal").containsEntry("storage_encoding","GZIP")
                .containsEntry("sha256",sha(bytes)).containsEntry("lifecycle_state","CLEAN");
        assertThat(((Number)stored.get("stored_size_bytes")).longValue()).isLessThan(bytes.length);
        assertThat(jdbc.queryForMap("SELECT storage_provider,status,final_storage_encoding,sha256 FROM attachment_upload_sessions WHERE storage_key=?",upload.key))
                .containsEntry("storage_provider","internal").containsEntry("status","PROMOTED")
                .containsEntry("final_storage_encoding","GZIP").containsEntry("sha256",sha(bytes));
        var repeated=json(HttpMethod.POST,"/api/attachments/confirm",upload.confirm,HttpStatus.OK);
        assertThat(repeated.path("id").asText()).isEqualTo(id.toString());
        var grant=json(HttpMethod.GET,"/api/attachments/"+id+"/download-grant",null,HttpStatus.OK);
        var downloaded=http.exchange("/api"+grant.path("url").asText(),HttpMethod.GET,new HttpEntity<>(headers()),byte[].class);
        assertThat(downloaded.getStatusCode()).isEqualTo(HttpStatus.OK);assertThat(downloaded.getBody()).isEqualTo(bytes);
        assertThat(downloaded.getHeaders().getContentLength()).isEqualTo(bytes.length);
        assertThat(http.getForEntity("/api/attachments/raw/"+upload.key,byte[].class).getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        json(HttpMethod.DELETE,"/api/attachments/"+id,null,HttpStatus.ACCEPTED);
        for(int i=0;i<5 && outbox.processNext();i++) { /* bounded real queue drain */ }
        assertThat(jdbc.queryForMap("SELECT lifecycle_state,sha256,storage_provider FROM attachments WHERE id=?",id))
                .containsEntry("lifecycle_state","DELETED").containsEntry("sha256",sha(bytes)).containsEntry("storage_provider","internal");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE attachment_id=? AND storage_provider='internal' AND operation='DELETE_FINAL' AND status='SUCCEEDED'",Long.class,id)).isEqualTo(1L);
        assertThat(http.exchange("/api/attachments/raw/"+upload.key,HttpMethod.GET,new HttpEntity<>(headers()),byte[].class).getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test void rejectedMalwareNeverBecomesAnAttachmentAndSelectedAvatarReturnsOriginalPng() throws Exception {
        byte[] malware="EICAR-STANDARD-ANTIVIRUS-TEST-FILE".getBytes(StandardCharsets.US_ASCII);
        var reservation=reserve("scanner-proof.txt","text/plain",malware);
        put(reservation,malware,"text/plain");
        json(HttpMethod.POST,"/api/attachments/confirm",confirmation(reservation,"scanner-proof.txt","text/plain",malware),HttpStatus.UNPROCESSABLE_ENTITY);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE storage_key=?",Long.class,reservation.path("storageKey").asText())).isZero();
        assertThat(jdbc.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,reservation.path("storageKey").asText())).isEqualTo("REJECTED");
        byte[] png=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==");
        Upload avatar=upload("original.png","image/png",png);
        json(HttpMethod.POST,"/api/org/employees/"+employee+"/avatar",Map.of("attachmentId",avatar.attachment.path("id").asText()),HttpStatus.OK);
        var original=http.exchange("/api/org/employees/"+employee+"/avatar",HttpMethod.GET,new HttpEntity<>(headers()),byte[].class);
        assertThat(original.getStatusCode()).isEqualTo(HttpStatus.OK);assertThat(original.getBody()).isEqualTo(png);
        assertThat(original.getHeaders().getCacheControl()).contains("no-store");
        assertThat(original.getHeaders().getFirst("X-Content-Type-Options")).isEqualTo("nosniff");
    }

    @Test void twoBoundedUploadsDoNotBlockTheBusinessAttachmentList() throws Exception {
        byte[] bytes="0123456789abcdef\n".repeat(400000).getBytes(StandardCharsets.US_ASCII);
        var first=reserve("parallel-one.txt","text/plain",bytes);var second=reserve("parallel-two.txt","text/plain",bytes);
        put(first,bytes,"text/plain");put(second,bytes,"text/plain");
        List<Long> latency=new ArrayList<>();
        try(var executor=Executors.newFixedThreadPool(2)) {
            var a=executor.submit(()->json(HttpMethod.POST,"/api/attachments/confirm",confirmation(first,"parallel-one.txt","text/plain",bytes),HttpStatus.OK));
            var b=executor.submit(()->json(HttpMethod.POST,"/api/attachments/confirm",confirmation(second,"parallel-two.txt","text/plain",bytes),HttpStatus.OK));
            for(int i=0;i<15;i++) {
                long start=System.nanoTime();json(HttpMethod.GET,"/api/attachments?ownerType=EMPLOYEE&ownerId="+employee,null,HttpStatus.OK);
                latency.add(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-start));
            }
            assertThat(a.get(30,TimeUnit.SECONDS).path("sizeBytes").asLong()).isEqualTo(bytes.length);
            assertThat(b.get(30,TimeUnit.SECONDS).path("sizeBytes").asLong()).isEqualTo(bytes.length);
        }
        Collections.sort(latency);
        assertThat(latency.get(latency.size()-1)).isLessThan(5000);
        System.out.println("INTERNAL_ATTACHMENT_QUERY_LATENCY samples=15 bytesPerUpload="+bytes.length+" p95Millis="+latency.get(14));
    }

    @Test void pendingReservationProtectsAnAlreadyPromotedObjectUntilDatabaseConfirmationRetries() throws Exception {
        byte[] bytes="scanned original awaiting its business lock".getBytes(StandardCharsets.UTF_8);
        JsonNode grant=reserve("retry.txt","text/plain",bytes);put(grant,bytes,"text/plain");
        Map<String,Object> confirm=confirmation(grant,"retry.txt","text/plain",bytes);
        org.mockito.Mockito.doThrow(new ApiException(ErrorCode.CONFLICT,"Business owner changed concurrently"))
                .when(ownerPolicy).requireCanManageForUpdate(org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any());
        try { json(HttpMethod.POST,"/api/attachments/confirm",confirm,HttpStatus.CONFLICT); }
        finally { org.mockito.Mockito.doCallRealMethod().when(ownerPolicy)
                .requireCanManageForUpdate(org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any()); }
        String key=grant.path("storageKey").asText();
        assertThat(jdbc.queryForObject("SELECT status FROM attachment_upload_sessions WHERE storage_key=?",String.class,key)).isEqualTo("PENDING");
        properties.getReconciliation().setEnabled(true);
        try { reconciliation.reconcileInventory(storage.inventory()); }
        finally { properties.getReconciliation().setEnabled(false); }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_reconciliation_findings WHERE storage_key=? AND finding_state='OBSERVED'",Long.class,key)).isZero();
        assertThat(json(HttpMethod.POST,"/api/attachments/confirm",confirm,HttpStatus.OK).path("sizeBytes").asLong()).isEqualTo(bytes.length);
    }

    @Test void softDeletedOrderFilesMustFinishNormalDeletionBeforeBusinessResetAndHumanFilesSurvive() throws Exception {
        byte[] humanBytes="human file must survive a business reset".getBytes(StandardCharsets.UTF_8);
        Upload human=upload("human-preserved.txt","text/plain",humanBytes);
        UUID client=UUID.randomUUID(),order=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type)
                VALUES(?,'RESET-FILES-CLIENT','reset evidence client','使用',100900,'MONTHLY')
                """,client);
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,owner_employee_id,maker_id,status)
                VALUES(?,'XD20260908009991',CURRENT_DATE,?,?,?,0)
                """,order,client,UUID.fromString(employee),UUID.fromString(employee));
        byte[] bytes="original sales contract bound to a test order".getBytes(StandardCharsets.UTF_8);
        int oldExpiry=properties.getPresignedExpirySeconds();
        JsonNode grant,attachment;
        try {
            properties.setPresignedExpirySeconds(8);
            grant=json(HttpMethod.POST,"/api/attachments/presign",Map.of("ownerType","SALES_ORDER","ownerId",order,
                    "fileName","contract.txt","contentType","text/plain","sizeBytes",bytes.length),HttpStatus.OK);
            put(grant,bytes,"text/plain");
            Map<String,Object> confirm=new HashMap<>(confirmation(grant,"contract.txt","text/plain",bytes));
            confirm.put("ownerType","SALES_ORDER");confirm.put("ownerId",order);
            attachment=json(HttpMethod.POST,"/api/attachments/confirm",confirm,HttpStatus.OK);
        } finally { properties.setPresignedExpirySeconds(oldExpiry); }
        UUID fileId=UUID.fromString(attachment.path("id").asText());
        String key=grant.path("storageKey").asText();
        json(HttpMethod.DELETE,"/api/sales/orders/"+order,null,HttpStatus.OK);
        json(HttpMethod.DELETE,"/api/attachments/"+fileId,null,HttpStatus.NOT_FOUND);
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,fileId)).isEqualTo("CLEAN");
        JsonNode preview=json(HttpMethod.GET,"/api/system-test/business-data/attachments/preview",null,HttpStatus.OK);
        assertThat(preview.path("blockingCount").asLong()).isGreaterThan(0);
        assertThat(preview.path("items").toString()).doesNotContain("human-preserved.txt");
        Map<String,Object> approval=new HashMap<>();
        approval.put("confirm","清理测试业务附件");approval.put("database",preview.path("database").asText());
        approval.put("fingerprint",preview.path("fingerprint").asText());
        Map<String,Object> wrong=new HashMap<>(approval);wrong.put("database","wrong-target");
        json(HttpMethod.POST,"/api/system-test/business-data/attachments/prepare",wrong,HttpStatus.CONFLICT);
        wrong=new HashMap<>(approval);wrong.put("fingerprint","not-current-preview");
        json(HttpMethod.POST,"/api/system-test/business-data/attachments/prepare",wrong,HttpStatus.CONFLICT);
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,fileId)).isEqualTo("CLEAN");
        json(HttpMethod.POST,"/api/system-test/business-data/attachments/prepare",approval,HttpStatus.OK);
        json(HttpMethod.POST,"/api/system-test/business-data/reset",Map.of("confirm","清空业务数据"),HttpStatus.CONFLICT);
        for(int i=0;i<20&&outbox.processNext();i++) { /* real deletion processor */ }
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,fileId)).isEqualTo("DELETED");
        assertThat(http.exchange("/api/attachments/raw/"+key,HttpMethod.GET,new HttpEntity<>(headers()),byte[].class).getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
        // A DELETED flag alone is insufficient: failure/missing completion is still rejected.
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>)connection->{
            connection.setAutoCommit(false);
            try(var st=connection.createStatement()) {
                st.executeUpdate("UPDATE attachment_object_outbox SET status='FAILED' WHERE attachment_id='"+fileId+"'");
                try(var r=st.executeQuery("SELECT count(*) FROM fn_business_attachment_reset_blockers() WHERE entity_type='ATTACHMENT' AND entity_id='"+fileId+"'")){
                    r.next();assertThat(r.getLong(1)).isEqualTo(1);
                }
            } finally { connection.rollback();connection.setAutoCommit(true); }
            return null;
        });
        java.time.Instant expiry=java.time.Instant.parse(grant.path("expiresAt").asText());
        org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(12))
                .until(()->java.time.Instant.now().isAfter(expiry));
        for(int i=0;i<20&&outbox.processNext();i++) { /* delayed staging deletion after signed grant expiry */ }
        preview=json(HttpMethod.GET,"/api/system-test/business-data/attachments/preview",null,HttpStatus.OK);
        assertThat(preview.path("blockingCount").asLong()).isZero();
        long humans=jdbc.queryForObject("SELECT count(*) FROM employees",Long.class);
        String humanDigest=jdbc.queryForObject("SELECT md5(to_jsonb(attachment)::text) FROM attachments attachment WHERE id=?",String.class,UUID.fromString(human.attachment.path("id").asText()));
        JsonNode result=json(HttpMethod.POST,"/api/system-test/business-data/reset",Map.of("confirm","清空业务数据"),HttpStatus.OK);
        assertThat(result.path("clearedTableCount").asInt()).isEqualTo(266);
        assertThat(result.path("preservedTableCount").asInt()).isEqualTo(96);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_orders",Long.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM employees",Long.class)).isEqualTo(humans);
        assertThat(jdbc.queryForObject("SELECT md5(to_jsonb(attachment)::text) FROM attachments attachment WHERE id=?",String.class,UUID.fromString(human.attachment.path("id").asText()))).isEqualTo(humanDigest);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='business_attachment_reset_prepare'",Long.class)).isPositive();
        login();
        var original=http.exchange("/api/attachments/raw/"+human.key,HttpMethod.GET,new HttpEntity<>(headers()),byte[].class);
        assertThat(original.getStatusCode()).isEqualTo(HttpStatus.OK);assertThat(original.getBody()).isEqualTo(humanBytes);
    }

    private Upload upload(String name,String type,byte[] bytes) throws Exception {
        JsonNode grant=reserve(name,type,bytes);put(grant,bytes,type);Map<String,Object> confirm=confirmation(grant,name,type,bytes);
        return new Upload(grant.path("storageKey").asText(),json(HttpMethod.POST,"/api/attachments/confirm",confirm,HttpStatus.OK),confirm);
    }
    private JsonNode reserve(String name,String type,byte[] bytes) {
        return json(HttpMethod.POST,"/api/attachments/presign",Map.of("ownerType","EMPLOYEE","ownerId",employee,"fileName",name,"contentType",type,"sizeBytes",bytes.length),HttpStatus.OK);
    }
    private void put(JsonNode grant,byte[] bytes,String type) {
        HttpHeaders headers=headers();headers.setContentType(MediaType.parseMediaType(type));headers.setContentLength(bytes.length);
        headers.set("X-Uten-Attachment-Upload-Token",grant.path("confirmToken").asText());
        assertThat(http.exchange("/api"+grant.path("url").asText(),HttpMethod.PUT,new HttpEntity<>(bytes,headers),Void.class).getStatusCode()).isEqualTo(HttpStatus.NO_CONTENT);
    }
    private Map<String,Object> confirmation(JsonNode grant,String name,String type,byte[] bytes) {
        return Map.of("storageKey",grant.path("storageKey").asText(),"confirmToken",grant.path("confirmToken").asText(),
                "ownerType","EMPLOYEE","ownerId",employee,"originalName",name,"contentType",type,"sizeBytes",bytes.length,"category","OTHER");
    }
    private JsonNode json(HttpMethod method,String path,Object body,HttpStatus expected) {
        var response=http.exchange(path,method,new HttpEntity<>(body,headers()),JsonNode.class);
        String error=response.getBody()==null?"":response.getBody().path("message").asText();
        assertThat(response.getStatusCode()).as(method+" "+path+" "+error).isEqualTo(expected);return response.getBody();
    }
    private HttpHeaders headers(){var headers=new HttpHeaders();headers.setBearerAuth(token);headers.setContentType(MediaType.APPLICATION_JSON);return headers;}
    private static String sha(byte[] bytes) throws Exception {return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));}
    private static Path temporaryRoot(){try{return Files.createTempDirectory("uten-internal-pipeline-");}catch(Exception e){throw new IllegalStateException(e);}}
    private record Upload(String key,JsonNode attachment,Map<String,Object> confirm) {}
}
