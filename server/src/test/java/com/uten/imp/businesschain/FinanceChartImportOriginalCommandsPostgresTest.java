package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.FinanceOperationJournal;
import com.uten.imp.features.finance.gl.FinanceChartContracts.*;
import com.uten.imp.features.finance.gl.FinanceChartService;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.security.AuthUser;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.io.ByteArrayOutputStream;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Actual source files, immutable previews, original batch keys and real directory transactions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain @TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FinanceChartImportOriginalCommandsPostgresTest {
    private static final String APPLY="CHART_IMPORT_APPLY",REVIEW="CHART_IMPORT_REPREVIEW";
    private static final Set<String> READ=Set.of("finance_report:view","finance:view:all");
    private static final Set<String> WRITE=Set.of("finance_report:view","finance:view:all","payment_style:edit","payment_style:create");
    private static final AtomicInteger CODES=new AtomicInteger(881000);
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceChartImportOriginalCommandsPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager manager;
    private FullChainEndToEndTest.World a,b;
    @BeforeAll void actors(){var seed=new FullChainEndToEndTest();beans.autowireBean(seed);a=seed.seedWorld("chart-import-a");b=seed.seedWorld("chart-import-b");}
    @BeforeEach void login(){login(a,WRITE);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void lostUploadResponseCanBeRecoveredByItsOwnShaBeyondTheRecentTenWithoutMoneyWrites()throws Exception {
        var original=file(2);var first=preview(original);
        for(int i=0;i<11;i++)preview(file(1));
        assertThat(chart.recent()).noneMatch(row->first.importId().equals(row.get("importId")));
        login(a,READ);var recovered=chart.importBySha(ImmutableDocumentStore.digest(original.bytes));
        assertThat(recovered).containsEntry("found",true).containsEntry("importId",first.importId()).containsEntry("sha256",first.sha256());
        assertThat(((Number)recovered.get("storageSize")).longValue()).isEqualTo(original.bytes.length);
        assertThat(chart.imported(first.importId()).rows()).containsExactlyElementsOf(first.rows());
        assertThat(chart.importApplyOperation(first.importId())).containsEntry("found",false);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code IN(?,?)",Long.class,original.codes.get(0),original.codes.get(1))).isZero();
        login(b,READ);assertThat(chart.importBySha(first.sha256())).containsEntry("found",false);
        assertThat(chart.importApplyOperation(first.importId())).containsEntry("found",false);
        assertThatThrownBy(()->chart.imported(first.importId())).isInstanceOf(ApiException.class);
        login(b,WRITE);assertThat(preview(original).importId()).isNotEqualTo(first.importId());
    }

    @Test void successfulOriginalApplySurvivesLostResponseAndLaterEditsWithoutRewritingItsReceipt()throws Exception {
        var source=file(2);var preview=preview(source);var body=applyBody(preview.importId());String literal=literal(preview.importId());String reference=reference(preview.importId());
        int journal=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);var success=chart.applyCommand(body);String original=row(preview.importId());
        assertThat(chart.apply(new Apply(preview.importId()))).isEqualTo(new Result(preview.importId(),2,"APPLIED"));
        chart.updateAccount(source.codes.getFirst(),new UpdateAccount(UUID.randomUUID(),version(source.codes.getFirst()),"匿名后续名称","后续独立审阅"));
        login(a,READ);assertThat(chart.importApplyOperation(preview.importId())).isEqualTo(success);
        assertThat(chart.cancelImportApply(preview.importId(),applyCancellation(preview.importId()))).isEqualTo(success);
        assertThat(row(preview.importId())).isEqualTo(original);assertThat(literal(preview.importId())).isEqualTo(literal);assertThat(reference(preview.importId())).isEqualTo(reference);
        assertThat(chart.importView(preview.importId())).containsEntry("applied",true).containsEntry("cancelled",false).containsEntry("applyOutcome","SUCCEEDED");
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journal);
        assertThatThrownBy(()->chart.applyCommand(body)).isInstanceOf(ApiException.class).hasMessageContaining("payment_style:edit");
    }

    @Test void unwrittenApplyStopIsPermanentForThePublishedImportIdIncludingControlledTypedCallers()throws Exception {
        var source=file(2);var preview=preview(source);String literal=literal(preview.importId());String reference=reference(preview.importId());
        login(a,READ);var stopped=chart.cancelImportApply(preview.importId(),applyCancellation(preview.importId()));String terminal=row(preview.importId());
        assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");assertThat(chart.importApplyOperation(preview.importId())).isEqualTo(stopped);
        assertThat(chart.cancelImportApply(preview.importId(),applyCancellation(preview.importId()))).isEqualTo(stopped);
        login(a,WRITE);assertThatThrownBy(()->chart.applyCommand(applyBody(preview.importId()))).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThatThrownBy(()->chart.apply(new Apply(preview.importId()))).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(chart.importView(preview.importId())).containsEntry("applied",false).containsEntry("cancelled",true);
        assertThat(chart.imported(preview.importId()).rows()).hasSize(2);assertThat(row(preview.importId())).isEqualTo(terminal);
        assertThat(literal(preview.importId())).isEqualTo(literal);assertThat(reference(preview.importId())).isEqualTo(reference);
        for(String code:source.codes)assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Long.class,code)).isZero();
        assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET cancelled_at=NULL,cancellation_result=NULL WHERE id=?",preview.importId())).hasMessageContaining("Terminal");
    }

    @ParameterizedTest @ValueSource(booleans={true,false})
    void originalApplyAndStopSerializeInBothCommitOrders(boolean cancelFirst)throws Exception {
        var source=file(2);var preview=preview(source);var entered=new CountDownLatch(1);var release=new CountDownLatch(1);var pool=Executors.newFixedThreadPool(2);
        try {
            var first=pool.submit(()->{login(a,cancelFirst?READ:WRITE);try{return new TransactionTemplate(manager).execute(status->{var result=cancelFirst?chart.cancelImportApply(preview.importId(),applyCancellation(preview.importId())):chart.applyCommand(applyBody(preview.importId()));entered.countDown();await(release);return result;});}finally{SecurityContextHolder.clearContext();}});
            assertThat(entered.await(30,TimeUnit.SECONDS)).isTrue();
            var second=pool.submit(()->{login(a,cancelFirst?WRITE:READ);try{return attempt(()->cancelFirst?chart.apply(new Apply(preview.importId())):chart.cancelImportApply(preview.importId(),applyCancellation(preview.importId())));}finally{SecurityContextHolder.clearContext();}});
            org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(20)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
            release.countDown();var result=first.get(40,TimeUnit.SECONDS);var other=second.get(40,TimeUnit.SECONDS);
            if(cancelFirst){assertThat(result).containsEntry("outcome","CANCELLED_UNWRITTEN");assertThat(other).isInstanceOf(ApiException.class);}else{assertThat(result).containsEntry("outcome","SUCCEEDED");assertThat(other).isEqualTo(result);}
            login(a,READ);assertThat(chart.importApplyOperation(preview.importId())).isEqualTo(result);
            for(String code:source.codes)assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Long.class,code)).isEqualTo(cancelFirst?0L:1L);
        }finally{release.countDown();pool.shutdownNow();}
    }

    @Test void deliberateNewReviewRefreshesOnlyVersionsAndRetainsLiteralRowsOriginalReceiptsAndFileReference()throws Exception {
        var source=file(2);manual(source.codes.getFirst());var original=preview(source);String beforeLiteral=literal(original.importId()),beforeReference=reference(original.importId());
        chart.updateAccount(source.codes.getFirst(),new UpdateAccount(UUID.randomUUID(),0,"匿名独立维护名称","目录已变化"));
        assertThatThrownBy(()->chart.apply(new Apply(original.importId()))).isInstanceOf(ApiException.class).hasMessageContaining("重新预览");
        assertThat(chart.importApplyOperation(original.importId())).containsEntry("found",false);
        var stopped=chart.cancelImportApply(original.importId(),applyCancellation(original.importId()));assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");String originalAfterStop=row(original.importId());
        UUID request=UUID.randomUUID();var body=reviewBody(request);var reviewed=chart.repreview(original.importId(),body);UUID child=child(reviewed);
        assertThat(child).isNotEqualTo(original.importId());assertThat(chart.repreview(original.importId(),body)).isEqualTo(reviewed);
        assertThat(chart.operationReceipt(request)).isEqualTo(reviewed);assertThat(reference(child)).isEqualTo(beforeReference);
        assertSameSourceRows(literal(original.importId()),literal(child));assertThat(literal(original.importId())).isEqualTo(beforeLiteral);assertThat(row(original.importId())).isEqualTo(originalAfterStop);
        assertThat(chart.importView(child)).containsEntry("parentImportId",original.importId()).containsEntry("sourceImportId",original.importId()).containsEntry("applied",false);
        assertThat(chart.imported(child).rows().getFirst().existingVersion()).isEqualTo(1L);
        assertThat(chart.preview("same-bytes-renamed.xlsx",source.bytes).importId()).isEqualTo(original.importId());
        assertThat(chart.apply(new Apply(child))).isEqualTo(new Result(child,2,"APPLIED"));
        assertThat(chart.account(source.codes.getFirst()).name()).isEqualTo(source.names.getFirst());
        login(a,READ);assertThat(chart.cancelOperation(request,reviewCancellation(original.importId(),request))).isEqualTo(reviewed);
        assertThat(chart.importApplyOperation(original.importId())).isEqualTo(stopped);assertThat(row(original.importId())).isEqualTo(originalAfterStop);
    }

    @Test void reviewStopBlocksTheLateOriginalButANewExplicitReviewIntentCanUseTheSameRetainedFile()throws Exception {
        var original=preview(file(2));UUID request=UUID.randomUUID();login(a,READ);
        var stopped=chart.cancelOperation(request,reviewCancellation(original.importId(),request));assertThat(stopped).containsEntry("outcome","CANCELLED_UNWRITTEN");
        login(a,WRITE);assertThatThrownBy(()->chart.repreview(original.importId(),reviewBody(request))).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_imports WHERE review_request_id=?",Long.class,request)).isZero();
        var newReview=chart.repreview(original.importId(),reviewBody(UUID.randomUUID()));assertThat(reference(child(newReview))).isEqualTo(reference(original.importId()));
        assertThat(chart.operationReceipt(request)).isEqualTo(stopped);
    }

    @Test void failedLaterRowRollsBackTheWholeApplyBeforeStopAndFreshReviewCanSafelyProceed()throws Exception {
        var source=file(2);var original=preview(source);manual(source.codes.get(1));String second=codeRow(source.codes.get(1)),initial=row(original.importId());
        assertThatThrownBy(()->chart.apply(new Apply(original.importId()))).isInstanceOf(ApiException.class).hasMessageContaining("重新预览");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_codes WHERE code=?",Long.class,source.codes.getFirst())).isZero();
        assertThat(codeRow(source.codes.get(1))).isEqualTo(second);assertThat(row(original.importId())).isEqualTo(initial);
        assertThat(chart.importApplyOperation(original.importId())).containsEntry("found",false);chart.cancelImportApply(original.importId(),applyCancellation(original.importId()));
        UUID child=child(chart.repreview(original.importId(),reviewBody(UUID.randomUUID())));chart.apply(new Apply(child));
        for(int i=0;i<source.codes.size();i++)assertThat(chart.account(source.codes.get(i)).name()).isEqualTo(source.names.get(i));
    }

    @Test void filePolicyFailureNeverCreatesANewReviewAndItsStoppedRequestCannotReviveAfterPolicyAba()throws Exception {
        var original=preview(file(2));UUID request=UUID.randomUUID();var target=AopTestUtils.getUltimateTargetObject(chart);
        var files=(ImmutableDocumentStore)ReflectionTestUtils.getField(target,"files");var failure=mock(ImmutableDocumentStore.class);
        when(failure.read(any(ImmutableDocumentStore.Reference.class))).thenThrow(new ApiException(ErrorCode.VALIDATION_FAILED,"anonymous-file-policy-refused"));
        ReflectionTestUtils.setField(target,"files",failure);
        try{assertThatThrownBy(()->chart.repreview(original.importId(),reviewBody(request))).isInstanceOf(ApiException.class).hasMessageContaining("file-policy-refused");}
        finally{ReflectionTestUtils.setField(target,"files",files);}
        assertThat(chart.operationReceipt(request)).containsEntry("found",false);login(a,READ);chart.cancelOperation(request,reviewCancellation(original.importId(),request));
        login(a,WRITE);assertThatThrownBy(()->chart.repreview(original.importId(),reviewBody(request))).isInstanceOf(ApiException.class).hasMessageContaining("已停止");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_imports WHERE review_request_id=?",Long.class,request)).isZero();
    }

    @Test void malformedBodiesWrongActorsAndLostReadCannotStopOrAcknowledgeAnotherSource()throws Exception {
        var original=preview(file(2));var body=applyBody(original.importId());body.put("requestId",UUID.randomUUID().toString());
        assertThatThrownBy(()->chart.applyCommand(body)).isInstanceOf(ApiException.class);assertThat(chart.importApplyOperation(original.importId())).containsEntry("found",false);
        var wrong=new FinanceOperationJournal.Cancellation(original.importId(),a.superAdminUserId(),APPLY,"POST","/finance/chart/import-apply",applyBody(UUID.randomUUID()));
        assertThatThrownBy(()->chart.cancelImportApply(original.importId(),wrong)).isInstanceOf(ApiException.class);
        login(b,READ);assertThat(chart.importApplyOperation(original.importId())).containsEntry("found",false);assertThatThrownBy(()->chart.cancelImportApply(original.importId(),applyCancellation(original.importId()))).isInstanceOf(ApiException.class);
        login(a,Set.of());assertThatThrownBy(()->chart.importBySha(original.sha256())).isInstanceOf(ApiException.class);assertThatThrownBy(()->chart.importApplyOperation(original.importId())).isInstanceOf(ApiException.class);assertThatThrownBy(()->chart.cancelImportApply(original.importId(),applyCancellation(original.importId()))).isInstanceOf(ApiException.class);
    }

    @Test void realSourceAndJournalConstraintsRejectFakeLineageMissingProofAndEveryTerminalRewrite()throws Exception {
        var original=preview(file(2));UUID child=child(chart.repreview(original.importId(),reviewBody(UUID.randomUUID())));String before=row(child);
        assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET preview=jsonb_set(preview,'{rows,0,name}','\"forged\"'::jsonb) WHERE id=?",child)).hasMessageContaining("immutable");
        assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET parent_import_id=NULL,review_request_id=NULL WHERE id=?",child)).hasMessageContaining("immutable");
        assertThatThrownBy(()->db.update("DELETE FROM finance_chart_imports WHERE id=?",child)).hasMessageContaining("retained");
        for(String mutation:List.of("actor","reference","literal","order","version","missingJournal","reuseJournal")){
            UUID fake=UUID.randomUUID(),request=UUID.randomUUID();var raw=(ObjectNode)json.readTree(literal(original.importId()));raw.put("importId",fake.toString());
            if(mutation.equals("reuseJournal"))chart.createAccount(new CreateAccount(request,Integer.toString(CODES.incrementAndGet()),"匿名其他已成功操作","",null,"不能拿其他成功冒充重新审阅","ASSET",null));
            for(var source:raw.path("rows")){var mutable=(ObjectNode)source;Long current=db.queryForObject("SELECT max(row_version) FROM finance_chart_codes WHERE code=?",Long.class,source.path("code").asText());if(current==null)mutable.putNull("existingVersion");else mutable.put("existingVersion",current);}
            if(mutation.equals("literal"))((ObjectNode)raw.path("rows").get(0)).put("name","forged");
            if(mutation.equals("order")){var array=(com.fasterxml.jackson.databind.node.ArrayNode)raw.path("rows");var first=array.remove(0);array.add(first);}
            if(mutation.equals("version"))((ObjectNode)raw.path("rows").get(0)).put("existingVersion",9999);
            assertThatThrownBy(()->new TransactionTemplate(manager).executeWithoutResult(status->{db.update("""
                    INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size,preview,parent_import_id,review_request_id)
                    SELECT ?,?,source_name,sha256,storage_provider,CASE WHEN ? THEN storage_key||'-forged' ELSE storage_key END,storage_version,storage_size,?::jsonb,id,? FROM finance_chart_imports WHERE id=?
                    """,fake,mutation.equals("actor")?b.superAdminUserId():a.superAdminUserId(),mutation.equals("reference"),raw.toString(),request,original.importId());db.execute("SET CONSTRAINTS ALL IMMEDIATE");})).isInstanceOf(RuntimeException.class);
            assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_imports WHERE id=?",Long.class,fake)).isZero();
        }
        assertThat(row(child)).isEqualTo(before);chart.apply(new Apply(child));String applied=row(child);
        assertThatThrownBy(()->db.update("UPDATE finance_chart_imports SET applied_result='{}'::jsonb WHERE id=?",child)).hasMessageContaining("Terminal");assertThat(row(child)).isEqualTo(applied);
    }

    @Test void fullTwoThousandRowReviewKeepsOriginalOrderAndTheLastTailWithoutCreatingAnotherBlob()throws Exception {
        var source=file(2000);var original=preview(source);var target=AopTestUtils.getUltimateTargetObject(chart);var files=(ImmutableDocumentStore)ReflectionTestUtils.getField(target,"files");var observed=spy(files);
        ReflectionTestUtils.setField(target,"files",observed);
        UUID child;try{child=child(chart.repreview(original.importId(),reviewBody(UUID.randomUUID())));}finally{ReflectionTestUtils.setField(target,"files",files);}
        var copied=chart.imported(child);assertThat(copied.rows()).hasSize(2000);assertThat(copied.rows()).extracting(SourceRow::code).containsExactlyElementsOf(source.codes);
        assertThat(copied.rows().getLast().code()).isEqualTo(source.codes.getLast());assertSameSourceRows(literal(original.importId()),literal(child));assertThat(reference(child)).isEqualTo(reference(original.importId()));
        verify(observed,never()).save(any(),any(),any(),any(byte[].class));
    }

    @Test void newLineageAndStopAuditExposeSafeKeysWithoutSourceNamesRowsOrReceiptValues()throws Exception {
        var source=file(2);var original=chart.preview("PRIVATE-FILE-"+UUID.randomUUID()+".xlsx",source.bytes);UUID request=UUID.randomUUID();UUID child=child(chart.repreview(original.importId(),reviewBody(request)));chart.cancelImportApply(child,applyCancellation(child));
        String audit=db.queryForObject("SELECT jsonb_agg(to_jsonb(a) ORDER BY id)::text FROM audit_log a WHERE target_type='finance_chart_imports' AND target_id IN(?,?)",String.class,original.importId().toString(),child.toString());
        assertThat(audit).contains("parent_import_id","review_request_id","cancelled_at").doesNotContain("PRIVATE-FILE-",source.names.getFirst(),"requestBody","preview","cancellation_result","apply_receipt");
    }

    private record FileInput(byte[] bytes,List<String> codes,List<String> names) { }
    private FileInput file(int size)throws Exception {
        var codes=new ArrayList<String>();var names=new ArrayList<String>();
        try(var book=new XSSFWorkbook();var output=new ByteArrayOutputStream()){
            var sheet=book.createSheet("匿名科目");var header=sheet.createRow(0);header.createCell(0).setCellValue("科目编码");header.createCell(1).setCellValue("科目名称");header.createCell(2).setCellValue("外币名称");
            for(int i=0;i<size;i++){String code=Integer.toString(CODES.incrementAndGet()),name="匿名源行-"+code;codes.add(code);names.add(name);var row=sheet.createRow(i+1);row.createCell(0).setCellValue(code);row.createCell(1).setCellValue(name);}
            String total=null;for(var group:FinanceTemplateContract.template("chartCodes").path("classifications"))if("ASSET".equals(group.path("id").asText()))total=group.path("totalLabel").asText();
            sheet.createRow(size+1).createCell(0).setCellValue(Objects.requireNonNull(total));book.write(output);return new FileInput(output.toByteArray(),List.copyOf(codes),List.copyOf(names));
        }
    }
    private Preview preview(FileInput file){var preview=chart.preview("anonymous-chart.xlsx",file.bytes);assertThat(preview.issues()).isEmpty();assertThat(preview.rows()).hasSize(file.codes.size()).allSatisfy(row->assertThat(row.classification()).isEqualTo("ASSET"));return preview;}
    private void manual(String code){chart.createAccount(new CreateAccount(UUID.randomUUID(),code,"匿名先前科目","",null,"匿名原维护依据","ASSET",null));}
    private ObjectNode applyBody(UUID id){return (ObjectNode)json.valueToTree(new Apply(id));}
    private ObjectNode reviewBody(UUID id){return (ObjectNode)json.valueToTree(new Repreview(id));}
    private FinanceOperationJournal.Cancellation applyCancellation(UUID id){return new FinanceOperationJournal.Cancellation(id,a.superAdminUserId(),APPLY,"POST","/finance/chart/import-apply",applyBody(id));}
    private FinanceOperationJournal.Cancellation reviewCancellation(UUID source,UUID request){return new FinanceOperationJournal.Cancellation(request,a.superAdminUserId(),REVIEW,"POST","/finance/chart/imports/"+source+"/repreview",reviewBody(request));}
    private static UUID child(Map<String,Object> receipt){return UUID.fromString(((Map<?,?>)receipt.get("result")).get("importId").toString());}
    private String row(UUID id){return db.queryForObject("SELECT to_jsonb(s)::text FROM finance_chart_imports s WHERE id=?",String.class,id);}
    private String literal(UUID id){return db.queryForObject("SELECT preview::text FROM finance_chart_imports WHERE id=?",String.class,id);}
    private String reference(UUID id){return db.queryForObject("SELECT jsonb_build_array(actor_id,source_name,sha256,storage_provider,storage_key,storage_version,storage_size)::text FROM finance_chart_imports WHERE id=?",String.class,id);}
    private String codeRow(String code){return db.queryForObject("SELECT to_jsonb(c)::text FROM finance_chart_codes c WHERE code=?",String.class,code);}
    private long version(String code){return db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code=?",Long.class,code);}
    private void assertSameSourceRows(String one,String two)throws Exception {var old=json.readTree(one).path("rows").deepCopy();var current=json.readTree(two).path("rows").deepCopy();for(var row:old)((ObjectNode)row).remove("existingVersion");for(var row:current)((ObjectNode)row).remove("existingVersion");assertThat(current).isEqualTo(old);}
    private static Object attempt(Supplier<?> action){try{return action.get();}catch(ApiException error){return error;}}
    private static void await(CountDownLatch release){try{if(!release.await(40,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private static void login(FullChainEndToEndTest.World actor,Set<String> permissions){var user=new AuthUser(actor.superAdminUserId(),actor.employeeId(),"anonymous-chart-import",permissions,false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));}
}
