package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.statement.FinanceAuxiliaryImportService;
import com.uten.imp.features.finance.statement.FinanceAuxiliaryImportController;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.*;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
 "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
 "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
 "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
 "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
 "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
 "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
 "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceDocumentIntakeOperationsPostgresTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceDocumentIntakeOperationsPostgresTest.class);}
 @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired FinanceAuxiliaryImportService imports;
 @Autowired FinanceAuxiliaryImportController controller;@Autowired GlobalExceptionHandler errors;@Autowired ObjectMapper json;
 private FullChainEndToEndTest fixture;private FullChainEndToEndTest.World w;private UUID base,actor;private byte[] file;
 private static final LocalDate FROM=LocalDate.of(2026,9,1),TO=LocalDate.of(2026,9,30);
 @BeforeEach void setup()throws Exception{
  if(!Boolean.TRUE.equals(db.queryForObject("SELECT to_regclass('public.finance_document_intake_operations') IS NOT NULL",Boolean.class)))db.execute(Files.readString(Path.of("../tmp/finance-research/V1030__finance_document_intake_operations.sql.draft")));
  fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);w=fixture.seedWorld("intake-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
  UUID chart=UUID.randomUUID();db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview)VALUES(?,?,'anonymous.xlsx',?,'TEST','anonymous',1,'{}')",chart,w.superAdminUserId(),"e".repeat(64));
  db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,sort_order,source_row,source_import_id,updated_by)VALUES('112201','匿名原科目','',?,1,1,?,?) ON CONFLICT(code) DO UPDATE SET currency_name='',currency_id=EXCLUDED.currency_id,row_version=finance_chart_codes.row_version+1",base,chart,w.superAdminUserId());
  var maker=FinanceAuxiliaryPostgresTest.class.getDeclaredMethod("auxiliaryFile");maker.setAccessible(true);file=(byte[])maker.invoke(null);
  actor=fixture.createUserWithPerms(w,"intake-maker-"+w.supplierId(),"finance_report:view","finance:view:all","payment_style:edit");fixture.loginAs(actor);
 }
 @AfterEach void logout(){SecurityContextHolder.clearContext();}
 private FinanceAuxiliaryImportService.Preview upload(UUID request,String book,String filename,byte[] bytes){return imports.preview(true,book,base,FROM,TO,filename,bytes,request,"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");}
 @Test void mappingChangesDoNotReinterpretAnUnknownOriginalUploadAndFreshRequestsCanCreateAnotherVersion(){
  UUID request=UUID.randomUUID();String book="原账套-"+request;var first=upload(request,book,"original.xlsx",file);UUID foreign=UUID.randomUUID();db.update("INSERT INTO currencies(id,code,name,exchange_rate,status)VALUES(?,?,'独立外币',7,'使用')",foreign,"INTAKE-"+foreign);db.update("UPDATE finance_chart_codes SET currency_id=?,row_version=row_version+1 WHERE code='112201'",foreign);
  var replay=upload(request,book,"original.xlsx",file);assertThat(replay.importId()).isEqualTo(first.importId());assertThat(replay.rows().getFirst().currencyId()).isEqualTo(base);assertThat(((FinanceAuxiliaryImportService.Preview)imports.operation(request).get("preview")).importId()).isEqualTo(first.importId());
  var fresh=upload(UUID.randomUUID(),book,"original.xlsx",file);assertThat(fresh.importId()).isNotEqualTo(first.importId());assertThat(fresh.rows().getFirst().currencyId()).isEqualTo(foreign);assertThat(imports.imported(first.importId()).rows().getFirst().currencyId()).isEqualTo(base);
  assertThatThrownBy(()->upload(request,book,"changed-name.xlsx",file)).isInstanceOf(ApiException.class).hasMessageContaining("不能换内容");assertThat(db.queryForObject("SELECT count(*) FROM finance_document_intake_operations WHERE request_id=?",Integer.class,request)).isEqualTo(1);
 }
 @Test void existingContentGetsItsOwnDurableReceiptAndReadPermissionCanRecoverAfterWriteRevocation(){
  String book="旧原件-"+UUID.randomUUID();var legacy=imports.preview(true,book,base,FROM,TO,"legacy.xlsx",file);UUID request=UUID.randomUUID();assertThat(upload(request,book,"new-label.xlsx",file).importId()).isEqualTo(legacy.importId());
  db.update("UPDATE finance_chart_codes SET row_version=row_version+1 WHERE code='112201'");assertThat(upload(request,book,"new-label.xlsx",file).importId()).isEqualTo(legacy.importId());
  db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id IN(SELECT id FROM permissions WHERE code='payment_style:edit')",actor);fixture.loginAs(actor);
  assertThat(((FinanceAuxiliaryImportService.Preview)imports.operation(request).get("preview")).importId()).isEqualTo(legacy.importId());assertThat(imports.sourceBytes(legacy.importId())).containsExactly(file);assertThatThrownBy(()->upload(UUID.randomUUID(),book,"original.xlsx",file)).isInstanceOf(ApiException.class).hasMessageContaining("payment_style:edit");
  fixture.loginAs(w.superAdminUserId());assertThatThrownBy(()->imports.operation(request)).isInstanceOf(ApiException.class).hasMessageContaining("本人");assertThatThrownBy(()->imports.sourceBytes(legacy.importId())).isInstanceOf(ApiException.class).hasMessageContaining("当前账号");
 }
 @Test void concurrentSameRequestUsesOneSourceAndImmutableReceipt()throws Exception{
  UUID request=UUID.randomUUID();String book="并发原件-"+request;var start=new CountDownLatch(1);var workers=Executors.newFixedThreadPool(2);
  try{var a=workers.submit(()->{fixture.loginAs(actor);try{start.await(20,TimeUnit.SECONDS);return upload(request,book,"same.xlsx",file).importId();}finally{SecurityContextHolder.clearContext();}});var b=workers.submit(()->{fixture.loginAs(actor);try{start.await(20,TimeUnit.SECONDS);return upload(request,book,"same.xlsx",file).importId();}finally{SecurityContextHolder.clearContext();}});start.countDown();UUID first=a.get(60,TimeUnit.SECONDS);assertThat(b.get(60,TimeUnit.SECONDS)).isEqualTo(first);fixture.loginAs(actor);assertThat(((FinanceAuxiliaryImportService.Preview)imports.operation(request).get("preview")).importId()).isEqualTo(first);assertThat(db.queryForObject("SELECT count(*) FROM finance_statement_source_reviews WHERE actor_id=? AND source_system=?",Integer.class,actor,book)).isEqualTo(1);assertThatThrownBy(()->db.update("UPDATE finance_document_intake_operations SET family='CHANGED' WHERE request_id=?",request)).isInstanceOf(org.springframework.dao.DataAccessException.class);
  }finally{workers.shutdownNow();assertThat(workers.awaitTermination(20,TimeUnit.SECONDS)).isTrue();}
 }
 @Test void manualSeedHttpContractRetainsNonceFileAndDirectoryWithZeroRepeatedBusinessWrites()throws Exception{
  // Real Spring controller/proxies/services/transactions and a fully migrated isolated PostgreSQL.
  // Standalone dispatch retains the actual fixture principal; no company token or security override.
  var mvc=MockMvcBuilders.standaloneSetup(controller).setControllerAdvice(errors).build();
  UUID request=UUID.randomUUID();String book="anonymous-seed-"+request;
  var businessBefore=businessCounts();
  var multipart=new MockMultipartFile("file","anonymous-original.xlsx","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",file);
  var response=mvc.perform(multipart("/api/finance/auxiliary-imports/preview").file(multipart)
    .param("side","receivable").param("sourceSystem",book).param("currencyId",base.toString())
    .param("dateFrom",FROM.toString()).param("dateTo",TO.toString()).param("requestId",request.toString()))
    .andExpect(status().isOk()).andReturn().getResponse();
  var parsed=json.readTree(response.getContentAsByteArray());UUID source=UUID.fromString(parsed.required("importId").asText());
  assertThat(parsed.required("issues").isEmpty()).isTrue();
  String hash=com.uten.imp.common.storage.ImmutableDocumentStore.digest(file);
  mvc.perform(get("/api/finance/auxiliary-imports/operations/"+request)).andExpect(status().isOk())
    .andExpect(jsonPath("$.requestId").value(request.toString())).andExpect(jsonPath("$.preview.importId").value(source.toString()))
    .andExpect(jsonPath("$.preview.sha256").value(hash));
  mvc.perform(post("/api/finance/auxiliary-imports/"+source+"/file")).andExpect(status().isOk()).andExpect(content().bytes(file));
  byte[] body=json.writeValueAsBytes(Map.of("importId",source));
  mvc.perform(post("/api/finance/auxiliary-imports/directory-apply").contentType("application/json").content(body)).andExpect(status().isOk());
  var afterFirst=sourceAndDirectoryCounts();
  // A normal second script run uses these GETs only. A repeated original POST is independently safe.
  mvc.perform(get("/api/finance/auxiliary-imports/"+source)).andExpect(status().isOk()).andExpect(jsonPath("$.directoryApplied").value(true));
  mvc.perform(get("/api/finance/auxiliary-imports/operations/"+request)).andExpect(status().isOk());
  mvc.perform(post("/api/finance/auxiliary-imports/"+source+"/file")).andExpect(status().isOk()).andExpect(content().bytes(file));
  assertThat(sourceAndDirectoryCounts()).isEqualTo(afterFirst);
  mvc.perform(multipart("/api/finance/auxiliary-imports/preview").file(multipart)
    .param("side","receivable").param("sourceSystem",book).param("currencyId",base.toString())
    .param("dateFrom",FROM.toString()).param("dateTo",TO.toString()).param("requestId",request.toString()))
    .andExpect(status().isOk()).andExpect(jsonPath("$.importId").value(source.toString()));
  mvc.perform(post("/api/finance/auxiliary-imports/directory-apply").contentType("application/json").content(body)).andExpect(status().isOk());
  assertThat(sourceAndDirectoryCounts()).isEqualTo(afterFirst);assertThat(businessCounts()).isEqualTo(businessBefore);
 }
 private List<Long> businessCounts(){return List.of("gl_entries","ar_ap_ledger","stock_movements","finance_receipts","finance_payments").stream().map(table->db.queryForObject("SELECT count(*) FROM "+table,Long.class)).toList();}
 private List<Long> sourceAndDirectoryCounts(){return List.of("finance_statement_source_reviews","finance_document_intake_operations","finance_auxiliary_items").stream().map(table->db.queryForObject("SELECT count(*) FROM "+table,Long.class)).toList();}
}
