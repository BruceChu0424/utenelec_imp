package com.uten.imp.businesschain;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.application.port.SalesMasterLearningPort.SalesLearningRequest;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 保存单据的请求里顺带从客户文件补全客户资料时, 审计日志两行都在(ADR-105 + ADR-134): 请求自己的语义事件
 * (资源.方法、状态码、耗时)与「从客户文件补全资料」旁路事件, 且是同一个请求编号。
 *
 * <p>真实的报价/订货保存端点在销售包里; 这里用测试专用的探针端点做同样的事(保存事务里写单据头 + 登记
 * 提交后学习), 走完整的 MockMvc 过滤器链与审计拦截器。<b>CI 必须显式设置 {@code UTEN_RUN_DB_TESTS=true}</b>。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
@Import(MasterLearningRequestAuditPostgresTest.LearningProbeController.class)
class MasterLearningRequestAuditPostgresTest {

    static final String PROBE_ACTION = "learning_probe.save";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc mvc;

    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private String tag;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        tag = "MLA" + UUID.randomUUID().toString().replace("-", "").substring(0, 8).toUpperCase(Locale.ROOT);
        world = fixture.seedWorld(tag);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void saveRequestKeepsItsOwnOperationRowNextToTheClientLearningEvent() throws Exception {
        UUID user = fixture.createUserWithPerms(world, "seller-" + tag,
                "client:view", "client:edit", "sales_order:view", "sales_order:create");
        UUID employee = db.queryForObject("select employee_id from users where id = ?", UUID.class, user);
        UUID clientId = UUID.randomUUID();
        db.update("""
                insert into clients(id, code, name, status, code_sequence, owner_employee_id)
                values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), ?)
                """, clientId, "MLA-" + tag, "审计客户" + tag, employee);
        String email = "buyer@" + tag.toLowerCase(Locale.ROOT) + ".example";
        fixture.loginAs(user);
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        SecurityContextHolder.clearContext();

        mvc.perform(post("/api/test/master-learning-probe/{clientId}/orders", clientId)
                        .param("email", email)
                        .with(authentication(auth)))
                .andExpect(status().isOk());

        assertThat(db.queryForObject("select email from clients where id = ?", String.class, clientId))
                .isEqualTo(email);
        List<Map<String, Object>> rows = db.queryForList("""
                select action, target_type, target_id, http_method, status_code, duration_ms, request_id, result
                from audit_log
                where actor_id = ? and action in (?, 'client.learn_from_document')
                """, user, PROBE_ACTION);
        assertThat(rows).extracting(row -> row.get("action"))
                .as("保存请求自己的语义事件不能因为学习写了旁路事件而被跳过")
                .containsExactlyInAnyOrder(PROBE_ACTION, "client.learn_from_document");
        Map<String, Object> operation = row(rows, PROBE_ACTION);
        assertThat(operation).containsEntry("http_method", "POST").containsEntry("status_code", 200)
                .containsEntry("target_id", clientId.toString());
        assertThat(operation.get("duration_ms")).isNotNull();
        Map<String, Object> learned = row(rows, "client.learn_from_document");
        assertThat(learned).containsEntry("target_type", "clients").containsEntry("target_id", clientId.toString());
        assertThat((String) learned.get("result")).contains("邮箱").doesNotContain(email);
        assertThat(learned.get("request_id")).isNotNull().isEqualTo(operation.get("request_id"));
    }

    private static Map<String, Object> row(List<Map<String, Object>> rows, String action) {
        return rows.stream().filter(row -> action.equals(row.get("action"))).findFirst().orElseThrow();
    }

    /** 测试专用: 在保存事务里写一张订货单头并登记提交后学习(与报价/订货保存端点的调用方式一致)。 */
    @RestController
    @RequestMapping("/api/test/master-learning-probe")
    static class LearningProbeController {

        private final JdbcTemplate db;
        private final PlatformTransactionManager transactionManager;
        private final SalesMasterLearningPort learning;
        private final DocNumberService docNumbers;

        LearningProbeController(JdbcTemplate db, PlatformTransactionManager transactionManager,
                                SalesMasterLearningPort learning, DocNumberService docNumbers) {
            this.db = db;
            this.transactionManager = transactionManager;
            this.learning = learning;
            this.docNumbers = docNumbers;
        }

        @PostMapping("/{clientId}/orders")
        @PreAuthorize("isAuthenticated()")
        public Map<String, Object> save(@PathVariable UUID clientId, @RequestParam String email) {
            AuthUser user = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            UUID orderId = UUID.randomUUID();
            new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
                db.update("""
                        insert into sales_orders(id, bill_no, bill_date, client_id, owner_employee_id, maker_id, status)
                        values (?, ?, current_date, ?, ?, ?, 0)
                        """, orderId, docNumbers.nextNumber(DocNumberPrefix.SALES_ORDER), clientId,
                        user.getEmployeeId(), user.getEmployeeId());
                learning.learnAfterCommit(new SalesLearningRequest("order", orderId, clientId, user.getId(),
                        user.getEmployeeId(), List.of(), Map.of("email", email), null));
            });
            return Map.of("id", orderId);
        }
    }
}
