package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.SalesQuoteFinanceReviewerEligibilityPort;
import com.uten.imp.application.port.SalesQuoteNoticePort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesPriceAuthority;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceDecisionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceEditRequest;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceListItem;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceReviewDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * 销售报价财务核价(ADR-134)。
 *
 * <p>核价人 = {@link SalesQuoteFinanceReviewerEligibilityPort}(财务部门树 + 查看/核价权限 + 在职); 改折扣/
 * 成交单价、退回、确认都要先认领({@code SALES_QUOTE_FINANCE_REVIEW}), 并带页面看到的核价修订号。
 * 核价可以改的只有: 各行折扣或成交单价(货品没有标价或成交单价高于标价时由财务定价)、赠品/0 价、按最新标价刷新,
 * 以及基价、数量、整行删除和表头有效期、结账方式、财务备注；新增货品退回销售处理。确认时不允许还有没定价的行。
 * 金额口径与报价单一致(数量 × 单价 × 折扣, 只在 {@link MoneyPolicy} 取位)。
 */
@Service
@RequiredArgsConstructor
public class SalesQuoteFinanceService {

    private static final String FINANCE_VIEW = SalesQuoteService.FINANCE_VIEW;
    private static final String FINANCE_CONFIRM = SalesQuoteService.FINANCE_CONFIRM;
    private static final String TARGET = SalesQuoteFinanceClaimTargetLocks.TARGET_TYPE;
    private static final int MAX_PAGE_SIZE = 100;

    private final EntityManager em;
    private com.uten.imp.common.columns.BusinessColumnService businessColumns;

    @org.springframework.beans.factory.annotation.Autowired
    public void setBusinessColumns(com.uten.imp.common.columns.BusinessColumnService service) { this.businessColumns = service; }
    private final SalesQuoteRepository quoteRepo;
    private final SalesQuoteItemRepository itemRepo;
    private final SalesQuoteService quotes;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final SalesQuoteFinanceReviewerEligibilityPort reviewers;
    private final TaskClaimMutationGuardPort claimGuard;
    private final TaskClaimService claimViews;
    private final SalesQuoteRevisionLog revisionLog;
    private final SalesQuoteNoticePort notices;
    private final SalesPriceAuthority priceAuthority;
    private final SalesDocumentAccessPolicy accessPolicy;

    // ------------------------------------------------------------------ 列表与计数

