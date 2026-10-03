package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.SalesMasterLearningPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.documents.DocumentDraftCountController;
import com.uten.imp.features.sales.SalesAiIntakeRequest;
import com.uten.imp.features.sales.intake.SalesIntakeUsedEvent;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.sales.order.dto.OrderDetail;
import com.uten.imp.features.sales.order.dto.OrderItemDto;
import com.uten.imp.features.sales.order.dto.OrderItemLine;
import com.uten.imp.features.sales.order.dto.OrderSaveRequest;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceDecisionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceEditRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceReviewDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.event.ApplicationEvents;
import org.springframework.test.context.event.RecordApplicationEvents;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

/**
 * ADR-134 报价核价流程(真实 PostgreSQL, 切换销售/财务/无资格账号走完整服务栈):
 * 报价单价权威、提交/撤回/退回/确认/撤销确认、财务读范围、认领与修订号、确认前阻断、转订货单带折扣并锁定、
 * 看不到价格的人保存、学习出口与识别采用事件、分段计数/草稿计数/徽章。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=quote-finance-harness-jwt-secret-0123456789-tst",
                "uten.crypto.pgp-master-key=quote-finance-harness-pgp-key-test-only-0123",
                "uten.crypto.hmac-key=quote-finance-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=quote-finance-bootstrap-admin-test",
                "uten.bootstrap.admin-password=QuoteFinanceAdminPass-1!"
        })
@RecordApplicationEvents
class SalesQuoteFinanceFlowPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    private static final String CLAIM = SalesQuoteFinanceClaimTargetLocks.TARGET_TYPE;
    private static final AtomicInteger SEQ = new AtomicInteger();
    private static final List<String> SALES_PERMS = List.of(
            "sales_quote:view", "sales_quote:create", "sales_quote:edit", "sales_quote:delete",
            "sales_quote:convert", "sales_quote:reverse",
            "sales_order:view", "sales_order:create", "sales_order:edit", "sales_order:delete", "sales_order:approve",
            "sales_order:cancel", "sales_order:stop", "sales_order:reverse", "notice:read");

    @Autowired private JdbcTemplate jdbc;
    @Autowired private PermissionResolver permissionResolver;
    @Autowired private SalesQuoteService quotes;
    @Autowired private SalesQuoteFinanceService finance;
    @Autowired private SalesOrderService orders;
    @Autowired private SalesOrderFinanceConfirmService orderFinance;
    @Autowired private TaskClaimService claims;
    @Autowired private DocumentDraftCountController documentCounts;
    @Autowired private ApplicationEvents events;
    @Autowired private com.uten.imp.common.columns.BusinessColumnService businessColumns;

    /** 学习出口由主档包实现; 这里替换成可核对入参的替身(ADR-134: 保存事务内调用一次)。 */
    @MockitoBean private SalesMasterLearningPort learning;

    @AfterEach
    void clearAuth() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void quoteFeeAndEnglishSnapshotSurviveFinanceMaskedConversionAndQuantityChange() {
        Fixture f = fixture("columns");
        UUID listed = goods("扩展列货品", BigDecimal.TEN);
        jdbc.update("UPDATE goods SET name_en='Original clip' WHERE id=?", listed);
        loginAs(f.sales());
        var definition = businessColumns.create(new com.uten.imp.common.columns.BusinessColumnService.Create(
                "sales_quote", "客户包装费", "AMOUNT", "ADD"));
        assertThat(businessColumns.search("sales_quote", "包装费用"))
                .extracting(com.uten.imp.common.columns.BusinessColumnService.Definition::id).contains(definition.id());
        QuoteSaveRequest request = quoteRequest(f.client(), line(listed, "2", null, "1", null));
        request.getItems().getFirst().setExtraColumns(List.of(
                new com.uten.imp.common.columns.ExtraColumnInput(definition.id(), "5")));
        QuoteDetail quote = quotes.create(request);
        assertThat(quote.getItems().getFirst().getAmountOriginal()).isEqualByComparingTo("25");
        assertThat(quote.getItems().getFirst().getGoodsNameEn()).isEqualTo("Original clip");
        quotes.submit(quote.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, quote.getId().toString());
        var review = finance.confirm(quote.getId(), new QuoteFinanceDecisionRequest(1, claim.claimId(), null));
        assertThat(review.lines().getFirst().extraColumns().getFirst().value()).isEqualTo("5");
        assertThat(review.lines().getFirst().goodsNameEn()).isEqualTo("Original clip");
        jdbc.update("UPDATE goods SET name_en='Renamed master' WHERE id=?", listed);
        loginAs(f.sales());
        AuthUser original = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var maskedPermissions = new java.util.HashSet<>(original.getPermissions());
        maskedPermissions.remove("sales_order:price:view");
        AuthUser masked = new AuthUser(original.getId(), original.getEmployeeId(), original.getLoginAccount(),
                maskedPermissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(masked, null, masked.getAuthorities()));
        OrderDetail order = acceptAndConvert(quote.getId());
        assertThat(order.getItems().getFirst().getExtraColumns().getFirst().value()).isNull();
        assertThat(order.getItems().getFirst().getGoodsNameEn()).isEqualTo("Original clip");
        OrderSaveRequest edit = orderRequest(order);
        edit.getItems().getFirst().setQty(new BigDecimal("3"));
        orders.update(order.getId(), edit);
        assertThat(jdbc.queryForObject("SELECT amount_original FROM sales_order_items WHERE order_id=? AND NOT is_deleted",
                BigDecimal.class, order.getId())).isEqualByComparingTo("35");
        loginAs(f.finance());
        var orderReview = orderFinance.review(order.getId());
        assertThat(orderReview.items().getFirst().extraColumns().getFirst().value()).isEqualTo("5");
        assertThat(orderReview.items().getFirst().goodsNameEn()).isEqualTo("Original clip");
        assertThat(orderReview.items().getFirst().matchesQuote()).as("订货数量由报价 2 改为 3，不能再提示报价一致").isFalse();
    }

    // =====================================================================
    // 单价权威
    // =====================================================================

    @Test
    void salesCanProposeDocumentPricesWithoutChangingTheGoodsMaster() {
        Fixture f = fixture("price");
        loginAs(f.sales());
        UUID priced = goods("报价标价货品", new BigDecimal("10"));
        UUID unpriced = goods("报价未定价货品", null);

        QuoteSaveRequest request = quoteRequest(f.client(),
                line(priced, "5", "10", "0.9", null),
                line(unpriced, "2", null, null, "3.5"));
        QuoteDetail created = quotes.create(request);
        QuoteItemDto first = created.getItems().get(0);
        QuoteItemDto second = created.getItems().get(1);
        assertThat(first.getPrice()).isEqualByComparingTo("10");
        assertThat(first.getDiscount()).isEqualByComparingTo("0.9");
        assertThat(first.getAmountOriginal()).isEqualByComparingTo("45");
        assertThat(second.getPrice()).isNull();
        assertThat(second.isPricePending()).isTrue();
        assertThat(second.getAmountOriginal()).isNull();
        assertThat(second.getClientPrice()).isEqualByComparingTo("3.5");
        assertThat(created.getTotalOriginal()).isEqualByComparingTo("45");
        assertThat(created.getPricePendingCount()).isEqualTo(1);
        assertThat(created.getStatusBucket()).isEqualTo("DRAFT");
        assertThat(created.getAllowedActions()).contains("edit", "submit", "delete").doesNotContain("convert");

        QuoteSaveRequest proposed = copy(created, request);
        proposed.getItems().get(0).setPrice(new BigDecimal("11"));
        proposed.getItems().get(1).setPrice(new BigDecimal("5"));
        QuoteDetail repriced = quotes.update(created.getId(), proposed);
        assertThat(repriced.getItems().getFirst().getPriceSource()).isEqualTo("SALES");
        assertThat(repriced.getItems().getFirst().getPrice()).isEqualByComparingTo("11");
        assertThat(repriced.getItems().get(1).getPrice()).isEqualByComparingTo("5");
        assertThat(jdbc.queryForObject("SELECT price FROM goods WHERE id=?", BigDecimal.class, priced))
                .isEqualByComparingTo("10");
        assertConflict(() -> quotes.update(created.getId(), proposed));
        jdbc.update("UPDATE goods SET price = 12 WHERE id = ?", priced);
        QuoteSaveRequest resave = copy(repriced, request);
        resave.getItems().add(line(priced, "1", null, null, null));
        QuoteDetail updated = quotes.update(created.getId(), resave);
        assertThat(updated.getItems().get(0).getId()).isEqualTo(first.getId());
        assertThat(updated.getItems().get(0).getPrice()).isEqualByComparingTo("11");
        assertThat(updated.getItems().get(2).getPrice()).isEqualByComparingTo("12");
        assertThat(updated.getItems().get(1).getId()).isEqualTo(second.getId());
        assertConflict(() -> quotes.delete(updated.getId(), created.getReviewRevision()));
        quotes.submit(updated.getId(), new QuoteActionRequest(updated.getReviewRevision()));
        assertThat(jdbc.queryForObject("""
                SELECT title FROM notices WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW'
                  AND audience_user_id = ? AND aggregate_id = ?
                """, String.class, f.finance(), updated.getId())).startsWith("报价待核价：");
    }

    // =====================================================================
    // 核价主流程 + 转订货单锁定折扣
    // =====================================================================

    @Test
    void financeReviewCycleFromSubmitToConvertedOrderWithLockedDiscount() {
        Fixture f = fixture("cycle");
        UUID listed = goods("核价标价货品", new BigDecimal("10"));
        UUID noPrice = goods("核价无标价货品", null);
        UUID zeroPrice = goods("核价零标价货品", BigDecimal.ZERO);
        UUID extraGoods = goods("订单新增货品", new BigDecimal("20"));

        loginAs(f.sales());
        QuoteSaveRequest request = quoteRequest(f.client(),
                line(listed, "10", "10", "0.95", "9.5"),
                line(noPrice, "4", null, null, "3.5"),
                line(zeroPrice, "2", "0", null, "2"));
        request.setContractNo("UJ23");
        request.setClientFileCurrency("rmb");
        request.setSellerId(employeeOf(f.sales()));
        request.setDeliverDate(LocalDate.of(2026, 12, 1));
        QuoteDetail draft = quotes.create(request);
        UUID quoteId = draft.getId();
        assertThat(draft.getClientFileCurrency()).isEqualTo("CNY");

        // 提交前财务看不到。
        loginAs(f.finance());
        assertNotFound(() -> finance.review(quoteId));
        assertNotFound(() -> quotes.detail(quoteId));

        loginAs(f.sales());
        long pendingBefore = pendingQuoteReviews(f);
        QuoteDetail submitted = quotes.submit(quoteId, new QuoteActionRequest(0));
        assertThat(submitted.getStatus()).isEqualTo((short) 2);
        assertThat(submitted.getReviewRevision()).isEqualTo(1);
        assertThat(submitted.getStatusBucket()).isEqualTo("PENDING_FINANCE");
        assertThat(submitted.getAllowedActions()).contains("withdraw").doesNotContain("edit", "submit");
        assertThat(pendingQuoteReviews(f)).isEqualTo(pendingBefore + 1);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW' AND audience_user_id = ?
                """, Long.class, f.finance())).isPositive();
        assertBusiness(() -> quotes.update(quoteId, copy(submitted, request)));

        // 财务可读: 列表 + 核价页 + 普通详情(不脱敏)。
        loginAs(f.finance());
        assertThat(finance.list("pending", null, 1, 100).getItems())
                .anyMatch(item -> item.id().equals(quoteId));
        QuoteFinanceReviewDto review = finance.review(quoteId);
        assertThat(review.lines().getFirst().salesProposedDiscount()).isEqualByComparingTo("0.95");
        assertThat(review.lines().getFirst().unitId()).isEqualTo(unitOf(listed));
        assertThat(review.financeActions()).containsExactly("edit", "return", "confirm");
        assertThat(review.blockingLineCount()).isEqualTo(2);
        assertThat(quotes.detail(quoteId).isPriceMasked()).isFalse();

        // 销售撤回: 陈旧修订号 409; 财务正在核价(持有认领) 409; 释放后撤回成功, 财务再也看不到。
        loginAs(f.sales());
        assertConflict(() -> quotes.withdraw(quoteId, new QuoteActionRequest(0)));
        loginAs(f.finance());
        var heldClaim = claims.claim(CLAIM, quoteId.toString());
        loginAs(f.sales());
        assertConflict(() -> quotes.withdraw(quoteId, new QuoteActionRequest(1)));
        loginAs(f.finance());
        claims.release(CLAIM, quoteId.toString(), heldClaim.claimId());
        loginAs(f.sales());
        QuoteDetail withdrawn = quotes.withdraw(quoteId, new QuoteActionRequest(1));
        assertThat(withdrawn.getStatusBucket()).isEqualTo("DRAFT");
        loginAs(f.finance());
        assertNotFound(() -> finance.review(quoteId));
        assertThat(finance.list("pending", null, 1, 100).getItems()).noneMatch(item -> item.id().equals(quoteId));

        loginAs(f.sales());
        quotes.submit(quoteId, new QuoteActionRequest(2));

        // 不在财务部门树的权限持有人: 不能认领、不能改价。
        loginAs(f.outsider());
        assertThat(currentPermissions()).contains("sales_quote_finance:confirm");
        assertThat(finance.pendingCount()).as("不在核价组: 红徽章不算他的待办").containsEntry("pending", 0L);
        assertForbidden(() -> claims.claim(CLAIM, quoteId.toString()));
        assertForbidden(() -> finance.edit(quoteId, edit(3, null, List.of())));

        // 财务: 没认领不能改; 认领后确认被未定价行拦下; 陈旧修订号 409。
        loginAs(f.finance());
        assertConflict(() -> finance.edit(quoteId, edit(3, null, List.of())));
        var claim = claims.claim(CLAIM, quoteId.toString());
        assertThatThrownBy(() -> finance.confirm(quoteId, new QuoteFinanceDecisionRequest(3, claim.claimId(), null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("还没有单价")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertConflict(() -> finance.edit(quoteId, edit(2, claim.claimId(), List.of())));

        List<UUID> itemIds = finance.review(quoteId).lines().stream().map(QuoteFinanceReviewDto.Line::itemId).toList();
        QuoteFinanceReviewDto edited = finance.edit(quoteId, edit(3, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(itemIds.get(0), null, new BigDecimal("9.2"), null, null),
                new QuoteFinanceEditRequest.Line(itemIds.get(1), null, new BigDecimal("3.5"), null, null),
                new QuoteFinanceEditRequest.Line(itemIds.get(2), null, null, true, null))));
        assertThat(edited.reviewRevision()).isEqualTo(4);
        QuoteFinanceReviewDto.Line dealLine = edited.lines().get(0);
        assertThat(dealLine.listPrice()).isEqualByComparingTo("10");
        assertThat(dealLine.discount()).isEqualByComparingTo("0.92");
        assertThat(dealLine.amount()).isEqualByComparingTo("92");
        QuoteFinanceReviewDto.Line financePriced = edited.lines().get(1);
        assertThat(financePriced.priceSource()).isEqualTo("FINANCE");
        assertThat(financePriced.listPrice()).isEqualByComparingTo("3.5");
        assertThat(financePriced.amount()).isEqualByComparingTo("14");
        assertThat(edited.lines().get(2).priceSource()).isEqualTo("FINANCE");
        assertThat(edited.blockingLineCount()).isZero();
        // 财务不能用 0 当成交单价(要勾赠品), 也不能一行两种改法。
        assertThatThrownBy(() -> finance.edit(quoteId, edit(4, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(itemIds.get(0), new BigDecimal("0.9"), BigDecimal.ONE, null, null)))))
                .isInstanceOf(ApiException.class);

        // 退回销售: 原因必填; 退回后财务仍可见(已退回), 销售草稿计数不含退回件, 红徽章计 1。
        assertThatThrownBy(() -> finance.returnToSales(quoteId,
                new QuoteFinanceDecisionRequest(4, claim.claimId(), " "))).isInstanceOf(ApiException.class);
        QuoteFinanceReviewDto returned = finance.returnToSales(quoteId,
                new QuoteFinanceDecisionRequest(4, claim.claimId(), "客户要改数量"));
        assertThat(returned.statusBucket()).isEqualTo("FINANCE_REJECTED");
        assertThat(finance.list("returned", null, 1, 100).getItems()).anyMatch(item -> item.id().equals(quoteId));

        loginAs(f.sales());
        Map<String, Long> buckets = documentCounts.statusCounts("salesQuote", null, null);
        assertThat(buckets).containsEntry("FINANCE_REJECTED", 1L).containsEntry("DRAFT", 0L)
                .containsEntry("PENDING_FINANCE", 0L);
        assertThat(documentCounts.draftCounts().salesQuote()).isZero();
        assertThat(documentCounts.financeRejectedCounts()).containsEntry("salesQuote", 1L);
        assertThat(quotes.list(new QuoteQueryFilter(null, null, null, null, null, null, "FINANCE_REJECTED"),
                1, 50, null, null).getItems()).extracting(item -> item.getId()).containsExactly(quoteId);
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices WHERE source_event = 'SALES_QUOTE_FINANCE_RETURNED' AND audience_user_id = ?
                """, Long.class, f.sales())).isEqualTo(1L);

        // 销售改数量后重新提交: 财务定价行保持财务定价(行 id 不变)。
        QuoteDetail returnedDraft = quotes.detail(quoteId);
        QuoteSaveRequest changed = copy(returnedDraft, request);
        changed.getItems().get(0).setQty(new BigDecimal("12"));
        changed.getItems().get(0).setDiscount(new BigDecimal("0.92"));
        QuoteDetail resaved = quotes.update(quoteId, changed);
        assertThat(resaved.getItems().get(1).isFinancePriced()).isTrue();
        assertThat(resaved.getItems().get(1).getPrice()).isEqualByComparingTo("3.5");
        assertThat(resaved.getStatusBucket()).isEqualTo("FINANCE_REJECTED");
        quotes.submit(quoteId, new QuoteActionRequest(6));

        loginAs(f.finance());
        var claim2 = claims.claim(CLAIM, quoteId.toString());
        QuoteFinanceReviewDto confirmed = finance.confirm(quoteId, new QuoteFinanceDecisionRequest(7, claim2.claimId(), "按 9.2 折"));
        assertThat(confirmed.statusBucket()).isEqualTo("APPROVED");
        assertThat(confirmed.financeActions()).containsExactly("reopen");
        assertThat(confirmed.financeRemark()).isEqualTo("按 9.2 折");
        assertThat(claims.activeClaimView(CLAIM, quoteId.toString())).isEmpty();

        // 财务撤销确认 → 待核价, 再确认: 上次确认折扣可对照。
        finance.reopen(quoteId, new QuoteActionRequest(8, "客户追加折扣"));
        var claim3 = claims.claim(CLAIM, quoteId.toString());
        QuoteFinanceReviewDto reconfirmed = finance.confirm(quoteId, new QuoteFinanceDecisionRequest(9, claim3.claimId(), null));
        assertThat(reconfirmed.lines().getFirst().lastFinanceConfirmedDiscount()).isEqualByComparingTo("0.92");
        assertThat(reconfirmed.revisions()).extracting(r -> r.action()).containsExactly(
                "SUBMIT", "WITHDRAW", "SUBMIT", "FINANCE_EDIT", "RETURN", "SALES_EDIT", "SUBMIT", "CONFIRM",
                "FINANCE_REOPEN", "CONFIRM");

        loginAs(f.sales());
        assertThat(quotes.counts().awaitingCustomerConfirmation()).isEqualTo(1);
        assertThat(quotes.counts().awaitingConversion()).isZero();
        QuoteDetail accepted = quotes.customerConfirm(quoteId, new QuoteActionRequest(10));
        assertThat(quotes.counts().awaitingConversion()).isEqualTo(1);
        QuoteQueryFilter awaiting = new QuoteQueryFilter(null, null, null, null, null, null, "awaiting_conversion");
        assertThat(quotes.list(awaiting, 1, 50, null, null).getItems())
                .as("「从报价引入」的筛选与徽章同口径").extracting(item -> item.getId()).containsExactly(quoteId);
        assertThat(quotes.detail(quoteId).getAllowedActions()).contains("convert", "reopen", "cancel");
        OrderDetail order = quotes.convertToOrder(quoteId, new QuoteActionRequest(accepted.getReviewRevision()));
        assertThat(quotes.counts().awaitingConversion()).isZero();
        assertThat(quotes.list(awaiting, 1, 50, null, null).getItems()).isEmpty();
        assertThat(order.getSourceQuoteId()).isEqualTo(quoteId);
        assertThat(order.getSourceQuote().billNo()).isEqualTo(draft.getBillNo());
        assertThat(order.getContractNo()).isEqualTo("UJ23");
        assertThat(order.getClientFileCurrency()).isEqualTo("CNY");
        assertThat(order.getSellerId()).isEqualTo(employeeOf(f.sales()));
        assertThat(order.getDeliverDate()).isEqualTo(LocalDate.of(2026, 12, 1));
        OrderItemDto lockedLine = order.getItems().getFirst();
        assertThat(lockedLine.getDiscount()).isEqualByComparingTo("0.92");
        assertThat(lockedLine.isQuoteLocked()).isTrue();
        assertThat(lockedLine.getQuoteDiscount()).isEqualByComparingTo("0.92");
        assertThat(order.getItems().get(1).getPrice()).isEqualByComparingTo("3.5");
        assertThat(order.getItems().get(1).getClientPrice()).isEqualByComparingTo("3.5");

        // 订货草稿: 改报价核定行的折扣 409; 改数量、加报价外的新行可以; 折扣留空沿用报价。
        OrderSaveRequest orderEdit = orderRequest(order);
        orderEdit.getItems().getFirst().setDiscount(new BigDecimal("0.8"));
        assertConflict(() -> orders.update(order.getId(), orderEdit));
        OrderSaveRequest qtyEdit = orderRequest(order);
        qtyEdit.getItems().getFirst().setDiscount(null);
        qtyEdit.getItems().getFirst().setQty(new BigDecimal("15"));
        OrderItemLine extra = new OrderItemLine();
        extra.setGoodsId(extraGoods);
        extra.setUnitId(unitOf(extraGoods));
        extra.setUnitRate(BigDecimal.ONE);
        extra.setQty(BigDecimal.ONE);
        extra.setDiscount(new BigDecimal("0.5"));
        qtyEdit.getItems().add(extra);
        OrderDetail revisedOrder = orders.update(order.getId(), qtyEdit);
        assertThat(revisedOrder.getItems().getFirst().getDiscount()).isEqualByComparingTo("0.92");
        assertThat(revisedOrder.getItems().getFirst().getQty()).isEqualByComparingTo("15");
        assertThat(revisedOrder.getItems().getLast().getDiscount()).isEqualByComparingTo("0.5");
        assertThat(revisedOrder.getItems().getLast().isQuoteLocked()).isFalse();

        // 报价已转单: 销售不能重新修改/作废, 财务不能撤销确认。
        assertConflict(() -> quotes.reopen(quoteId, new QuoteActionRequest(9)));
        assertConflict(() -> quotes.reverse(quoteId));
        loginAs(f.finance());
        assertConflict(() -> finance.reopen(quoteId, new QuoteActionRequest(9)));

        // 订单财务审核页: 带来源报价与逐行一致标记(报价外新增行不一致)。
        var orderReview = orderFinance.review(order.getId());
        assertThat(orderReview.sourceQuote().billNo()).isEqualTo(draft.getBillNo());
        assertThat(orderReview.sourceQuote().allLinesMatch()).isFalse();
        assertThat(orderReview.items().getFirst().matchesQuote()).as("订货数量由报价 12 改为 15，不能再提示报价一致").isFalse();
        assertThat(orderReview.items().getFirst().quoteDiscount()).isEqualByComparingTo("0.92");
        assertThat(orderReview.items().getLast().matchesQuote()).isFalse();
        assertThat(orderReview.clientFileCurrency()).isEqualTo("CNY");
    }

    @Test
    void salesReopenReturnsAConfirmedQuoteToDraftAndFinanceStopsSeeingIt() {
        Fixture f = fixture("reopen");
        UUID listed = goods("重新修改货品", new BigDecimal("8"));
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(listed, "3", null, null, null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(draft.getReviewRevision()));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        finance.confirm(draft.getId(), new QuoteFinanceDecisionRequest(1, claim.claimId(), null));
        loginAs(f.sales());
        assertConflict(() -> quotes.reopen(draft.getId(), new QuoteActionRequest(1)));
        QuoteDetail reopened = quotes.reopen(draft.getId(), new QuoteActionRequest(2));
        assertThat(reopened.getStatusBucket()).isEqualTo("DRAFT");
        assertThat(reopened.getFinanceConfirmedAt()).isNull();
        loginAs(f.finance());
        assertNotFound(() -> finance.review(draft.getId()));
    }

    @Test
    void quoteCurrencyMustBeTheBaseCurrencyAtSaveAndSubmit() {
        Fixture f = fixture("currency");
        UUID listed = goods("报价币种货品", new BigDecimal("8"));
        ensureUsd("7.1");
        UUID usd = jdbc.queryForObject("""
                SELECT id FROM currencies WHERE NOT is_deleted AND NOT is_base_currency AND status = '使用'
                  AND (name IN ('美元', '美金') OR upper(code) IN ('USD', 'US$', 'USD-QT'))
                ORDER BY code LIMIT 1
                """, UUID.class);
        loginAs(f.sales());
        QuoteSaveRequest foreign = quoteRequest(f.client(), line(listed, "3", null, null, null));
        foreign.setCurrencyId(usd);
        assertThatThrownBy(() -> quotes.create(foreign)).isInstanceOf(ApiException.class)
                .hasMessageContaining("本位币")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);

        QuoteSaveRequest base = quoteRequest(f.client(), line(listed, "3", null, null, null));
        base.setCurrencyId(baseCurrency());
        QuoteDetail draft = quotes.create(base);
        assertThat(draft.getCurrencyId()).isEqualTo(baseCurrency());
        QuoteSaveRequest switched = copy(draft, base);
        switched.setCurrencyId(usd);
        assertCode(() -> quotes.update(draft.getId(), switched), ErrorCode.VALIDATION_FAILED);

        // 库里已有外币草稿(直接写库模拟): 提交核价同样拦下, 不等财务确认后转订货单才报错。
        jdbc.update("UPDATE sales_quotes SET currency_id = ? WHERE id = ?", usd, draft.getId());
        assertCode(() -> quotes.submit(draft.getId(), new QuoteActionRequest(draft.getReviewRevision())), ErrorCode.VALIDATION_FAILED);
        assertThat(jdbc.queryForObject("SELECT status FROM sales_quotes WHERE id = ?", Integer.class, draft.getId()))
                .isZero();
    }

    @Test
    void ordersRefuseLinesWithAClientPriceWhenTheGoodsHasNoListPriceOrIsBelowIt() {
        Fixture f = fixture("orderguard");
        UUID zero = goods("订货零价货品", BigDecimal.ZERO);
        UUID listed = goods("订货标价货品", BigDecimal.TEN);
        loginAs(f.sales());
        java.util.function.BiFunction<UUID, String, OrderSaveRequest> order = (goodsId, clientPrice) -> {
            OrderSaveRequest request = new OrderSaveRequest();
            request.setBillDate(LocalDate.of(2026, 9, 27));
            request.setClientId(f.client());
            request.setCurrencyId(baseCurrency());
            request.setShipmentPolicy("ALLOW_PARTIAL");
            OrderItemLine line = new OrderItemLine();
            line.setGoodsId(goodsId);
            line.setUnitId(unitOf(goodsId));
            line.setUnitRate(BigDecimal.ONE);
            line.setQty(BigDecimal.TEN);
            line.setClientPrice(clientPrice == null ? null : new BigDecimal(clientPrice));
            request.setItems(new ArrayList<>(List.of(line)));
            return request;
        };
        assertThatThrownBy(() -> orders.create(order.apply(zero, "5"))).isInstanceOf(ApiException.class)
                .hasMessageContaining("报价单")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertConflict(() -> orders.create(order.apply(listed, "12")));
        assertThat(orders.create(order.apply(listed, "9")).getId()).isNotNull();
        assertThat(orders.create(order.apply(zero, null)).getId()).as("没有文件单价的 0 价货品照旧").isNotNull();
    }

    @Test
    void legacyApprovedQuotesWithoutFinanceConfirmationAreNeitherFinanceReadableNorConvertible() {
        Fixture f = fixture("legacy");
        UUID listed = goods("旧流程已审报价货品", new BigDecimal("8"));
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(listed, "3", null, null, null)));
        // 旧流程销售自审: 状态 1, 没有提交/财务确认时间(V742 不回填)。
        jdbc.update("""
                UPDATE sales_quotes SET status = 1, submitted_at = NULL, finance_confirmed_at = NULL,
                                        finance_confirmed_by = NULL
                WHERE id = ?
                """, draft.getId());
        QuoteDetail legacy = quotes.detail(draft.getId());
        assertThat(legacy.getAllowedActions()).doesNotContain("convert").contains("reopen");
        assertBusiness(() -> quotes.convertToOrder(draft.getId()));
        assertThat(jdbc.queryForObject("SELECT count(*) FROM sales_orders WHERE source_quote_id = ?", Long.class,
                draft.getId())).isZero();

        // 只持核价查看权限、不是负责人: 看不到这张没经财务的报价。
        loginAs(f.finance());
        assertNotFound(() -> finance.review(draft.getId()));
        assertNotFound(() -> quotes.detail(draft.getId()));

        // 负责人「重新修改」后照常走核价流程。
        loginAs(f.sales());
        QuoteDetail reopened = quotes.reopen(draft.getId(), new QuoteActionRequest(legacy.getReviewRevision()));
        assertThat(reopened.getStatusBucket()).isEqualTo("DRAFT");
    }

    // =====================================================================
    // 看不到价格的人保存
    // =====================================================================

    @Test
    void maskedSellersNeverSetDiscountsButKeepStoredOnesAndDeriveFromTheFilePrice() {
        Fixture f = fixture("masked");
        UUID listed = goods("脱敏报价货品", BigDecimal.TEN);
        UUID usdGoods = goods("脱敏美元货品", new BigDecimal("70"));
        loginAs(f.masked());
        assertThat(currentPermissions()).doesNotContain("sales_order:price:view");

        QuoteSaveRequest request = quoteRequest(f.maskedClient(),
                line(listed, "1", null, null, "8"),    // 按文件单价 8 ÷ 10 推出 0.8
                line(listed, "1", null, null, "1"),    // 0.1 不合理 → 原价 + 备注提示
                line(listed, "1", null, null, null));  // 没有文件单价 → 原价
        QuoteDetail created = quotes.create(request);
        assertThat(created.isPriceMasked()).isTrue();
        assertThat(created.getItems().getFirst().getPrice()).isNull();
        assertThat(created.getItems().getFirst().getClientPrice()).isEqualByComparingTo("8");
        assertThat(storedDiscounts(created.getId())).containsExactly(
                new BigDecimal("0.8000"), new BigDecimal("1.0000"), new BigDecimal("1.0000"));
        assertThat(created.getItems().get(1).getRemark()).contains("换算不出合理折扣");

        // 财务后来改成 0.75(直接写库模拟), 脱敏的负责人再保存: 回传空折扣与空文件单价 → 原值保留。
        jdbc.update("UPDATE sales_quote_items SET discount = 0.75, amount_original = 7.5 WHERE id = ?",
                created.getItems().getFirst().getId());
        QuoteSaveRequest resave = copy(created, request);
        resave.getItems().forEach(item -> {
            item.setDiscount(null);
            item.setClientPrice(null);
        });
        resave.getItems().getFirst().setDiscount(new BigDecimal("1"));
        assertForbidden(() -> quotes.update(created.getId(), resave));
        resave.getItems().getFirst().setDiscount(null);
        quotes.update(created.getId(), resave);
        assertThat(storedDiscounts(created.getId()).getFirst()).isEqualByComparingTo("0.75");
        assertThat(jdbc.queryForObject("SELECT client_price FROM sales_quote_items WHERE id = ?",
                BigDecimal.class, created.getItems().getFirst().getId())).isEqualByComparingTo("8");

        // 订货单: 美元文件, 财务汇率 7 → 9 美元 × 7 ÷ 70 = 0.9。
        ensureUsd("7");
        OrderSaveRequest order = new OrderSaveRequest();
        order.setBillDate(LocalDate.of(2026, 9, 27));
        order.setClientId(f.maskedClient());
        order.setCurrencyId(baseCurrency());
        order.setShipmentPolicy("ALLOW_PARTIAL");
        order.setClientFileCurrency("US$");
        OrderItemLine orderLine = new OrderItemLine();
        orderLine.setGoodsId(usdGoods);
        orderLine.setUnitId(unitOf(usdGoods));
        orderLine.setUnitRate(BigDecimal.ONE);
        orderLine.setQty(BigDecimal.TEN);
        orderLine.setDiscount(new BigDecimal("0.3001"));
        orderLine.setClientPrice(new BigDecimal("9"));
        order.setItems(new ArrayList<>(List.of(orderLine)));
        OrderDetail created2 = orders.create(order);
        assertThat(created2.isPriceMasked()).isTrue();
        assertThat(jdbc.queryForObject("SELECT discount FROM sales_order_items WHERE order_id = ? AND NOT is_deleted",
                BigDecimal.class, created2.getId())).isEqualByComparingTo("0.9");
        assertThat(created2.getClientFileCurrency()).isEqualTo("USD");

        // 脱敏的负责人改订货草稿: 请求折扣被忽略、空文件单价 = 不变 → 既有行保留 0.9 与文件单价 9。
        OrderSaveRequest maskedEdit = orderRequest(created2);
        maskedEdit.getItems().getFirst().setDiscount(BigDecimal.ONE);
        maskedEdit.getItems().getFirst().setClientPrice(null);
        maskedEdit.getItems().getFirst().setQty(new BigDecimal("11"));
        orders.update(created2.getId(), maskedEdit);
        assertThat(jdbc.queryForObject("SELECT discount FROM sales_order_items WHERE order_id = ? AND NOT is_deleted",
                BigDecimal.class, created2.getId())).isEqualByComparingTo("0.9");
        assertThat(jdbc.queryForObject("SELECT client_price FROM sales_order_items WHERE order_id = ? AND NOT is_deleted",
                BigDecimal.class, created2.getId())).isEqualByComparingTo("9");

        // 文件单价精度超出单价界限(解析文件带来的浮点尾数): 保存时 400, 免得核价页之后打不开。
        OrderSaveRequest noisy = orderRequest(orders.detail(created2.getId()));
        noisy.getItems().getFirst().setClientPrice(new BigDecimal("9.1234567890123456789012"));
        assertThatThrownBy(() -> orders.update(created2.getId(), noisy))
                .isInstanceOf(ApiException.class).hasMessageContaining("文件单价")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
        QuoteSaveRequest noisyQuote = quoteRequest(f.maskedClient(),
                line(listed, "1", null, null, "8.00000000001"));
        assertThatThrownBy(() -> quotes.create(noisyQuote))
                .isInstanceOf(ApiException.class).hasMessageContaining("文件单价")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);
    }

    // =====================================================================
    // 确认前阻断 + 核价修改的各种改法
    // =====================================================================

    @Test
    void confirmIsBlockedByUnpricedAndZeroPricedLinesUntilFinancePricesThem() {
        Fixture f = fixture("block");
        UUID listed = goods("阻断标价货品", BigDecimal.TEN);
        UUID noPrice = goods("阻断待定价货品", null);
        UUID zeroWithFile = goods("阻断零价有文件价货品", BigDecimal.ZERO);
        UUID zeroNoFile = goods("阻断零价无文件价货品", BigDecimal.ZERO);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(),
                line(listed, "10", null, "0.95", null),
                line(noPrice, "4", null, null, "3.5"),
                line(zeroWithFile, "2", null, null, "2"),
                line(zeroNoFile, "1", null, null, null)));
        UUID id = draft.getId();
        quotes.submit(id, new QuoteActionRequest(0));

        loginAs(f.finance());
        var claim = claims.claim(CLAIM, id.toString());
        QuoteFinanceReviewDto review = finance.review(id);
        assertThat(review.lines()).extracting(QuoteFinanceReviewDto.Line::blockingReason).containsExactly(
                null, "还没有单价, 请先填写成交单价", "标价为 0, 请填写成交单价或勾选赠品/0价", null);
        assertThatThrownBy(() -> finance.confirm(id, new QuoteFinanceDecisionRequest(1, claim.claimId(), null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("还没有单价")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);
        List<UUID> ids = review.lines().stream().map(QuoteFinanceReviewDto.Line::itemId).toList();

        // 没有单价的行不能直接改折扣(要填成交单价)。
        assertThatThrownBy(() -> finance.edit(id, edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(1), new BigDecimal("0.9"), null, null, null)))))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("还没有单价")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED);

        // 改法一「折扣」: 标价 10 × 0.85; 改法二「成交单价」: 没有标价 → 财务定价 3.5。
        QuoteFinanceReviewDto edited = finance.edit(id, edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(0), new BigDecimal("0.85"), null, null, null),
                new QuoteFinanceEditRequest.Line(ids.get(1), null, new BigDecimal("3.5"), null, null))));
        QuoteFinanceReviewDto.Line discounted = edited.lines().get(0);
        assertThat(discounted.priceSource()).isEqualTo("MASTER");
        assertThat(discounted.discount()).isEqualByComparingTo("0.85");
        assertThat(discounted.dealPrice()).isEqualByComparingTo("8.5");
        assertThat(discounted.amount()).isEqualByComparingTo("85");
        assertThat(edited.lines().get(1).priceSource()).isEqualTo("FINANCE");
        // 标价为 0 而文件有单价的行仍拦着确认。
        assertThatThrownBy(() -> finance.confirm(id, new QuoteFinanceDecisionRequest(2, claim.claimId(), null)))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("标价为 0")
                .extracting(error -> ((ApiException) error).getCode()).isEqualTo(ErrorCode.CONFLICT);

        // 改法三「按最新标价」: 货品资料后来维护了标价 4 → 单价改回货品资料价, 不再是财务定价;
        // 改法四「赠品/0价」: 财务定价 0。
        jdbc.update("UPDATE goods SET price = 4 WHERE id = ?", noPrice);
        QuoteFinanceReviewDto refreshed = finance.edit(id, edit(2, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(1), null, null, null, true),
                new QuoteFinanceEditRequest.Line(ids.get(2), null, null, true, null))));
        QuoteFinanceReviewDto.Line master = refreshed.lines().get(1);
        assertThat(master.listPrice()).isEqualByComparingTo("4");
        assertThat(master.priceSource()).isEqualTo("MASTER");
        assertThat(master.financePriceByName()).isNull();
        assertThat(master.discount()).isEqualByComparingTo("1");
        assertThat(master.amount()).isEqualByComparingTo("16");
        assertThat(refreshed.lines().get(2).priceSource()).isEqualTo("FINANCE");
        assertThat(refreshed.lines().get(2).listPrice()).isEqualByComparingTo("0");
        assertThat(refreshed.blockingLineCount()).isZero();
        // 货品资料没有标价的行不能按标价刷新。
        jdbc.update("UPDATE goods SET price = NULL WHERE id = ?", noPrice);
        assertThatThrownBy(() -> finance.edit(id, edit(3, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(1), null, null, null, true)))))
                .isInstanceOf(ApiException.class).hasMessageContaining("还没有标价");

        QuoteFinanceReviewDto confirmed = finance.confirm(id, new QuoteFinanceDecisionRequest(3, claim.claimId(), null));
        assertThat(confirmed.statusBucket()).isEqualTo("APPROVED");
    }

    // =====================================================================
    // 重新提交的对照高亮
    // =====================================================================

    @Test
    void resubmissionHighlightsCompareWithFinancesLastResultNotWithFinancesOwnLaterEdits() {
        Fixture f = fixture("highlight");
        UUID listed = goods("对照货品", BigDecimal.TEN);
        UUID other = goods("对照其它货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteSaveRequest request = quoteRequest(f.client(),
                line(listed, "10", null, "0.95", null), line(other, "1", null, "1", null));
        UUID id = quotes.create(request).getId();
        quotes.submit(id, new QuoteActionRequest(0));                                   // 1 提交(0.95)

        loginAs(f.finance());
        var first = claims.claim(CLAIM, id.toString());
        List<UUID> ids = finance.review(id).lines().stream().map(QuoteFinanceReviewDto.Line::itemId).toList();
        finance.edit(id, edit(1, first.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(0), new BigDecimal("0.9"), null, null, null))));   // 2
        finance.confirm(id, new QuoteFinanceDecisionRequest(2, first.claimId(), null));                     // 3 确认(0.9)

        // 财务撤销确认后自己再改: 不是「销售改了」, 也没有新的提交可对照。
        finance.reopen(id, new QuoteActionRequest(3, "客户再要一点折扣"));                                   // 4
        var second = claims.claim(CLAIM, id.toString());
        QuoteFinanceReviewDto.Line afterReopen = finance.edit(id, edit(4, second.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(ids.get(0), new BigDecimal("0.85"), null, null, null))))  // 5
                .lines().getFirst();
        assertThat(afterReopen.salesProposedDiscount()).isEqualByComparingTo("0.95");
        assertThat(afterReopen.lastFinanceConfirmedDiscount()).isEqualByComparingTo("0.9");
        assertThat(afterReopen.changedSinceLastConfirm()).isFalse();
        assertThat(afterReopen.lastFinanceDiscount()).isNull();
        assertThat(afterReopen.changedSinceFinance()).isFalse();

        // 财务退回(当时已改成 0.85, 还没确认); 销售把折扣改回 0.95 重新提交 → 标出来。
        finance.returnToSales(id, new QuoteFinanceDecisionRequest(5, second.claimId(), "客户要改数量"));    // 6
        loginAs(f.sales());
        QuoteSaveRequest undo = copy(quotes.detail(id), request);
        undo.getItems().getFirst().setDiscount(new BigDecimal("0.95"));
        quotes.update(id, undo);
        quotes.submit(id, new QuoteActionRequest(7));                                                        // 7
        loginAs(f.finance());
        QuoteFinanceReviewDto resubmitted = finance.review(id);
        QuoteFinanceReviewDto.Line changed = resubmitted.lines().getFirst();
        assertThat(changed.salesProposedDiscount()).isEqualByComparingTo("0.95");
        assertThat(changed.lastFinanceDiscount()).isEqualByComparingTo("0.85");
        assertThat(changed.changedSinceFinance()).isTrue();
        assertThat(changed.lastFinanceConfirmedDiscount()).isEqualByComparingTo("0.9");
        assertThat(changed.changedSinceLastConfirm()).isTrue();
        QuoteFinanceReviewDto.Line untouched = resubmitted.lines().get(1);
        assertThat(untouched.lastFinanceDiscount()).isEqualByComparingTo("1");
        assertThat(untouched.changedSinceFinance()).isFalse();
        assertThat(untouched.changedSinceLastConfirm()).isFalse();

        // 财务改了还没确认, 销售撤回后改回原折扣再提交: 同样标出来(没有确认过, 不算「上次确认」)。
        loginAs(f.sales());
        QuoteSaveRequest secondRequest = quoteRequest(f.client(), line(listed, "2", null, "0.95", null));
        UUID withdrawn = quotes.create(secondRequest).getId();
        quotes.submit(withdrawn, new QuoteActionRequest(0));                                                // 1
        loginAs(f.finance());
        var third = claims.claim(CLAIM, withdrawn.toString());
        UUID line = finance.review(withdrawn).lines().getFirst().itemId();
        finance.edit(withdrawn, edit(1, third.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(line, new BigDecimal("0.9"), null, null, null))));       // 2
        claims.release(CLAIM, withdrawn.toString(), third.claimId());
        loginAs(f.sales());
        quotes.withdraw(withdrawn, new QuoteActionRequest(2));                                              // 3
        QuoteSaveRequest back = copy(quotes.detail(withdrawn), secondRequest);
        back.getItems().getFirst().setDiscount(new BigDecimal("0.95"));
        quotes.update(withdrawn, back);
        quotes.submit(withdrawn, new QuoteActionRequest(4));                                                // 4
        loginAs(f.finance());
        QuoteFinanceReviewDto.Line again = finance.review(withdrawn).lines().getFirst();
        assertThat(again.lastFinanceDiscount()).isEqualByComparingTo("0.9");
        assertThat(again.changedSinceFinance()).isTrue();
        assertThat(again.lastFinanceConfirmedDiscount()).isNull();
        assertThat(again.changedSinceLastConfirm()).isFalse();
    }

    // =====================================================================
    // 报价转入订单: 财务确认列表与审核页同一对照规则; 已审修订仍锁折扣; 转单后不重复学习
    // =====================================================================

    @Test
    void convertedOrderFinanceListAgreesWithTheReviewAndApprovedRevisionsKeepTheLock() {
        Fixture f = fixture("orderlist");
        UUID listed = goods("订单对照货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteSaveRequest request = quoteRequest(f.client(), line(listed, "10", null, "0.95", "9.2"));
        request.getItems().getFirst().setClientModel("GZ23/D");
        QuoteDetail draft = quotes.create(request);
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        UUID quoteLine = finance.review(draft.getId()).lines().getFirst().itemId();
        finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(quoteLine, new BigDecimal("0.92"), null, null, null))));
        finance.confirm(draft.getId(), new QuoteFinanceDecisionRequest(2, claim.claimId(), null));

        // 转单不学习; 转单后第一次保存(只改数量)也不把报价时已学过的文件原文再记一次。
        loginAs(f.sales());
        clearInvocations(learning);
        OrderDetail order = acceptAndConvert(draft.getId());
        assertThat(order.getItems().getFirst().getClientModel()).isEqualTo("GZ23/D");
        loginAs(f.finance());
        assertThat(orderFinance.review(order.getId()).matchesQuote()).as("尚未改量时与客户确认报价一致").isTrue();
        loginAs(f.sales());
        OrderSaveRequest qty = orderRequest(order);
        qty.getItems().getFirst().setQty(new BigDecimal("12"));
        orders.update(order.getId(), qty);
        verify(learning, never()).learnAfterCommit(any());
        // 销售改了文件型号: 这是新的叫法, 照常学习。
        OrderSaveRequest corrected = orderRequest(orders.detail(order.getId()));
        corrected.getItems().getFirst().setClientModel("GZ23/E");
        orders.update(order.getId(), corrected);
        ArgumentCaptor<SalesMasterLearningPort.SalesLearningRequest> learned =
                ArgumentCaptor.forClass(SalesMasterLearningPort.SalesLearningRequest.class);
        verify(learning).learnAfterCommit(learned.capture());
        assertThat(learned.getValue().docType()).isEqualTo("order");
        assertThat(learned.getValue().lines()).extracting(SalesMasterLearningPort.LearnedLine::clientModel)
                .containsExactly("GZ23/E");

        orders.approve(order.getId());
        loginAs(f.finance());
        var listed1 = orderFinance.pending(1, 100, null, null, null, null, null, order.getBillNo()).getItems();
        assertThat(listed1).hasSize(1);
        var source = listed1.getFirst().sourceQuote();
        assertThat(source).isNotNull();
        assertThat(source.id()).isEqualTo(draft.getId());
        assertThat(source.billNo()).isEqualTo(draft.getBillNo());
        assertThat(source.financeConfirmedByName()).isNotBlank();
        assertThat(source.financeConfirmedAt()).isNotNull();
        assertThat(source.allLinesMatch()).as("订货数量由报价 10 改成 12").isFalse();
        assertThat(listed1.getFirst().matchesQuote()).isFalse();
        assertThat(orderFinance.review(order.getId()).sourceQuote().allLinesMatch()).isFalse();
        assertThat(orderFinance.review(order.getId()).matchesQuote()).isFalse();

        // 已审订单修订: 改报价核定行的折扣 409; 再加一行同货品同价同折扣(报价外) → 列表与审核页都「不一致」。
        loginAs(f.sales());
        OrderDetail approved = orders.detail(order.getId());
        OrderSaveRequest lockedChange = orderRequest(approved);
        lockedChange.getItems().getFirst().setDiscount(new BigDecimal("0.8"));
        assertConflict(() -> orders.update(order.getId(), lockedChange));
        OrderSaveRequest extra = orderRequest(orders.detail(order.getId()));
        OrderItemLine sameGoods = new OrderItemLine();
        sameGoods.setGoodsId(listed);
        sameGoods.setUnitId(unitOf(listed));
        sameGoods.setUnitRate(BigDecimal.ONE);
        sameGoods.setQty(BigDecimal.ONE);
        sameGoods.setDiscount(new BigDecimal("0.92"));
        extra.getItems().add(sameGoods);
        OrderDetail revised = orders.update(order.getId(), extra);
        assertThat(revised.getStatus()).isEqualTo((short) 1);
        assertThat(revised.getItems()).extracting(OrderItemDto::isQuoteLocked).containsExactly(true, false);

        loginAs(f.finance());
        var listed2 = orderFinance.pending(1, 100, null, null, null, null, null, order.getBillNo()).getItems();
        assertThat(listed2).hasSize(1);
        assertThat(listed2.getFirst().sourceQuote().allLinesMatch()).isFalse();
        assertThat(listed2.getFirst().matchesQuote()).isFalse();
        var reviewAfter = orderFinance.review(order.getId());
        assertThat(reviewAfter.sourceQuote().allLinesMatch()).isFalse();
        assertThat(reviewAfter.items()).extracting(line -> line.matchesQuote()).containsExactly(false, false);
    }

    @Test
    void ordersFromQuotesFinanceNeverPricedAreNotLocked() {
        Fixture f = fixture("legacy");
        UUID listed = goods("旧流程报价货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail legacy = quotes.create(quoteRequest(f.client(), line(listed, "5", null, "0.9", null)));
        // V742 之前按旧「审核」直接生效的报价: 已审核, 但财务从没核过价。收紧后这种报价不能再转单
        // (见 legacyApprovedQuotesWithoutFinanceConfirmationAreNeitherFinanceReadableNorConvertible),
        // 这里模拟收紧前已经转出来的存量订货单: 直接回链, 验证它仍然不锁折扣、没有「报价核定」对照。
        jdbc.update("UPDATE sales_quotes SET status = 1 WHERE id = ?", legacy.getId());
        OrderSaveRequest request = new OrderSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 28));
        request.setClientId(f.client());
        request.setCurrencyId(baseCurrency());
        request.setShipmentPolicy("ALLOW_PARTIAL");
        OrderItemLine carried = new OrderItemLine();
        carried.setGoodsId(listed);
        carried.setUnitId(unitOf(listed));
        carried.setUnitRate(BigDecimal.ONE);
        carried.setQty(new BigDecimal("5"));
        carried.setDiscount(new BigDecimal("0.9"));
        request.setItems(new ArrayList<>(List.of(carried)));
        OrderDetail created = orders.create(request);
        jdbc.update("UPDATE sales_orders SET source_quote_id = ?, source_doc_no = ? WHERE id = ?",
                legacy.getId(), legacy.getBillNo(), created.getId());
        OrderDetail order = orders.detail(created.getId());
        OrderItemDto first = order.getItems().getFirst();
        assertThat(first.getDiscount()).isEqualByComparingTo("0.9");
        assertThat(first.isQuoteLocked()).isFalse();
        assertThat(first.getQuoteDiscount()).isNull();
        assertThat(order.getSourceQuote().financeConfirmedAt()).isNull();

        OrderSaveRequest edit = orderRequest(order);
        edit.getItems().getFirst().setDiscount(new BigDecimal("0.8"));
        OrderDetail edited = orders.update(order.getId(), edit);
        assertThat(edited.getItems().getFirst().getDiscount()).isEqualByComparingTo("0.8");

        loginAs(f.finance());
        var review = orderFinance.review(order.getId());
        assertThat(review.sourceQuote()).isNull();
        assertThat(review.matchesQuote()).isNull();
        assertThat(review.items().getFirst().matchesQuote()).isNull();
    }

    // =====================================================================
    // 办结撤回(ReviewNoticeCatalog 登记 SALES_QUOTE_PENDING_FINANCE_REVIEW → SALES_QUOTE)
    // =====================================================================

    @Test
    void withdrawReturnAndConfirmResolveEveryReviewersPendingQuoteCard() {
        assertThat(com.uten.imp.features.notice.ReviewNoticeCatalog.isReviewEvent(
                com.uten.imp.features.notice.SalesQuoteNoticeService.EVENT_PENDING_REVIEW)).isTrue();
        Fixture f = fixture("resolve");
        UUID listed = goods("撤卡货品", BigDecimal.TEN);
        loginAs(f.sales());
        UUID id = quotes.create(quoteRequest(f.client(), line(listed, "1", null, null, null))).getId();

        // 提交 → 财务核价人收到行动卡(聚合 = 报价); 销售撤回 → 撤卡。
        quotes.submit(id, new QuoteActionRequest(0));
        assertThat(pendingQuoteCards(id, f.finance())).isEqualTo(1L);
        quotes.withdraw(id, new QuoteActionRequest(1));
        assertThat(pendingQuoteCards(id, null)).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT resolved_reason FROM notices
                WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_id = ? AND audience_user_id = ?
                """, String.class, id, f.finance())).isEqualTo("WITHDRAWN");

        // 再提交 → 新卡; 财务退回 → 撤卡, 发给销售的退回通知不被撤(不在 SALES_QUOTE 聚合下)。
        quotes.submit(id, new QuoteActionRequest(2));
        assertThat(pendingQuoteCards(id, f.finance())).isEqualTo(1L);
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, id.toString());
        finance.returnToSales(id, new QuoteFinanceDecisionRequest(3, claim.claimId(), "客户要改数量"));
        assertThat(pendingQuoteCards(id, null)).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE source_event = 'SALES_QUOTE_FINANCE_RETURNED' AND audience_user_id = ?
                  AND aggregate_id IS NULL AND resolved_at IS NULL
                """, Long.class, f.sales())).isEqualTo(1L);

        // 重新提交 → 新卡; 财务确认 → 撤卡。
        loginAs(f.sales());
        quotes.submit(id, new QuoteActionRequest(4));
        assertThat(pendingQuoteCards(id, f.finance())).isEqualTo(1L);
        loginAs(f.finance());
        var confirmClaim = claims.claim(CLAIM, id.toString());
        finance.confirm(id, new QuoteFinanceDecisionRequest(5, confirmClaim.claimId(), null));
        assertThat(pendingQuoteCards(id, null)).isZero();
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices
                WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_id = ?
                  AND resolved_reason = 'CONFIRMED'
                """, Long.class, id)).isPositive();
    }

    /** 某报价未办结的核价行动卡数(recipient 为空 = 所有收件人)。 */
    private long pendingQuoteCards(UUID quoteId, UUID recipient) {
        return recipient == null
                ? jdbc.queryForObject("""
                        SELECT COUNT(*) FROM notices
                        WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_kind = 'SALES_QUOTE'
                          AND aggregate_id = ? AND resolved_at IS NULL
                        """, Long.class, quoteId)
                : jdbc.queryForObject("""
                        SELECT COUNT(*) FROM notices
                        WHERE source_event = 'SALES_QUOTE_PENDING_FINANCE_REVIEW' AND aggregate_kind = 'SALES_QUOTE'
                          AND aggregate_id = ? AND audience_user_id = ? AND resolved_at IS NULL
                        """, Long.class, quoteId, recipient);
    }

    // =====================================================================
    // 学习出口与识别采用事件
    // =====================================================================

    @Test
    void savingWithCustomerTextCallsTheLearningPortAndAnnouncesTheIntakeJob() {
        Fixture f = fixture("learn");
        UUID listed = goods("学习货品", BigDecimal.TEN);
        UUID plain = goods("学习普通货品", BigDecimal.TEN);
        loginAs(f.sales());
        clearInvocations(learning);

        UUID jobId = UUID.randomUUID();
        QuoteSaveRequest request = quoteRequest(f.client(),
                line(listed, "3", null, "0.9", "9"),
                line(plain, "1", null, null, null));
        QuoteItemLine learned = request.getItems().getFirst();
        learned.setClientModel(" GZ23/D ");
        learned.setClientGoodsName("DOUBLE 3 PIN UNIVERSAL SOCKET WITH SWITCH");
        learned.setIntakeLineKey("S1R9");
        learned.setUserConfirmed(true);
        learned.setSetNameEn(true);
        SalesAiIntakeRequest intake = new SalesAiIntakeRequest();
        intake.setJobId(jobId);
        intake.setClientFields(Map.of("email", "buyer@example.test"));
        request.setAiIntake(intake);
        QuoteDetail created = quotes.create(request);

        ArgumentCaptor<SalesMasterLearningPort.SalesLearningRequest> captor =
                ArgumentCaptor.forClass(SalesMasterLearningPort.SalesLearningRequest.class);
        verify(learning).learnAfterCommit(captor.capture());
        SalesMasterLearningPort.SalesLearningRequest sent = captor.getValue();
        assertThat(sent.docType()).isEqualTo("quote");
        assertThat(sent.docId()).isEqualTo(created.getId());
        assertThat(sent.clientId()).isEqualTo(f.client());
        assertThat(sent.actorUserId()).isEqualTo(f.sales());
        assertThat(sent.intakeJobId()).isEqualTo(jobId);
        assertThat(sent.clientFields()).containsEntry("email", "buyer@example.test");
        assertThat(sent.lines()).hasSize(1);
        assertThat(sent.lines().getFirst().goodsId()).isEqualTo(listed);
        assertThat(sent.lines().getFirst().clientModel()).isEqualTo("GZ23/D");
        assertThat(sent.lines().getFirst().intakeLineKey()).isEqualTo("S1R9");
        assertThat(sent.lines().getFirst().userConfirmed()).isTrue();
        assertThat(sent.lines().getFirst().setNameEn()).isTrue();
        assertThat(sent.learningReceiptId()).isNotNull();
        assertThat(events.stream(SalesIntakeUsedEvent.class))
                .containsExactly(new SalesIntakeUsedEvent(jobId, f.sales(), "quote", created.getId(), f.client(),
                        List.of("S1R9"), sent.learningReceiptId()));

        // 订货单没有文件原文、也没有识别任务: 不打扰学习出口。
        clearInvocations(learning);
        OrderSaveRequest order = new OrderSaveRequest();
        order.setBillDate(LocalDate.of(2026, 9, 27));
        order.setClientId(f.client());
        order.setCurrencyId(baseCurrency());
        order.setShipmentPolicy("ALLOW_PARTIAL");
        OrderItemLine line = new OrderItemLine();
        line.setGoodsId(plain);
        line.setUnitId(unitOf(plain));
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(BigDecimal.ONE);
        order.setItems(new ArrayList<>(List.of(line)));
        orders.create(order);
        verify(learning, never()).learnAfterCommit(any());

        // 订货单带文件品名: 学习(文件型号保存进 client_model, 品名进 client_goods_name)。
        line.setClientGoodsName("Pressure plate");
        orders.create(order);
        verify(learning, atLeastOnce()).learnAfterCommit(any());
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM sales_order_items item JOIN sales_orders o ON o.id = item.order_id
                WHERE o.client_id = ? AND item.client_goods_name = 'Pressure plate'
                """, Long.class, f.client())).isEqualTo(1L);
    }

    // =====================================================================
    // 夹具
    // =====================================================================

    @Test void deletedQuoteRetainsNativeMaskedDetailAndScopedFiltersWithNoActions() {
        Fixture f=fixture("retained-history");loginAs(f.masked());
        UUID goods=goods("历史品名",new BigDecimal("25.00"));
        QuoteDetail draft=quotes.create(quoteRequest(f.maskedClient(),line(goods,"2",null,null,"25")));
        quotes.delete(draft.getId(), draft.getReviewRevision());
        assertNotFound(()->quotes.detail(draft.getId()));
        QuoteDetail history=quotes.detailHistory(draft.getId());
        assertThat(history.isDeleted()).isTrue();
        assertThat(history.isHistoryReadOnly()).isTrue();
        assertThat(history.isWritable()).isFalse();
        assertThat(history.getStatus()).isEqualTo((short)0);
        assertThat(history.isPriceMasked()).isTrue();
        assertThat(history.getTotalLocal()).isNull();
        assertThat(history.getItems()).hasSize(1);
        assertThat(history.getItems().getFirst().getQty()).isEqualByComparingTo("2");
        var filter=new QuoteQueryFilter(null,f.maskedClient(),null,null,null,draft.getBillNo(),null);
        assertThat(quotes.list(filter,1,20,null,null).getItems()).isEmpty();
        var page=quotes.list(filter.withHistory(false,true),1,20,null,null);
        assertThat(page.getItems()).hasSize(1);
        assertThat(page.getItems().getFirst().isDeleted()).isTrue();
        assertThat(page.getItems().getFirst().isWritable()).isFalse();
        assertThat(quotes.facets(filter.withHistory(false,true)).get("billNo")).isNotEmpty();
        loginAs(f.outsider());assertNotFound(()->quotes.detailHistory(draft.getId()));
    }

    @Test
    void customerAcceptanceIsRevisionBoundAndFinanceChangesInvalidateIt() {
        Fixture f = fixture("customer-accept");
        UUID goods = goods("议价货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", "12", "0.8", null)));
        assertConflict(() -> quotes.submit(draft.getId(), null));
        assertConflict(() -> quotes.customerConfirm(draft.getId(), new QuoteActionRequest(0)));
        QuoteDetail submitted = quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        var confirmed = finance.confirm(draft.getId(), new QuoteFinanceDecisionRequest(submitted.getReviewRevision(), claim.claimId(), null));
        loginAs(f.sales());
        assertConflict(() -> quotes.convertToOrder(draft.getId(), new QuoteActionRequest(confirmed.reviewRevision())));
        assertConflict(() -> quotes.customerConfirm(draft.getId(), new QuoteActionRequest(0)));
        QuoteDetail accepted = quotes.customerConfirm(draft.getId(), new QuoteActionRequest(confirmed.reviewRevision()));
        assertThat(accepted.getCustomerAcceptedRevision()).isEqualTo(accepted.getReviewRevision());
        assertThat(accepted.getAllowedActions()).contains("convert").doesNotContain("customerConfirm");
        assertConflict(() -> quotes.convertToOrder(draft.getId(), new QuoteActionRequest(confirmed.reviewRevision())));
        loginAs(f.finance());
        var reopened = finance.reopen(draft.getId(), new QuoteActionRequest(accepted.getReviewRevision()));
        loginAs(f.sales());
        assertThat(quotes.detail(draft.getId()).getCustomerAcceptedAt()).isNull();
        assertBusiness(() -> quotes.convertToOrder(draft.getId(), new QuoteActionRequest(reopened.reviewRevision())));
    }

    @Test
    void financeDealPriceUsesTheSalesBasePriceWithoutResettingItToMaster() {
        Fixture f = fixture("sales-base");
        UUID goods = goods("单据价基准", new BigDecimal("100"));
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", "80", "1", null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        var reviewed = finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(draft.getItems().getFirst().getId(), null, new BigDecimal("72"), null, null))));
        assertThat(reviewed.lines().getFirst().listPrice()).isEqualByComparingTo("80");
        assertThat(reviewed.lines().getFirst().discount()).isEqualByComparingTo("0.9");
        assertThat(reviewed.lines().getFirst().priceSource()).isEqualTo("SALES");
        assertThat(reviewed.lines().getFirst().amount()).isEqualByComparingTo("144");
    }

    @Test
    void financeQuantityPriceDiscountAndDeletionPreserveInspectableSnapshots() {
        Fixture f = fixture("cell-diff");
        UUID first = goods("保留货品", BigDecimal.TEN);
        UUID second = goods("删除货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(first, "2", "12", "0.8", null),
                line(second, "3", "8", "1", null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        var firstId = draft.getItems().getFirst().getId();
        var secondId = draft.getItems().getLast().getId();
        assertCode(() -> finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(firstId, null, null, null, null, BigDecimal.ZERO, null, null)))),
                ErrorCode.VALIDATION_FAILED);
        assertCode(() -> finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(firstId, null, null, null, null, null, null, true),
                new QuoteFinanceEditRequest.Line(secondId, null, null, null, null, null, null, true)))),
                ErrorCode.VALIDATION_FAILED);
        var edited = finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(firstId, new BigDecimal("0.9"), null, null, null,
                        new BigDecimal("5"), new BigDecimal("11"), null),
                new QuoteFinanceEditRequest.Line(secondId, null, null, null, null, null, null, true))));
        assertThat(edited.lines()).hasSize(1);
        assertThat(edited.lines().getFirst().amount()).isEqualByComparingTo("49.5");
        assertThat(edited.revisions().getFirst().snapshot().path("lines")).hasSize(2);
        assertThat(edited.revisions().getLast().snapshot().path("lines")).hasSize(1);
        assertThat(edited.revisions().getFirst().snapshot().path("lines").get(0).path("price").asText()).isEqualTo("12");
        assertThat(edited.revisions().getLast().snapshot().path("lines").get(0).path("price").asText()).isEqualTo("11");
        assertThat(edited.revisions().getLast().snapshot().path("lines").get(0).path("unitName").asText()).isEqualTo("个");
        assertThat(jdbc.queryForObject("SELECT price FROM goods WHERE id=?", BigDecimal.class, first)).isEqualByComparingTo("10");
        assertConflict(() -> finance.edit(draft.getId(), edit(1, claim.claimId(), List.of())));
        finance.returnToSales(draft.getId(), new QuoteFinanceDecisionRequest(2, claim.claimId(), "请确认新方案"));
        loginAs(f.sales());
        AuthUser original = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var permissions = new java.util.HashSet<>(original.getPermissions());
        permissions.remove("sales_order:price:view");
        AuthUser masked = new AuthUser(original.getId(), original.getEmployeeId(), original.getLoginAccount(), permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(masked, null, masked.getAuthorities()));
        var snapshot = quotes.detail(draft.getId()).getRevisions().getFirst().snapshot();
        assertThat(snapshot.has("totalOriginal")).isFalse();
        assertThat(snapshot.path("lines").get(0).has("price")).isFalse();
        assertThat(snapshot.path("lines").get(0).has("discount")).isFalse();
    }

    @Test
    void cancellationRequiresReasonRevisionAndReleasedClaimAndRemainsFinanceReadable() {
        Fixture f = fixture("cancel");
        UUID goods = goods("取消货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", null, null, null)));
        assertCode(() -> quotes.cancel(draft.getId(), new QuoteActionRequest(0, "  ")), ErrorCode.VALIDATION_FAILED);
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        loginAs(f.sales());
        assertConflict(() -> quotes.cancel(draft.getId(), new QuoteActionRequest(0, "客户放弃")));
        assertThatThrownBy(() -> quotes.cancel(draft.getId(), new QuoteActionRequest(1, "客户放弃"))).isInstanceOf(ApiException.class);
        loginAs(f.finance());
        claims.release(CLAIM, draft.getId().toString(), claim.claimId());
        loginAs(f.sales());
        QuoteDetail cancelled = quotes.cancel(draft.getId(), new QuoteActionRequest(1, "客户放弃"));
        assertThat(cancelled.getStatus()).isEqualTo((short) -1);
        assertThat(cancelled.getCancelReason()).isEqualTo("客户放弃");
        assertThat(cancelled.getAllowedActions()).doesNotContain("convert", "submit", "edit", "cancel");
        loginAs(f.finance());
        assertThat(finance.review(draft.getId()).financeActions()).isEmpty();
        assertThat(finance.review(draft.getId()).revisions().getLast().action()).isEqualTo("CANCEL");
    }

    @Test
    void expiredQuotesCannotBeAcceptedAndHistoricalOrdersRequireIndependentRequote() {
        Fixture f = fixture("requote");
        UUID goods = goods("重新议价货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", "12", "0.8", null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        finance.confirm(draft.getId(), new QuoteFinanceDecisionRequest(1, claim.claimId(), null));
        jdbc.update("UPDATE sales_quotes SET valid_until=DATE '2020-01-01' WHERE id=?", draft.getId());
        loginAs(f.sales());
        assertConflict(() -> quotes.customerConfirm(draft.getId(), new QuoteActionRequest(2)));
        jdbc.update("UPDATE sales_quotes SET valid_until=NULL WHERE id=?", draft.getId());
        OrderDetail order = acceptAndConvert(draft.getId());
        QuoteDetail original = quotes.detail(draft.getId());
        assertConflict(() -> quotes.requote(draft.getId(), new QuoteActionRequest(original.getReviewRevision())));
        orders.delete(order.getId());
        assertConflict(() -> quotes.reopen(draft.getId(), new QuoteActionRequest(original.getReviewRevision())));
        QuoteDetail copy = quotes.requote(draft.getId(), new QuoteActionRequest(original.getReviewRevision(), "客户要求重新谈价"));
        assertThat(copy.getId()).isNotEqualTo(draft.getId());
        assertThat(copy.getOriginQuoteId()).isEqualTo(draft.getId());
        assertThat(copy.getCustomerAcceptedAt()).isNull();
        assertThat(copy.getFinanceConfirmedAt()).isNull();
        assertThat(copy.getItems().getFirst().getPrice()).isEqualByComparingTo("12");
        assertThat(quotes.requote(draft.getId(), new QuoteActionRequest(original.getReviewRevision())).getId()).isEqualTo(copy.getId());
        assertThat(quotes.detail(draft.getId()).getItems().getFirst().getPrice()).isEqualByComparingTo("12");
        assertThat(jdbc.queryForObject("SELECT source_quote_id FROM sales_orders WHERE id=?", UUID.class, order.getId())).isEqualTo(draft.getId());
    }

    @Test
    void quotedOrderCannotReuseAcceptedPricesForAnotherCustomer() {
        Fixture f = fixture("quote-client-fence");
        UUID goods = goods("客户绑定报价货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        UUID another = client("OTHER-" + UUID.randomUUID(), employeeOf(f.sales()));
        OrderSaveRequest edit = orderRequest(order);
        edit.setClientId(another);
        assertConflict(() -> orders.update(order.getId(), edit));
        assertThat(orders.detail(order.getId()).getClientId()).isEqualTo(f.client());
    }

    @Test
    void quotedOrderCannotReinterpretAcceptedBasePricesInAnotherCurrency() {
        Fixture f = fixture("quote-currency-fence");
        UUID goods = goods("币种绑定报价货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        ensureUsd("7");
        UUID foreign = jdbc.queryForObject("""
                SELECT id FROM currencies WHERE NOT is_deleted AND NOT is_base_currency AND status='使用'
                  AND name IN ('美元','美金') ORDER BY code LIMIT 1
                """, UUID.class);
        OrderSaveRequest edit = orderRequest(order);
        edit.setCurrencyId(foreign);
        assertConflict(() -> orders.update(order.getId(), edit));
        assertThat(orders.detail(order.getId()).getCurrencyId()).isEqualTo(order.getCurrencyId());
    }

    @Test
    void legacyNullQuoteCurrencyAndOmittedOrderCurrencyKeepTheSameBaseIdentity() {
        Fixture f = fixture("quote-null-currency");
        UUID goods = goods("空币种报价货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        assertThat(quotes.detail(order.getSourceQuoteId()).getCurrencyId()).isNull();
        OrderSaveRequest edit = orderRequest(order);
        edit.setCurrencyId(null);
        edit.getItems().getFirst().setQty(new BigDecimal("3"));
        OrderDetail saved = orders.update(order.getId(), edit);
        assertThat(saved.getCurrencyId()).isEqualTo(baseCurrency());
        assertThat(saved.getItems().getFirst().getPrice()).isEqualByComparingTo("12");
        assertThat(saved.getItems().getFirst().getAmountOriginal()).isEqualByComparingTo("28.8");
    }

    @Test
    void legacyCustomerOrCurrencyMismatchIsNeverReportedAsQuoteAgreement() {
        Fixture f = fixture("quote-legacy-identity");
        UUID goods = goods("历史身份错配货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        orders.update(order.getId(), orderRequest(order));
        orders.approve(order.getId());
        UUID another = client("LEGACY-OTHER-" + UUID.randomUUID(), employeeOf(f.sales()));
        jdbc.update("UPDATE sales_orders SET client_id=? WHERE id=?", another, order.getId());
        loginAs(f.finance());
        assertThat(orderFinance.review(order.getId()).matchesQuote()).isFalse();
        assertThat(orderFinance.pending(1, 20, null, null, null, null, null, order.getBillNo()).getItems())
                .singleElement().satisfies(row -> assertThat(row.matchesQuote()).isFalse());
        ensureUsd("7");
        UUID foreign = jdbc.queryForObject("SELECT id FROM currencies WHERE name='美元' AND NOT is_deleted ORDER BY code LIMIT 1", UUID.class);
        jdbc.update("UPDATE sales_orders SET client_id=?,currency_id=? WHERE id=?", f.client(), foreign, order.getId());
        assertThat(orderFinance.review(order.getId()).matchesQuote()).isFalse();
    }

    @Test
    void canceledRejectedOrderCanRequoteAndNeverRevivesAfterReplacementCancellationOrDeletion() {
        Fixture f = fixture("quote-rejection-requote");
        UUID goods = goods("驳回重议价货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        orders.update(order.getId(), orderRequest(order));
        orders.approve(order.getId());
        loginAs(f.finance());
        var claim = claims.claim("SALES_ORDER_FINANCE_CONFIRM", order.getId().toString());
        orderFinance.reject(order.getId(), new SalesOrderFinanceConfirmService.FinanceRejectRequest(
                "条款需重新议价", 0L, claim.claimId()));
        long before = orderFinance.pendingCount().get("count");
        loginAs(f.sales());
        orders.cancel(order.getId());
        QuoteDetail source = quotes.detail(order.getSourceQuoteId());
        QuoteDetail replacement = quotes.requote(source.getId(), new QuoteActionRequest(source.getReviewRevision(), "客户继续谈价"));
        assertThat(quotes.requote(source.getId(), new QuoteActionRequest(source.getReviewRevision())).getId()).isEqualTo(replacement.getId());
        OrderDetail retired = orders.detail(order.getId());
        assertThat(retired.getRequotedToId()).isEqualTo(replacement.getId());
        assertThat(retired.isWritable()).isFalse();
        assertThat(retired.isHistoryReadOnly()).isTrue();
        assertThat(retired.getReadOnlyReason()).contains("永久");
        quotes.cancel(replacement.getId(), new QuoteActionRequest(replacement.getReviewRevision(), "本轮未谈成"));
        assertThatThrownBy(() -> orders.toggleStopped(order.getId(), false)).hasMessageContaining("永久");
        assertThatThrownBy(() -> orders.update(order.getId(), orderRequest(retired))).hasMessageContaining("永久");
        assertThatThrownBy(() -> orders.approve(order.getId())).hasMessageContaining("永久");
        QuoteDetail next = quotes.requote(source.getId(), new QuoteActionRequest(source.getReviewRevision()));
        assertThat(next.getId()).isNotEqualTo(replacement.getId());
        quotes.delete(next.getId(), next.getReviewRevision());
        assertThatThrownBy(() -> orders.toggleStopped(order.getId(), false)).hasMessageContaining("永久");
        assertThat(orders.detail(order.getId()).getRequotedToId()).as("首次替代事实不能跟着后续草稿覆盖").isEqualTo(replacement.getId());
        loginAs(f.finance());
        assertConflict(() -> claims.claim("SALES_ORDER_FINANCE_CONFIRM", order.getId().toString()));
        assertThatThrownBy(() -> orderFinance.confirm(order.getId(), new SalesOrderFinanceConfirmService.FinanceConfirmRequest(null, 0L)))
                .hasMessageContaining("永久");
        assertThatThrownBy(() -> orderFinance.reject(order.getId(), new SalesOrderFinanceConfirmService.FinanceRejectRequest("再次拒绝", 0L)))
                .hasMessageContaining("永久");
        assertThatThrownBy(() -> orderFinance.confirmBatch(new SalesOrderFinanceConfirmService.FinanceBatchConfirmRequest(List.of(order.getId()), null)))
                .hasMessageContaining("永久");
        assertThat(orderFinance.pending(1, 20, null, null, null, null, null, order.getBillNo()).getItems()).isEmpty();
        assertThat(orderFinance.pendingCount().get("count")).isEqualTo(before);
        assertThat(orderFinance.review(order.getId()).readOnlyReason()).contains("永久");
        assertThat(jdbc.queryForObject("""
                SELECT COUNT(*) FROM notices WHERE aggregate_id=? AND source_event='SALES_ORDER_PENDING_FINANCE_CONFIRM'
                  AND resolved_at IS NULL
                """, Long.class, order.getId())).isZero();
    }

    @Test
    void requoteNormalizesOnlyCopiedRowsAndNeverTouchesOldAcceptedItems() {
        Fixture f = fixture("quote-copy-only");
        UUID goods = goods("历史单位报价货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        orders.delete(order.getId());
        jdbc.update("UPDATE sales_quote_items SET unit_rate=NULL WHERE quote_id=?", order.getSourceQuoteId());
        QuoteDetail source = quotes.detail(order.getSourceQuoteId());
        QuoteDetail replacement = quotes.requote(source.getId(), new QuoteActionRequest(source.getReviewRevision()));
        assertThat(replacement.getItems().getFirst().getUnitRate()).isEqualByComparingTo("1");
        assertThat(jdbc.queryForObject("SELECT unit_rate FROM sales_quote_items WHERE quote_id=?", BigDecimal.class, source.getId())).isNull();
    }

    @Test
    void mixedDeletedAndRequotedOrderPageKeepsThePermanentReadOnlyCapability() {
        Fixture f = fixture("quote-read-only-page");
        UUID goods = goods("历史混合页货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        orders.update(order.getId(), orderRequest(order));
        orders.approve(order.getId());
        orders.cancel(order.getId());
        QuoteDetail original = quotes.detail(order.getSourceQuoteId());
        quotes.requote(original.getId(), new QuoteActionRequest(original.getReviewRevision()));
        OrderDetail disposable = orders.create(orderRequest(order));
        orders.delete(disposable.getId());
        var filter = new com.uten.imp.features.sales.order.dto.OrderQueryFilter(null, f.client(), null, null,
                null, null, null, null).withHistory(true, false);
        var page = orders.list(filter, 1, 50, null, null);
        assertThat(page.getItems()).anyMatch(row -> row.isDeleted());
        assertThat(page.getItems().stream().filter(row -> row.getId().equals(order.getId())).toList())
                .singleElement().satisfies(row -> {
                    assertThat(row.isDeleted()).isFalse();
                    assertThat(row.isHistoryReadOnly()).isTrue();
                    assertThat(row.isWritable()).isFalse();
                    assertThat(row.getReadOnlyReason()).contains("永久");
                });
    }

    @Test
    void concurrentConversionCreatesOneOrderAndOneConversionEvidence() throws Exception {
        Fixture f = fixture("quote-convert-race");
        UUID goods = goods("并发转单货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail source = quotes.create(quoteRequest(f.client(), line(goods, "2", "12", "0.8", null)));
        quotes.submit(source.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, source.getId().toString());
        finance.confirm(source.getId(), new QuoteFinanceDecisionRequest(1, claim.claimId(), null));
        loginAs(f.sales());
        QuoteDetail accepted = quotes.customerConfirm(source.getId(), new QuoteActionRequest(2));
        var results = race(f, () -> { quotes.convertToOrder(source.getId(), new QuoteActionRequest(accepted.getReviewRevision())); return "ORDER"; },
                () -> { quotes.convertToOrder(source.getId(), new QuoteActionRequest(accepted.getReviewRevision())); return "ORDER"; });
        assertThat(results).containsExactlyInAnyOrder("ORDER", "CONFLICT");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sales_orders WHERE source_quote_id=?", Long.class, source.getId())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sales_quote_revision_logs WHERE quote_id=? AND action='CONVERT'", Long.class, source.getId())).isEqualTo(1);
    }

    @Test
    void resumeAndRequoteRaceCannotLeaveBothOldOrderAndReplacementActive() throws Exception {
        Fixture f = fixture("quote-resume-race");
        UUID goods = goods("恢复重报价竞争货品", BigDecimal.TEN);
        OrderDetail order = quotedOrder(f, goods);
        orders.update(order.getId(), orderRequest(order));
        orders.approve(order.getId());
        orders.cancel(order.getId());
        QuoteDetail source = quotes.detail(order.getSourceQuoteId());
        var results = race(f, () -> { quotes.requote(source.getId(), new QuoteActionRequest(source.getReviewRevision())); return "QUOTE"; },
                () -> { orders.toggleStopped(order.getId(), false); return "RESUMED"; });
        assertThat(results).contains("CONFLICT");
        assertThat(results.stream().filter(result -> !result.equals("CONFLICT"))).hasSize(1);
        long replacements = jdbc.queryForObject("SELECT COUNT(*) FROM sales_quotes WHERE origin_quote_id=?", Long.class, source.getId());
        var state = jdbc.queryForMap("SELECT is_stopped,requoted_to_id FROM sales_orders WHERE id=?", order.getId());
        if (results.contains("QUOTE")) {
            assertThat(replacements).isEqualTo(1);
            assertThat(state.get("is_stopped")).isEqualTo(true);
            assertThat(state.get("requoted_to_id")).isNotNull();
        } else {
            assertThat(replacements).isZero();
            assertThat(state.get("is_stopped")).isEqualTo(false);
            assertThat(state.get("requoted_to_id")).isNull();
        }
    }

    private List<String> race(Fixture f, java.util.concurrent.Callable<String> first,
                              java.util.concurrent.Callable<String> second) throws Exception {
        var ready = new java.util.concurrent.CountDownLatch(2);
        var start = new java.util.concurrent.CountDownLatch(1);
        try (var pool = java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var tasks = List.of(first, second).stream().map(action -> pool.submit(() -> {
                loginAs(f.sales());
                ready.countDown();
                if (!start.await(30, java.util.concurrent.TimeUnit.SECONDS)) throw new IllegalStateException("race start timeout");
                try { return action.call(); }
                catch (ApiException conflict) {
                    if (conflict.getCode() != ErrorCode.CONFLICT) throw conflict;
                    return "CONFLICT";
                } finally { SecurityContextHolder.clearContext(); }
            })).toList();
            assertThat(ready.await(30, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
            start.countDown();
            List<String> results = new ArrayList<>();
            for (var task : tasks) results.add(task.get(90, java.util.concurrent.TimeUnit.SECONDS));
            return results;
        }
    }

    @Test
    void financeDealPriceCannotBypassTheSamePrecisionBoundaryAsDirectPrice() {
        Fixture f = fixture("quote-deal-precision");
        UUID goods = goods("成交价精度货品", BigDecimal.TEN);
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", null, null, null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        assertCode(() -> finance.edit(draft.getId(), edit(1, claim.claimId(), List.of(
                new QuoteFinanceEditRequest.Line(draft.getItems().getFirst().getId(), null,
                        new BigDecimal("12.12345678901"), null, null)))), ErrorCode.VALIDATION_FAILED);
        assertThat(finance.review(draft.getId()).reviewRevision()).isEqualTo(1);
        assertThat(finance.review(draft.getId()).lines().getFirst().listPrice()).isEqualByComparingTo("10");
    }

    private OrderDetail quotedOrder(Fixture f, UUID goods) {
        loginAs(f.sales());
        QuoteDetail draft = quotes.create(quoteRequest(f.client(), line(goods, "2", "12", "0.8", null)));
        quotes.submit(draft.getId(), new QuoteActionRequest(0));
        loginAs(f.finance());
        var claim = claims.claim(CLAIM, draft.getId().toString());
        finance.confirm(draft.getId(), new QuoteFinanceDecisionRequest(1, claim.claimId(), null));
        loginAs(f.sales());
        return acceptAndConvert(draft.getId());
    }

    private record Fixture(UUID sales, UUID masked, UUID finance, UUID outsider,
                           UUID client, UUID maskedClient) {
    }

    private Fixture fixture(String tag) {
        baseCurrency();
        String suffix = tag + SEQ.incrementAndGet();
        UUID salesDept = department("QS-" + suffix);
        UUID outsiderDept = department("QO-" + suffix);
        grantDepartment(outsiderDept, "sales_quote_finance:view", "sales_quote_finance:confirm", "sales_quote:view");
        UUID financeDept = jdbc.queryForObject(
                "SELECT id FROM departments WHERE code = 'DEPT_FIN' AND is_deleted = FALSE LIMIT 1", UUID.class);
        List<String> salesPerms = new ArrayList<>(SALES_PERMS);
        salesPerms.add("sales_order:price:view");
        UUID sales = user("qs-" + suffix, salesDept, salesPerms);
        UUID masked = user("qm-" + suffix, salesDept, SALES_PERMS);
        UUID financeUser = user("qf-" + suffix, financeDept, List.of(
                "sales_quote_finance:view", "sales_quote_finance:confirm", "sales_quote:view",
                "sales_order_finance:view", "sales_order_finance:confirm", "sales_order:view", "notice:read"));
        UUID outsider = user("qx-" + suffix, outsiderDept, List.of("notice:read"));
        return new Fixture(sales, masked, financeUser, outsider,
                client("QC-" + suffix, employeeOf(sales)), client("QM-" + suffix, employeeOf(masked)));
    }

    private UUID department(String code) {
        UUID id = UUID.randomUUID();
        jdbc.update("insert into departments(id, code, name, level) values (?, ?, ?, '一级部门')",
                id, code, "报价核价测试部门-" + code);
        return id;
    }

    private void grantDepartment(UUID departmentId, String... codes) {
        for (String code : codes) {
            jdbc.update("""
                    insert into department_permissions(department_id, permission_id)
                    select ?, p.id from permissions p where p.code = ?
                    """, departmentId, code);
        }
    }

    private UUID user(String login, UUID departmentId, List<String> perms) {
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        jdbc.update("""
                insert into employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                values (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "EMP-" + login, "员工-" + login, departmentId);
        jdbc.update("""
                insert into users(id, employee_id, login_account, password_hash, must_change_password, is_super_admin, status)
                values (?, ?, ?, 'x', false, false, 'active')
                """, user, employee, login);
        for (String code : perms) {
            int granted = jdbc.update("""
                    insert into user_permission_overrides(user_id, permission_id, effect)
                    select ?, p.id, 'grant' from permissions p where p.code = ?
                    """, user, code);
            assertThat(granted).as("permission %s exists", code).isEqualTo(1);
        }
        return user;
    }

    private UUID client(String code, UUID ownerEmployee) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into clients(id, code, name, status, code_sequence, owner_employee_id)
                values (?, ?, ?, '使用', (select coalesce(max(code_sequence), 0) + 1 from clients), ?)
                """, id, code, "报价核价测试客户-" + code, ownerEmployee);
        return id;
    }

    private UUID goods(String name, BigDecimal price) {
        UUID unit = UUID.randomUUID();
        String tag = UUID.randomUUID().toString().substring(0, 8);
        jdbc.update("insert into units(id, code, name, status) values (?, ?, '个', '使用')", unit, "U-Q-" + tag);
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into goods(id, code, name, source_type, status, unit_id, price, code_sequence)
                values (?, ?, ?, '自制', '使用', ?, ?, (select coalesce(max(code_sequence), 0) + 1 from goods))
                """, id, "G-Q-" + tag, name + "-" + tag, unit, price);
        return id;
    }

    private UUID unitOf(UUID goods) {
        return jdbc.queryForObject("SELECT unit_id FROM goods WHERE id = ?", UUID.class, goods);
    }

    private UUID employeeOf(UUID user) {
        return jdbc.queryForObject("SELECT employee_id FROM users WHERE id = ?", UUID.class, user);
    }

    private UUID baseCurrency() {
        List<UUID> base = jdbc.queryForList("""
                SELECT id FROM currencies WHERE is_base_currency AND status = '使用' AND NOT is_deleted
                """, UUID.class);
        if (!base.isEmpty()) return base.getFirst();
        UUID id = UUID.randomUUID();
        jdbc.update("""
                insert into currencies(id, code, name, exchange_rate, status, is_base_currency)
                values (?, 'CNY-QT', '人民币', 1, '使用', TRUE)
                """, id);
        return id;
    }

    /** 美元币种资料(任何写法: 美元/美金/USD)一律设成给定的财务参考汇率; 没有就新建一条。 */
    private void ensureUsd(String rate) {
        baseCurrency();
        int updated = jdbc.update("""
                UPDATE currencies SET exchange_rate = ?, status = '使用'
                WHERE NOT is_deleted AND NOT is_base_currency
                  AND (name IN ('美元', '美金') OR upper(code) IN ('USD', 'US$'))
                """, new BigDecimal(rate));
        if (updated == 0) {
            jdbc.update("""
                    insert into currencies(id, code, name, exchange_rate, status)
                    values (?, 'USD-QT', '美元', ?, '使用')
                    """, UUID.randomUUID(), new BigDecimal(rate));
        }
    }

    private List<BigDecimal> storedDiscounts(UUID quoteId) {
        return jdbc.queryForList(
                "SELECT discount FROM sales_quote_items WHERE quote_id = ? ORDER BY line_no", BigDecimal.class, quoteId);
    }

    private long pendingQuoteReviews(Fixture f) {
        UUID previous = currentUserId();
        loginAs(f.finance());
        long count = finance.pendingCount().get("pending");
        if (previous != null) loginAs(previous);
        return count;
    }

    private void loginAs(UUID userId) {
        Map<String, Object> u = jdbc.queryForMap(
                "SELECT employee_id, login_account, is_super_admin FROM users WHERE id = ?", userId);
        UUID employeeId = (UUID) u.get("employee_id");
        boolean superAdmin = Boolean.TRUE.equals(u.get("is_super_admin"));
        PermissionResolver.AuthorizationSnapshot snapshot =
                permissionResolver.authorizationSnapshot(userId, employeeId, superAdmin);
        AuthUser authUser = new AuthUser(userId, employeeId, (String) u.get("login_account"),
                snapshot.permissions(), false, true, superAdmin);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(authUser, null, authUser.getAuthorities()));
    }

    private UUID currentUserId() {
        var auth = SecurityContextHolder.getContext().getAuthentication();
        return auth != null && auth.getPrincipal() instanceof AuthUser user ? user.getId() : null;
    }

    private java.util.Set<String> currentPermissions() {
        return ((AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getPermissions();
    }

    private static QuoteSaveRequest quoteRequest(UUID clientId, QuoteItemLine... lines) {
        QuoteSaveRequest request = new QuoteSaveRequest();
        request.setBillDate(LocalDate.of(2026, 9, 27));
        request.setClientId(clientId);
        request.setItems(new ArrayList<>(List.of(lines)));
        return request;
    }

    private QuoteItemLine line(UUID goods, String qty, String previewPrice, String discount, String clientPrice) {
        QuoteItemLine line = new QuoteItemLine();
        line.setGoodsId(goods);
        line.setUnitId(unitOf(goods));
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setPrice(previewPrice == null ? null : new BigDecimal(previewPrice));
        line.setDiscount(discount == null ? null : new BigDecimal(discount));
        line.setClientPrice(clientPrice == null ? null : new BigDecimal(clientPrice));
        return line;
    }

    /** 按已保存详情重建保存请求(带行 id, 价格留空), 表头沿用原请求。 */
    private static QuoteSaveRequest copy(QuoteDetail detail, QuoteSaveRequest header) {
        QuoteSaveRequest request = new QuoteSaveRequest();
        request.setExpectedRevision(detail.getReviewRevision());
        request.setBillDate(header.getBillDate());
        request.setClientId(header.getClientId());
        request.setContractNo(header.getContractNo());
        request.setClientFileCurrency(header.getClientFileCurrency());
        request.setSellerId(header.getSellerId());
        request.setDeliverDate(header.getDeliverDate());
        List<QuoteItemLine> lines = new ArrayList<>();
        for (QuoteItemDto item : detail.getItems()) {
            QuoteItemLine line = new QuoteItemLine();
            line.setId(item.getId());
            line.setGoodsId(item.getGoodsId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setDiscount(item.getDiscount());
            line.setClientPrice(item.getClientPrice());
            line.setRemark(item.getRemark());
            lines.add(line);
        }
        request.setItems(lines);
        return request;
    }

    private OrderDetail acceptAndConvert(UUID id) {
        QuoteDetail current = quotes.detail(id);
        QuoteDetail accepted = quotes.customerConfirm(id, new QuoteActionRequest(current.getReviewRevision()));
        return quotes.convertToOrder(id, new QuoteActionRequest(accepted.getReviewRevision()));
    }

    private static OrderSaveRequest orderRequest(OrderDetail order) {
        OrderSaveRequest request = new OrderSaveRequest();
        request.setBillDate(order.getBillDate());
        request.setClientId(order.getClientId());
        request.setCurrencyId(order.getCurrencyId());
        request.setSellerId(order.getSellerId());
        request.setDeliverDate(order.getDeliverDate());
        request.setContractNo(order.getContractNo());
        request.setClientFileCurrency(order.getClientFileCurrency());
        request.setShipmentPolicy("ALLOW_PARTIAL");
        List<OrderItemLine> lines = new ArrayList<>();
        for (OrderItemDto item : order.getItems()) {
            OrderItemLine line = new OrderItemLine();
            line.setId(item.getId());
            line.setGoodsId(item.getGoodsId());
            line.setUnitId(item.getUnitId());
            line.setUnitRate(item.getUnitRate());
            line.setQty(item.getQty());
            line.setDiscount(item.getDiscount());
            line.setClientPrice(item.getClientPrice());
            line.setClientModel(item.getClientModel());
            line.setClientGoodsName(item.getClientGoodsName());
            lines.add(line);
        }
        request.setItems(lines);
        return request;
    }

    private static QuoteFinanceEditRequest edit(int revision, UUID claimId, List<QuoteFinanceEditRequest.Line> lines) {
        return new QuoteFinanceEditRequest(revision, claimId, null, null, null, lines);
    }

    private static void assertConflict(Runnable action) {
        assertCode(action, ErrorCode.CONFLICT);
    }

    private static void assertForbidden(Runnable action) {
        assertCode(action, ErrorCode.FORBIDDEN);
    }

    private static void assertNotFound(Runnable action) {
        assertCode(action, ErrorCode.NOT_FOUND);
    }

    private static void assertBusiness(Runnable action) {
        assertCode(action, ErrorCode.BUSINESS);
    }

    private static void assertCode(Runnable action, ErrorCode code) {
        assertThatThrownBy(action::run)
                .isInstanceOf(ApiException.class)
                .extracting(error -> ((ApiException) error).getCode())
                .isEqualTo(code);
    }

}
