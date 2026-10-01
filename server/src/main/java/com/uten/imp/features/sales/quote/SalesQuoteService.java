package com.uten.imp.features.sales.quote;

import com.uten.imp.application.port.SalesMasterLearningPort.LearnedLine;
import com.uten.imp.application.port.SalesQuoteNoticePort;
import com.uten.imp.application.port.TaskClaimMutationGuardPort;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.SalesGoodsSnapshot;
import com.uten.imp.features.sales.SalesIntakeSaveHooks;
import com.uten.imp.features.sales.SalesMasterReferenceValidator;
import com.uten.imp.features.sales.SalesPriceAuthority;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import com.uten.imp.features.sales.quote.dto.QuoteActionRequest;
import com.uten.imp.features.sales.quote.dto.QuoteDetail;
import com.uten.imp.features.sales.quote.dto.QuoteItemDto;
import com.uten.imp.features.sales.quote.dto.QuoteItemLine;
import com.uten.imp.features.sales.quote.dto.QuoteListItem;
import com.uten.imp.features.sales.quote.dto.QuoteQueryFilter;
import com.uten.imp.features.sales.quote.dto.QuoteSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 销售报价单服务(ADR-134 报价核价流程)。
 *
 * <p>状态: 0 草稿(财务退回的草稿带退回原因) → 提交财务核价 2 → 财务确认 1 → 转订货单; 1 → -1 作废。
 * 待核价期间销售可撤回(财务没在核价时); 已确认未转单时销售可「重新修改」回草稿, 财务可「撤销确认」回待核价。
 * 报价不再由销售自己审核(sales_quote:approve 已退役)。
 *
 * <p>单价权威与订货单一致({@link SalesPriceAuthority}): 新行取货品资料售价(报价允许为空 = 待财务定价),
 * 同一草稿既有行保留冻结单价(含财务成交单价), 页面预览价不一致 409; 金额 = 数量 × 单价 × 折扣。
 * 看不到价格的人保存时折扣由服务端决定(既有行保留, 新行按文件单价反推)。财务核价见 {@link SalesQuoteFinanceService}。
 *
 * <p>财务读范围: 持 {@code sales_quote_finance:view} 的人可读待核价/已核价/财务退回的报价(不论负责人),
 * 其他人仍按负责人(maker_id)范围。
 */
@Service
@RequiredArgsConstructor
public class SalesQuoteService {
    private com.uten.imp.common.history.RetainedRecordReader retainedRecords;
    @org.springframework.beans.factory.annotation.Autowired
    public void setRetainedRecords(com.uten.imp.common.history.RetainedRecordReader reader) { retainedRecords = reader; }


    static final short STATUS_DRAFT = 0;
    static final short STATUS_CONFIRMED = 1;
    static final short STATUS_PENDING_FINANCE = 2;
    static final short STATUS_REVERSED = -1;

    public static final String FINANCE_VIEW = "sales_quote_finance:view";
    public static final String FINANCE_CONFIRM = "sales_quote_finance:confirm";

    public static final String BUCKET_DRAFT = "DRAFT";
    public static final String BUCKET_FINANCE_REJECTED = "FINANCE_REJECTED";
    public static final String BUCKET_PENDING_FINANCE = "PENDING_FINANCE";
    public static final String BUCKET_APPROVED = "APPROVED";
    public static final String BUCKET_REVERSED = "REVERSED";
    /**
     * 只作列表筛选(不是分段, 分段计数里没有它): 财务已核价、还没转成订货单的报价, 与工作台徽章
     * 「报价已核价待转订货」({@link #counts()})同一条件; 「从报价引入」选报价时用。
     */
    public static final String BUCKET_AWAITING_CONVERSION = "AWAITING_CONVERSION";