    /** 核价列表: state = pending 待核价(默认) / confirmed 已核价 / returned 已退回。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public PageResponse<QuoteFinanceListItem> list(String state, String keyword, int page, int size) {
        String normalizedState = state == null || state.isBlank() ? "pending" : state.trim().toLowerCase(Locale.ROOT);
        String statePredicate = switch (normalizedState) {
            case "pending" -> "o.status = 2";
            case "confirmed" -> "o.status = 1 AND o.finance_confirmed_at IS NOT NULL";
            case "returned" -> "o.status = 0 AND o.finance_returned_at IS NOT NULL"
                    + " AND o.submitted_at IS NOT NULL AND o.finance_returned_at >= o.submitted_at";
            case "cancelled" -> "o.status = -1 AND o.submitted_at IS NOT NULL";
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "核价列表分类无效: " + state);
        };
        String orderBy = switch (normalizedState) {
            case "confirmed" -> " ORDER BY o.finance_confirmed_at DESC, o.bill_no";
            case "returned" -> " ORDER BY o.finance_returned_at DESC, o.bill_no";
            default -> " ORDER BY o.submitted_at NULLS LAST, o.bill_no";
        };
        String normalizedKeyword = keyword == null ? "" : keyword.trim().toLowerCase(Locale.ROOT);
        String keywordFilter = normalizedKeyword.isEmpty() ? "" : """
                  AND (POSITION(:keyword IN LOWER(COALESCE(o.bill_no, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(c.name, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(seller.full_name, ''))) > 0
                    OR POSITION(:keyword IN LOWER(COALESCE(maker.full_name, ''))) > 0)
                """;
        String from = """
                FROM sales_quotes o
                LEFT JOIN clients c ON c.id = o.client_id
                LEFT JOIN employees seller ON seller.id = o.seller_id
                LEFT JOIN employees maker ON maker.id = o.maker_id
                LEFT JOIN employees confirmer ON confirmer.id = o.finance_confirmed_by
                WHERE o.is_deleted = FALSE AND""" + " " + statePredicate + "\n" + keywordFilter;
        int p = Math.max(1, page);
        int sz = Math.min(Math.max(1, size), MAX_PAGE_SIZE);
        var countQuery = em.createNativeQuery("SELECT COUNT(*) " + from);
        if (!normalizedKeyword.isEmpty()) countQuery.setParameter("keyword", normalizedKeyword);
        long total = ((Number) countQuery.getSingleResult()).longValue();
        int totalPages = total == 0 ? 0 : (int) ((total + sz - 1) / sz);
        if (totalPages > 0 && p > totalPages) p = totalPages;
        var rowsQuery = em.createNativeQuery("""
                SELECT o.id, o.bill_no, o.bill_date, COALESCE(c.name, ''),
                       COALESCE(seller.full_name, maker.full_name, ''), COALESCE(maker.full_name, ''),
                       o.submitted_at,
                       (SELECT COUNT(*) FROM sales_quote_items i WHERE i.quote_id = o.id),
                       (SELECT COUNT(*) FROM sales_quote_items i WHERE i.quote_id = o.id AND i.price IS NULL),
                       o.total_original, o.client_file_currency, o.status, o.finance_return_reason,
                       o.review_revision,
                       (SELECT COUNT(*) FROM sales_quote_revision_logs l
                        WHERE l.quote_id = o.id AND l.action = 'SUBMIT') > 1,
                       o.finance_returned_at, o.finance_confirmed_at, COALESCE(confirmer.full_name, ''),
                       (SELECT so.bill_no FROM sales_orders so
                        WHERE so.source_quote_id = o.id AND so.is_deleted = FALSE LIMIT 1)
                """ + from + orderBy + " LIMIT :lim OFFSET :off");
        if (!normalizedKeyword.isEmpty()) rowsQuery.setParameter("keyword", normalizedKeyword);
        rowsQuery.setParameter("lim", sz);
        rowsQuery.setParameter("off", (p - 1) * sz);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = rowsQuery.getResultList();
        Map<String, TaskClaimService.TaskClaimView> claims = claimViews.activeClaimViewsByTargetKey(TARGET);
        List<QuoteFinanceListItem> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            UUID id = (UUID) r[0];
            short status = ((Number) r[11]).shortValue();
            String reason = (String) r[12];
            TaskClaimService.TaskClaimView claim = claims.get(id.toString());
            items.add(new QuoteFinanceListItem(
                    id, (String) r[1], NativeValueConverters.toLocalDate(r[2]),
                    (String) r[3], (String) r[4], (String) r[5],
                    NativeValueConverters.toOffsetDateTime(r[6]),
                    ((Number) r[7]).longValue(), ((Number) r[8]).longValue(),
                    (BigDecimal) r[9], (String) r[10],
                    bucketOf(status, reason), ((Number) r[13]).intValue(),
                    Boolean.TRUE.equals(r[14]), reason,
                    NativeValueConverters.toOffsetDateTime(r[15]),
                    NativeValueConverters.toOffsetDateTime(r[16]),
                    blankToNull((String) r[17]), (String) r[18],
                    claim == null ? null : claim.claimedByName(),
                    claim != null && claim.claimedByMe()));
        }
        return new PageResponse<>(items, p, sz, total, totalPages);
    }

    /**
     * 工作台徽章「报价待核价」(红 = 轮到我): 待核价张数; 只算合格核价人(与认领、通知同一资格口径:
     * 财务部门树或个人加授 + 查看/核价权限 + 账号启用), 只看不办或不在核价组的人固定 0, 不查报价表。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public Map<String, Long> pendingCount() {
        if (!accessPolicy.hasAuthority(FINANCE_CONFIRM)
                || !reviewers.isEligible(currentUser.get().map(AuthUser::getId).orElse(null))) {
            return Map.of("pending", 0L);
        }
        Number n = (Number) em.createNativeQuery(
                "SELECT COUNT(*) FROM sales_quotes o WHERE o.is_deleted = FALSE AND o.status = 2")
                .getSingleResult();
        return Map.of("pending", n.longValue());
    }

    // ------------------------------------------------------------------ 核价详情

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote_finance:view')")
    public QuoteFinanceReviewDto review(UUID id) {
        SalesQuote q = quoteRepo.findById(id)
                .filter(SalesQuoteService::financeVisible)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"));
        return reviewOf(q);
    }

    private QuoteFinanceReviewDto reviewOf(SalesQuote q) {
        UUID id = q.getId();
        Object[] h = (Object[]) em.createNativeQuery("""
                        SELECT COALESCE(c.name, ''), COALESCE(c.code, ''),
                               COALESCE(maker.full_name, ''), COALESCE(seller.full_name, ''),
                               COALESCE(cur.name, base.name, ''), COALESCE(cur.is_base_currency, TRUE),
                               COALESCE(sm.name, ''),
                               COALESCE(submitter.full_name, ''), COALESCE(returner.full_name, ''),
                               COALESCE(confirmer.full_name, '')
                        FROM sales_quotes o
                        LEFT JOIN clients c ON c.id = o.client_id
                        LEFT JOIN employees maker ON maker.id = o.maker_id
                        LEFT JOIN employees seller ON seller.id = o.seller_id
                        LEFT JOIN currencies cur ON cur.id = o.currency_id
                        LEFT JOIN currencies base ON base.is_base_currency AND base.is_deleted = FALSE
                        LEFT JOIN settlement_methods sm ON sm.id = o.settlement_method_id
                        LEFT JOIN employees submitter ON submitter.id = o.submitted_by
                        LEFT JOIN employees returner ON returner.id = o.finance_returned_by
                        LEFT JOIN employees confirmer ON confirmer.id = o.finance_confirmed_by
                        WHERE o.id = :id
                        """)
                .setParameter("id", id)
                .getSingleResult();
        @SuppressWarnings("unchecked")
        List<Object[]> lineRows = em.createNativeQuery("""
                        SELECT i.id, i.line_no, i.goods_id,
                               COALESCE(i.goods_code_snapshot, g.code, ''),
                               COALESCE(i.goods_name_snapshot, g.name, ''),
                               COALESCE(col.name, ''), COALESCE(u.name, ''),
                               i.qty, i.price, i.price_source, COALESCE(fp.full_name, ''), i.finance_price_at,
                               CASE WHEN g.status = '使用' AND NOT COALESCE(g.is_deleted, FALSE) THEN g.price END,
                               i.client_price, i.discount, i.amount_original,
                               i.client_model, i.client_goods_name, i.remark, i.unit_id, CAST(i.extra_columns AS text),
                               i.goods_name_en_snapshot
                        FROM sales_quote_items i
                        LEFT JOIN goods g ON g.id = i.goods_id
                        LEFT JOIN colors col ON col.id = i.color_id
                        LEFT JOIN units u ON u.id = i.unit_id
                        LEFT JOIN employees fp ON fp.id = i.finance_price_by
                        WHERE i.quote_id = :id
                        ORDER BY i.line_no NULLS LAST, i.id
                        """)
                .setParameter("id", id)
                .getResultList();
        SalesPriceAuthority.FileCurrency fileCurrency = priceAuthority.resolveFileCurrency(q.getClientFileCurrency());
        BigDecimal rate = fileCurrency.base() ? BigDecimal.ONE : fileCurrency.financeRate();
        boolean rateMissing = !fileCurrency.base() && (rate == null || rate.signum() <= 0);
        // 对照口径: 「销售提交的折扣」取最近一次提交; 只有在上次财务确认(或上次财务核价/退回)之后又提交过,
        // 才把提交与财务定的折扣不同的行标出来(财务撤销确认后自己改的折扣不算销售改的)。
        SalesQuoteRevisionLog.DiscountSnapshot submitted =
                revisionLog.latestSnapshot(id, List.of(SalesQuoteRevisionLog.SUBMIT), null);
        SalesQuoteRevisionLog.DiscountSnapshot confirmed =
                revisionLog.latestSnapshot(id, List.of(SalesQuoteRevisionLog.CONFIRM), null);
        boolean resubmittedAfterConfirm = submitted != null && confirmed != null
                && submitted.revision() > confirmed.revision();
        SalesQuoteRevisionLog.DiscountSnapshot financeBeforeSubmit = submitted == null ? null
                : revisionLog.latestSnapshot(id, SalesQuoteRevisionLog.FINANCE_ACTIONS, submitted.revision());
        List<QuoteFinanceReviewDto.Line> lines = new ArrayList<>(lineRows.size());
        int pricePending = 0;
        int blocking = 0;
        BigDecimal fileTotal = BigDecimal.ZERO;
        boolean fileTotalComplete = true;
        for (Object[] r : lineRows) {
            UUID itemId = (UUID) r[0];
            BigDecimal qty = (BigDecimal) r[7];
            BigDecimal price = (BigDecimal) r[8];
            String priceSource = (String) r[9];
            BigDecimal clientPrice = (BigDecimal) r[13];
            BigDecimal discount = (BigDecimal) r[14];
            BigDecimal amount = (BigDecimal) r[15];
            BigDecimal clientLocal = clientPrice == null || rateMissing ? null
                    : fileCurrency.base() ? clientPrice : MoneyPolicy.local(clientPrice, rate);
            BigDecimal fileAmount = clientLocal == null || qty == null ? null
                    : MoneyPolicy.exactProduct(qty, clientLocal);
            if (fileAmount == null) fileTotalComplete = false;
            else fileTotal = fileTotal.add(fileAmount);
            BigDecimal dealPrice = price == null ? null : MoneyPolicy.exactProduct(BigDecimal.ONE, price, discount);
            BigDecimal proposed = submitted == null ? null : submitted.discountOf(itemId);
            BigDecimal lastConfirmed = confirmed == null ? null : confirmed.discountOf(itemId);
            BigDecimal lastFinance = financeBeforeSubmit == null ? null : financeBeforeSubmit.discountOf(itemId);
            String blockingReason = blockingReason(price, priceSource, clientPrice);
            if (price == null) pricePending++;
            if (blockingReason != null) blocking++;
            lines.add(new QuoteFinanceReviewDto.Line(
                    itemId,
                    r[1] == null ? null : ((Number) r[1]).intValue(),
                    (UUID) r[2], (String) r[3], (String) r[4], (String) r[5], (UUID) r[19], (String) r[6],
                    qty, price, priceSource,
                    blankToNull((String) r[10]), NativeValueConverters.toOffsetDateTime(r[11]),
                    (BigDecimal) r[12], clientPrice, clientLocal, dealPrice, discount, amount,
                    fileAmount,
                    amount == null || fileAmount == null ? null : MoneyPolicy.canonical(amount.subtract(fileAmount)),
                    proposed, lastConfirmed,
                    resubmittedAfterConfirm && differs(proposed, lastConfirmed),
                    lastFinance,
                    differs(proposed, lastFinance),
                    (String) r[16], (String) r[17], (String) r[18],
                    blockingReason, r.length > 20 ? businessColumns.parse(r[20]) : List.of(),
                    r.length > 21 ? (String) r[21] : null));
        }
        String convertedOrderNo = quotes.convertedOrders(List.of(id)).values().stream()
                .map(SalesQuoteService.ConvertedOrder::billNo).findFirst().orElse(null);
        return new QuoteFinanceReviewDto(
                id, q.getBillNo(), q.getBillDate(), q.getClientId(),
                (String) h[0], (String) h[1], (String) h[2], blankToNull((String) h[3]),
                (String) h[4], Boolean.TRUE.equals(h[5]),
                q.getSettlementMethodId(), blankToNull((String) h[6]),
                q.getValidUntil(), q.getDeliverDate(), q.getContractNo(), q.getRemark(),
                q.getClientFileCurrency(), fileCurrency.base() ? null : rate, rateMissing,
                q.getStatus(), SalesQuoteService.statusBucket(q), q.getReviewRevision(),
                q.getSubmittedAt(), blankToNull((String) h[7]),
                q.getFinanceRemark(), q.getFinanceReturnReason(), q.getFinanceReturnedAt(),
                blankToNull((String) h[8]), q.getFinanceConfirmedAt(), blankToNull((String) h[9]),
                q.getTotalOriginal(),
                fileTotalComplete && !lines.isEmpty() ? MoneyPolicy.canonical(fileTotal) : null,
                pricePending, blocking,
                confirmed != null || revisionLog.hasAction(id, SalesQuoteRevisionLog.RETURN),
                convertedOrderNo,
                accessPolicy.hasAuthority("goods:price:edit"),
                financeActions(q, convertedOrderNo != null),
                TARGET,
                lines,
                revisionLog.history(id));
    }

    private List<String> financeActions(SalesQuote q, boolean converted) {
        if (!accessPolicy.hasAuthority(FINANCE_CONFIRM) || !reviewers.isEligible(currentUser.requireId())) {
            return List.of();
        }
        short status = q.getStatus() == null ? SalesQuoteService.STATUS_DRAFT : q.getStatus();
        if (status == SalesQuoteService.STATUS_PENDING_FINANCE) return List.of("edit", "return", "confirm");
        if (status == SalesQuoteService.STATUS_CONFIRMED && !converted) return List.of("reopen");
        return List.of();
    }

    // ------------------------------------------------------------------ 核价动作

    /** 财务核价修改(折扣/成交单价/赠品/按最新标价刷新 + 表头有效期、结账方式、财务备注)。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto edit(UUID id, QuoteFinanceEditRequest req) {
        tx.bind();
        requireEligibleReviewer();
        SalesQuote q = lockForDecision(id);
        requirePendingFinance(q);
        SalesQuoteService.requireRevision(q, req.expectedRevision());
        claimGuard.requireActiveClaimByMe(TARGET, id.toString(), req.expectedClaimId());
        UUID actor = currentUser.requireEmployeeId();
        OffsetDateTime now = OffsetDateTime.now();
        if (req.settlementMethodId() != null) {
            com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.settlementMethodId(), null, "结帐方式");
        }
        q.setValidUntil(req.validUntil());
        q.setSettlementMethodId(req.settlementMethodId());
        q.setFinanceRemark(blankToNull(req.financeRemark()));

        List<SalesQuoteItem> items = new ArrayList<>(itemRepo.findByQuoteIdOrderByLineNoAsc(id));
        Map<UUID, SalesQuoteItem> byId = new HashMap<>();
        items.forEach(item -> byId.put(item.getId(), item));
        List<QuoteFinanceEditRequest.Line> edits = req.lines() == null ? List.of() : req.lines();
        java.util.Set<UUID> seen = new java.util.HashSet<>();
        List<UUID> needMaster = new ArrayList<>();
        for (QuoteFinanceEditRequest.Line edit : edits) {
            SalesQuoteItem item = byId.get(edit.itemId());
            if (item == null) {
                throw new ApiException(ErrorCode.CONFLICT, "报价明细已变化, 请刷新后再核价");
            }
            if (!seen.add(edit.itemId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一行不能重复修改");
            }
            int actions = (edit.discount() != null ? 1 : 0) + (edit.dealPrice() != null ? 1 : 0)
                    + (Boolean.TRUE.equals(edit.giftZeroPrice()) ? 1 : 0)
                    + (Boolean.TRUE.equals(edit.useMasterPrice()) ? 1 : 0);
            boolean removed = Boolean.TRUE.equals(edit.removed());
            if (removed && (actions > 0 || edit.qty() != null || edit.price() != null)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "删除整行不能同时修改该行金额或数量");
            }
            if (!removed && ((edit.price() != null && (edit.dealPrice() != null
                    || Boolean.TRUE.equals(edit.giftZeroPrice()) || Boolean.TRUE.equals(edit.useMasterPrice())))
                    || actions > 1 || (actions == 0 && edit.price() == null && edit.qty() == null))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "不能混用成交价、赠品和标价刷新；直接填写单价可同时修改折扣和数量");
            }
            if (edit.qty() != null) {
                com.uten.imp.common.util.FinancialExactAmount.quantity(edit.qty(), "核价数量");
                if (edit.qty().signum() <= 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, "核价数量必须大于 0");
            }
            if (edit.price() != null) {
                SalesPriceAuthority.requireClientPrice(edit.price(), "核价单价");
            }
            if (edit.dealPrice() != null || Boolean.TRUE.equals(edit.useMasterPrice())
                    || item.getPrice() == null) {
                needMaster.add(item.getGoodsId());
            }
        }
        if (edits.stream().filter(edit -> Boolean.TRUE.equals(edit.removed())).count() >= items.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报价至少保留一行货品；无法承接请退回销售取消报价");
        }
        Map<UUID, BigDecimal> master = priceAuthority.loadMasterPrices(needMaster);
        boolean baseCurrency = quotes.isBaseCurrency(q.getCurrencyId());
        for (QuoteFinanceEditRequest.Line edit : edits) {
            SalesQuoteItem item = byId.get(edit.itemId());
            String label = lineLabel(item);
            if (Boolean.TRUE.equals(edit.removed())) {
                itemRepo.delete(item);
                items.remove(item);
                continue;
            }
            if (edit.qty() != null) item.setQty(edit.qty());
            if (edit.price() != null) {
                BigDecimal discount = edit.discount() == null ? item.getDiscount()
                        : SalesPriceAuthority.normalizeExplicitDiscount(edit.discount());
                financePrice(item, edit.price(), actor, now);
                item.setDiscount(discount);
            } else if (edit.discount() != null) {
                if (item.getPrice() == null) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,
                            label + "还没有单价, 请直接填写成交单价");
                }
                item.setDiscount(SalesPriceAuthority.normalizeExplicitDiscount(edit.discount()));
            } else if (Boolean.TRUE.equals(edit.giftZeroPrice())) {
                financePrice(item, BigDecimal.ZERO, actor, now);
            } else if (Boolean.TRUE.equals(edit.useMasterPrice())) {
                BigDecimal current = master.get(item.getGoodsId());
                if (current == null || current.signum() < 0) {
                    throw new ApiException(ErrorCode.CONFLICT, label + "货品资料还没有标价, 不能按标价刷新");
                }
                item.setPrice(current);
                item.setPriceSource(SalesQuoteItem.PRICE_SOURCE_MASTER);
                item.setFinancePriceBy(null);
                item.setFinancePriceAt(null);
                item.setDiscount(SalesPriceAuthority.normalizeDiscountForWrite(item.getDiscount()));
            } else if (edit.dealPrice() != null) {
                applyDealPrice(item, edit.dealPrice(), master.get(item.getGoodsId()), label, actor, now);
            }
            BigDecimal amount = item.getPrice() == null ? null
                    : com.uten.imp.common.columns.ExtraColumnCalculator.apply(
                            MoneyPolicy.exactProduct(item.getQty(), item.getPrice(), item.getDiscount()), item.getExtraColumns());
            item.setAmountOriginal(amount);
            item.setAmountLocal(baseCurrency ? amount : null);
            itemRepo.save(item);
        }
        quotes.applyTotals(q, items);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        itemRepo.flush();
        revisionLog.append(q, items, SalesQuoteRevisionLog.FINANCE_EDIT, actor, null);
        return reviewOf(q);
    }

    /** 退回销售: 待核价 → 草稿(带原因), 通知报价负责人。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto returnToSales(UUID id, QuoteFinanceDecisionRequest req) {
        tx.bind();
        requireEligibleReviewer();
        String reason = req == null || req.text() == null ? "" : req.text().strip();
        if (reason.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明退回原因, 告诉销售要改什么");
        }
        SalesQuote q = lockForDecision(id);
        requirePendingFinance(q);
        SalesQuoteService.requireRevision(q, req.expectedRevision());
        claimGuard.requireActiveClaimByMe(TARGET, id.toString(), req.expectedClaimId());
        UUID actor = currentUser.requireEmployeeId();
        q.setStatus(SalesQuoteService.STATUS_DRAFT);
        q.setFinanceReturnedAt(OffsetDateTime.now());
        q.setFinanceReturnedBy(actor);
        q.setFinanceReturnReason(reason);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        revisionLog.append(q, items, SalesQuoteRevisionLog.RETURN, actor, reason);
        notices.notifyReturned(id);
        notices.resolveReviewNotices(id, "RETURNED");
        claimGuard.release(TARGET, id.toString());
        return reviewOf(q);
    }

    /**
     * 确认报价: 待核价 → 已核价。每行都必须有单价; 标价为 0 而客户文件有单价的行必须由财务定价或勾选赠品/0价。
     * 冻结货品快照, 通知报价负责人可以转订货单。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto confirm(UUID id, QuoteFinanceDecisionRequest req) {
        tx.bind();
        requireEligibleReviewer();
        SalesQuote q = lockForDecision(id);
        requirePendingFinance(q);
        SalesQuoteService.requireRevision(q, req == null ? null : req.expectedRevision());
        claimGuard.requireActiveClaimByMe(TARGET, id.toString(), req.expectedClaimId());
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "报价没有货品明细, 不能确认");
        }
        for (SalesQuoteItem item : items) {
            String reason = blockingReason(item.getPrice(), item.getPriceSource(), item.getClientPrice());
            if (reason != null) {
                throw new ApiException(ErrorCode.CONFLICT, lineLabel(item) + reason);
            }
        }
        requireStoredReferencesUsable(q, items);
        UUID actor = currentUser.requireEmployeeId();
        OffsetDateTime now = OffsetDateTime.now();
        quotes.captureApprovalSnapshots(items, now);
        items.forEach(itemRepo::save);
        q.setStatus(SalesQuoteService.STATUS_CONFIRMED);
        q.setFinanceConfirmedAt(now);
        q.setFinanceConfirmedBy(actor);
        q.setApproverId(actor);
        String remark = req.text() == null ? null : blankToNull(req.text());
        if (remark != null) q.setFinanceRemark(remark);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        itemRepo.flush();
        revisionLog.append(q, items, SalesQuoteRevisionLog.CONFIRM, actor, remark);
        notices.notifyConfirmed(id);
        notices.resolveReviewNotices(id, "CONFIRMED");
        claimGuard.release(TARGET, id.toString());
        return reviewOf(q);
    }

    /** 撤销确认再修改: 已核价且未转订货单 → 待核价(之后照常认领核价)。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote_finance:view') and hasAuthority('sales_quote_finance:confirm')")
    public QuoteFinanceReviewDto reopen(UUID id, QuoteActionRequest req) {
        tx.bind();
        requireEligibleReviewer();
        SalesQuote q = lockForDecision(id);
        if (q.getStatus() == null || q.getStatus() != SalesQuoteService.STATUS_CONFIRMED
                || q.getFinanceConfirmedAt() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "只有财务已确认的报价可以撤销确认");
        }
        SalesQuoteService.requireRevision(q, req == null ? null : req.expectedRevision());
        if (!quotes.convertedOrders(List.of(id)).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "报价已转成订货单, 不能撤销确认");
        }
        UUID actor = currentUser.requireEmployeeId();
        q.setStatus(SalesQuoteService.STATUS_PENDING_FINANCE);
        q.setFinanceConfirmedAt(null);
        q.setFinanceConfirmedBy(null);
        SalesQuoteService.clearCustomerAcceptance(q);
        q.setApproverId(null);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        revisionLog.append(q, items, SalesQuoteRevisionLog.FINANCE_REOPEN, actor, req == null ? null : req.reason());
        notices.notifyFinanceReopened(id);
        return reviewOf(q);
    }

    // ------------------------------------------------------------------ 内部

    /**
     * 成交单价: 有标价且不高于标价 → 保留标价, 按「成交单价 ÷ 标价」反推 4 位折扣(取位只在 MoneyPolicy);
     * 没有标价(空或 0)或高于标价 → 财务定价(单价 = 成交单价, 折扣 1)。成交单价为 0 请用赠品/0价。
     */
    private void applyDealPrice(SalesQuoteItem item, BigDecimal dealPrice, BigDecimal currentMaster,
                                String label, UUID actor, OffsetDateTime now) {
        if (dealPrice.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "成交单价要大于 0; 0 价请勾选赠品/0价");
        }
        BigDecimal listPrice = !SalesQuoteItem.PRICE_SOURCE_FINANCE.equals(item.getPriceSource()) && item.getPrice() != null
                ? item.getPrice() : currentMaster;
        MoneyPolicy.DiscountQuote quote = MoneyPolicy.discountFromUnitPrice(dealPrice, BigDecimal.ONE, listPrice);
        switch (quote.flag()) {
            case OK, ROUNDED -> {
                item.setPrice(listPrice);
                // A negotiated sales base price stays a sales snapshot; deriving a discount
                // must not silently replace it with the current goods master price.
                if (!SalesQuoteItem.PRICE_SOURCE_SALES.equals(item.getPriceSource())) {
                    item.setPriceSource(SalesQuoteItem.PRICE_SOURCE_MASTER);
                }
                item.setFinancePriceBy(null);
                item.setFinancePriceAt(null);
                item.setDiscount(quote.discount());
            }
            case NO_LIST_PRICE, ABOVE_LIST -> financePrice(item, dealPrice, actor, now);
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    label + "成交单价太小, 算不出有效折扣, 请改填折扣");
        }
    }

    private static void financePrice(SalesQuoteItem item, BigDecimal price, UUID actor, OffsetDateTime now) {
        item.setPrice(price);
        item.setPriceSource(SalesQuoteItem.PRICE_SOURCE_FINANCE);
        item.setFinancePriceBy(actor);
        item.setFinancePriceAt(now);
        item.setDiscount(BigDecimal.ONE.setScale(4));
    }

    private static boolean differs(BigDecimal proposed, BigDecimal financeSet) {
        return proposed != null && financeSet != null && proposed.compareTo(financeSet) != 0;
    }

    /** 确认前必须处理的行问题; 没有问题返回 null。 */
    static String blockingReason(BigDecimal price, String priceSource, BigDecimal clientPrice) {
        if (price == null) return "还没有单价, 请先填写成交单价";
        if (price.signum() == 0 && !SalesQuoteItem.PRICE_SOURCE_FINANCE.equals(priceSource)
                && clientPrice != null && clientPrice.signum() > 0) {
            return "标价为 0, 请填写成交单价或勾选赠品/0价";
        }
        return null;
    }

    /** 确认前复核客户与货品仍可用于新业务(不按核价人的负责人范围, 只看启用/删除状态)。 */
    private void requireStoredReferencesUsable(SalesQuote q, List<SalesQuoteItem> items) {
        Number clientOk = (Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM clients
                        WHERE id = :id AND is_deleted = FALSE AND status = '使用'
                        """)
                .setParameter("id", q.getClientId())
                .getSingleResult();
        if (clientOk.longValue() != 1) {
            throw new ApiException(ErrorCode.CONFLICT, "报价客户已删除或停用, 请退回销售处理");
        }
        List<UUID> goodsIds = items.stream().map(SalesQuoteItem::getGoodsId).distinct().toList();
        Number usable = (Number) em.createNativeQuery("""
                        SELECT COUNT(*) FROM goods
                        WHERE id IN (:ids) AND COALESCE(is_deleted, FALSE) = FALSE AND status = '使用'
                        """)
                .setParameter("ids", goodsIds)
                .getSingleResult();
        if (usable.longValue() != goodsIds.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "报价里有货品已停用或删除, 请退回销售处理");
        }
    }

    private SalesQuote lockForDecision(UUID id) {
        SalesQuote q = em.find(SalesQuote.class, id);
        if (q == null || q.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在");
        }
        em.refresh(q, LockModeType.PESSIMISTIC_WRITE);
        if (q.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在");
        }
        return q;
    }

    private static void requirePendingFinance(SalesQuote q) {
        if (q.getStatus() == null || q.getStatus() != SalesQuoteService.STATUS_PENDING_FINANCE) {
            throw new ApiException(ErrorCode.CONFLICT, "报价已不在待财务核价状态, 请刷新");
        }
    }

    private void requireEligibleReviewer() {
        if (!reviewers.isEligible(currentUser.requireId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "只有财务部门在职、并有报价核价权限的人员可以核价");
        }
    }

    private static String lineLabel(SalesQuoteItem item) {
        String name = item.getGoodsNameSnapshot() == null ? "" : "「" + item.getGoodsNameSnapshot() + "」";
        return "第 " + (item.getLineNo() == null ? "?" : item.getLineNo()) + " 行" + name;
    }

    private static String bucketOf(short status, String returnReason) {
        return switch (status) {
            case SalesQuoteService.STATUS_PENDING_FINANCE -> SalesQuoteService.BUCKET_PENDING_FINANCE;
            case SalesQuoteService.STATUS_CONFIRMED -> SalesQuoteService.BUCKET_APPROVED;
            case SalesQuoteService.STATUS_REVERSED -> SalesQuoteService.BUCKET_REVERSED;
            default -> returnReason != null ? SalesQuoteService.BUCKET_FINANCE_REJECTED : SalesQuoteService.BUCKET_DRAFT;
        };
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
