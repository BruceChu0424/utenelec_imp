package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.application.SubcontractApplicationService;
import com.uten.imp.features.subcontract.application.dto.ApplicationItemLine;
import com.uten.imp.features.subcontract.application.dto.ApplicationSaveRequest;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** Issued application inputs; every order, source allocation, approval and reversal uses real services. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(properties = {"spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractOrderSourceFifoEndToEndTest {
    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractApplicationService applications;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    private FullChainEndToEndTest fixture;

    @BeforeEach void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach void logout() {
        SecurityContextHolder.clearContext();
    }

    static Stream<Arguments> cases() {
        return Stream.of(
                Arguments.of("shared multi-source rows", "25", List.of(0, 1), "25", List.of(0, 1),
                        List.of("25", "0", "0"), List.of("5", "20", "0")),
                Arguments.of("single-source consumes later FIFO capacity", "25", List.of(0), "25", List.of(0, 1),
                        List.of("25", "0", "0"), List.of("5", "20", "0")),
                Arguments.of("a prior last source consumes its later non-last capacity", "35", List.of(0, 1),
                        "25", List.of(1, 2), List.of("30", "5", "0"), List.of("0", "15", "10")),
                Arguments.of("genuine excess remains on the last declared source", "35", List.of(0, 1),
                        "25", List.of(0, 1), List.of("30", "5", "0"), List.of("0", "25", "0")));
    }

    @Test
    void listOnlyApplicationSourcesCannotBypassSingleOrBatchCreateAuthority() {
        String tag = "sc-source-create-" + UUID.randomUUID().toString().substring(0, 8);
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        UUID source = application(w, "20", 0);
        UUID buyer = fixture.createUserWithPerms(w, tag + "-buyer", "subcontract_order:create", "subcontract_order:view");
        var request = order(w);
        request.setItems(List.of(row(w, 1, "2", "3", List.of(source))));
        fixture.loginAs(buyer);
        assertNoDecompositionAuthority();

        assertForbidden(() -> orders.create(request));
        assertForbidden(() -> orders.createBatch(request));

        assertThat(db.queryForObject("""
                SELECT count(*) FROM subcontract_orders
                WHERE maker_id=(SELECT employee_id FROM users WHERE id=?)
                """, Integer.class, buyer)).isZero();
        assertThat(db.queryForObject("""
                SELECT count(*) FROM subcontract_order_item_sources WHERE application_item_id=?
                """, Integer.class, source)).isZero();
        counter(source, "0");
    }

    @Test
    void draftEditsKeepExistingSourcesButRequireAuthorityToAddReplaceOrDetachThem() {
        String tag = "sc-source-edit-" + UUID.randomUUID().toString().substring(0, 8);
        var w = fixture.seedWorld(tag);
        fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        UUID originalSource = application(w, "20", 0);
        UUID replacementSource = application(w, "20", 1);
        UUID buyer = fixture.createUserWithPerms(w, tag + "-buyer", "subcontract_order:create", "subcontract_order:edit",
                "subcontract_order:view", "subcontract_application:view", "subcontract_order:decompose");
        fixture.withSubcontractKitStaged(w, Map.of(w.goodsE(), "20"), () -> {
            try {
                fixture.loginAs(buyer);
                var request = order(w);
                request.setItems(List.of(row(w, 1, "2", "3", List.of(originalSource))));
                var saved = orders.create(request);
                db.update("""
                        DELETE FROM user_permission_overrides
                        WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='subcontract_order:decompose')
                        """, buyer);
                fixture.loginAs(buyer);
                assertNoDecompositionAuthority();

                request.setRemark("Ordinary edit keeps the existing application source");
                var edited = orders.update(saved.getId(), request);
                assertThat(edited.getRemark()).isEqualTo(request.getRemark());
                String before = sourceFacts(saved.getId());
                var line = request.getItems().getFirst();
                line.setApplicationItemIds(List.of(replacementSource));
                assertForbidden(() -> orders.update(saved.getId(), request));
                line.setApplicationItemIds(List.of(originalSource, replacementSource));
                assertForbidden(() -> orders.update(saved.getId(), request));
                line.setApplicationItemIds(List.of());
                assertForbidden(() -> orders.update(saved.getId(), request));
                assertThat(sourceFacts(saved.getId())).isEqualTo(before);
                counter(originalSource, "0");
                counter(replacementSource, "0");

                db.update("""
                        INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                        SELECT ?,id,'grant' FROM permissions WHERE code='subcontract_order:decompose'
                        """, buyer);
                fixture.loginAs(buyer);
                line.setApplicationItemIds(List.of(replacementSource));
                var replaced = orders.update(saved.getId(), request);
                assertThat(db.queryForList("""
                        SELECT source.application_item_id FROM subcontract_order_item_sources source
                        JOIN subcontract_order_items item ON item.id=source.order_item_id
                        WHERE item.order_id=? AND NOT item.is_deleted
                        """, UUID.class, replaced.getId())).containsExactly(replacementSource);
            } finally {
                fixture.loginAs(w.superAdminUserId());
            }
        });
    }

    private static void assertNoDecompositionAuthority() {
        AuthUser actor = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertThat(actor.getPermissions()).doesNotContain("subcontract_order:decompose");
    }

    private static void assertForbidden(Runnable action) {
        assertThatThrownBy(action::run).isInstanceOfSatisfying(ApiException.class, error ->
                assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }

    @ParameterizedTest(name = "{0}")
    @MethodSource("cases")
    void savedRowsShareFifoCapacityAndApprovalReversalMirrorTheirExactSourceFacts(
            String scenario, String firstQty, List<Integer> firstSources, String secondQty,
            List<Integer> secondSources, List<String> firstExpected, List<String> secondExpected) {
        var w = fixture.seedWorld("subcontract-source-fifo-" + UUID.randomUUID());
        fixture.loginAs(w.superAdminUserId());
        fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        List<UUID> sources = List.of(application(w, "30", 0), application(w, "20", 1), application(w, "20", 2));
        UUID reviewer = ReflectionTestUtils.invokeMethod(fixture, "createApprover", w);
        BigDecimal totalQty = new BigDecimal(firstQty).add(new BigDecimal(secondQty));
        fixture.withSubcontractKitStaged(w, Map.of(w.goodsE(), totalQty.toPlainString()), () -> {
            var request = order(w);
            request.setItems(List.of(
                    row(w, 1, firstQty, "3", firstSources.stream().map(sources::get).toList()),
                    row(w, 2, secondQty, "7", secondSources.stream().map(sources::get).toList())));
            var saved = orders.create(request);
            assertThat(saved.getItems()).hasSize(2);
            UUID first = saved.getItems().getFirst().getId();
            UUID second = saved.getItems().getLast().getId();
            assertSources(first, sources, firstExpected);
            assertSources(second, sources, secondExpected);
            String originalSources = sourceFacts(saved.getId());
            for (UUID source : sources) counter(source, "0");

            BigDecimal original = new BigDecimal(firstQty).multiply(new BigDecimal("3"))
                    .add(new BigDecimal(secondQty).multiply(new BigDecimal("7")));
            assertThat(saved.getTotalOriginal()).isEqualByComparingTo(original);
            assertThat(saved.getTotalLocal()).isEqualByComparingTo(original.multiply(new BigDecimal("7")));
            var submitted = finance.submit("SUBCONTRACT", saved.getId());
            for (UUID source : sources) counter(source, "0");
            assertThat(sourceFacts(saved.getId())).isEqualTo(originalSources);
            fixture.loginAs(reviewer);
            fixture.approvePendingFinance("SUBCONTRACT", saved.getId());
            fixture.loginAs(w.superAdminUserId());
            assertThat(orders.detail(saved.getId()).getStatus()).isEqualTo((short) 1);
            assertThat(sourceFacts(saved.getId())).isEqualTo(originalSources);
            for (int i = 0; i < sources.size(); i++) {
                BigDecimal expected = new BigDecimal(firstExpected.get(i)).add(new BigDecimal(secondExpected.get(i)));
                counter(sources.get(i), expected.toPlainString());
                assertThat(db.queryForObject("""
                        SELECT application.is_closed FROM subcontract_applications application
                        JOIN subcontract_application_items item ON item.application_id=application.id WHERE item.id=?
                        """, Boolean.class, sources.get(i)))
                        .isEqualTo(expected.compareTo(new BigDecimal(i == 0 ? "30" : "20")) >= 0);
            }
            assertThat(db.queryForObject("""
                    SELECT COUNT(*) FROM procurement_order_approval_events WHERE case_id=? AND event_type='APPROVED'
                    """, Integer.class, submitted.caseId())).isEqualTo(1);
            assertThat(db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=?",
                    Integer.class, saved.getId())).isZero();

            var reversed = orders.reverse(saved.getId());
            assertThat(reversed.getStatus()).isEqualTo((short) -1);
            assertThat(sourceFacts(saved.getId())).isEqualTo(originalSources);
            assertThat(reversed.getTotalOriginal()).isEqualByComparingTo(original);
            assertThat(reversed.getTotalLocal()).isEqualByComparingTo(original.multiply(new BigDecimal("7")));
            for (UUID source : sources) {
                counter(source, "0");
                assertThat(db.queryForObject("""
                        SELECT application.is_closed FROM subcontract_applications application
                        JOIN subcontract_application_items item ON item.application_id=application.id WHERE item.id=?
                        """, Boolean.class, source)).isFalse();
            }
            assertThat(db.queryForObject("SELECT COUNT(*) FROM stock_movements WHERE source_doc_id=?",
                    Integer.class, saved.getId())).isZero();
            return null;
        });
    }

    private UUID application(FullChainEndToEndTest.World w, String quantity, int day) {
        var request = new ApplicationSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setNeedDate(BusinessTime.today().plusDays(day));
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        var line = new ApplicationItemLine();
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        request.setItems(List.of(line));
        var saved = applications.create(request);
        // Input fixture represents an issued application; never seed orders, source shares or ordered counters.
        db.update("UPDATE subcontract_applications SET status=1 WHERE id=?", saved.getId());
        return saved.getItems().getFirst().getId();
    }

    private OrderSaveRequest order(FullChainEndToEndTest.World w) {
        var request = new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());
        request.setSupplierId(w.supplierId());
        request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());
        request.setExchangeRate(new BigDecimal("7"));
        request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture, "activeSettlementMethodId"));
        return request;
    }

    private OrderItemLine row(FullChainEndToEndTest.World w, int number, String quantity,
                              String price, List<UUID> sources) {
        var line = new OrderItemLine();
        line.setLineNo(number);
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setPrice(new BigDecimal(price));
        line.setApplicationItemIds(sources);
        return line;
    }

    private void assertSources(UUID item, List<UUID> sources, List<String> expected) {
        int positive = 0;
        UUID anchor = null;
        for (int i = 0; i < sources.size(); i++) {
            BigDecimal quantity = new BigDecimal(expected.get(i));
            if (quantity.signum() > 0) {
                positive++;
                if (anchor == null) anchor = sources.get(i);
                assertThat(db.queryForObject("""
                        SELECT alloc_qty FROM subcontract_order_item_sources
                        WHERE order_item_id=? AND application_item_id=?
                        """, BigDecimal.class, item, sources.get(i))).isEqualByComparingTo(quantity);
            } else {
                assertThat(db.queryForObject("""
                        SELECT COUNT(*) FROM subcontract_order_item_sources
                        WHERE order_item_id=? AND application_item_id=?
                        """, Integer.class, item, sources.get(i))).isZero();
            }
        }
        assertThat(db.queryForObject("SELECT COUNT(*) FROM subcontract_order_item_sources WHERE order_item_id=?",
                Integer.class, item)).isEqualTo(positive);
        assertThat(db.queryForObject("SELECT application_item_id FROM subcontract_order_items WHERE id=?",
                UUID.class, item)).isEqualTo(anchor);
    }

    private void counter(UUID source, String expected) {
        assertThat(db.queryForObject("SELECT ordered_qty FROM subcontract_application_items WHERE id=?",
                BigDecimal.class, source)).isEqualByComparingTo(expected);
    }

    private String sourceFacts(UUID order) {
        return db.queryForObject("""
                SELECT COALESCE(jsonb_agg(to_jsonb(source) ORDER BY item.line_no,source.line_no),'[]'::jsonb)::text
                FROM subcontract_order_item_sources source JOIN subcontract_order_items item ON item.id=source.order_item_id
                WHERE item.order_id=? AND NOT item.is_deleted
                """, String.class, order);
    }
}
