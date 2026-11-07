package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import java.io.ByteArrayInputStream;
import java.math.BigDecimal;
import java.util.*;
import org.apache.poi.ss.usermodel.DataFormatter;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.web.servlet.MockMvc;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.assertj.core.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Protected HTTP updates, field-presence/version CAS, exact headers and real workbook serialization. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@DirtiesContext(classMode=DirtiesContext.ClassMode.AFTER_CLASS)
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=false",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ClientNativeCreditEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ClientService clients;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired XlsxExportService xlsx;
    FullChainEndToEndTest fixture;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void exactCreditAndFloorSurviveFullEditInlineCasHeadersAndWorkbookWithoutChangingOtherFinancialTerms()throws Exception {
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("client-credit-native-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
        String credit="1234567890123456789012345678901234567890.123456789012345678901234";
        String floor="0.123456789012345678901234",tiny="0.000000000000000000000001";
        var before=clients.detail(world.clientId());
        Map<String,Object> body=new LinkedHashMap<>();body.put("categoryId",before.getCategoryId());body.put("code",before.getCode());
        body.put("name",before.getName());body.put("status",before.getStatus());body.put("version",before.getVersion());
        body.put("credit",credit);body.put("creditFloor",floor);body.put("remark","匿名原备注");
        var auth=SecurityContextHolder.getContext().getAuthentication();
        var saved=http.perform(put("/api/master/clients/"+world.clientId()).with(authenticated(auth)).contentType("application/json").content(json.writeValueAsBytes(body))).andReturn().getResponse();
        assertThat(saved.getStatus()).as(saved.getContentAsString()).isEqualTo(200);
        JsonNode detail=json.readTree(saved.getContentAsString());
        assertThat(detail.path("creditExact").asText()).isEqualTo(credit);assertThat(detail.path("creditFloorExact").asText()).isEqualTo(floor);
        assertThat(db.queryForList("SELECT atttypmod FROM pg_attribute WHERE attrelid='clients'::regclass AND attname IN('credit','credit_floor')",Integer.class)).containsExactlyInAnyOrder(-1,-1);
        assertThat(db.queryForObject("SELECT credit FROM clients WHERE id=?",BigDecimal.class,world.clientId())).isEqualByComparingTo(credit);
        fixture.loginAs(world.superAdminUserId());auth=SecurityContextHolder.getContext().getAuthentication();
        var patchBody=Map.of("expected",Map.of("version",detail.path("version").asLong()),"changes",Map.of("creditFloor",tiny));
        var patched=http.perform(patch("/api/master/inline-edit/clients/"+world.clientId()).with(authenticated(auth)).contentType("application/json").content(json.writeValueAsBytes(patchBody))).andReturn().getResponse();
        assertThat(patched.getStatus()).as(patched.getContentAsString()).isEqualTo(200);
        JsonNode exact=json.readTree(patched.getContentAsString());
        assertThat(exact.path("creditExact").asText()).isEqualTo(credit);assertThat(exact.path("creditFloorExact").asText()).isEqualTo(tiny);
        assertThat(exact.path("remark").asText()).isEqualTo("匿名原备注");
        fixture.loginAs(world.superAdminUserId());auth=SecurityContextHolder.getContext().getAuthentication();
        var stale=http.perform(patch("/api/master/inline-edit/clients/"+world.clientId()).with(authenticated(auth)).contentType("application/json").content(json.writeValueAsBytes(patchBody))).andReturn().getResponse();
        assertThat(stale.getStatus()).isEqualTo(409);
        fixture.loginAs(world.superAdminUserId());auth=SecurityContextHolder.getContext().getAuthentication();
        var queried=http.perform(get("/api/master/clients").with(authenticated(auth)).param("search.credit",credit).param("search.creditFloor",tiny)).andReturn().getResponse();
        assertThat(queried.getStatus()).as(queried.getContentAsString()).isEqualTo(200);
        assertThat(json.readTree(queried.getContentAsString()).path("items")).hasSize(1);
        fixture.loginAs(world.superAdminUserId());auth=SecurityContextHolder.getContext().getAuthentication();
        var rounded=http.perform(get("/api/master/clients").with(authenticated(auth)).param("search.creditFloor","0")).andReturn().getResponse();
        assertThat(rounded.getStatus()).isEqualTo(200);
        assertThat(json.readTree(rounded.getContentAsString()).path("items").findValuesAsText("id")).doesNotContain(world.clientId().toString());
        fixture.loginAs(world.superAdminUserId());
        var filter=json.convertValue(Map.of(),ClientQueryFilter.class).withColumnSearch(Map.of("credit",credit,"creditFloor",tiny));
        var exported=clients.export(filter,"creditFloor","asc");
        try(var book=new XSSFWorkbook(new ByteArrayInputStream(xlsx.build(exported.columns(),exported.rows())))){
            var sheet=book.getSheetAt(0);var formatter=new DataFormatter();int creditColumn=-1,floorColumn=-1;
            for(var cell:sheet.getRow(0)){if(cell.getStringCellValue().startsWith("信用额度")){creditColumn=cell.getColumnIndex();}if("铺底额".equals(cell.getStringCellValue()))floorColumn=cell.getColumnIndex();}
            assertThat(creditColumn).isNotNegative();assertThat(floorColumn).isNotNegative();
            assertThat(formatter.formatCellValue(sheet.getRow(1).getCell(creditColumn))).isEqualTo(credit);
            assertThat(formatter.formatCellValue(sheet.getRow(1).getCell(floorColumn))).isEqualTo(tiny);
        }
        fixture.loginAs(world.superAdminUserId());auth=SecurityContextHolder.getContext().getAuthentication();
        var invalid=Map.of("expected",Map.of("version",exact.path("version").asLong()),"changes",Map.of("creditFloor","0.0000000000000000000000001"));
        var rejected=http.perform(patch("/api/master/inline-edit/clients/"+world.clientId()).with(authenticated(auth)).contentType("application/json").content(json.writeValueAsBytes(invalid))).andReturn().getResponse();
        assertThat(rejected.getStatus()).isEqualTo(422);
        assertThat(db.queryForObject("SELECT credit_floor FROM clients WHERE id=?",BigDecimal.class,world.clientId())).isEqualByComparingTo(tiny);
        assertThat(db.queryForObject("SELECT credit FROM clients WHERE id=?",BigDecimal.class,world.clientId())).isEqualByComparingTo(credit);
        fixture.loginAs(world.superAdminUserId());var after=clients.detail(world.clientId());
        assertThat(after.getDefaultCurrencyId()).isEqualTo(before.getDefaultCurrencyId());
        assertThat(after.getDefaultSettlementMethodId()).isEqualTo(before.getDefaultSettlementMethodId());
    }
}
