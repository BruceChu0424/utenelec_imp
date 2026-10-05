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
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Actual HTTP/authorization/JPA/Flyway/queue flow; native fsync is proved separately on Linux. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.storage.provider=local","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.storage.outbox.poll-delay-millis=60000",
        "uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
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

    // This class shares one real browser session. Re-authenticating for every
    // file scenario plus the reset recovery exhausts the real login limiter.
    @BeforeAll void initializeSession() { login(); }

    private void login() {
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
    @AfterAll void logout() {
        if (refresh != null) http.postForEntity("/api/auth/logout",Map.of("refreshToken",refresh),Void.class);
        token=null;refresh=null;
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
                .containsEntry("lifecycle_state","RETAINED_HISTORY").containsEntry("sha256",sha(bytes)).containsEntry("storage_provider","internal");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_object_outbox WHERE attachment_id=? AND storage_provider='internal' AND operation='DELETE_FINAL' AND status='RETAINED_HISTORY'",Long.class,id)).isEqualTo(1L);
        assertThat(http.exchange("/api/attachments/raw/"+upload.key,HttpMethod.GET,new HttpEntity<>(headers()),byte[].class).getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
        var history=http.exchange("/api/attachments/"+id+"/history/download",HttpMethod.GET,new HttpEntity<>(headers()),byte[].class);
        assertThat(history.getStatusCode()).isEqualTo(HttpStatus.OK);assertThat(history.getBody()).isEqualTo(bytes);
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

    @Test void explicitTestingResetClearsRetainedBusinessOriginalsButKeepsHumanFilesAndRequiresRelogin() throws Exception {
        byte[] humanBytes="human original remains".getBytes(StandardCharsets.UTF_8);
        Upload human=upload("human-preserved.txt","text/plain",humanBytes);
        UUID client=UUID.randomUUID(),order=UUID.randomUUID();
        jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence) VALUES(?,'RESET-PERMANENT-CLIENT','permanent evidence client','使用',100901)",client);
        jdbc.update("INSERT INTO sales_orders(id,bill_no,bill_date,client_id,owner_employee_id,maker_id,status) VALUES(?,'XD'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'009991',(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date,?,?,?,0)",order,client,UUID.fromString(employee),UUID.fromString(employee));
        byte[] businessBytes="original test order evidence\n".repeat(50).getBytes(StandardCharsets.UTF_8);
        JsonNode grant=json(HttpMethod.POST,"/api/attachments/presign",Map.of("ownerType","SALES_ORDER","ownerId",order.toString(),
                "fileName","test-order.txt","contentType","text/plain","sizeBytes",businessBytes.length),HttpStatus.OK);
        put(grant,businessBytes,"text/plain");
        JsonNode business=json(HttpMethod.POST,"/api/attachments/confirm",Map.of("storageKey",grant.path("storageKey").asText(),
                "confirmToken",grant.path("confirmToken").asText(),"ownerType","SALES_ORDER","ownerId",order.toString(),
                "originalName","test-order.txt","contentType","text/plain","sizeBytes",businessBytes.length,"category","OTHER"),HttpStatus.OK);
        UUID attachment=UUID.fromString(business.path("id").asText());String businessKey=grant.path("storageKey").asText();
        String version=jdbc.queryForObject("SELECT storage_version FROM attachments WHERE id=?",String.class,attachment);
        json(HttpMethod.DELETE,"/api/attachments/"+attachment,null,HttpStatus.ACCEPTED);
        for(int i=0;i<50 && outbox.processNext();i++) { /* ordinary deletion retains the original */ }
        assertThat(jdbc.queryForObject("SELECT lifecycle_state FROM attachments WHERE id=?",String.class,attachment)).isEqualTo("RETAINED_HISTORY");
        try(var retained=storage.openFinal(businessKey,version)){assertThat(retained.readAllBytes()).isEqualTo(businessBytes);}
        // The dialog preview over real HTTP: the JSON field names the Flutter client reads (ADR-155).
        JsonNode preview=json(HttpMethod.GET,"/api/system-test/business-data/preview",null,HttpStatus.OK);
        assertThat(preview.path("refusals").isArray()).isTrue();
        assertThat(preview.path("refusals")).isEmpty();
        assertThat(preview.path("inspectionComplete").asBoolean()).isTrue();
        assertThat(preview.path("allListedMissing").asBoolean()).isFalse();
        assertThat(preview.path("presentFiles").asLong()).isPositive();
        assertThat(preview.path("inspectedObjects").asLong()).isEqualTo(preview.path("locations").asLong());
        assertThat(preview.has("absentFiles")).isTrue();
        assertThat(preview.path("deadBackgroundEvents").isArray()).isTrue();
        assertThat(preview.path("kinds").findValuesAsText("label")).contains("业务附件");
        assertThat(preview.path("kinds").get(0).path("files").asLong()).isPositive();
        assertThat(preview.has("refused")).as("derived by the client, not serialized").isFalse();
        UUID attempt=UUID.randomUUID();
        JsonNode result=stepUpJson(HttpMethod.POST,"/api/system-test/business-data/reset",
                Map.of("confirm","清空业务数据","attemptId",attempt.toString()),HttpStatus.OK);
        assertThat(result.path("deletedAttachmentFiles").asLong()).isPositive();
        assertThat(result.has("deadBackgroundEventsCleared")).isTrue();
        assertThat(http.exchange("/api/auth/me",HttpMethod.GET,new HttpEntity<>(headers()),JsonNode.class).getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_orders",Long.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachments WHERE id=?",Long.class,attachment)).isZero();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM attachment_upload_sessions WHERE storage_key=?",Long.class,businessKey)).isZero();
        assertThatThrownBy(()->{try(var ignored=storage.openFinal(businessKey,version)) {}})
                .isInstanceOf(IllegalStateException.class).hasRootCauseInstanceOf(java.nio.file.NoSuchFileException.class);
        login();
        var receipt=json(HttpMethod.GET,"/api/system-test/business-data/last-result?attemptId="+attempt,null,HttpStatus.OK);
        assertThat(receipt.path("available").asBoolean()).isTrue();assertThat(receipt.path("attemptId").asText()).isEqualTo(attempt.toString());
        assertThat(receipt.path("deletedAttachmentFiles").asLong()).isEqualTo(result.path("deletedAttachmentFiles").asLong());
        assertThat(receipt.has("deadBackgroundEventsCleared")).isTrue();
        assertThat(receipt.path("attemptFailed").asBoolean()).isFalse();
        assertThat(receipt.has("attemptDeletedAttachmentFiles")).isTrue();
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
    /** 敏感写接口(ADR-110)：先用本次密码换一次性再认证凭证，再带 X-Uten-Step-Up 调用。 */
    private JsonNode stepUpJson(HttpMethod method,String path,Object body,HttpStatus expected) {
        String stepUp=json(HttpMethod.POST,"/api/auth/step-up",Map.of("password",password),HttpStatus.OK)
                .path("stepUpToken").asText();
        HttpHeaders headers=headers();headers.set("X-Uten-Step-Up",stepUp);
        var response=http.exchange(path,method,new HttpEntity<>(body,headers),JsonNode.class);
        assertThat(response.getStatusCode()).as(path+" "+response.getBody()).isEqualTo(expected);
        return response.getBody();
    }

    private HttpHeaders headers(){var headers=new HttpHeaders();headers.setBearerAuth(token);headers.setContentType(MediaType.APPLICATION_JSON);return headers;}
    private static String sha(byte[] bytes) throws Exception {return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));}
    private static Path temporaryRoot(){try{return Files.createTempDirectory("uten-internal-pipeline-");}catch(Exception e){throw new IllegalStateException(e);}}
    private record Upload(String key,JsonNode attachment,Map<String,Object> confirm) {}
}
