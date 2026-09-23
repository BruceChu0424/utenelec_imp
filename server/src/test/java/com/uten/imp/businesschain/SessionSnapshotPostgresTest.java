package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.auth.DocumentScopeCapabilityService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/**
 * 会话快照(GET /api/auth/me 的 session 段, ADR-108)的真库契约:
 * 可委派页面、六个单据范围写能力、偏好整表随资料一次带回, 且与各自的原口径一致;
 * 已删除的逐页 capability / document-scopes / 偏好 GET 端点不再可达。
 *
 * <p><b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>, 否则本类 SKIP。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
@Import(ProductionJdbcMeasurement.Configuration.class)
class SessionSnapshotPostgresTest {

    private static final Set<String> SCOPES =
            Set.of("sales", "finance", "purchase", "subcontract", "production_plan", "stock_doc");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired DocumentScopeCapabilityService documentScopes;

    private FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
        ProductionJdbcMeasurement.end();
    }

    @Test
    void meCarriesProfileAndOneSessionSnapshot() throws Exception {
        var world = fixture.seedWorld("SNAP" + tag());
        UUID seller = fixture.createUserWithPerms(world, "snap-" + tag(), "sales_order:view");
        Authentication actor = auth(seller);

        // 偏好写路径不变(PUT 单键); 读取随快照带回。
        var put = http.perform(put("/api/user/preferences/{key}", "report.filter")
                        .with(authentication(actor))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"range\":\"month\"}"))
                .andReturn().getResponse();
        assertThat(put.getStatus()).isEqualTo(200);

        ProductionJdbcMeasurement.Sample sample = ProductionJdbcMeasurement.begin();
        JsonNode me;
        try {
            me = getJson("/api/auth/me", actor);
        } finally {
            ProductionJdbcMeasurement.end();
        }
        System.out.printf(Locale.ROOT, "SESSION_SNAPSHOT_BUDGET /auth/me statements=%d jdbcMillis=%.1f%n",
                sample.logicalStatements, sample.jdbcNanos / 1e6);

        assertThat(me.path("id").asText()).as("资料字段平铺在顶层, 与登录响应里的 user 同形")
                .isEqualTo(seller.toString());
        assertThat(me.path("permissions").isArray()).isTrue();
        JsonNode session = me.path("session");
        assertThat(session.path("delegableSurfaceKeys").isArray()).isTrue();
        assertThat(session.path("delegableSurfaceKeys")).as("普通员工不是负责人: 没有可委派页面").isEmpty();
        assertThat(names(session.path("documentScopes"))).isEqualTo(new TreeSet<>(SCOPES));
        fixture.loginAs(seller);
        for (String scope : SCOPES) {
            var expected = documentScopes.current(scope);
            JsonNode actual = session.path("documentScopes").path(scope);
            assertThat(actual.path("writeAll").asBoolean()).as("范围 %s writeAll", scope)
                    .isEqualTo(expected.writeAll());
            Set<String> owners = new TreeSet<>();
            actual.path("writableOwnerIds").forEach(owner -> owners.add(owner.asText()));
            Set<String> expectedOwners = new TreeSet<>();
            expected.writableOwnerIds().forEach(owner -> expectedOwners.add(owner.toString()));
            assertThat(owners).as("范围 %s 可写归属人", scope).isEqualTo(expectedOwners);
        }
        SecurityContextHolder.clearContext();
        assertThat(session.path("preferences").path("report.filter").path("range").asText()).isEqualTo("month");
        assertThat(sample.logicalStatements).as("/auth/me 语句预算(资料 + 6 个范围 + 偏好)")
                .isLessThanOrEqualTo(40);
    }

    @Test
    void superAdminCanDelegateEveryRegisteredPageAndOldPerPageEndpointsAreGone() throws Exception {
        var world = fixture.seedWorld("SNAPADMIN" + tag());
        Authentication admin = auth(world.superAdminUserId());
        JsonNode session = getJson("/api/auth/me", admin).path("session");
        assertThat(session.path("delegableSurfaceKeys")).as("超管对全部已登记页面都能打开本页权限设置").isNotEmpty();
        for (JsonNode scope : session.path("documentScopes")) {
            assertThat(scope.path("writeAll").asBoolean()).as("超管各范围可写全部").isTrue();
        }
        for (String removed : new String[] {
                "/api/department-staff-permissions/capability?surfaceKey=org.employee",
                "/api/auth/me/document-scopes/sales",
                "/api/user/preferences"}) {
            int status = http.perform(get(removed).with(authentication(admin))).andReturn().getResponse().getStatus();
            assertThat(status).as("已由会话快照替代的旧端点 %s", removed).isIn(404, 405);
        }
    }

    private JsonNode getJson(String path, Authentication actor) throws Exception {
        var response = http.perform(get(path).with(authentication(actor))).andReturn().getResponse();
        assertThat(response.getStatus()).as("GET %s", path).isEqualTo(200);
        return json.readTree(response.getContentAsByteArray());
    }

    private Authentication auth(UUID userId) {
        fixture.loginAs(userId);
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        SecurityContextHolder.clearContext();
        return authentication;
    }

    private static Set<String> names(JsonNode object) {
        Set<String> out = new TreeSet<>();
        object.fieldNames().forEachRemaining(out::add);
        return out;
    }

    private static String tag() {
        return UUID.randomUUID().toString().substring(0, 8).toUpperCase(Locale.ROOT);
    }
}