    private static final String DOC_LABEL = "报价";
    private static final String MASKED_DISCOUNT_NOTE = "文件单价换算不出合理折扣, 暂按原价, 请有价格权限的同事核对";

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额/单据号可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate", "total", "totalOriginal",
            "billNo", "billNo"); // 2026-09-25 单号列统一

    private final SalesQuoteRepository quoteRepo;
    private final SalesQuoteItemRepository itemRepo;
    private com.uten.imp.common.columns.BusinessColumnService businessColumns;

    @org.springframework.beans.factory.annotation.Autowired
    public void setBusinessColumns(com.uten.imp.common.columns.BusinessColumnService service) { this.businessColumns = service; }
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.sales.order.SalesOrderService salesOrderService;
    private final SalesDocumentAccessPolicy accessPolicy;
    private final SalesMasterReferenceValidator referenceValidator;
    private final SalesPriceAuthority priceAuthority;
    private final SalesPriceMasker priceMasker;
    private final SalesIntakeSaveHooks intakeHooks;
    private final SalesQuoteRevisionLog revisionLog;
    private final SalesQuoteNoticePort notices;
    private final TaskClaimMutationGuardPort taskClaim;

    // ------------------------------------------------------------------ 读

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public PageResponse<QuoteListItem> list(QuoteQueryFilter f, int page, int size, String sort, String order) {
        Specification<SalesQuote> spec = quoteSpec(f);
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<SalesQuote> p = quoteRepo.findAll(spec, pageable);
        boolean canEdit = hasObjectActionAuthority();
        boolean masked = pricesMasked();
        Map<UUID, ConvertedOrder> converted = convertedOrders(p.getContent().stream().map(SalesQuote::getId).toList());
        var readScope = accessPolicy.scope();
        PageResponse<QuoteListItem> result = new PageResponse<>(p.map(q -> toList(q,
                        canEdit && accessPolicy.canWrite(q.getMakerId(), readScope), masked,
                        converted.get(q.getId()), readScope)).getContent(),
                p);
        return p.stream().noneMatch(SalesQuote::isDeleted) ? result
                : retainedRecords.page(result, "sales_quotes", p.getContent());
    }

    /** 单据号列值筛选桶（2026-09-25 单号列统一）：与列表同一份谓词分组计数。 */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public java.util.Map<String, java.util.List<java.util.Map<String, Object>>> facets(QuoteQueryFilter f) {
        return java.util.Map.of("billNo",
                com.uten.imp.common.web.TableFacets.groupCount(em, SalesQuote.class, quoteSpec(f), "billNo"));
    }

    /**
     * 工作台徽章「报价已核价待转订货」: 本人负责范围内财务已确认、还没转成订货单的报价张数。
     * 没有转单权限(报价转单 + 新建订货单)时固定 0, 不查库。
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteCounts counts() {
        if (!accessPolicy.hasAuthority("sales_quote:convert") || !accessPolicy.hasAuthority("sales_order:create")) {
            return new QuoteCounts(0);
        }
        var scope = accessPolicy.nativeReadScope("o.maker_id", "quoteOwners");
        var query = em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_quotes o
                WHERE o.is_deleted = FALSE AND o.status = 1 AND o.finance_confirmed_at IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM sales_orders converted
                                  WHERE converted.source_quote_id = o.id AND converted.is_deleted = FALSE)
                  AND""" + " " + scope.predicate());
        scope.bind(query);
        return new QuoteCounts(((Number) query.getSingleResult()).longValue());
    }

    /** 报价计数(工作台徽章来源)。 */
    public record QuoteCounts(long awaitingConversion) {
    }

    /** 列表谓词(list 与 facets 共用；billNo=表头单据号精确匹配；bucket=分段)。 */
    private Specification<SalesQuote> quoteSpec(QuoteQueryFilter f) {
        var readScope = accessPolicy.scope();
        String bucket = normalizeBucket(f.bucket());
        return (Root<SalesQuote> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (f.onlyDeleted()) ps.add(cb.isTrue(root.get("deleted")));
            else if (!f.includeDeleted()) ps.add(cb.isFalse(root.get("deleted")));
            // 报价表没有独立 owner 列，maker_id 是其有效归属人。
            ps.add(accessPolicy.readablePredicate(root, cb, "makerId", readScope));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String kw = "%" + f.keyword().toLowerCase() + "%";
                // 关键字同时匹配 单据号 / 客户名称（日常检索按客户找单）
                jakarta.persistence.criteria.Subquery<java.util.UUID> cs = q.subquery(java.util.UUID.class);
                Root<com.uten.imp.features.master.client.Client> cr =
                        cs.from(com.uten.imp.features.master.client.Client.class);
                cs.select(cr.get("id")).where(cb.isFalse(cr.get("deleted")),
                        cb.like(cb.lower(cr.get("name")), kw));
                ps.add(cb.or(cb.like(cb.lower(root.get("billNo")), kw),
                        root.get("clientId").in(cs)));
            }
            if (f.clientId() != null) ps.add(cb.equal(root.get("clientId"), f.clientId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (bucket != null) ps.add(bucketPredicate(bucket, root, q, cb));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            // 单据号表头值筛选（2026-09-25 单号列统一）：精确匹配。
            if (f.billNo() != null && !f.billNo().isBlank()) {
                ps.add(cb.equal(root.get("billNo"), f.billNo().trim()));
            }
            if (f.currencyId() != null) ps.add(cb.equal(root.get("currencyId"), f.currencyId()));
            f.headerFilters().apply(root, cb, ps, "totalLocal", priceMasker != null && priceMasker.canView(), "deliverDate", false, null, false);
            return cb.and(ps.toArray(new Predicate[0]));
        };
    }

    private static String normalizeBucket(String raw) {
        if (raw == null || raw.isBlank()) return null;
        String bucket = raw.trim().toUpperCase(java.util.Locale.ROOT);
        return switch (bucket) {
            case BUCKET_DRAFT, BUCKET_FINANCE_REJECTED, BUCKET_PENDING_FINANCE, BUCKET_APPROVED, BUCKET_REVERSED,
                 BUCKET_AWAITING_CONVERSION -> bucket;
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "报价分段无效: " + raw);
        };
    }

    /**
     * 分段谓词: 与 DocumentStatusCountQueryService 的 salesQuote 分桶逐条一致;
     * AWAITING_CONVERSION 与 {@link #counts()} 的「已核价待转订货」同一条件(状态 1、财务确认过、没有未删除的订货单引用它)。
     */
    private static Predicate bucketPredicate(String bucket, Root<SalesQuote> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> query, CriteriaBuilder cb) {
        return switch (bucket) {
            case BUCKET_DRAFT -> cb.and(cb.equal(root.get("status"), STATUS_DRAFT),
                    cb.isNull(root.get("financeReturnReason")));
            case BUCKET_FINANCE_REJECTED -> cb.and(cb.equal(root.get("status"), STATUS_DRAFT),
                    cb.isNotNull(root.get("financeReturnReason")));
            case BUCKET_PENDING_FINANCE -> cb.equal(root.get("status"), STATUS_PENDING_FINANCE);
            case BUCKET_APPROVED -> cb.equal(root.get("status"), STATUS_CONFIRMED);
            case BUCKET_AWAITING_CONVERSION -> {
                jakarta.persistence.criteria.Subquery<Integer> converted = query.subquery(Integer.class);
                Root<com.uten.imp.features.sales.order.SalesOrder> order =
                        converted.from(com.uten.imp.features.sales.order.SalesOrder.class);
                converted.select(cb.literal(1)).where(
                        cb.equal(order.get("sourceQuoteId"), root.get("id")),
                        cb.isFalse(order.get("deleted")));
                yield cb.and(cb.equal(root.get("status"), STATUS_CONFIRMED),
                        cb.isNotNull(root.get("financeConfirmedAt")),
                        cb.not(cb.exists(converted)));
            }
            default -> cb.equal(root.get("status"), STATUS_REVERSED);
        };
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteDetail detail(UUID id) { return readDetail(id, false); }


    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public QuoteDetail detailHistory(UUID id) { return readDetail(id, true); }

    private QuoteDetail readDetail(UUID id, boolean historyRead) {
        SalesQuote q = requireReadableQuote(id, historyRead);
        return finishHistory(toDetail(q, itemRepo.findByQuoteIdOrderByLineNoAsc(id), true), q, historyRead);
    }

    // ------------------------------------------------------------------ 草稿写

    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:create')")
    public QuoteDetail create(QuoteSaveRequest req) {
        tx.bind();
        referenceValidator.validate(req);
        validateHeaderReferences(req);
        SalesQuote q = new SalesQuote();
        applyHeader(req, q);
        q.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（报表按 maker_id 解析制单员）
        q.setStatus(STATUS_DRAFT);
        quoteRepo.save(q);
        List<SalesQuoteItem> items = saveItems(q, req.getItems(), List.of());
        applyTotals(q, items);
        intakeHooks.afterSave(SalesIntakeSaveHooks.DOC_QUOTE, q.getId(), q.getClientId(),
                learnedLines(req.getItems(), items), req.getAiIntake());
        return toDetail(q, items, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail update(UUID id, QuoteSaveRequest req) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行重读, 与提交核价互斥
        if (q.getStatus() == null || q.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, q.getStatus() != null && q.getStatus() == STATUS_PENDING_FINANCE
                    ? "报价已提交财务核价, 请先撤回再修改" : "仅草稿单据可编辑");
        }
        referenceValidator.validate(req);
        validateHeaderReferences(req);
        applyHeader(req, q);
        List<SalesQuoteItem> existing = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        List<SalesQuoteItem> items = saveItems(q, req.getItems(), existing);
        applyTotals(q, items);
        intakeHooks.afterSave(SalesIntakeSaveHooks.DOC_QUOTE, q.getId(), q.getClientId(),
                learnedLines(req.getItems(), items), req.getAiIntake());
        return toDetail(q, items, false);
    }

    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:delete')")
    public void delete(UUID id) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(q.getStatus());
        q.setDeleted(true);
        q.setDeletedAt(OffsetDateTime.now());
        quoteRepo.save(q);
    }

    // ------------------------------------------------------------------ 状态动作(销售)

    /** 提交财务核价: 草稿 → 待财务核价; 清空上次退回原因, 通知全部核价人。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail submit(UUID id, QuoteActionRequest req) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (q.getStatus() == null || q.getStatus() != STATUS_DRAFT || q.isClosed()) {
            throw new ApiException(ErrorCode.CONFLICT, "只有草稿报价可以提交财务核价");
        }
        if (req != null && req.expectedRevision() != null) {
            requireRevision(q, req.expectedRevision());
        }
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报价还没有货品明细, 不能提交财务核价");
        }
        referenceValidator.validateStoredQuote(q.getClientId(), items);
        if (!isBaseCurrency(q.getCurrencyId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, NON_BASE_CURRENCY_MESSAGE);
        }
        UUID actor = currentUser.requireEmployeeId();
        q.setStatus(STATUS_PENDING_FINANCE);
        q.setSubmittedAt(OffsetDateTime.now());
        q.setSubmittedBy(actor);
        q.setFinanceReturnReason(null);
        q.setFinanceReturnedAt(null);
        q.setFinanceReturnedBy(null);
        q.setFinanceConfirmedAt(null);
        q.setFinanceConfirmedBy(null);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        revisionLog.append(q, items, SalesQuoteRevisionLog.SUBMIT, actor, null);
        notices.notifySubmittedForReview(q.getId());
        return toDetail(q, items, true);
    }

    /** 撤回核价: 待财务核价 → 草稿; 财务正在核价(持有认领)时不能撤回。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail withdraw(UUID id, QuoteActionRequest req) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (q.getStatus() == null || q.getStatus() != STATUS_PENDING_FINANCE) {
            throw new ApiException(ErrorCode.CONFLICT, "报价不在待财务核价状态, 不能撤回");
        }
        requireRevision(q, req == null ? null : req.expectedRevision());
        taskClaim.requireNoActiveClaim(SalesQuoteFinanceClaimTargetLocks.TARGET_TYPE, id.toString());
        UUID actor = currentUser.requireEmployeeId();
        q.setStatus(STATUS_DRAFT);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        revisionLog.append(q, items, SalesQuoteRevisionLog.WITHDRAW, actor, req == null ? null : req.reason());
        notices.resolveReviewNotices(q.getId(), "WITHDRAWN");
        return toDetail(q, items, true);
    }

    /** 重新修改: 财务已确认但还没转订货单的报价 → 草稿(财务确认作废, 改完须重新提交核价)。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:edit')")
    public QuoteDetail reopen(UUID id, QuoteActionRequest req) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (q.getStatus() == null || q.getStatus() != STATUS_CONFIRMED) {
            throw new ApiException(ErrorCode.CONFLICT, "只有已核价的报价可以重新修改");
        }
        requireRevision(q, req == null ? null : req.expectedRevision());
        requireNotConverted(q.getId(), "报价已转成订货单, 不能重新修改; 如需改价请先处理订货单");
        UUID actor = currentUser.requireEmployeeId();
        q.setStatus(STATUS_DRAFT);
        q.setFinanceConfirmedAt(null);
        q.setFinanceConfirmedBy(null);
        q.setApproverId(null);
        q.setReviewRevision(q.getReviewRevision() + 1);
        quoteRepo.save(q);
        List<SalesQuoteItem> items = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        revisionLog.append(q, items, SalesQuoteRevisionLog.REOPEN, actor, req == null ? null : req.reason());
        return toDetail(q, items, true);
    }

    /** 作废：status 1→-1(已转订货单的报价不能作废)。 */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:reverse')")
    public QuoteDetail reverse(UUID id) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过状态守卫（TOCTOU，对齐 M28）
        if (q.getStatus() == null || q.getStatus() != STATUS_CONFIRMED) {
            throw new ApiException(ErrorCode.BUSINESS, "仅已核价的报价可以作废");
        }
        requireNotConverted(q.getId(), "报价已转成订货单, 不能作废; 请先处理订货单");
        q.setStatus(STATUS_REVERSED);
        quoteRepo.save(q);
        return toDetail(q, itemRepo.findByQuoteIdOrderByLineNoAsc(id), true);
    }

    /**
     * 报价转订货(SOP §三1)：财务已核价的报价一键生成订货草稿。
     * 表头带入客户/币种(必须是本位币)/业务员/交货日期/结账方式/合同号/文件币种; 行带入货品/颜色/单位/数量/
     * 单价/折扣/文件型号品名单价。单价与折扣是财务核定的, 在订货单上锁定(改折扣 409); 数量与新增行仍可改。
     * 审核才走库存检查+软预留(订货既有链路)。
     */
    @Transactional
    @PreAuthorize("hasAuthority('sales_quote:convert') and hasAuthority('sales_order:create')")
    public com.uten.imp.features.sales.order.dto.OrderDetail convertToOrder(UUID id) {
        tx.bind();
        SalesQuote q = requireWritableQuote(id);
        em.refresh(q, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE); // 锁行并重读最新状态，防陈旧快照绕过守卫
        if (q.getStatus() == null || q.getStatus() != STATUS_CONFIRMED) {
            throw new ApiException(ErrorCode.BUSINESS, "报价还没有财务核价确认, 不能转订货单");
        }
        if (q.getFinanceConfirmedAt() == null) {
            throw new ApiException(ErrorCode.BUSINESS,
                    "报价还没有财务核价确认, 不能转订货单; 请点「重新修改」后提交财务核价");
        }
        // 防重复/并发转入：运行时只按报价 UUID；source_doc_no 仅保留可读快照。
        // 防重复——转入不改报价状态；此查询在 em.refresh 锁行后执行，见最新提交，并发也只一笔成功。
        Integer existingFromQuote = ((Number) em.createNativeQuery("""
                SELECT COUNT(*) FROM sales_orders
                WHERE source_quote_id = :quoteId AND COALESCE(is_deleted, false) = false
                """)
                .setParameter("quoteId", q.getId())
                .getSingleResult()).intValue();
        if (existingFromQuote != null && existingFromQuote > 0) {
            throw new ApiException(ErrorCode.CONFLICT, "该报价单已转入订货单，禁止重复转入");
        }
        List<SalesQuoteItem> qitems = itemRepo.findByQuoteIdOrderByLineNoAsc(id);
        if (qitems.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可转入");
        }
        if (q.getCurrencyId() != null && !isBaseCurrency(q.getCurrencyId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "报价用的币种不是本位币, 不能直接转订货单; 请点「重新修改」把币种改成本位币后再提交核价");
        }
        com.uten.imp.features.sales.order.dto.OrderSaveRequest req =
                new com.uten.imp.features.sales.order.dto.OrderSaveRequest();
        req.setBillDate(BusinessTime.today());
        req.setClientId(q.getClientId());
        req.setCurrencyId(q.getCurrencyId());
        req.setSellerId(q.getSellerId() == null ? q.getMakerId() : q.getSellerId());
        req.setDeliverDate(q.getDeliverDate());
        req.setSettlementMethodId(q.getSettlementMethodId());
        req.setContractNo(q.getContractNo());
        req.setClientFileCurrency(q.getClientFileCurrency());
        req.setSourceDocNo(q.getBillNo());
        req.setRemark("从报价单 " + q.getBillNo() + " 转入"
                + (q.getRemark() == null || q.getRemark().isBlank() ? "" : "；" + q.getRemark()));
        List<com.uten.imp.features.sales.order.dto.OrderItemLine> lines = new ArrayList<>(qitems.size());
        for (SalesQuoteItem qi : qitems) {
            com.uten.imp.features.sales.order.dto.OrderItemLine l =
                    new com.uten.imp.features.sales.order.dto.OrderItemLine();
            l.setLineNo(qi.getLineNo());
            l.setGoodsId(qi.getGoodsId());
            l.setColorId(qi.getColorId());
            l.setUnitId(qi.getUnitId());
            l.setUnitRate(qi.getUnitRate());
            l.setQty(qi.getQty());
            l.setPrice(qi.getPrice());
            l.setDiscount(qi.getDiscount());
            // The order inherits authoritative quote snapshots internally. Treating these
            // as client writes would reject a salesperson whose financial values are masked.
            l.setWeight(qi.getWeight());
            l.setClientModel(qi.getClientModel());
            l.setClientGoodsName(qi.getClientGoodsName());
            l.setClientPrice(qi.getClientPrice());
            l.setSourceDocNo(q.getBillNo());
            l.setRemark(qi.getRemark());
            lines.add(l);
        }
        req.setItems(lines);
        return salesOrderService.createFromQuote(req, q.getId(), q.getMakerId());
    }

    // ------------------------------------------------------------------ 表头与明细

    private void applyHeader(QuoteSaveRequest req, SalesQuote q) {
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时取号；更新保留既有号，忽略客户端值。
        if (q.getBillNo() == null || q.getBillNo().isBlank()) {
            q.setBillNo(docNumberService.nextNumber(DocNumberPrefix.SALES_QUOTE));
        }
        q.setBillDate(req.getBillDate());
        q.setClientId(req.getClientId());
        q.setValidUntil(req.getValidUntil());
        q.setRemark(req.getRemark());
        q.setCurrencyId(req.getCurrencyId());
        q.setSellerId(req.getSellerId());
        q.setDeliverDate(req.getDeliverDate());
        q.setSettlementMethodId(req.getSettlementMethodId());
        q.setContractNo(blankToNull(req.getContractNo()));
        q.setClientFileCurrency(SalesPriceAuthority.canonicalCurrency(req.getClientFileCurrency()));
    }

    /** 表头引用: 币种启用、结账方式启用、业务员在职(不接受已离职员工)。 */
    private void validateHeaderReferences(QuoteSaveRequest req) {
        if (req.getCurrencyId() != null) {
            Number count = (Number) em.createNativeQuery("""
                            SELECT COUNT(*) FROM currencies
                            WHERE id = :id AND COALESCE(is_deleted, FALSE) = FALSE AND status = '使用'
                            """)
                    .setParameter("id", req.getCurrencyId())
                    .getSingleResult();
            if (count.longValue() != 1) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "币种不存在或已停用");
            }
            if (!isBaseCurrency(req.getCurrencyId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, NON_BASE_CURRENCY_MESSAGE);
            }
        }
        if (req.getSettlementMethodId() != null) {
            com.uten.imp.common.util.SettlementMethodReferenceResolver.resolve(
                    em, req.getSettlementMethodId(), null, "结帐方式");
        }
        if (req.getSellerId() != null) {
            Number count = (Number) em.createNativeQuery("""
                            SELECT COUNT(*) FROM employees
                            WHERE id = :id AND is_deleted = FALSE AND status IN ('active', 'probation', 'onLeave')
                            """)
                    .setParameter("id", req.getSellerId())
                    .getSingleResult();
            if (count.longValue() != 1) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "业务员不存在或已离职");
            }
        }
    }

    /**
     * 明细按行原位保存: 请求行先按行 id(身份不变)再按商业身份配对既有行, 配上的沿用行 id 与冻结单价
     * (含财务成交单价), 新行取货品资料售价; 没配上的既有行删除。
     */
    private List<SalesQuoteItem> saveItems(SalesQuote q, List<QuoteItemLine> lines, List<SalesQuoteItem> existing) {
        List<QuoteItemLine> requested = lines == null ? List.of() : lines;
        Map<UUID, SalesGoodsSnapshot> goodsSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                requested.stream().map(QuoteItemLine::getGoodsId).toList(),
                SalesGoodsSnapshot.MASTER_AT_SAVE);
        SalesPriceAuthority.ExistingPriceBook<SalesQuoteItem, QuoteItemLine> book =
                new SalesPriceAuthority.ExistingPriceBook<>(
                        existing,
                        SalesQuoteItem::getId,
                        item -> SalesPriceAuthority.identity(
                                item.getGoodsId(), item.getColorId(), item.getUnitId(), item.getUnitRate()),
                        QuoteItemLine::getId,
                        line -> SalesPriceAuthority.identity(
                                line.getGoodsId(), line.getColorId(), line.getUnitId(), line.getUnitRate()));
        List<SalesQuoteItem> matched = new ArrayList<>(requested.size());
        List<UUID> needsMaster = new ArrayList<>();
        for (QuoteItemLine line : requested) {
            SalesQuoteItem stored = book.take(line);
            matched.add(stored);
            if (stored == null) needsMaster.add(line.getGoodsId());
        }
        Map<UUID, BigDecimal> masterPrices = priceAuthority.loadMasterPrices(needsMaster);
        boolean masked = pricesMasked();
        // 看不到价格的人才需要按文件单价反推折扣; 文件币种每次保存只解析一次。
        SalesPriceAuthority.FileCurrency fileCurrency = masked
                ? priceAuthority.resolveFileCurrency(q.getClientFileCurrency()) : null;
        boolean baseCurrency = q.getCurrencyId() == null || isBaseCurrency(q.getCurrencyId());
        for (SalesQuoteItem stale : book.unconsumed(existing)) {
            itemRepo.delete(stale);
        }
        itemRepo.flush();

        List<SalesQuoteItem> out = new ArrayList<>(requested.size());
        int auto = 1;
        for (int index = 0; index < requested.size(); index++) {
            QuoteItemLine l = requested.get(index);
            SalesQuoteItem stored = matched.get(index);
            SalesQuoteItem it = stored != null ? stored : new SalesQuoteItem();
            BigDecimal price;
            if (stored != null) {
                price = stored.getPrice();
            } else {
                if (!masterPrices.containsKey(l.getGoodsId())) {
                    throw new ApiException(ErrorCode.CONFLICT, "第 " + auto + " 行货品已停用或已删除, 不能报价");
                }
                price = SalesPriceAuthority.requireNonNegativePrice(masterPrices.get(l.getGoodsId()));
                it.setPriceSource(SalesQuoteItem.PRICE_SOURCE_MASTER);
                it.setFinancePriceBy(null);
                it.setFinancePriceAt(null);
            }
            SalesPriceAuthority.requirePreviewMatches(l.getPrice(), price, DOC_LABEL);
            requireSafeQuoteLine(l, auto);
            String note = null;
            BigDecimal discount;
            if (masked) {
                if (stored != null) {
                    discount = SalesPriceAuthority.normalizeDiscountForWrite(stored.getDiscount());
                } else if (l.getClientPrice() != null && price != null) {
                    var derived = SalesPriceAuthority.deriveDiscountFromClientPrice(
                            l.getClientPrice(), fileCurrency, price);
                    discount = derived.orElse(BigDecimal.ONE.setScale(4));
                    if (derived.isEmpty()) note = MASKED_DISCOUNT_NOTE;
                } else {
                    discount = BigDecimal.ONE.setScale(4);
                }
            } else {
                discount = SalesPriceAuthority.normalizeDiscountForWrite(l.getDiscount());
            }
            BigDecimal clientPrice = masked && stored != null && l.getClientPrice() == null
                    ? stored.getClientPrice() : l.getClientPrice();
            it.setQuoteId(q.getId());
            it.setBillNo(q.getBillNo());
            it.setBillDate(q.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            applyGoodsSnapshot(
                    it,
                    SalesGoodsSnapshot.require(goodsSnapshots, l.getGoodsId(), "销售报价明细"),
                    null);
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setPrice(price);
            it.setDiscount(discount);
            // 金额只由服务端派生(ADR-112): 数量 × 单价 × 折扣; 单价空(待财务定价)则金额空。
            it.setExtraColumns(com.uten.imp.common.columns.BusinessColumnService.resolveForSave(businessColumns, "sales_quote", l.getExtraColumns(),
                    stored == null ? List.of() : stored.getExtraColumns(), masked));
            BigDecimal amount = price == null ? null : com.uten.imp.common.columns.ExtraColumnCalculator.apply(
                    MoneyPolicy.exactProduct(l.getQty(), price, discount), it.getExtraColumns());
            it.setAmountOriginal(amount);
            it.setAmountLocal(baseCurrency ? amount : null);
            it.setWeight(l.getWeight());
            it.setRemark(appendNote(l.getRemark(), note));
            it.setClientModel(blankToNull(l.getClientModel()));
            it.setClientGoodsName(blankToNull(l.getClientGoodsName()));
            it.setClientPrice(clientPrice);
            itemRepo.save(it);
            out.add(it);
            auto++;
        }
        itemRepo.flush();
        return out;
    }

    private static void requireSafeQuoteLine(QuoteItemLine line, int lineNo) {
        if (line.getGoodsId() == null
                || line.getUnitId() == null
                || line.getUnitRate() == null
                || line.getUnitRate().signum() <= 0
                || line.getQty() == null || line.getQty().signum() <= 0
                || (line.getWeight() != null && line.getWeight().signum() < 0)
                || (line.getClientPrice() != null && line.getClientPrice().signum() < 0)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行: 货品、单位和大于 0 的数量必须完整, 金额由系统计算");
        }
        SalesPriceAuthority.requireClientPrice(line.getClientPrice(), "第 " + lineNo + " 行文件单价");
    }

    /** 学习出口的行输入: 保存结果(货品/文件原文) + 请求里的识别行键与用户确认标记, 按顺序一一对应。 */
    private static List<LearnedLine> learnedLines(List<QuoteItemLine> requested, List<SalesQuoteItem> saved) {
        List<LearnedLine> lines = new ArrayList<>(saved.size());
        for (int index = 0; index < saved.size(); index++) {
            SalesQuoteItem item = saved.get(index);
            QuoteItemLine line = requested.get(index);
            lines.add(new LearnedLine(item.getGoodsId(), item.getClientModel(), item.getClientGoodsName(),
                    blankToNull(line.getIntakeLineKey()),
                    Boolean.TRUE.equals(line.getUserConfirmed()),
                    Boolean.TRUE.equals(line.getSetNameEn())));
        }
        return lines;
    }

    private void captureGoodsSnapshots(
            List<SalesQuoteItem> items, String source, OffsetDateTime lockedAt) {
        Map<UUID, SalesGoodsSnapshot> goodsSnapshots = SalesGoodsSnapshot.fromMaster(
                em,
                items.stream().map(SalesQuoteItem::getGoodsId).toList(),
                source);
        for (SalesQuoteItem item : items) {
            applyGoodsSnapshot(
                    item,
                    SalesGoodsSnapshot.require(
                            goodsSnapshots, item.getGoodsId(), "销售报价明细"),
                    lockedAt);
        }
    }

    /** 财务确认时冻结货品编号/名称快照(MASTER_AT_APPROVAL), 由核价服务调用。 */
    public void captureApprovalSnapshots(List<SalesQuoteItem> items, OffsetDateTime lockedAt) {
        captureGoodsSnapshots(items, SalesGoodsSnapshot.MASTER_AT_APPROVAL, lockedAt);
    }

    private static void applyGoodsSnapshot(
            SalesQuoteItem item, SalesGoodsSnapshot snapshot, OffsetDateTime lockedAt) {
        item.setGoodsCodeSnapshot(snapshot.code());
        item.setGoodsNameSnapshot(snapshot.name());
        if (lockedAt == null) item.setGoodsNameEnSnapshot(snapshot.nameEn());
        item.setGoodsSnapshotSource(snapshot.source());
        item.setGoodsSnapshotLockedAt(lockedAt);
    }

    /** 表头合计 = 行金额相加(空金额不计); 本币合计只在本位币报价时有值。 */
    public void applyTotals(SalesQuote q, List<SalesQuoteItem> items) {
        BigDecimal original = MoneyPolicy.sum(items.stream().map(SalesQuoteItem::getAmountOriginal).toList());
        boolean baseCurrency = q.getCurrencyId() == null || isBaseCurrency(q.getCurrencyId());
        q.setTotalOriginal(original);
        q.setTotalLocal(baseCurrency ? original : null);
        quoteRepo.save(q);
    }

    // ------------------------------------------------------------------ 映射

    private QuoteListItem toList(SalesQuote q, boolean writable, boolean masked, ConvertedOrder converted,
                                 com.uten.imp.security.OwnerVisibility.OwnerScope scope) {
        QuoteListItem item = new QuoteListItem();
        item.setId(q.getId());
        item.setBillNo(q.getBillNo());
        item.setBillDate(q.getBillDate());
        item.setClientId(q.getClientId());
        item.setTotalOriginal(masked ? null : q.getTotalOriginal());
        item.setTotalLocal(masked ? null : q.getTotalLocal());
        item.setStatus(q.getStatus());
        item.setClosed(q.isClosed());
        item.setLegacyId(q.getLegacyId());
        item.setWritable(writable);
        item.setSellerId(q.getSellerId());
        item.setCurrencyId(q.getCurrencyId());
        item.setDeliverDate(q.getDeliverDate());
        item.setStatusBucket(statusBucket(q));
        item.setFinanceReturnReason(q.getFinanceReturnReason());
        item.setSubmittedAt(q.getSubmittedAt());
        item.setFinanceConfirmedAt(q.getFinanceConfirmedAt());
        item.setReviewRevision(q.getReviewRevision());
        item.setConvertedOrderId(converted == null ? null : converted.id());
        item.setConvertedOrderNo(converted == null ? null : converted.billNo());
        item.setClientFileCurrency(q.getClientFileCurrency());
        // 列表不逐张数明细: 「提交」按有明细处理, 真正提交时服务端再校验。
        item.setAllowedActions(allowedActions(q, converted, true, scope));
        item.setPriceMasked(masked);
        return item;
    }

    private QuoteDetail toDetail(SalesQuote q, List<SalesQuoteItem> items, boolean withRevisions) {
        boolean masked = pricesMasked();
        ConvertedOrder converted = convertedOrders(List.of(q.getId())).get(q.getId());
        QuoteDetail d = new QuoteDetail();
        d.setId(q.getId());
        d.setLegacyId(q.getLegacyId());
        d.setBillNo(q.getBillNo());
        d.setBillDate(q.getBillDate());
        d.setClientId(q.getClientId());
        d.setMakerId(q.getMakerId());
        d.setApproverId(q.getApproverId());
        d.setValidUntil(q.getValidUntil());
        d.setRemark(q.getRemark());
        d.setTotalOriginal(masked ? null : q.getTotalOriginal());
        d.setTotalLocal(masked ? null : q.getTotalLocal());
        d.setStatus(q.getStatus());
        d.setClosed(q.isClosed());
        d.setSourceDocNo(q.getSourceDocNo());
        List<QuoteItemDto> itemDtos = items.stream().map(item -> toItemDto(item, masked)).toList();
        d.setItems(itemDtos);
        d.setMakerName(nameResolver.nameOf(q.getMakerId()));
        d.setCreatedAt(q.getCreatedAt());
        var scope = accessPolicy.scope();
        d.setWritable(hasObjectActionAuthority() && accessPolicy.canWrite(q.getMakerId(), scope));
        d.setCurrencyId(q.getCurrencyId());
        d.setSellerId(q.getSellerId());
        d.setSellerName(q.getSellerId() == null ? null : nameResolver.nameOf(q.getSellerId()));
        d.setDeliverDate(q.getDeliverDate());
        d.setSettlementMethodId(q.getSettlementMethodId());
        d.setContractNo(q.getContractNo());
        d.setClientFileCurrency(q.getClientFileCurrency());
        d.setStatusBucket(statusBucket(q));
        d.setSubmittedAt(q.getSubmittedAt());
        d.setSubmittedByName(q.getSubmittedBy() == null ? null : nameResolver.nameOf(q.getSubmittedBy()));
        d.setFinanceReturnReason(q.getFinanceReturnReason());
        d.setFinanceReturnedAt(q.getFinanceReturnedAt());
        d.setFinanceReturnedByName(q.getFinanceReturnedBy() == null ? null : nameResolver.nameOf(q.getFinanceReturnedBy()));
        d.setFinanceConfirmedAt(q.getFinanceConfirmedAt());
        d.setFinanceConfirmedByName(q.getFinanceConfirmedBy() == null ? null : nameResolver.nameOf(q.getFinanceConfirmedBy()));
        d.setFinanceRemark(q.getFinanceRemark());
        d.setReviewRevision(q.getReviewRevision());
        d.setConvertedOrderId(converted == null ? null : converted.id());
        d.setConvertedOrderNo(converted == null ? null : converted.billNo());
        d.setAllowedActions(allowedActions(q, converted, !items.isEmpty(), scope));
        d.setPriceMasked(masked);
        d.setPricePendingCount((int) items.stream().filter(item -> item.getPrice() == null).count());
        d.setRevisions(withRevisions ? revisionLog.history(q.getId()) : List.of());
        return d;
    }

    private static QuoteItemDto toItemDto(SalesQuoteItem it, boolean masked) {
        QuoteItemDto dto = new QuoteItemDto();
        dto.setExtraColumns(com.uten.imp.common.columns.BusinessColumnService.visible(it.getExtraColumns(), masked));
        dto.setId(it.getId());
        dto.setLineNo(it.getLineNo());
        dto.setGoodsId(it.getGoodsId());
        dto.setGoodsCodeSnapshot(it.getGoodsCodeSnapshot());
        dto.setGoodsNameSnapshot(it.getGoodsNameSnapshot());
        dto.setGoodsNameEn(it.getGoodsNameEnSnapshot());
        dto.setGoodsSnapshotSource(it.getGoodsSnapshotSource());
        dto.setGoodsSnapshotLockedAt(it.getGoodsSnapshotLockedAt());
        dto.setColorId(it.getColorId());
        dto.setUnitId(it.getUnitId());
        dto.setUnitRate(it.getUnitRate());
        dto.setQty(it.getQty());
        dto.setPrice(masked ? null : it.getPrice());
        dto.setDiscount(masked ? null : it.getDiscount());
        dto.setAmountOriginal(masked ? null : it.getAmountOriginal());
        dto.setAmountLocal(masked ? null : it.getAmountLocal());
        dto.setWeight(it.getWeight());
        dto.setRemark(it.getRemark());
        dto.setPriceSource(it.getPriceSource());
        dto.setFinancePriced(SalesQuoteItem.PRICE_SOURCE_FINANCE.equals(it.getPriceSource()));
        dto.setPricePending(it.getPrice() == null);
        dto.setClientModel(it.getClientModel());
        dto.setClientGoodsName(it.getClientGoodsName());
        dto.setClientPrice(it.getClientPrice());
        return dto;
    }

    /**
     * 当前用户对这张报价能做的动作(按钮只按它显示)。负责人动作要求写范围; financeReview = 核价人可打开核价页。
     */
    private List<String> allowedActions(SalesQuote q, ConvertedOrder converted, boolean hasItems,
                                        com.uten.imp.security.OwnerVisibility.OwnerScope scope) {
        List<String> actions = new ArrayList<>();
        short status = q.getStatus() == null ? STATUS_DRAFT : q.getStatus();
        boolean owner = accessPolicy.canWrite(q.getMakerId(), scope);
        boolean draft = status == STATUS_DRAFT && !q.isClosed();
        boolean open = status == STATUS_CONFIRMED && converted == null;
        // 转订货单只认财务确认过的(与「报价已核价待转订货」徽章、待转订货筛选、主档引用保护同口径)。
        boolean convertible = open && q.getFinanceConfirmedAt() != null;
        if (owner && draft && accessPolicy.hasAuthority("sales_quote:edit")) {
            actions.add("edit");
            if (hasItems) actions.add("submit");
        }
        if (owner && draft && accessPolicy.hasAuthority("sales_quote:delete")) actions.add("delete");
        if (owner && status == STATUS_PENDING_FINANCE && accessPolicy.hasAuthority("sales_quote:edit")) {
            actions.add("withdraw");
        }
        if (owner && open && accessPolicy.hasAuthority("sales_quote:edit")) actions.add("reopen");
        if (owner && convertible && accessPolicy.hasAuthority("sales_quote:convert")
                && accessPolicy.hasAuthority("sales_order:create")) {
            actions.add("convert");
        }
        if (owner && open && accessPolicy.hasAuthority("sales_quote:reverse")) actions.add("reverse");
        if (accessPolicy.hasAuthority(FINANCE_VIEW) && financeVisible(q)) actions.add("financeReview");
        return actions;
    }

    static String statusBucket(SalesQuote q) {
        short status = q.getStatus() == null ? STATUS_DRAFT : q.getStatus();
        return switch (status) {
            case STATUS_PENDING_FINANCE -> BUCKET_PENDING_FINANCE;
            case STATUS_CONFIRMED -> BUCKET_APPROVED;
            case STATUS_REVERSED -> BUCKET_REVERSED;
            default -> q.getFinanceReturnReason() != null ? BUCKET_FINANCE_REJECTED : BUCKET_DRAFT;
        };
    }

    /**
     * 财务读范围: 待核价、财务确认过的已核价(旧流程销售自审、没有财务确认时间的不算), 以及本轮被财务退回的草稿
     * (退回时间不早于最近一次提交)。销售提交后又撤回的草稿财务看不到。
     */
    static boolean financeVisible(SalesQuote q) { return financeVisible(q,false); }

    static boolean financeVisible(SalesQuote q, boolean includeDeleted) {
        if (q == null || (!includeDeleted && q.isDeleted()) || q.getStatus() == null) return false;
        short status = q.getStatus();
        if (status == STATUS_PENDING_FINANCE) return true;
        if (status == STATUS_CONFIRMED) return q.getFinanceConfirmedAt() != null;
        return status == STATUS_DRAFT
                && q.getFinanceReturnedAt() != null
                && q.getSubmittedAt() != null
                && !q.getFinanceReturnedAt().isBefore(q.getSubmittedAt());
    }

    /** 看不到价格: 既没有订单价格查看权限, 也不是核价人(核价人始终看到完整价格)。 */
    public boolean pricesMasked() {
        return !priceMasker.canView() && !accessPolicy.hasAuthority(FINANCE_VIEW);
    }

    /** 报价按货品标价(本位币)计价, 外币报价转不了订货单; 保存/提交时就拦下。 */
    static final String NON_BASE_CURRENCY_MESSAGE =
            "报价按货品标价(本位币)计价, 币种只能选本位币或不填; 客户文件里的外币单价只作参考";

    public boolean isBaseCurrency(UUID currencyId) {
        if (currencyId == null) return true;
        List<?> rows = em.createNativeQuery("SELECT is_base_currency FROM currencies WHERE id = :id")
                .setParameter("id", currencyId)
                .getResultList();
        return !rows.isEmpty() && Boolean.TRUE.equals(rows.getFirst());
    }

    /** 报价 id → 由它转出的有效订货单。 */
    public Map<UUID, ConvertedOrder> convertedOrders(Collection<UUID> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) return Map.of();
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT source_quote_id, id, bill_no
                        FROM sales_orders
                        WHERE source_quote_id IN (:ids) AND COALESCE(is_deleted, FALSE) = FALSE
                        """)
                .setParameter("ids", List.copyOf(quoteIds))
                .getResultList();
        Map<UUID, ConvertedOrder> out = new HashMap<>();
        for (Object[] row : rows) {
            out.put((UUID) row[0], new ConvertedOrder((UUID) row[1], (String) row[2]));
        }
        return out;
    }

    public record ConvertedOrder(UUID id, String billNo) {
    }

    private void requireNotConverted(UUID quoteId, String message) {
        if (!convertedOrders(List.of(quoteId)).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    static void requireRevision(SalesQuote q, Integer expectedRevision) {
        if (expectedRevision == null || expectedRevision != q.getReviewRevision()) {
            throw new ApiException(ErrorCode.CONFLICT, "报价刚被其他人处理过, 请刷新后再操作");
        }
    }

    private boolean hasObjectActionAuthority() {
        return accessPolicy.hasAuthority("sales_quote:edit")
                || accessPolicy.hasAuthority("sales_quote:delete")
                || accessPolicy.hasAuthority("sales_quote:reverse")
                || accessPolicy.hasAuthority("sales_quote:convert");
    }

    private SalesQuote requireQuote(UUID id) { return requireQuote(id, false); }

    private SalesQuote requireQuote(UUID id, boolean includeDeleted) {
        return quoteRepo.findById(id).filter(q -> includeDeleted || !q.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在"));
    }

    private SalesQuote requireReadableQuote(UUID id) { return requireReadableQuote(id, false); }

    private SalesQuote requireReadableQuote(UUID id, boolean includeDeleted) {
        SalesQuote quote = requireQuote(id, includeDeleted);
        if (accessPolicy.canRead(quote.getMakerId())) return quote;
        if (accessPolicy.hasAuthority(FINANCE_VIEW) && financeVisible(quote,includeDeleted)) return quote;
        throw new ApiException(ErrorCode.NOT_FOUND, "销售报价单不存在");
    }

    private SalesQuote requireWritableQuote(UUID id) {
        SalesQuote quote = requireQuote(id);
        accessPolicy.requireWritable(quote.getMakerId(), "只能操作本人负责的销售报价单");
        return quote;
    }

    private static String appendNote(String remark, String note) {
        if (note == null) return remark;
        return remark == null || remark.isBlank() ? note : remark.strip() + "; " + note;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }

    private QuoteDetail finishHistory(QuoteDetail view, SalesQuote entity, boolean historyRead) {
        if (!historyRead && !entity.isDeleted()) return view;
        return retainedRecords.detail(view, "sales_quotes", entity.getId(), entity.isDeleted(), entity.getDeletedAt(), historyRead);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('sales_quote:view')")
    public java.util.List<com.uten.imp.common.history.RetainedRecordReader.RetainedRow> historyRows(UUID id, Long beforeId, int size) {
        var document=detailHistory(id);
        com.uten.imp.common.history.RetainedRecordAccess.requireUnmaskedCostOriginal(document.isPriceMasked());
        return retainedRecords.children("sales_quotes",id,beforeId,size);
    }
}
