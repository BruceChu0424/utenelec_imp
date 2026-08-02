package com.uten.imp.features.stock;

import com.uten.imp.application.port.ProductionCompletionReversePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.allocation.ProductionMaterialStockLedgerService;
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
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 仓库管理统一单据服务（9 类 doc_type 共用）：CRUD（主+明细）+ 审核状态机 + 库存联动。
 *
 * <p>设计（doc 17）：一个 Service 覆盖全部 9 类——审核时 {@link #applyStockEffect} 按 doc_type
 * 生成 stock_movements（调拨双仓双动、盘点按盘盈亏），红冲反向。取代老库 9 套表 + 触发器。
 *
 * <p>状态机：0草稿 / 1已审 / -1红冲。审核 0→1（写库存）；红冲 1→-1（反向冲销）；编辑/删除仅草稿。
 */
@Service
@RequiredArgsConstructor
public class StockDocService {

    private static final String AUTHORIZED_BALANCE_ADJUSTMENT_SOURCE =
            "AUTHORIZED_BALANCE_ADJUSTMENT:";
    private static final String BALANCE_ADJUSTMENT_PERMISSION = "stock:balance:adjust";

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** DRAW 出库进度（V97）。 */
    private static final short ISSUE_NONE = 0, ISSUE_PARTIAL = 1, ISSUE_FULL = 2;

    /** 来源单据类型（与迁移 source_doc_type='STOCK_DOC' 对齐，报表/流水同源）。 */
    public static final String SRC_STOCK_DOC = "STOCK_DOC";

    /** movement_type（V45 1-12 + 本模块 13/14）。 */
    private static final short T_OTHER_IN = 11, T_OTHER_OUT = 12;
    private static final short T_DRAW = 5, T_WDRAW = 6;
    private static final short T_FINISHED_IN = 13, T_FINISHED_OUT = 14;
    private static final short T_TRANSFER_OUT = 8, T_TRANSFER_IN = 7;
    private static final short T_CHECK_GAIN = 9, T_CHECK_LOSS = 10;

    private static final short DIR_IN = 1, DIR_OUT = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    /** doc_type → 单据号前缀（无映射的 doc_type 如 WASTE 不自动生成，保留客户端值）。 */
    private static final Map<String, DocNumberPrefix> DOC_TYPE_TO_PREFIX = Map.of(
            "TRANSFER", DocNumberPrefix.STOCK_TRANSFER,
            "OTHER_IN", DocNumberPrefix.STOCK_OTHER_IN,
            "OTHER_OUT", DocNumberPrefix.STOCK_OTHER_OUT,
            "DRAW", DocNumberPrefix.STOCK_DRAW,
            "WDRAW", DocNumberPrefix.STOCK_WDRAW,
            "FINISHED_OUT", DocNumberPrefix.STOCK_FINISHED_OUT,
            "FINISHED_IN", DocNumberPrefix.STOCK_FINISHED_IN,
            "CHECK", DocNumberPrefix.STOCK_CHECK);

    private final StockDocumentRepository docRepo;
    private final StockDocumentItemRepository itemRepo;
    private final StockBalanceRepository balanceRepo;
    private final StockService stockService;
    private final StockReservationService reservationService;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final ProductionMaterialStockLedgerService productionMaterialLedger;
    private final ProductionCompletionReversePort productionCompletionReverse;

    // ===== 列表 =====

    @Transactional(readOnly = true)
    public PageResponse<StockDocListItem> list(StockDocQueryFilter f, int page, int size, String sort, String order) {
        Specification<StockDocument> spec = (Root<StockDocument> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.docType() != null && !f.docType().isBlank()) {
                ps.add(cb.equal(root.get("docType"), f.docType()));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                ps.add(cb.like(cb.lower(root.get("billNo")), "%" + f.keyword().toLowerCase() + "%"));
            }
            if (f.warehouseId() != null) ps.add(cb.equal(root.get("warehouseId"), f.warehouseId()));
            if (f.status() != null) ps.add(cb.equal(root.get("status"), f.status()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            if (f.departmentId() != null) ps.add(cb.equal(root.get("departmentId"), f.departmentId()));
            if (f.issueStatus() != null) ps.add(cb.equal(root.get("issueStatus"), f.issueStatus()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"), ALLOWED_SORT));
        Page<StockDocument> p = docRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    // ===== 详情 =====

    @Transactional(readOnly = true)
    public StockDocDetail detail(UUID id) {
        StockDocument d = requireDoc(id);
        List<StockDocItemDto> items = itemRepo.findByDocIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(d, items);
    }

    // ===== CRUD =====

    @Transactional
    public StockDocDetail create(StockDocSaveRequest req) {
        return createInternal(req, null);
    }

    /**
     * 创建由高权限余额调整入口产生的 CHECK 单。
     *
     * <p>结构化来源标记不接受客户端传入，用于幂等约束和后续红冲/删除权限保护。
     */
    @Transactional
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public StockDocDetail createAuthorizedBalanceAdjustment(
            StockDocSaveRequest req,
            String idempotencyKey) {
        return createInternal(req, AUTHORIZED_BALANCE_ADJUSTMENT_SOURCE + idempotencyKey);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public Optional<StockDocDetail> findAuthorizedBalanceAdjustment(String idempotencyKey) {
        return docRepo
                .findBySourceDocNoAndDeletedFalse(
                        AUTHORIZED_BALANCE_ADJUSTMENT_SOURCE + idempotencyKey)
                .map(document -> toDetail(
                        document,
                        itemRepo.findByDocIdOrderByLineNoAsc(document.getId()).stream()
                                .map(this::toItemDto)
                                .toList()));
    }

    private StockDocDetail createInternal(StockDocSaveRequest req, String sourceDocNo) {
        tx.bind();
        StockDocument d = new StockDocument();
        applyHeader(req, d);
        d.setSourceDocNo(sourceDocNo);
        d.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（服务端权威，忽略客户端值）
        d.setStatus(STATUS_DRAFT);
        docRepo.save(d);
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    public StockDocDetail update(UUID id, StockDocSaveRequest req) {
        tx.bind();
        StockDocument d = requireDocForUpdate(id);
        requireBalanceAdjustmentPermission(d);
        rejectGenericMutationOfProductionDocument(d);
        if (d.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        applyHeader(req, d);
        itemRepo.deleteByDocId(id);
        itemRepo.flush();
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        StockDocument d = requireDocForUpdate(id);
        if (isAuthorizedBalanceAdjustment(d)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "授权库存余额调整记录必须永久保留；如需纠正，请由授权人员红冲后重新调整");
        }
        rejectGenericMutationOfProductionDocument(d);
        if (d.getStatus() == STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "已审核单据不可删，请红冲");
        d.setDeleted(true);
        d.setDeletedAt(OffsetDateTime.now());
        docRepo.save(d);
    }

    // ===== 审核 / 红冲（库存联动） =====

    /** 审核：0→1，按 doc_type 写库存（流水+余额）。DRAW 例外：审核=确认领料单，库存由分轮出库产生（V97）。 */
    @Transactional
    public StockDocDetail approve(UUID id) {
        tx.bind();
        StockDocument d = requireDocForUpdate(id);
        requireBalanceAdjustmentPermission(d);
        if (d.getStatus() == null || d.getStatus() != STATUS_DRAFT)
            throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可审核");
        if (("DRAW".equals(d.getDocType()) || "FINISHED_IN".equals(d.getDocType()))
                && d.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "生产领料或成品入库必须指定目标仓库，禁止无库存流水推进业务链");
        }
        if ("DRAW".equals(d.getDocType()) || "FINISHED_IN".equals(d.getDocType())) {
            requireApprovedLinkedProductionPlan(d);
        }
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        if (items.isEmpty()) throw new ApiException(ErrorCode.BUSINESS, "明细为空，不可审核");
        validatePositiveStockItems(d, items, "审核");
        if ("FINISHED_IN".equals(d.getDocType())) {
            productionCompletionReverse.lockFinishedInboundProductionDimensions(
                    d.getId(), d.getWarehouseId());
        }
        lockInventory(items);
        if ("CHECK".equals(d.getDocType())) {
            validateCheckSnapshot(d, items);
        }
        if (!"DRAW".equals(d.getDocType())) {
            applyStockEffect(d, items, +1);
        }
        if ("WDRAW".equals(d.getDocType())) {
            applyGoodReturnLedger(d, items, false);
        }
        if ("FINISHED_IN".equals(d.getDocType())) {
            applyFinishedInChain(d, items, +1); // 业务链：完工入库补预留 + 回写 iqty/produced_qty（V90）
            productionCompletionReverse.afterFinishedInboundApproved(
                    d.getId(), d.getWarehouseId());
            chainNotice.notifyFinishedInbound(d.getId()); // 旁路通知：完工/部分完工→销售，提交后发送
        }
        d.setStatus(STATUS_APPROVED);
        d.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（服务端权威，忽略客户端值）
        docRepo.save(d);
        return detail(id);
    }

    /** 红冲：1→-1，反向冲销库存。DRAW 有已出库量时须先全部反出库（V97）。 */
    @Transactional
    public StockDocDetail reverse(UUID id) {
        tx.bind();
        StockDocument d = requireDocForUpdate(id);
        requireBalanceAdjustmentPermission(d);
        if ("DRAW".equals(d.getDocType()) && isProductionLinked(d.getId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "生产链领料单不能在仓库通用页面红冲；"
                    + "请先在对应执行计划中取消或反向物料流程");
        }
        if (d.getStatus() == null || d.getStatus() != STATUS_APPROVED)
            throw new ApiException(ErrorCode.BUSINESS, "仅已审核单据可红冲");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        if ("FINISHED_IN".equals(d.getDocType())) {
            productionCompletionReverse.lockFinishedInboundProductionDimensions(
                    d.getId(), d.getWarehouseId());
        }
        lockInventory(items);
        if ("DRAW".equals(d.getDocType())) {
            boolean anyIssued = items.stream().anyMatch(it ->
                    it.getIssuedQty() != null && it.getIssuedQty().signum() > 0);
            if (anyIssued) {
                throw new ApiException(ErrorCode.BUSINESS, "领料单已有出库记录，请先全部反出库再红冲");
            }
        } else {
            if ("FINISHED_IN".equals(d.getDocType())) {
                productionCompletionReverse.beforeFinishedInboundReversed(d.getId());
                applyFinishedInChain(d, items, -1);
            }
            if ("WDRAW".equals(d.getDocType())) {
                applyGoodReturnLedger(d, items, true);
            }
            applyStockEffect(d, items, -1);
        }
        d.setStatus(STATUS_REVERSED);
        docRepo.save(d);
        return detail(id);
    }

    // ===== DRAW 部分出库（V97，仓库部门需求：领料单引用 + 部分出库 + 未完成保留） =====

    /** 分轮领料：先消耗物料占用，再扣物理库存；同事务保证可用量不二次下降。 */
    @Transactional
    public StockDocDetail issue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        StockDocument d = requireDrawForIssue(id);
        requireApprovedLinkedProductionPlan(d);
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        ProductionMaterialStockLedgerService.PostingResult posted =
                productionMaterialLedger.issue(
                        d.getId(), d.getWarehouseId(),
                        issueMaterialLines(d, items, req),
                        req.getIdempotencyKey(), currentUser.requireId());
        if (posted.replayed()) return detail(id);
        validateIssueRequest(items, req, false);
        OffsetDateTime ts = OffsetDateTime.now();
        for (StockDocIssueRequest.Line line : req.getLines()) {
            StockDocumentItem item = findItem(items, line.getItemId());
            applyIssueMovement(d, item, line.getQty(), ts, +1);
            item.setIssuedQty(item.getIssuedQty().add(line.getQty()));
            itemRepo.save(item);
        }
        recomputeIssueStatus(d, itemRepo.findByDocIdOrderByLineNoAsc(id));
        return detail(id);
    }

    /** 反出库：幂等预检后先恢复物理库存，再对称恢复 allocation.consumed_qty。 */
    @Transactional
    public StockDocDetail reverseIssue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        StockDocument d = requireDrawForIssue(id);
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        lockInventory(items);
        ProductionMaterialStockLedgerService.PreparedReverse prepared =
                productionMaterialLedger.prepareReverseIssue(
                        d.getId(), d.getWarehouseId(),
                        issueMaterialLines(d, items, req),
                        req.getIdempotencyKey(), currentUser.requireId());
        if (prepared.replayed()) return detail(id);
        validateIssueRequest(items, req, true);
        OffsetDateTime ts = OffsetDateTime.now();
        for (StockDocIssueRequest.Line line : req.getLines()) {
            StockDocumentItem item = findItem(items, line.getItemId());
            applyIssueMovement(d, item, line.getQty(), ts, -1);
        }
        productionMaterialLedger.completeReverseIssue(prepared);
        for (StockDocIssueRequest.Line line : req.getLines()) {
            StockDocumentItem item = findItem(items, line.getItemId());
            item.setIssuedQty(item.getIssuedQty().subtract(line.getQty()));
            itemRepo.save(item);
        }
        recomputeIssueStatus(d, itemRepo.findByDocIdOrderByLineNoAsc(id));
        return detail(id);
    }

    private void validateIssueRequest(
            List<StockDocumentItem> items, StockDocIssueRequest req,
            boolean reverse) {
        if (req == null || req.getLines() == null || req.getLines().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "领料操作明细不能为空");
        }
        Map<UUID, BigDecimal> totals = new HashMap<>();
        for (StockDocIssueRequest.Line line : req.getLines()) {
            StockDocumentItem item = findItem(items, line.getItemId());
            requirePositiveStockItem(item, reverse ? "反出库" : "领料出库");
            totals.merge(item.getId(), line.getQty(), BigDecimal::add);
        }
        for (Map.Entry<UUID, BigDecimal> entry : totals.entrySet()) {
            StockDocumentItem item = findItem(items, entry.getKey());
            BigDecimal limit = reverse
                    ? item.getIssuedQty()
                    : item.getQty().subtract(item.getIssuedQty());
            if (entry.getValue().compareTo(limit) > 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "本次合计数量超过领料行实时可操作数量");
            }
        }
    }

    private List<ProductionMaterialStockLedgerService.MaterialLine>
    issueMaterialLines(
            StockDocument document, List<StockDocumentItem> items,
            StockDocIssueRequest request) {
        return request.getLines().stream().map(line -> {
            StockDocumentItem item = findItem(items, line.getItemId());
            return new ProductionMaterialStockLedgerService.MaterialLine(
                    document.getId(), item.getId(), item.getGoodsId(),
                    item.getColorId(), document.getWarehouseId(), null,
                    line.getQty().multiply(unitRateOrOne(item.getUnitRate())));
        }).toList();
    }

    private void applyGoodReturnLedger(
            StockDocument document, List<StockDocumentItem> items,
            boolean reverse) {
        List<ProductionMaterialStockLedgerService.MaterialLine> lines =
                items.stream().map(item ->
                        new ProductionMaterialStockLedgerService.MaterialLine(
                                document.getId(), item.getId(), item.getGoodsId(),
                                item.getColorId(), document.getWarehouseId(),
                                item.getUpstreamItemId(),
                                item.getQty().multiply(
                                        unitRateOrOne(item.getUnitRate()))))
                        .toList();
        if (reverse) {
            productionMaterialLedger.reverseGoodReturn(
                    document.getId(), document.getWarehouseId(), lines,
                    currentUser.requireId());
        } else {
            productionMaterialLedger.goodReturn(
                    document.getId(), document.getWarehouseId(), lines,
                    currentUser.requireId());
        }
    }

    /** DRAW 出库前置校验：类型 + 已审 + 行锁。 */
    private StockDocument requireDrawForIssue(UUID id) {
        StockDocument d = requireDocForUpdate(id);
        if (!"DRAW".equals(d.getDocType())) {
            throw new ApiException(ErrorCode.BUSINESS, "仅生产领料单支持出库操作");
        }
        if (d.getStatus() == null || d.getStatus() != STATUS_APPROVED) {
            throw new ApiException(ErrorCode.BUSINESS, "领料单须先审核再出库");
        }
        return d;
    }

    /**
     * 生产领料/成品入库审核的服务端最终门槛。生成接口的状态校验不能替代这里：
     * 历史草稿、手工改写或并发状态变化都必须在库存动作前再次核验。
     */
    private void requireApprovedLinkedProductionPlan(StockDocument document) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT p.id, p.status, p.is_canceled, p.is_stopped, p.is_deleted
                FROM plan_draw_links l
                JOIN production_plans p ON p.id = l.plan_id
                WHERE l.draw_id = :docId AND l.is_deleted = false
                ORDER BY p.id
                FOR UPDATE OF p
                """).setParameter("docId", document.getId()));
        if (rows.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产领料/成品入库单必须且只能关联一张有效生产计划");
        }
        Object[] row = rows.getFirst();
        Short status = row[1] == null ? null : ((Number) row[1]).shortValue();
        if (status == null
                || status != STATUS_APPROVED
                || Boolean.TRUE.equals(row[2])
                || Boolean.TRUE.equals(row[3])
                || Boolean.TRUE.equals(row[4])) {
            throw new ApiException(
                    ErrorCode.BUSINESS,
                    "关联生产计划须已审核且未取消、未中止、未删除");
        }
    }

    private StockDocumentItem findItem(List<StockDocumentItem> items, UUID itemId) {
        return items.stream().filter(it -> it.getId().equals(itemId)).findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "明细行不存在于本单: " + itemId));
    }

    private void lockInventory(List<StockDocumentItem> items) {
        stockService.lockInventory(items.stream()
                .filter(it -> it.getGoodsId() != null)
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
    }

    /**
     * 出库/反出库库存流水：数量按本次 qty（×unit_rate 转基本量），金额/重量按 本次/行总量 比例分摊。
     * sign +1=出库（DIR_OUT）/ -1=反出库（反向 DIR_IN）。
     *
     * <p>正向出库遇到任何无效维度都硬失败，绝不能只增加 issued_qty 而不扣库存。
     * 反出库仍允许清理历史上“零换算率/缺仓”等从未产生库存流水、却误增 issued_qty 的脏记录。
     */
    private void applyIssueMovement(StockDocument d, StockDocumentItem it, BigDecimal issueQty,
                                    OffsetDateTime ts, int sign) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        if (issueQty == null || issueQty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "本次领料数量必须大于 0");
        }
        BigDecimal baseQty = issueQty.multiply(rate);

        if (sign < 0) {
            // 旧实现只有“缺仓”或“基本量=0”会跳过库存流水；此时仅回减误增的 issued_qty。
            if (d.getWarehouseId() == null || baseQty.signum() == 0) return;
            if (it.getGoodsId() == null || rate.signum() < 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "历史领料行无法判定原库存流水，禁止自动反出库并需先修复数据");
            }
        } else {
            if (d.getWarehouseId() == null
                    || it.getGoodsId() == null
                    || it.getUnitId() == null
                    || it.getQty() == null
                    || it.getQty().signum() <= 0
                    || rate.signum() <= 0
                    || baseQty.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "领料行缺少仓库、货品、单位、正数数量或有效换算率，禁止出库");
            }
        }

        BigDecimal ratio = it.getQty() == null || it.getQty().signum() == 0
                ? BigDecimal.ZERO
                : issueQty.divide(it.getQty(), 6, java.math.RoundingMode.HALF_UP);
        BigDecimal amount = it.getAmountLocal() == null ? null : it.getAmountLocal().multiply(ratio);
        BigDecimal weight = it.getWeight() == null ? null : it.getWeight().multiply(ratio).multiply(rate);
        stockService.recordMovement(new StockService.MovementRequest(
                ts, T_DRAW, SRC_STOCK_DOC, d.getId(), it.getId(),
                it.getGoodsId(), it.getColorId(), d.getWarehouseId(), (short) (DIR_OUT * sign), baseQty,
                it.getUnitId(), it.getUnitRate(), amount, it.getRemark(), weight));
    }

    private static void requirePositiveStockItem(StockDocumentItem item, String action) {
        if (item.getUnitRate() == null) {
            item.setUnitRate(BigDecimal.ONE);
        }
        BigDecimal rate = item.getUnitRate();
        if (item.getGoodsId() == null
                || item.getUnitId() == null
                || item.getQty() == null
                || item.getQty().signum() <= 0
                || rate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    action + "要求每行货品、单位完整，数量和单位换算率均大于 0");
        }
    }

    private static void validatePositiveStockItems(
            StockDocument document, List<StockDocumentItem> items, String action) {
        if ("CHECK".equals(document.getDocType())) return;
        items.forEach(item -> requirePositiveStockItem(item, action));
    }

    /** 派生 issue_status：全部出完=2 / 有出库=1 / 未出库=0；全出完 is_closed=true，否则复位。 */
    private void recomputeIssueStatus(StockDocument d, List<StockDocumentItem> items) {
        boolean anyIssued = false, allIssued = true;
        for (StockDocumentItem it : items) {
            BigDecimal issued = it.getIssuedQty() == null ? BigDecimal.ZERO : it.getIssuedQty();
            if (issued.signum() > 0) anyIssued = true;
            if (issued.compareTo(it.getQty()) < 0) allIssued = false;
        }
        short st = !anyIssued ? ISSUE_NONE : (allIssued ? ISSUE_FULL : ISSUE_PARTIAL);
        d.setIssueStatus(st);
        d.setClosed(st == ISSUE_FULL);
        docRepo.save(d);
    }

    // ===== 业务链：成品入库 ↔ 订单行（V90，docs/07-业务链路/02 §三） =====

    /**
     * 成品入库链联动：
     * <b>审核（+1）</b>——按 plan_draw_links 找到来源计划，把入库量 FIFO 分摊到挂订单行的计划明细：
     * 回写 production_plan_items.iqty（顺带修复 MRP 依赖但从未回写的缺口）与 links.inbound_qty；
     * 入库即补预留（source=1，绑入库仓）；订单行 produced_qty/reserved_qty 回写，行状态 6部分完工/7可发货；
     * 最后重算计划 is_closed。无计划关联的手工入库单只动库存、不进链。
     * <b>红冲（-1）</b>——先释放本单补的预留（已发货则拒绝，库存不动），再对称回退各累计量。
     */
    private void applyFinishedInChain(StockDocument d, List<StockDocumentItem> items, int sign) {
        List<UUID> planIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT l.plan_id FROM plan_draw_links l
                WHERE l.draw_id = :did AND l.is_deleted = false
                ORDER BY l.plan_id
                """).setParameter("did", d.getId()), UUID.class);
        if (planIds.size() > 1) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "成品入库单关联多张生产计划，禁止猜测业务链归属");
        }
        UUID planId = planIds.isEmpty() ? null : planIds.getFirst();
        if (sign < 0) {
            if (planId != null) {
                validateExactFinishedInReverseMapping(d, items, planId);
            }
            reservationService.releaseBySourceDoc("PRODUCTION_INBOUND", d.getId());
        }
        for (StockDocumentItem it : items) {
            if (it.getGoodsId() == null) continue;
            BigDecimal lineQty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
            if (lineQty.signum() <= 0) continue;
            if (planId == null) continue; // 手工入库：无计划关联不进链
            if (sign > 0 && it.getUpstreamItemId() == null) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "关联生产计划的成品入库行必须明确指向计划行，禁止生成不可逆的 FIFO 分摊");
            }
            allocateFinishedIn(d, it, planId, lineQty, sign);
        }
    }

    /**
     * 红冲不能按“当前 LIFO”猜测历史销售分摊。旧单没有 upstream_item_id，或一个计划行合并
     * 多个销售订单行时，现有表无法唯一还原原入库切片，直接阻断并要求先补分摊台账。
     *
     * <p>可安全自动红冲的范围：每个入库行明确指向计划行，且该计划行最多一个有效销售 link；
     * 同时本单来源预留的“订单行+货品+颜色+基本量”必须与这些唯一 link 完全一致。
     */
    private void validateExactFinishedInReverseMapping(
            StockDocument document, List<StockDocumentItem> items, UUID planId) {
        record SourceKey(UUID orderItemId, UUID goodsId, UUID colorId) {}
        Map<SourceKey, BigDecimal> expected = new HashMap<>();
        for (StockDocumentItem item : items) {
            if (item.getGoodsId() == null) continue;
            if (item.getUpstreamItemId() == null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "旧成品入库行缺少计划行溯源，无法安全还原销售分摊，禁止红冲");
            }
            List<Object[]> planRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT i.goods_id, i.color_id, i.unit_id, COALESCE(i.unit_rate,1)
                    FROM production_plan_items i
                    WHERE i.id = :itemId
                      AND i.plan_id = :planId
                      AND i.is_deleted = false
                    FOR UPDATE OF i
                    """)
                    .setParameter("itemId", item.getUpstreamItemId())
                    .setParameter("planId", planId));
            if (planRows.size() != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "成品入库关联的生产计划行不存在或已删除");
            }
            jakarta.persistence.Query reverseLinkQuery =
                    item.getExecutionSegmentSalesAllocationId() == null
                    ? em.createNativeQuery("""
                    SELECT id, order_item_id
                    FROM plan_order_item_links
                    WHERE plan_item_id = :itemId AND is_deleted = false
                    ORDER BY id
                    FOR UPDATE
                    """)
                    : em.createNativeQuery("""
                    SELECT link.id, allocation.sales_order_item_id
                    FROM execution_segment_sales_allocations allocation
                    JOIN plan_order_item_links link
                      ON link.id = allocation.plan_order_item_link_id
                    WHERE allocation.id = :salesAllocationId
                      AND allocation.execution_segment_id = :segmentId
                      AND link.plan_item_id = :itemId
                    FOR UPDATE OF link
                    """)
                    .setParameter(
                            "salesAllocationId",
                            item.getExecutionSegmentSalesAllocationId())
                    .setParameter("segmentId", item.getExecutionSegmentId());
            reverseLinkQuery.setParameter(
                    "itemId", item.getUpstreamItemId());
            List<Object[]> linkRows =
                    NativeQueryResults.objectArrayRows(reverseLinkQuery);
            if (item.getExecutionSegmentSalesAllocationId() == null
                    && linkRows.size() > 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "合并销售订单的成品入库缺少持久化分摊明细，禁止按当前顺序猜测红冲");
            }
            Object[] planRow = planRows.getFirst();
            BigDecimal planRate = unitRateOrOne((BigDecimal) planRow[3]);
            if (item.getUnitId() == null
                    || planRow[2] == null
                    || planRate.signum() <= 0
                    || !Objects.equals(item.getGoodsId(), planRow[0])
                    || !Objects.equals(item.getColorId(), planRow[1])
                    || !Objects.equals(item.getUnitId(), planRow[2])
                    || unitRateOrOne(item.getUnitRate()).compareTo(planRate) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "成品入库行与原生产计划行的货品、颜色、单位或换算率不一致");
            }
            if (!linkRows.isEmpty()) {
                SourceKey key = new SourceKey(
                        (UUID) linkRows.getFirst()[1], item.getGoodsId(), item.getColorId());
                expected.merge(key, baseQty(item), BigDecimal::add);
            }
        }

        Map<SourceKey, BigDecimal> actual = new HashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT order_item_id, goods_id, color_id, SUM(qty)::numeric
                FROM stock_reservations
                WHERE source_doc_type = 'PRODUCTION_INBOUND'
                  AND source_doc_id = :docId
                  AND is_deleted = false
                GROUP BY order_item_id, goods_id, color_id
                """).setParameter("docId", document.getId()))) {
            actual.put(
                    new SourceKey((UUID) row[0], (UUID) row[1], (UUID) row[2]),
                    (BigDecimal) row[3]);
        }
        if (!sameQuantities(expected, actual)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "成品入库来源预留与当前计划联动不一致，禁止红冲并需先修复分摊数据");
        }
    }

    private static <K> boolean sameQuantities(
            Map<K, BigDecimal> expected, Map<K, BigDecimal> actual) {
        if (!expected.keySet().equals(actual.keySet())) return false;
        return expected.entrySet().stream().allMatch(entry ->
                entry.getValue().compareTo(actual.get(entry.getKey())) == 0);
    }

    /**
     * 成品入库采用两层权威分摊。
     *
     * <p>第一层正向按计划行 {@code fqty-iqty}、红冲按 {@code iqty} 并锁行，确保只有
     * 已审核合格报工可以入库。第二层只对存在
     * {@code plan_order_item_links} 的计划行按 {@code allocated-inbound}/{@code inbound}
     * 分摊销售订单；完全无 link 的计划行不会伪造销售回写。任一层容量不足都会在任何 UPDATE
     * 之前抛错，让库存、计划、销售和预留在同一事务中全回滚。
     */
    private void allocateFinishedIn(StockDocument d, StockDocumentItem it, UUID planId,
                                    BigDecimal lineQty, int sign) {
        String itemRemainExpr = sign > 0
                ? "GREATEST(COALESCE(i.fqty,0) - COALESCE(i.iqty,0), 0)"
                : "GREATEST(COALESCE(i.iqty,0), 0)";
        String itemOrder = sign > 0
                ? " ORDER BY i.line_no NULLS LAST, i.id"
                : " ORDER BY i.line_no DESC NULLS LAST, i.id DESC";
        String upstreamFilter = it.getUpstreamItemId() == null ? "" : " AND i.id = :upstreamItemId";
        jakarta.persistence.Query itemQuery = em.createNativeQuery(
                "SELECT i.id, " + itemRemainExpr + " AS item_remain,"
                        + " i.unit_id, COALESCE(i.unit_rate,1) AS unit_rate"
                        + " FROM production_plan_items i"
                        + " WHERE i.plan_id = :pid AND i.is_deleted = false"
                        + " AND i.goods_id = :gid"
                        + " AND (i.color_id IS NOT DISTINCT FROM CAST(:cid AS uuid))"
                        + " AND " + itemRemainExpr + " > 0"
                        + upstreamFilter
                        + itemOrder
                        + " FOR UPDATE OF i")
                .setParameter("pid", planId)
                .setParameter("gid", it.getGoodsId())
                .setParameter("cid", it.getColorId());
        if (it.getUpstreamItemId() != null) {
            itemQuery.setParameter("upstreamItemId", it.getUpstreamItemId());
        }
        if (it.getUnitId() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "成品入库行缺少单位，禁止回写生产链");
        }
        List<Object[]> itemRows = NativeQueryResults.objectArrayRows(itemQuery);
        BigDecimal stockLineRate = unitRateOrOne(it.getUnitRate());
        if (stockLineRate.signum() <= 0) {
            throw new ApiException(ErrorCode.CONFLICT, "成品入库行单位换算率必须大于 0");
        }
        for (Object[] row : itemRows) {
            UUID planUnitId = (UUID) row[2];
            BigDecimal planUnitRate = unitRateOrOne((BigDecimal) row[3]);
            if (planUnitId == null) {
                throw new ApiException(ErrorCode.CONFLICT, "生产计划行缺少单位，禁止成品入库");
            }
            if (planUnitRate.signum() <= 0) {
                throw new ApiException(ErrorCode.CONFLICT, "生产计划行单位换算率必须大于 0");
            }
            if (!Objects.equals(it.getUnitId(), planUnitId)
                    || stockLineRate.compareTo(planUnitRate) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "成品入库行与生产计划行的单位或换算率不一致");
            }
        }
        List<FinishedInboundAllocator.PlanItemCandidate> itemCandidates = itemRows.stream()
                .map(r -> new FinishedInboundAllocator.PlanItemCandidate(
                        (UUID) r[0], (UUID) r[2], (BigDecimal) r[3], (BigDecimal) r[1]))
                .toList();
        FinishedInboundAllocator.Result<FinishedInboundAllocator.PlanItemAllocation> itemPlan =
                FinishedInboundAllocator.allocatePlanItems(lineQty, itemCandidates);
        requireFullyAllocated(itemPlan.unallocated(),
                "成品入库行数量超过计划行剩余量，未能分摊 "
                        + itemPlan.unallocated().stripTrailingZeros().toPlainString());

        record PlannedWrite(
                FinishedInboundAllocator.PlanItemAllocation planItem,
                List<FinishedInboundAllocator.LinkAllocation> links) {
        }
        List<PlannedWrite> writes = new ArrayList<>();
        for (FinishedInboundAllocator.PlanItemAllocation planAllocation : itemPlan.allocations()) {
            boolean exactSalesAllocation =
                    it.getExecutionSegmentSalesAllocationId() != null;
            String exactReported = """
                    (SELECT COALESCE(SUM(report_item.qty), 0)
                     FROM production_daily_report_items report_item
                     JOIN production_daily_reports report
                       ON report.id = report_item.report_id
                     WHERE report_item.execution_segment_sales_allocation_id =
                           CAST(:salesAllocationId AS uuid)
                       AND report_item.is_deleted = FALSE
                       AND report.is_deleted = FALSE
                       AND report.status = 1)
                    """;
            String exactInbound = """
                    (SELECT COALESCE(SUM(stock_item.qty), 0)
                     FROM stock_document_items stock_item
                     JOIN stock_documents stock_document
                       ON stock_document.id = stock_item.doc_id
                     WHERE stock_item.execution_segment_sales_allocation_id =
                           CAST(:salesAllocationId AS uuid)
                       AND stock_item.is_deleted = FALSE
                       AND stock_document.is_deleted = FALSE
                       AND stock_document.doc_type = 'FINISHED_IN'
                       AND stock_document.status = 1)
                    """;
            String linkRemainExpr = exactSalesAllocation
                    ? (sign > 0
                        ? "GREATEST((" + exactReported + ") - ("
                            + exactInbound + "), 0)"
                        : "GREATEST((" + exactInbound + "), 0)")
                    : (sign > 0
                        ? "GREATEST(COALESCE(l.allocated_qty,0) - COALESCE(l.inbound_qty,0), 0)"
                        : "GREATEST(COALESCE(l.inbound_qty,0), 0)");
            String linkOrder = sign > 0
                    ? " ORDER BY l.created_at, l.id"
                    : " ORDER BY l.created_at DESC, l.id DESC";
            String exactFilter = exactSalesAllocation
                    ? """
                       AND l.id = (
                           SELECT allocation.plan_order_item_link_id
                           FROM execution_segment_sales_allocations allocation
                           WHERE allocation.id =
                               CAST(:salesAllocationId AS uuid)
                             AND allocation.execution_segment_id =
                                 CAST(:executionSegmentId AS uuid)
                       )
                      """
                    : "";
            jakarta.persistence.Query linkQuery = em.createNativeQuery(
                    "SELECT l.id, l.order_item_id, " + linkRemainExpr + " AS link_remain,"
                            + " soi.id AS source_exists, COALESCE(soi.is_deleted,false) AS source_deleted,"
                            + " soi.unit_id, COALESCE(soi.unit_rate,1) AS source_unit_rate,"
                            + " soi.goods_id, soi.color_id, so.id AS order_id"
                            + " FROM plan_order_item_links l"
                            + " LEFT JOIN sales_order_items soi ON soi.id = l.order_item_id"
                            + " LEFT JOIN sales_orders so ON so.id = soi.order_id"
                            + " WHERE l.plan_item_id = :planItemId AND l.is_deleted = false"
                            + exactFilter
                            + linkOrder
                            + " FOR UPDATE OF l")
                    .setParameter("planItemId", planAllocation.planItemId());
            if (exactSalesAllocation) {
                linkQuery.setParameter(
                        "salesAllocationId",
                        it.getExecutionSegmentSalesAllocationId());
                linkQuery.setParameter(
                        "executionSegmentId", it.getExecutionSegmentId());
            }
            List<Object[]> linkRows =
                    NativeQueryResults.objectArrayRows(linkQuery);
            if (!exactSalesAllocation && linkRows.size() > 1) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "合并销售订单的成品入库缺少持久化分摊明细，禁止按顺序猜测销售归属");
            }
            if (linkRows.isEmpty()) {
                writes.add(new PlannedWrite(planAllocation, List.of()));
                continue;
            }

            List<UUID> orderIds = linkRows.stream()
                    .map(row -> (UUID) row[9])
                    .filter(Objects::nonNull)
                    .distinct()
                    .sorted()
                    .toList();
            if (orderIds.size() != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单不存在");
            }
            List<Object[]> lockedOrders = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id, status, is_stopped, is_closed, is_deleted
                    FROM sales_orders
                    WHERE id IN (:ids)
                    ORDER BY id
                    FOR UPDATE
                    """).setParameter("ids", orderIds));
            if (lockedOrders.size() != orderIds.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单不存在");
            }
            if (sign > 0) {
                for (Object[] order : lockedOrders) {
                    Short status = order[1] == null ? null : ((Number) order[1]).shortValue();
                    if (status == null || status != STATUS_APPROVED
                            || Boolean.TRUE.equals(order[2])
                            || Boolean.TRUE.equals(order[3])
                            || Boolean.TRUE.equals(order[4])) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "成品入库关联的销售订单须已审核且未停止、未结案、未删除");
                    }
                }
            }

            List<UUID> orderItemIds = linkRows.stream()
                    .map(row -> (UUID) row[1])
                    .distinct()
                    .sorted()
                    .toList();
            List<Object[]> lockedOrderItems = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                    SELECT id, goods_id, color_id, unit_id, COALESCE(unit_rate,1), is_deleted,
                           COALESCE(chain_status,0)
                    FROM sales_order_items
                    WHERE id IN (:ids)
                    ORDER BY id
                    FOR UPDATE
                    """).setParameter("ids", orderItemIds));
            if (lockedOrderItems.size() != orderItemIds.size()) {
                throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单行不存在");
            }
            Map<UUID, Object[]> lockedOrderItemById = new HashMap<>();
            for (Object[] source : lockedOrderItems) {
                lockedOrderItemById.put((UUID) source[0], source);
            }

            for (Object[] row : linkRows) {
                Object[] source = lockedOrderItemById.get((UUID) row[1]);
                if (source == null || (sign > 0 && (Boolean.TRUE.equals(source[5])
                        || ((Number) source[6]).intValue() <= 0
                        // 8=部分发货，仍允许既有计划的剩余成品继续入库；9=全部发货才拦截。
                        || ((Number) source[6]).intValue() > 8))) {
                    throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单行不存在或已删除");
                }
                if (source[3] == null) {
                    throw new ApiException(ErrorCode.CONFLICT, "计划关联的销售订单行缺少单位");
                }
                BigDecimal sourceRate = unitRateOrOne((BigDecimal) source[4]);
                if (sourceRate.signum() <= 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "计划关联的销售订单行单位换算率必须大于 0");
                }
                if (!Objects.equals(it.getGoodsId(), source[1])
                        || !Objects.equals(it.getColorId(), source[2])) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "成品入库货品或颜色与销售订单行不一致");
                }
                if (!Objects.equals(planAllocation.unitId(), source[3])
                        || planAllocation.unitRate().compareTo(sourceRate) != 0) {
                    throw new ApiException(
                            ErrorCode.CONFLICT,
                            "生产计划行与销售订单行的单位或换算率不一致");
                }
            }

            List<FinishedInboundAllocator.LinkCandidate> linkCandidates = linkRows.stream()
                    .map(row -> new FinishedInboundAllocator.LinkCandidate(
                            (UUID) row[0], (UUID) row[1], (BigDecimal) row[2]))
                    .toList();
            FinishedInboundAllocator.Result<FinishedInboundAllocator.LinkAllocation> linkPlan =
                    FinishedInboundAllocator.allocateLinks(planAllocation.quantity(), linkCandidates);
            requireFullyAllocated(linkPlan.unallocated(),
                    "成品入库数量超过计划订单分摊剩余量，未能分摊 "
                            + linkPlan.unallocated().stripTrailingZeros().toPlainString());
            writes.add(new PlannedWrite(planAllocation, linkPlan.allocations()));
        }

        // 上面两层已完成全量校验；从这里开始才允许写累计量与预留。
        for (PlannedWrite write : writes) {
            BigDecimal planDelta = sign > 0
                    ? write.planItem().quantity()
                    : write.planItem().quantity().negate();
            int planItemUpdated = em.createNativeQuery("""
                            UPDATE production_plan_items
                            SET iqty = COALESCE(iqty,0) + :d
                            WHERE id = :id AND COALESCE(iqty,0) + :d >= 0
                            """)
                    .setParameter("d", planDelta)
                    .setParameter("id", write.planItem().planItemId())
                    .executeUpdate();
            if (planItemUpdated != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "计划入库累计不足，禁止自动吞并红冲错账");
            }
            for (FinishedInboundAllocator.LinkAllocation allocation : write.links()) {
                UUID orderItemId = allocation.orderItemId();
                BigDecimal chunk = allocation.quantity();
                BigDecimal delta = sign > 0 ? chunk : chunk.negate();
                int linkUpdated = em.createNativeQuery("""
                        UPDATE plan_order_item_links
                        SET inbound_qty = COALESCE(inbound_qty,0) + :d, updated_at = now()
                        WHERE id = :linkId AND is_deleted = false
                          AND COALESCE(inbound_qty,0) + :d >= 0
                        """).setParameter("d", delta)
                        .setParameter("linkId", allocation.linkId()).executeUpdate();
                if (linkUpdated != 1) {
                    throw new ApiException(ErrorCode.CONFLICT,
                            "分摊入库累计不足，禁止自动吞并红冲错账");
                }
                if (sign > 0) {
                    BigDecimal reservationBaseQty = write.planItem().toBase(chunk);
                    reservationService.reserve(orderItemId, it.getGoodsId(), it.getColorId(),
                            d.getWarehouseId(), reservationBaseQty, StockReservation.SOURCE_PRODUCTION_IN,
                            "PRODUCTION_INBOUND", d.getId());
                    int orderUpdated = em.createNativeQuery("""
                            UPDATE sales_order_items
                            SET produced_qty = COALESCE(produced_qty,0) + :c,
                                reserved_qty = COALESCE(reserved_qty,0) + :c,
                                chain_status = CASE WHEN COALESCE(chain_status,0) BETWEEN 1 AND 6 THEN
                                    CASE WHEN COALESCE(reserved_qty,0) + :c
                                              >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                                 + COALESCE(returned_qty,0)
                                                 - COALESCE(flag_qty,0)
                                         THEN 7 ELSE 6 END
                                ELSE chain_status END
                            WHERE id = :id
                            """).setParameter("c", chunk).setParameter("id", orderItemId).executeUpdate();
                    if (orderUpdated != 1) {
                        throw new ApiException(ErrorCode.CONFLICT, "成品入库关联订单行不存在");
                    }
                } else {
                    int orderUpdated = em.createNativeQuery("""
                            UPDATE sales_order_items
                            SET produced_qty = COALESCE(produced_qty,0) - :c,
                                reserved_qty = COALESCE(reserved_qty,0) - :c,
                                chain_status = CASE WHEN COALESCE(chain_status,0) IN (6,7) THEN
                                    CASE
                                      WHEN COALESCE(reserved_qty,0) - :c
                                           >= COALESCE(qty,0) - COALESCE(shipped_qty,0)
                                              + COALESCE(returned_qty,0)
                                              - COALESCE(flag_qty,0) THEN 7
                                      WHEN GREATEST(COALESCE(planned_qty,0)
                                            - (COALESCE(produced_qty,0) - :c), 0) > 0 THEN 4
                                      ELSE 2 END
                                ELSE chain_status END
                            WHERE id = :id
                              AND COALESCE(produced_qty,0) >= :c
                              AND COALESCE(reserved_qty,0) >= :c
                            """).setParameter("c", chunk).setParameter("id", orderItemId).executeUpdate();
                    if (orderUpdated != 1) {
                        throw new ApiException(ErrorCode.CONFLICT,
                                "订单完工/预留累计小于成品入库红冲量，禁止自动吞并错账");
                    }
                }
            }
        }
        recomputePlanClosed(planId);
    }

    private static void requireFullyAllocated(BigDecimal unallocated, String message) {
        if (unallocated != null && unallocated.signum() > 0) {
            throw new ApiException(ErrorCode.CONFLICT, message);
        }
    }

    private static BigDecimal unitRateOrOne(BigDecimal unitRate) {
        return unitRate == null ? BigDecimal.ONE : unitRate;
    }

    /** 重算生产计划 is_closed（与 ProductionPlanService.recomputeClosed 同口径）。 */
    private void recomputePlanClosed(UUID planId) {
        em.createNativeQuery("""
                UPDATE production_plans p SET is_closed = (
                    SELECT COALESCE(bool_and(COALESCE(i.qty,0) - COALESCE(i.iqty,0) <= 0), true)
                    FROM production_plan_items i
                    WHERE i.plan_id = p.id AND COALESCE(i.is_deleted, false) = false
                ) WHERE p.id = :pid
                """).setParameter("pid", planId).executeUpdate();
    }

    /**
     * 按 doc_type 生成库存流水（调 {@link StockService#recordMovement}）。
     *
     * @param sign +1=审核（正方向）/ -1=红冲（反方向）
     */
    private void applyStockEffect(StockDocument d, List<StockDocumentItem> items, int sign) {
        OffsetDateTime ts = d.getBillDate() == null ? OffsetDateTime.now()
                : d.getBillDate().atStartOfDay(BusinessTime.ZONE).toOffsetDateTime();
        for (StockDocumentItem it : items) {
            if (it.getGoodsId() == null) continue;
            BigDecimal baseQty = baseQty(it);
            // 基本重量 = 明细 weight × unit_rate（与 baseQty 同口径；无重量则为 null，余额重量不动）。
            BigDecimal baseWgt = baseWeight(it);
            switch (d.getDocType()) {
                case "OTHER_IN" -> move(d, it, T_OTHER_IN, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "OTHER_OUT", "WASTE" -> move(d, it, T_OTHER_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "DRAW" -> move(d, it, T_DRAW, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "WDRAW" -> move(d, it, T_WDRAW, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "FINISHED_IN" -> move(d, it, T_FINISHED_IN, DIR_IN, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "FINISHED_OUT" -> move(d, it, T_FINISHED_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                case "TRANSFER" -> {
                    if (d.getWarehouseId() != null)
                        move(d, it, T_TRANSFER_OUT, DIR_OUT, baseQty, baseWgt, d.getWarehouseId(), ts, sign);
                    if (d.getToWarehouseId() != null)
                        move(d, it, T_TRANSFER_IN, DIR_IN, baseQty, baseWgt, d.getToWarehouseId(), ts, sign);
                }
                case "CHECK" -> {
                    BigDecimal surplus = it.getSurplusQty();
                    if (surplus == null || surplus.signum() == 0) continue;
                    // 盘点只记差额数量；盘盈盘亏无单重口径，重量传 null（不动余额重量，避免错账）。
                    if (surplus.signum() > 0)
                        move(d, it, T_CHECK_GAIN, DIR_IN, surplus, null, d.getWarehouseId(), ts, sign);
                    else
                        move(d, it, T_CHECK_LOSS, DIR_OUT, surplus.abs(), null, d.getWarehouseId(), ts, sign);
                }
                default -> { /* 未识别类型不动库存 */ }
            }
        }
    }

    /** base_qty = qty × unit_rate（库存基本量）。 */
    private BigDecimal baseQty(StockDocumentItem it) {
        BigDecimal qty = it.getQty() == null ? BigDecimal.ZERO : it.getQty();
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        return qty.multiply(rate);
    }

    /** base_weight = weight × unit_rate（V80 即时库存重量基本量）；明细无重量返回 null。 */
    private BigDecimal baseWeight(StockDocumentItem it) {
        if (it.getWeight() == null) return null;
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        return it.getWeight().multiply(rate);
    }

    /** 写一笔流水：审核用 naturalDir，红冲反向（naturalDir × sign）。weight 传正数，由 recordMovement 乘 direction。 */
    private void move(StockDocument d, StockDocumentItem it, short type, short naturalDir,
                      BigDecimal qty, BigDecimal weight, UUID warehouseId, OffsetDateTime ts, int sign) {
        if (warehouseId == null || qty == null || qty.signum() == 0) return;
        short dir = (short) (naturalDir * sign);
        stockService.recordMovement(new StockService.MovementRequest(
                ts, type, SRC_STOCK_DOC, d.getId(), it.getId(),
                it.getGoodsId(), it.getColorId(), warehouseId, dir, qty,
                it.getUnitId(), it.getUnitRate(), it.getAmountLocal(), it.getRemark(), weight));
    }

    // ===== 私有映射 =====

    private void applyHeader(StockDocSaveRequest req, StockDocument d) {
        d.setDocType(req.getDocType());
        // 单据号系统自动生成（服务端权威）：仅新建（billNo 空）时按 doc_type 取号；无映射类型（如 WASTE）保留客户端值；更新保留既有号。
        if (d.getBillNo() == null || d.getBillNo().isBlank()) {
            DocNumberPrefix prefix = DOC_TYPE_TO_PREFIX.get(d.getDocType());
            if (prefix != null) {
                d.setBillNo(docNumberService.nextNumber(prefix));
            }
        }
        d.setBillDate(req.getBillDate());
        d.setWarehouseId(req.getWarehouseId());
        d.setToWarehouseId(req.getToWarehouseId());
        d.setSupplierId(req.getSupplierId());
        d.setClientId(req.getClientId());
        d.setWorkerId(req.getWorkerId());
        // 制单员/审核员为服务端权威字段：建单/审核时由当前登录用户写入，忽略客户端传值（防伪造、划分责任）。
        d.setAssTeam(req.getAssTeam());
        d.setDepartmentId(req.getDepartmentId());
        d.setPlanNo(req.getPlanNo());
        d.setRemark(req.getRemark());
    }

    private List<StockDocItemDto> saveItems(StockDocument d, List<StockDocItemLine> lines) {
        if ("CHECK".equals(d.getDocType())) {
            prepareCheckLines(d, lines);
        }
        List<StockDocItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (StockDocItemLine l : lines) {
            if (!"CHECK".equals(d.getDocType())) {
                normalizeAndValidateSaveLine(d, l, auto);
            }
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType(d.getDocType());
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            it.setColorId(l.getColorId());
            it.setUnitId(l.getUnitId());
            it.setUnitRate(l.getUnitRate());
            it.setQty(l.getQty());
            it.setBaseQty(baseQtyOf(l));
            it.setPrice(l.getPrice());
            it.setAmountOriginal(l.getAmountOriginal());
            it.setAmountLocal(l.getAmountLocal() != null ? l.getAmountLocal() : l.getAmountOriginal());
            it.setWeight(l.getWeight());
            it.setGiftQty(l.getGiftQty() != null ? l.getGiftQty() : BigDecimal.ZERO);
            it.setSurplusQty(l.getSurplusQty());
            it.setCountQty(l.getCountQty());
            it.setPlace(l.getPlace());
            it.setUpstreamItemId(l.getUpstreamItemId());
            it.setExecutionSegmentId(l.getExecutionSegmentId());
            it.setExecutionSegmentSalesAllocationId(
                    l.getExecutionSegmentSalesAllocationId());
            it.setSourceDocNo(l.getSourceDocNo());
            it.setRemark(l.getRemark());
            itemRepo.save(it);
            out.add(toItemDto(it));
            auto++;
        }
        return out;
    }

    /**
     * Captures the authoritative book quantity for a physical-count draft.
     *
     * <p>The client-provided qty/surplus are previews only. The transaction
     * locks every goods/color key, reads the current warehouse balance and
     * persists {@code qty=book snapshot}, {@code surplus=count-book}.
     */
    private void prepareCheckLines(
            StockDocument document, List<StockDocItemLine> lines) {
        requireCheckWarehouse(document);
        if (lines == null || lines.isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "盘点单必须至少包含一条明细");
        }

        Set<InventoryKey> keys = new HashSet<>();
        int auto = 1;
        for (StockDocItemLine line : lines) {
            normalizeAndValidateSaveLine(document, line, auto);
            int lineNo = line.getLineNo() == null ? auto : line.getLineNo();
            if (line.getUnitRate().compareTo(BigDecimal.ONE) != 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行盘点数量必须使用货品基本单位");
            }
            StockCountPolicy.requireCountQuantity(line.getCountQty(), lineNo);
            InventoryKey key = new InventoryKey(line.getGoodsId(), line.getColorId());
            if (!keys.add(key)) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行货品和颜色重复，请合并为一条盘点明细");
            }
            auto++;
        }

        stockService.lockInventory(keys);
        for (StockDocItemLine line : lines) {
            BigDecimal bookQty = currentBalanceQty(
                    document.getWarehouseId(), line.getGoodsId(), line.getColorId());
            line.setQty(bookQty);
            line.setSurplusQty(
                    StockCountPolicy.adjustment(bookQty, line.getCountQty()));
        }
    }

    /**
     * Prevents a stale count sheet from overwriting legitimate movements that
     * were posted after its book snapshot.
     */
    private void validateCheckSnapshot(
            StockDocument document, List<StockDocumentItem> items) {
        requireCheckWarehouse(document);
        Set<InventoryKey> keys = new HashSet<>();
        int auto = 1;
        for (StockDocumentItem item : items) {
            int lineNo = item.getLineNo() == null ? auto : item.getLineNo();
            if (item.getUnitRate() != null
                    && item.getUnitRate().compareTo(BigDecimal.ONE) != 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "第 " + lineNo + " 行盘点快照不是货品基本单位，不能审核");
            }
            StockCountPolicy.requireCountQuantity(item.getCountQty(), lineNo);
            InventoryKey key = new InventoryKey(item.getGoodsId(), item.getColorId());
            if (!keys.add(key)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "第 " + lineNo + " 行货品和颜色重复，不能审核");
            }
            BigDecimal currentQty = currentBalanceQty(
                    document.getWarehouseId(), item.getGoodsId(), item.getColorId());
            StockCountPolicy.requireSnapshotUnchanged(
                    item.getQty(), currentQty, lineNo);
            item.setSurplusQty(
                    StockCountPolicy.adjustment(currentQty, item.getCountQty()));
            auto++;
        }
    }

    private void requireCheckWarehouse(StockDocument document) {
        if (document.getWarehouseId() == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "盘点单必须选择仓库");
        }
    }

    private BigDecimal currentBalanceQty(
            UUID warehouseId, UUID goodsId, UUID colorId) {
        return balanceRepo.findByWarehouseIdAndGoodsIdAndColorId(
                        warehouseId, goodsId, colorId)
                .map(StockBalance::getQty)
                .orElse(BigDecimal.ZERO);
    }

    /**
     * 手工仓库单前端只选货品时，以货品基本单位补齐 unit_id/unit_rate=1；
     * 显式传入的其他单位必须是有效主档且换算率为正。
     */
    private void normalizeAndValidateSaveLine(
            StockDocument document, StockDocItemLine line, int fallbackLineNo) {
        int lineNo = line.getLineNo() == null ? fallbackLineNo : line.getLineNo();
        if (line.getGoodsId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "第 " + lineNo + " 行缺少货品");
        }
        List<Object[]> goodsRows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT g.is_deleted, u.id, COALESCE(u.is_deleted, true)
                FROM goods g
                LEFT JOIN units u ON u.legacy_id = g.unit_legacy_id
                WHERE g.id = :goodsId
                """).setParameter("goodsId", line.getGoodsId()));
        if (goodsRows.size() != 1
                || Boolean.TRUE.equals(goodsRows.getFirst()[0])
                || goodsRows.getFirst()[1] == null
                || Boolean.TRUE.equals(goodsRows.getFirst()[2])) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "第 " + lineNo + " 行货品不存在、已删除或未维护有效基本单位");
        }
        UUID baseUnitId = (UUID) goodsRows.getFirst()[1];
        if (line.getUnitId() == null) {
            line.setUnitId(baseUnitId);
            line.setUnitRate(BigDecimal.ONE);
        } else {
            Number activeUnit = (Number) em.createNativeQuery("""
                    SELECT COUNT(*) FROM units
                    WHERE id = :unitId AND is_deleted = false
                    """).setParameter("unitId", line.getUnitId()).getSingleResult();
            if (activeUnit.longValue() != 1L) {
                throw new ApiException(ErrorCode.CONFLICT, "第 " + lineNo + " 行单位不存在或已删除");
            }
            if (Objects.equals(line.getUnitId(), baseUnitId)) {
                if (line.getUnitRate() == null) line.setUnitRate(BigDecimal.ONE);
                if (line.getUnitRate().compareTo(BigDecimal.ONE) != 0) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,
                            "第 " + lineNo + " 行使用货品基本单位时换算率必须为 1");
                }
            } else if (line.getUnitRate() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "第 " + lineNo + " 行使用非基本单位时必须提供单位换算率");
            }
        }
        if (line.getUnitRate().signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行单位换算率必须大于 0");
        }
        if (!"CHECK".equals(document.getDocType())
                && (line.getQty() == null || line.getQty().signum() <= 0)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "第 " + lineNo + " 行数量必须大于 0");
        }
    }

    private BigDecimal baseQtyOf(StockDocItemLine l) {
        BigDecimal qty = l.getQty() == null ? BigDecimal.ZERO : l.getQty();
        BigDecimal rate = l.getUnitRate() == null ? BigDecimal.ONE : l.getUnitRate();
        return qty.multiply(rate);
    }

    private void applyTotals(StockDocument d, List<StockDocItemDto> items) {
        BigDecimal local = items.stream().map(i -> i.getAmountLocal() == null ? BigDecimal.ZERO : i.getAmountLocal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        BigDecimal original = items.stream().map(i -> i.getAmountOriginal() == null ? BigDecimal.ZERO : i.getAmountOriginal())
                .reduce(BigDecimal.ZERO, BigDecimal::add);
        d.setTotalLocal(local);
        d.setTotalOriginal(original);
        docRepo.save(d);
    }

    private StockDocListItem toList(StockDocument d) {
        return new StockDocListItem(d.getId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getTotalLocal(), d.getStatus(),
                d.isClosed(), d.getLegacyId(), d.getDepartmentId(),
                "DRAW".equals(d.getDocType()) ? d.getIssueStatus() : null);
    }

    private StockDocItemDto toItemDto(StockDocumentItem it) {
        return new StockDocItemDto(it.getId(), it.getLineNo(), it.getGoodsId(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getBaseQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getWeight(), it.getGiftQty(),
                it.getSurplusQty(), it.getCountQty(), it.getPlace(), it.getUpstreamItemId(),
                it.getExecutionSegmentId(),
                it.getExecutionSegmentSalesAllocationId(), it.getSourceDocNo(), it.getRemark(),
                it.getBillDate(), it.getIssuedQty());
    }

    private StockDocDetail toDetail(StockDocument d, List<StockDocItemDto> items) {
        boolean productionLinked = isProductionLinked(d.getId());
        boolean authorizedBalanceAdjustment = isAuthorizedBalanceAdjustment(d);
        boolean canEdit = !productionLinked && !authorizedBalanceAdjustment && d.getStatus() != null
                && d.getStatus() == STATUS_DRAFT;
        boolean canDelete = !productionLinked && !authorizedBalanceAdjustment && d.getStatus() != null
                && d.getStatus() != STATUS_APPROVED;
        String restrictionReason = authorizedBalanceAdjustment
                ? "该单据是授权库存余额调整的永久审计记录，不能编辑或删除"
                : productionLinked
                ? "生产链自动生成单据由执行计划、物料占用和报工共同维护，"
                  + "请在对应生产任务中执行调整或反向操作"
                : null;
        return new StockDocDetail(d.getId(), d.getLegacyId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getSupplierId(), d.getClientId(),
                d.getWorkerId(), d.getMakerId(), d.getApproverId(), d.getAssTeam(), d.getPlanNo(), d.getRemark(),
                d.getTotalOriginal(), d.getTotalLocal(), d.getStatus(), d.isClosed(),
                d.getSourceDocNo(), d.getDepartmentId(), d.getIssueStatus(), items,
                nameResolver.nameOf(d.getMakerId()), d.getCreatedAt(),
                productionLinked, canEdit, canDelete, restrictionReason);
    }

    private boolean isAuthorizedBalanceAdjustment(StockDocument document) {
        return document.getSourceDocNo() != null
                && document.getSourceDocNo().startsWith(
                        AUTHORIZED_BALANCE_ADJUSTMENT_SOURCE);
    }

    private void requireBalanceAdjustmentPermission(StockDocument document) {
        if (!isAuthorizedBalanceAdjustment(document)) return;
        boolean allowed = currentUser.get()
                .map(user -> user.isSuperAdmin()
                        || user.getPermissions().contains(BALANCE_ADJUSTMENT_PERMISSION))
                .orElse(false);
        if (!allowed) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该单据由领导授权调整库存产生，仅授权人员可以审核或红冲");
        }
    }

    private void rejectGenericMutationOfProductionDocument(StockDocument document) {
        if (isProductionLinked(document.getId())) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "该单据由生产链自动生成，不能在仓库通用页面编辑或删除；"
                    + "请到对应生产任务执行调整或反向流程");
        }
    }

    private boolean isProductionLinked(UUID documentId) {
        Object result = em.createNativeQuery(
                        "SELECT fn_is_production_linked_stock_document(CAST(:id AS uuid))")
                .setParameter("id", documentId)
                .getSingleResult();
        return Boolean.TRUE.equals(result);
    }

    private StockDocument requireDoc(UUID id) {
        return docRepo.findById(id).filter(d -> !d.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在"));
    }

    /** 单次数据库往返即取得写锁，避免普通读取与随后加锁之间的陈旧状态窗口。 */
    private StockDocument requireDocForUpdate(UUID id) {
        StockDocument document = em.find(
                StockDocument.class, id, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (document == null || document.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在");
        }
        return document;
    }
}
