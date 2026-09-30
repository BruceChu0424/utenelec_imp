package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.master.goods.costing.GoodsCostContracts;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.support.DailyReportApproveRequests;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Full Flyway + real Spring/security/controller/service/export wiring, without a public HTTP server. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.provider=local","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class GoodsCostHttpSmokeEndToEndTest {
    private static final String ROOT="/api/master/goods/cost-sheets";
    private static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    private static Path attachmentDirectory;
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) throws Exception {
        POSTGRES.start();attachmentDirectory=Files.createTempDirectory("uten-cost-http-smoke-");
        properties.add("spring.datasource.url",POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username",POSTGRES::getUsername);
        properties.add("spring.datasource.password",POSTGRES::getPassword);
        properties.add("uten.storage.local-dir",()->attachmentDirectory.toString());
    }
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired Flyway flyway;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDailyReportService reports;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private Authentication owner;

    @BeforeEach void seed(){
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("cost-http-"+UUID.randomUUID().toString().substring(0,8));
        owner=auth(world.superAdminUserId());
        assertThat(owner.getAuthorities()).anyMatch(authority->authority.getAuthority().equals("goods:cost:export"));
        assertThat(flyway.info().pending()).isEmpty();
        assertThat(db.queryForObject("SELECT to_regclass('goods_cost_sheets') IS NOT NULL AND to_regclass('inventory_cost_gl_links') IS NOT NULL",Boolean.class)).isTrue();
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void openingCostTableNeedsNoFormAndKeepsUnpricedMaterialsVisibleWithoutSavingAnything() throws Exception {
        long sheetsBefore=db.queryForObject("SELECT count(*) FROM goods_cost_sheets",Long.class);
        long snapshotsBefore=db.queryForObject("SELECT count(*) FROM goods_cost_snapshots",Long.class);
        var goodsBefore=db.queryForMap("SELECT version,c_total FROM goods WHERE id=?",world.goodsA());
        for(int call=0;call<2;call++) {
            JsonNode opened=body(request(get(ROOT+"/bootstrap").param("goodsId",world.goodsA().toString()),owner,null,200));
            JsonNode input=opened.path("resolvedInput");
            assertThat(input.path("goodsId").asText()).isEqualTo(world.goodsA().toString());
            assertThat(input.path("batchQty").asText()).isEqualTo("1");
            assertThat(input.path("exchangeRateToLocal").asText()).isEqualTo("1");
            assertThat(input.path("effectiveDate").asText()).isEqualTo(com.uten.imp.common.time.BusinessTime.today().toString());
            assertThat(input.path("usageStrategy").asText()).isEqualTo("ACTUAL_FIRST");
            assertThat(input.path("clientId").isNull()||input.path("clientId").isMissingNode()).isTrue();
            assertThat(opened.path("lines").size()).isGreaterThanOrEqualTo(3);
            assertThat(opened.path("lines").toString()).contains(world.goodsB().toString(),world.goodsD().toString());
            assertThat(opened.path("totals").path("valueState").asText()).isEqualTo("INCOMPLETE");
            assertThat(opened.path("totals").path("unitCost").isNull()).isTrue();
            assertThat(opened.path("issues").isEmpty()).isFalse();
            for(JsonNode line:opened.path("lines")) {
                assertThat(line.path("goodsName").asText()).isNotBlank();
                assertThat(line.path("unitName").asText()).isEqualTo("个");
            }
        }
        assertThat(db.queryForObject("SELECT count(*) FROM goods_cost_sheets",Long.class)).isEqualTo(sheetsBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM goods_cost_snapshots",Long.class)).isEqualTo(snapshotsBefore);
        assertThat(db.queryForMap("SELECT version,c_total FROM goods WHERE id=?",world.goodsA())).isEqualTo(goodsBefore);
    }

    @Test void completeHttpCostLifecycleKeepsConfirmedSnapshotAndBothDownloadsFrozen() throws Exception {
        DraftInput input=input("0.5");
        JsonNode preview=body(request(post(ROOT+"/preview"),owner,input,200));
        assertThat(preview.path("totals").path("knownTotal").asText()).isEqualTo("5.2");
        assertThat(preview.path("totals").path("unitCost").asText()).isEqualTo("0.52");
        assertThat(preview.path("totals").path("valueState").asText()).isEqualTo("COMPLETE");
        JsonNode line=preview.path("lines").get(0);
        assertThat(line.path("unitId").asText()).isEqualTo(world.unitId().toString());
        assertThat(line.path("unitName").asText()).isEqualTo("个");
        assertThat(line.path("batchQty").asText()).isEqualTo("10");
        assertThat(line.path("perProductQty").asText()).isEqualTo("1");
        assertThat(line.path("extraCosts").path("inspection").asText()).isEqualTo("0.2");
        JsonNode created=body(request(post(ROOT),owner,new SaveRequest(null,key("create"),input),200));
        String id=created.path("id").asText();
        JsonNode saved=body(request(put(ROOT+"/"+id),owner,new SaveRequest(created.path("version").asLong(),key("save"),input("0.75")),200));
        assertThat(saved.path("calculation").path("totals").path("knownTotal").asText()).isEqualTo("7.7");
        JsonNode confirmed=body(request(post(ROOT+"/"+id+"/confirm"),owner,new Command(saved.path("version").asLong(),key("confirm")),200));
        assertThat(confirmed.path("status").asText()).isEqualTo("CONFIRMED");
        JsonNode snapshot=body(request(post(ROOT+"/"+id+"/snapshots"),owner,new Command(confirmed.path("version").asLong(),key("snapshot")),200));
        String snapshotId=snapshot.path("id").asText(),digest=snapshot.path("contentDigest").asText();
        assertThat(snapshotId).isEqualTo(confirmed.path("confirmedSnapshotId").asText());
        assertThat(digest).matches("[0-9a-f]{64}");
        JsonNode history=body(request(get(ROOT+"/"+id+"/snapshots"),owner,null,200));
        assertThat(history.toString()).contains(snapshotId,digest);
        request(put(ROOT+"/"+id),owner,new SaveRequest(confirmed.path("version").asLong(),key("forbidden-edit"),input("99")),409);
        // A real live-master change cannot rewrite an already confirmed calculation or export.
        db.update("UPDATE goods SET price=999,c_total=999,version=version+1 WHERE id=?",world.goodsD());
        JsonNode frozen=body(request(get(ROOT+"/snapshots/"+snapshotId),owner,null,200));
        assertThat(frozen.path("contentDigest").asText()).isEqualTo(digest);
        assertThat(frozen.path("calculation").path("totals").path("knownTotal").asText()).isEqualTo("7.7");
        for(String format:List.of("xlsx","pdf")) {
            MvcResult download=request(post(ROOT+"/export"),owner,Map.of("sheetId",id,"snapshotId",snapshotId,"format",format,"section","ALL"),200);
            assertThat(download.getResponse().getHeader("X-Cost-Snapshot")).isEqualTo(snapshotId);
            assertThat(download.getResponse().getHeader("X-Cost-Digest")).isEqualTo(digest);
            byte[] bytes=download.getResponse().getContentAsByteArray();assertThat(bytes.length).isGreaterThan(1000);
            if(format.equals("xlsx")) {
                assertThat(download.getResponse().getContentType()).contains("spreadsheetml");
                try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
                    assertThat(workbook.getNumberOfSheets()).isGreaterThanOrEqualTo(3);
                    var formatter=new DataFormatter(Locale.ROOT);StringBuilder cells=new StringBuilder();
                    for(var sheet:workbook)for(var row:sheet)for(var cell:row)cells.append(formatter.formatCellValue(cell)).append('|');
                    assertThat(cells.toString()).contains("检验费","7.7",digest);
                }
            } else {
                assertThat(download.getResponse().getContentType()).contains("application/pdf");
                try(var document=Loader.loadPDF(bytes)) {
                    assertThat(document.getNumberOfPages()).isPositive();
                    assertThat(new PDFTextStripper().getText(document)).contains("检验费","7.7",digest);
                }
            }
        }
    }

    @Test void actualHttpEmptyStateHasDigestAndAuthorizationBlocksCostAndExport() throws Exception {
        JsonNode actual=body(request(get(ROOT+"/actual").param("goodsId",world.goodsD().toString()),owner,null,200));
        assertThat(actual.path("contentDigest").asText()).matches("[0-9a-f]{64}");
        assertThat(actual.path("summary").path("knownInputCostLocal").isNull()).isTrue();
        assertThat(actual.path("summary").path("actualUnitCostLocal").isNull()).isTrue();
        assertThat(actual.path("summary").path("pending").asBoolean()).isTrue();
        assertThat(actual.path("inputs").isEmpty()).isTrue();
        String digest=actual.path("contentDigest").asText();
        MvcResult actualDownload=request(post(ROOT+"/actual/export"),owner,Map.of("goodsId",world.goodsD(),"expectedDigest",digest,"format","xlsx"),200);
        assertThat(actualDownload.getResponse().getHeader("X-Cost-Digest")).isEqualTo(digest);
        try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(actualDownload.getResponse().getContentAsByteArray()))) {assertThat(workbook.getNumberOfSheets()).isPositive();}
        request(post(ROOT+"/actual/export"),owner,Map.of("goodsId",world.goodsD(),"expectedDigest","0".repeat(64),"format","xlsx"),409);

        UUID viewer=fixture.createUserWithPerms(world,"cost-view-only-"+UUID.randomUUID().toString().substring(0,8),"goods:view");
        Authentication restricted=auth(viewer);
        assertThat(restricted.getAuthorities()).noneMatch(authority->authority.getAuthority().equals("goods:cost:view"));
        request(post(ROOT+"/preview"),restricted,input("0.5"),403);
        request(get(ROOT+"/bootstrap").param("goodsId",world.goodsD().toString()),restricted,null,403);
        request(get(ROOT+"/actual").param("goodsId",world.goodsD().toString()),restricted,null,403);
        request(get(ROOT+"/production-output").param("goodsId",world.goodsD().toString()),restricted,null,403);
        request(post(ROOT+"/export"),restricted,Map.of("sheetId",UUID.randomUUID(),"snapshotId",UUID.randomUUID(),"format","xlsx"),403);
    }
    @Test void productionOutputWithoutApprovedReportsIsReadOnlyAndDoesNotInventActualQuantity() throws Exception {
        long sheetsBefore=db.queryForObject("SELECT count(*) FROM goods_cost_sheets",Long.class);
        long reportsBefore=db.queryForObject("SELECT count(*) FROM production_daily_reports",Long.class);
        long costsBefore=db.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects",Long.class);
        var before=db.queryForMap("SELECT version,c_total FROM goods WHERE id=?",world.goodsD());
        for(int call=0;call<2;call++) {
            JsonNode result=body(request(get(ROOT+"/production-output").param("goodsId",world.goodsD().toString()),owner,null,200));
            assertThat(result.path("goodsId").asText()).isEqualTo(world.goodsD().toString());
            assertThat(result.path("state").asText()).isEqualTo("NONE");
            assertThat(result.path("approvedReportedQty").isNull()).isTrue();
            assertThat(result.path("effectiveCompletedQty").isNull()).isTrue();
        }
        assertThat(db.queryForObject("SELECT count(*) FROM goods_cost_sheets",Long.class)).isEqualTo(sheetsBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM production_daily_reports",Long.class)).isEqualTo(reportsBefore);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects",Long.class)).isEqualTo(costsBefore);
        assertThat(db.queryForMap("SELECT version,c_total FROM goods WHERE id=?",world.goodsD())).isEqualTo(before);
    }
    @Test void productionOutputTracksRealReportApprovalAndReversalBeforeAnyValuationOutputExists() throws Exception {
        fixture.loginAs(world.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",world,"10");
        UUID plan=ReflectionTestUtils.invokeMethod(fixture,"approvedPlan",world,world.goodsA(),"10","10");
        ReflectionTestUtils.invokeMethod(fixture,"issueReadyPlanAndMaterials",world,plan);
        UUID planItem=ReflectionTestUtils.invokeMethod(fixture,"planItemIdFor",plan,world.goodsA());
        UUID orderItem=ReflectionTestUtils.invokeMethod(fixture,"orderItemIdOfPlan",plan);
        Object draft=ReflectionTestUtils.invokeMethod(fixture,"createPrefixReportDraft",world,plan,planItem,orderItem,"4");
        UUID report=ReflectionTestUtils.invokeMethod(draft,"id"),reporter=ReflectionTestUtils.invokeMethod(draft,"reporter");
        JsonNode pending=body(request(get(ROOT+"/production-output").param("goodsId",world.goodsA().toString()),owner,null,200));
        assertThat(pending.path("state").asText()).isEqualTo("NONE");
        fixture.loginAs(reporter);reports.approve(report,DailyReportApproveRequests.freshKey());
        UUID segment=db.queryForObject("SELECT execution_segment_id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,report);
        UUID scope=db.queryForObject("SELECT fn_production_execution_cost_scope(?)",UUID.class,segment);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Integer.class,scope)).isZero();
        JsonNode approved=body(request(get(ROOT+"/production-output").param("goodsId",world.goodsA().toString()),owner,null,200));
        assertThat(approved.path("scopeId").asText()).isEqualTo(scope.toString());
        assertThat(approved.path("approvedReportedQty").asText()).isEqualTo("4");
        assertThat(approved.path("effectiveCompletedQty").asText()).isEqualTo("4");
        assertThat(approved.path("fqcDeductedQty").asText()).isEqualTo("0");
        assertThat(approved.path("unitId").asText()).isEqualTo(world.unitId().toString());
        assertThat(approved.path("unitName").asText()).isEqualTo("个");
        request(get(ROOT+"/production-output").param("goodsId",world.goodsD().toString()).param("executionSegmentId",segment.toString()),owner,null,422);
        fixture.loginAs(reporter);reports.reverse(report);
        JsonNode reversed=body(request(get(ROOT+"/production-output").param("goodsId",world.goodsA().toString()),owner,null,200));
        assertThat(reversed.path("state").asText()).isEqualTo("NONE");
        assertThat(reversed.path("effectiveCompletedQty").isNull()).isTrue();
        assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=?",Integer.class,scope)).isZero();
    }

    private DraftInput input(String price){
        return new DraftInput(world.goodsD(),null,"完整链路成本单","10",null,"1",LocalDate.of(2026,9,29),"DESIGN","MANUAL",null,
                List.of(new LineOverride("ROOT",null,"BUY",price,"1","1",null,"AS_RECORDED",null,"MANUAL","smoke checked original cost")),
                List.of(),List.of(new PriceColumn("inspection","检验费","PER_QUANTITY","PROCESS",List.of())),
                List.of(new PriceCell("ROOT","inspection","0.02",null,"smoke inspection fee")),Map.of(),"真实Schema接口闭环测试");
    }
    private Authentication auth(UUID user){fixture.loginAs(user);return SecurityContextHolder.getContext().getAuthentication();}
    private String key(String action){return "cost-http-"+action+"-"+UUID.randomUUID();}
    private JsonNode body(MvcResult result) throws Exception {return json.readTree(result.getResponse().getContentAsByteArray());}
    private MvcResult request(MockHttpServletRequestBuilder request,Authentication actor,Object body,int expected) throws Exception {
        request.with(authentication(actor));
        if(body!=null)request.contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsBytes(body));
        MvcResult result=http.perform(request).andReturn();
        assertThat(result.getResponse().getStatus()).as("%s %s: %s",result.getRequest().getMethod(),result.getRequest().getRequestURI(),result.getResponse().getContentAsString()).isEqualTo(expected);
        return result;
    }
}
