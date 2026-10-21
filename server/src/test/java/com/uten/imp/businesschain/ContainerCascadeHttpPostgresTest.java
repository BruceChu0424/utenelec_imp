package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Production MVC, method security, transaction and nested validation paths over real PostgreSQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class ContainerCascadeHttpPostgresTest {
    private static final String WAREHOUSES="/api/production/material-analyses/goods-owning-warehouses";
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired MockMvc http;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private Authentication actor;

    @BeforeEach
    void setup() {
        fixture=new FullChainEndToEndTest(); beans.autowireBean(fixture);
        world=fixture.seedWorld("cascade-"+UUID.randomUUID().toString().substring(0,8));
        fixture.loginAs(world.superAdminUserId()); actor=SecurityContextHolder.getContext().getAuthentication();
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test
    void rawListElementValidationPreservesErrorPermissionNullAndEmptyContracts() throws Exception {
        MvcResult invalid=putJson(WAREHOUSES,"[{}]",actor);
        assertError(invalid,422,"VALIDATION_FAILED");
        assertThat(body(invalid).path("fieldErrors").toString()).contains("goodsId");
        assertThat(putJson(WAREHOUSES,json.writeValueAsString(List.of(Map.of(
                "goodsId",world.goodsA(),"owningWarehouseId",world.warehouseId()))),actor)
                .getResponse().getStatus()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?",UUID.class,world.goodsA()))
                .isEqualTo(world.warehouseId());
        assertThat(putJson(WAREHOUSES,"[]",actor).getResponse().getStatus()).isEqualTo(200);
        assertError(putJson(WAREHOUSES,"null",actor),400,"MALFORMED_REQUEST");
        UUID viewer=fixture.createUserWithPerms(world,"cascade-viewer-"+UUID.randomUUID().toString().substring(0,8),
                "production_material_analysis:view");
        fixture.loginAs(viewer);
        Authentication denied=SecurityContextHolder.getContext().getAuthentication();
        // MVC argument validation precedes the method-security proxy. A malformed
        // element is rejected before invocation, regardless of the caller's grants.
        MvcResult deniedInvalid=putJson(WAREHOUSES,"[{}]",denied);
        assertError(deniedInvalid,422,"VALIDATION_FAILED");
        assertThat(body(deniedInvalid).path("fieldErrors").toString()).contains("goodsId");
        // This valid body would clear the current warehouse if authorization were
        // bypassed. Even a valid empty no-op must still pass the same method guard.
        assertError(putJson(WAREHOUSES,json.writeValueAsString(List.of(Map.of(
                "goodsId",world.goodsA()))),denied),403,"FORBIDDEN");
        assertError(putJson(WAREHOUSES,"[]",denied),403,"FORBIDDEN");
        assertThat(db.queryForObject("SELECT owning_warehouse_id FROM goods WHERE id=?",UUID.class,world.goodsA()))
                .isEqualTo(world.warehouseId());
    }

    @Test
    void vehicleAndPhoneInvalidReplacementRollsBackAndEmptyArrayStillClears() throws Exception {
        String vehicles="/api/profile/me/vehicles",phones="/api/profile/me/phones";
        assertThat(putJson(vehicles,"[{\"plateNo\":\"粤T12345\"}]",actor).getResponse().getStatus()).isEqualTo(200);
        assertThat(putJson(phones,"[{\"phone\":\"13800138000\"}]",actor).getResponse().getStatus()).isEqualTo(200);
        assertError(putJson(vehicles,"[{\"plateNo\":\"bad!\"}]",actor),422,"VALIDATION_FAILED");
        assertError(putJson(phones,"[{\"phone\":\"invalid\"}]",actor),422,"VALIDATION_FAILED");
        assertThat(db.queryForObject("SELECT count(*) FROM employee_vehicles WHERE employee_id=?",Integer.class,world.employeeId())).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM employee_phones WHERE employee_id=?",Integer.class,world.employeeId())).isEqualTo(1);
        assertError(putJson(vehicles,"null",actor),400,"MALFORMED_REQUEST");
        assertError(putJson(phones,"null",actor),400,"MALFORMED_REQUEST");
        assertThat(putJson(vehicles,"[]",actor).getResponse().getStatus()).isEqualTo(200);
        assertThat(putJson(phones,"[]",actor).getResponse().getStatus()).isEqualTo(200);
        assertThat(db.queryForObject("SELECT count(*) FROM employee_vehicles WHERE employee_id=?",Integer.class,world.employeeId())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM employee_phones WHERE employee_id=?",Integer.class,world.employeeId())).isZero();
    }

    @Test
    void jacksonSalesSaveStillRejectsInvalidNestedItemsBeforeCreatingAnyOrder() throws Exception {
        String content=json.writeValueAsString(Map.of("clientId",world.clientId(),"billDate",BusinessTime.today().toString(),
                "currencyId",world.currencyId(),"items",List.of(Map.of())));
        MvcResult response=http.perform(post("/api/sales/orders").with(authentication(actor)).with(csrf().asHeader())
                .contentType(MediaType.APPLICATION_JSON).content(content)).andReturn();
        assertError(response,422,"VALIDATION_FAILED");
        assertThat(body(response).path("fieldErrors").toString()).contains("items[0].goodsId");
        assertThat(db.queryForObject("SELECT count(*) FROM sales_orders WHERE client_id=?",Integer.class,world.clientId())).isZero();
    }

    private MvcResult putJson(String path,String content,Authentication authentication) throws Exception {
        return http.perform(put(path).with(authentication(authentication)).with(csrf().asHeader())
                .contentType(MediaType.APPLICATION_JSON).content(content)).andReturn();
    }
    private void assertError(MvcResult result,int status,String code) throws Exception {
        assertThat(result.getResponse().getStatus()).as(result.getResponse().getContentAsString()).isEqualTo(status);
        assertThat(body(result).path("code").asText()).isEqualTo(code);
    }
    private JsonNode body(MvcResult result) throws Exception { return json.readTree(result.getResponse().getContentAsByteArray()); }
}
