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
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmRequest;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmResponse;
import com.uten.imp.features.stock.dto.FinishedInboundConfirmRequest;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.features.stock.dto.StockDocItemDto;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocListItem;
import com.uten.imp.features.stock.dto.StockDocQueryFilter;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
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
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
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
 * 生成 stock_movements（调拨双仓双动、盘点按盘盈亏），红冲反向。
 *
 * <p>状态机：0草稿 / 1已审 / -1红冲。审核 0→1（写库存）；红冲 1→-1（反向冲销）；编辑/删除仅草稿。
 */
@Service
@RequiredArgsConstructor
public class StockDocService {

    private static final String BALANCE_ADJUSTMENT_PERMISSION = "stock:balance:adjust";

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;
    private static final short STATUS_REVERSED = -1;

    /** DRAW 出库进度。 */
    private static final short ISSUE_NONE = 0, ISSUE_PARTIAL = 1, ISSUE_FULL = 2;

    /** 来源单据类型（与迁移 source_doc_type='STOCK_DOC' 对齐，报表/流水同源）。 */
    public static final String SRC_STOCK_DOC = "STOCK_DOC";

    /** movement_type：1-12 共用，13/14 本模块（成品入/出）。 */
    private static final short T_OTHER_IN = 11, T_OTHER_OUT = 12;
    private static final short T_DRAW = 5, T_WDRAW = 6;
    private static final short T_FINISHED_IN = 13, T_FINISHED_OUT = 14;
    private static final short T_TRANSFER_OUT = 8, T_TRANSFER_IN = 7;
    private static final short T_CHECK_GAIN = 9, T_CHECK_LOSS = 10;

    private static final short DIR_IN = 1, DIR_OUT = -1;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额可排序；命中才排序，否则默认 billDate DESC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("billDate", "billDate", "total", "totalLocal");

    /** doc_type → 服务端权威单据号命名空间。 */
    private static final Map<String, DocNumberPrefix> DOC_TYPE_TO_PREFIX = Map.of(
            "TRANSFER", DocNumberPrefix.STOCK_TRANSFER,
            "OTHER_IN", DocNumberPrefix.STOCK_OTHER_IN,
            "OTHER_OUT", DocNumberPrefix.STOCK_OTHER_OUT,
            "DRAW", DocNumberPrefix.STOCK_DRAW,
            "WDRAW", DocNumberPrefix.STOCK_WDRAW,
            "FINISHED_OUT", DocNumberPrefix.STOCK_FINISHED_OUT,
            "FINISHED_IN", DocNumberPrefix.STOCK_FINISHED_IN,
            "CHECK", DocNumberPrefix.STOCK_CHECK,
            "WASTE", DocNumberPrefix.STOCK_WASTE);

    private final StockDocumentRepository docRepo;
    private final StockBalanceAdjustmentCommandRepository balanceAdjustmentCommands;
    private final StockDocumentItemRepository itemRepo;
    private final StockBalanceRepository balanceRepo;
    private final StockService stockService;
    private final StockReservationService reservationService;
    // V476：叶子仓落库校验。字段注入+可空——单测手工构造时缺省跳过，Spring 环境恒注入。
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    private final TxSessionVars tx;
    private final DocNumberService docNumberService;
    private final EntityManager em;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;
    private final com.uten.imp.common.util.EmployeeNameResolver nameResolver;
    private final com.uten.imp.features.notice.ChainNoticeService chainNotice;
    private final ProductionMaterialStockLedgerService productionMaterialLedger;
    private final ProductionCompletionReversePort productionCompletionReverse;
    private final TaskClaimService taskClaim;
    private final StockDocAccessPolicy access;
    private final ProductionStockTaskAccessPolicy productionStockTaskAccess;
    private final com.uten.imp.application.port.PreplanAnalysisPegPort preplanAnalysisPeg;
    private final com.uten.imp.application.port.ProductionQualityInspectionPort
            productionQualityInspection;

    // ===== 列表 =====

    @Transactional(readOnly = true)
    public PageResponse<StockDocListItem> list(StockDocQueryFilter f, int page, int size, String sort, String order) {
        if ("total".equals(sort)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "仓库实物单据不提供成本排序，请在财务或库存价值报表中查看");
        }
        var readScope = access.scope();
        Specification<StockDocument> spec = (Root<StockDocument> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(access.readablePredicate(root, cb, "makerId", readScope));
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
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "billDate"),
                        Map.of("billDate", "billDate")));
        Page<StockDocument> p = docRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toList).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    // ===== 详情 =====

    @Transactional(readOnly = true)
    public StockDocDetail detail(UUID id) {
        StockDocument d = requireDoc(id);
        boolean productionTaskReadable = isProductionLinked(d.getId())
                && productionStockTaskAccess.canAccessWarehouseTasks()
                && (access.hasAuthority("stock_doc:view")
                    || access.hasAuthority("stock_doc:approve")
                    || access.hasAuthority("stock_doc:reverse")
                    || access.hasAuthority("stock_doc:issue")
                    || access.hasAuthority("stock_doc:reverse_issue"));
        if (!productionTaskReadable) {
            access.requireReadable(d.getMakerId(), "仓库单据不存在");
        }
        List<StockDocItemDto> items = itemRepo.findByDocIdOrderByLineNoAsc(id).stream()
                .map(this::toItemDto).toList();
        return toDetail(d, items);
    }

    // ===== CRUD =====

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:create')")
    public StockDocDetail create(StockDocSaveRequest req) {
        return createInternal(req, null);
    }

    /**
     * 创建由高权限余额调整入口产生的 CHECK 单。
     *
     * <p>服务端生成 UUID 命令实体并以 stock_document_id 建立权威关联；
     * 客户端重试键只用于幂等查找，不再写入或解释 source_doc_no。
     */
    @Transactional
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public StockDocDetail createAuthorizedBalanceAdjustment(
            StockDocSaveRequest req,
            String idempotencyKey) {
        return createInternal(req, idempotencyKey);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('stock:balance:adjust')")
    public Optional<StockDocDetail> findAuthorizedBalanceAdjustment(String idempotencyKey) {
        return balanceAdjustmentCommands.findByRequestKey(idempotencyKey)
                .flatMap(command -> docRepo.findById(command.getStockDocumentId()))
                .filter(document -> !document.isDeleted())
                .map(document -> toDetail(
                        document,
                        itemRepo.findByDocIdOrderByLineNoAsc(document.getId()).stream()
                                .map(this::toItemDto)
                                .toList()));
    }

    private StockDocDetail createInternal(
            StockDocSaveRequest req,
            String balanceAdjustmentRequestKey) {
        requireCostWritePermission(req.getItems());
        tx.bind();
        StockDocument d = new StockDocument();
        applyHeader(req, d);
        d.setMakerId(currentUser.requireEmployeeId()); // 制单=当前登录用户（服务端权威，忽略客户端值）
        d.setStatus(STATUS_DRAFT);
        docRepo.save(d);
        if (balanceAdjustmentRequestKey != null) {
            StockBalanceAdjustmentCommand command = new StockBalanceAdjustmentCommand();
            command.setRequestKey(balanceAdjustmentRequestKey);
            command.setStockDocumentId(d.getId());
            balanceAdjustmentCommands.save(command);
        }
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:edit')")
    public StockDocDetail update(UUID id, StockDocSaveRequest req) {
        tx.bind();
        // 编辑认领只保护草稿修改，不授予审核能力。
        taskClaim.requireNoActiveClaimByOther("FULFILLMENT_TASK_EDIT", id.toString());
        StockDocument d = requireDocForUpdate(id);
        access.requireWritable(d.getMakerId(), "只能操作本人负责的仓库单据");
        requireBalanceAdjustmentPermission(d);
        rejectGenericMutationOfProductionDocument(d);
        if (d.getStatus() != STATUS_DRAFT) throw new ApiException(ErrorCode.BUSINESS, "仅草稿单据可编辑");
        requireCostWritePermission(req.getItems());
        requireExistingItemsCostFreeForMaskedUpdate(id);
        applyHeader(req, d);
        itemRepo.deleteByDocId(id);
        itemRepo.flush();
        List<StockDocItemDto> items = saveItems(d, req.getItems());
        applyTotals(d, items);
        return toDetail(d, items);
    }

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:delete')")
    public void delete(UUID id) {
        tx.bind();
        StockDocument d = requireDocForUpdate(id);
        access.requireWritable(d.getMakerId(), "只能操作本人负责的仓库单据");
        if (isAuthorizedBalanceAdjustment(d)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "授权库存余额调整记录必须永久保留；如需纠正，请由授权人员红冲后重新调整");
        }
        rejectGenericMutationOfProductionDocument(d);
        com.uten.imp.common.web.StandardDocumentLifecycleCapabilities.requireDraftForDelete(d.getStatus());
        d.setDeleted(true);
        d.setDeletedAt(OffsetDateTime.now());
        docRepo.save(d);
    }

    // ===== 审核 / 红冲（库存联动） =====

    /**
     * Production reports declare a quantity; warehouse physical acceptance is
     * the final inventory quantity authority. A short acceptance approves only
     * the accepted slice and creates a new, traceable residual draft instead
     * of silently changing fqty or losing the outstanding quantity.
     */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public FinishedInboundBatchConfirmResponse confirmFinishedInboundBatch(
            FinishedInboundBatchConfirmRequest request) {
        tx.bind();
        FinishedInboundBatchCommand command =
                normalizeFinishedInboundBatchRequest(request);
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();
        lockFinishedInboundBatchCommand(
                actorUserId, command.idempotencyKey());
        FinishedInboundBatchConfirmResponse replay =
                findFinishedInboundBatchReplay(
                        actorUserId,
                        command.idempotencyKey(),
                        command.requestHash());
        if (replay != null) return replay;

        prelockProductionDocuments(command.documentIds());
        List<FinishedInboundBatchConfirmResponse.Item> responseItems =
                new ArrayList<>();
        List<FinishedInboundBatchItem> persistedItems = new ArrayList<>();
        int position = 0;
        for (UUID documentId : command.documentIds()) {
            String childKey = finishedInboundBatchChildKey(
                    actorUserId,
                    command.idempotencyKey(),
                    documentId);
            FinishedInboundConfirmRequest itemRequest =
                    fullFinishedInboundAcceptanceRequest(
                            documentId, childKey);
            Map<UUID, BigDecimal> accepted =
                    normalizeFinishedInboundAccepted(itemRequest);
            String itemHash = finishedInboundConfirmationHash(
                    documentId, accepted, null);
            StockDocDetail detail = confirmFinishedInboundAfterPrelock(
                    documentId, itemRequest, accepted, null, itemHash);
            if (detail.getStatus() == null
                    || detail.getStatus() != STATUS_APPROVED
                    || detail.getBillNo() == null
                    || detail.getBillNo().isBlank()) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "批量点收未得到完整的已审核单据结果");
            }
            UUID confirmationId = finishedInboundConfirmationId(documentId);
            FinishedInboundBatchConfirmResponse.Item resultItem =
                    new FinishedInboundBatchConfirmResponse.Item(
                            documentId,
                            detail.getBillNo(),
                            detail.getStatus());
            responseItems.add(resultItem);
            persistedItems.add(new FinishedInboundBatchItem(
                    ++position, confirmationId, resultItem));
        }

        UUID batchId = UUID.randomUUID();
        insertFinishedInboundBatch(
                batchId,
                actorUserId,
                actorEmployeeId,
                command,
                responseItems,
                persistedItems);
        return new FinishedInboundBatchConfirmResponse(
                batchId, false, responseItems.size(), responseItems);
    }

    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public StockDocDetail confirmFinishedInbound(
            UUID id, FinishedInboundConfirmRequest request) {
        tx.bind();
        Map<UUID, BigDecimal> accepted =
                normalizeFinishedInboundAccepted(request);
        String varianceReason = normalizeVarianceReason(
                request == null ? null : request.getVarianceReason());
        String requestHash = finishedInboundConfirmationHash(
                id, accepted, varianceReason);

        prelockProductionDocument(id);

        return confirmFinishedInboundAfterPrelock(
                id, request, accepted, varianceReason, requestHash);
    }

    private StockDocDetail confirmFinishedInboundAfterPrelock(
            UUID id,
            FinishedInboundConfirmRequest request,
            Map<UUID, BigDecimal> accepted,
            String varianceReason,
            String requestHash) {
        taskClaim.requireNoActiveClaimByOther(
                "FULFILLMENT_TASK_APPROVE", id.toString());
        StockDocument document = requireDocForUpdate(id);
        requireOperationWritable(
                document, "stock_doc:approve", "无权点收此成品入库单");
        if (!"FINISHED_IN".equals(document.getDocType())
                || !isProductionLinked(document.getId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "仅生产报工自动生成的成品入库草稿使用实收确认入口");
        }

        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT idempotency_key, request_hash
                                FROM production_finished_in_confirmations
                                WHERE stock_document_id = :documentId
                                FOR UPDATE
                                """)
                        .setParameter("documentId", id));
        if (!replay.isEmpty()) {
            Object[] row = replay.getFirst();
            if (!Objects.equals(row[0], request.getIdempotencyKey().strip())
                    || !Objects.equals(row[1], requestHash)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "该成品入库单已按另一组实收数量确认");
            }
            return detail(id);
        }
        if (document.getStatus() == null
                || document.getStatus() != STATUS_DRAFT) {
            throw new ApiException(ErrorCode.BUSINESS, "仅待点收草稿可确认实收数量");
        }
        if (document.getWarehouseId() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "成品点收必须指定目标仓库");
        }
        UUID planId = requireApprovedLinkedProductionPlan(document);
        List<StockDocumentItem> items =
                itemRepo.findByDocIdOrderByLineNoAsc(id);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "成品入库明细为空");
        }
        Set<UUID> itemIds = items.stream()
                .map(StockDocumentItem::getId)
                .collect(java.util.stream.Collectors.toSet());
        if (!itemIds.equals(accepted.keySet())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "实收确认必须逐行覆盖当前成品入库单全部明细");
        }

        boolean hasVariance = false;
        boolean anyAccepted = false;
        for (StockDocumentItem item : items) {
            if (item.getSourceDailyReportItemId() == null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "历史成品入库行缺少精确报工明细 UUID，禁止仓库按货品猜测点收来源");
            }
            if (item.getAmountOriginal() != null || item.getAmountLocal() != null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "带金额的成品入库草稿不支持仓库点收；生产成品入库为纯数量单据，"
                                + "历史带金额草稿须先受控更正后再点收");
            }
            BigDecimal proposed = requirePositiveQuantity(
                    item.getQty(), "报工待入库数量");
            productionQualityInspection.requireInboundReleased(
                    item.getSourceDailyReportItemId(),
                    item.getId(),
                    proposed);
            BigDecimal actual = accepted.get(item.getId());
            if (actual.compareTo(proposed) > 0) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "实收数量不能超过报工待入库数量");
            }
            anyAccepted |= actual.signum() > 0;
            hasVariance |= actual.compareTo(proposed) < 0;
        }
        if (hasVariance && varianceReason == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "实收少于报工数量时必须填写差异原因");
        }

        if (!anyAccepted) {
            // 整单零实收仍是仓库拒收事实，不得改写已经发生的 FQC PASS。
            // 把全部未消费放行量复制为同来源待点收草稿，供生产重新交付；
            // confirmation/residual 谱系让后续点收复用原 PASS release，绝不重复消费。
            StockDocument residualDocument = newFinishedInboundResidual(document);
            residualDocument.setRemark("仓库整单拒收待重新交付；来源成品入库单 "
                    + document.getBillNo());
            docRepo.saveAndFlush(residualDocument);
            linkResidualFinishedInbound(planId, residualDocument.getId());

            UUID confirmationId = UUID.randomUUID();
            insertFinishedInboundConfirmation(
                    confirmationId, document, residualDocument,
                    request.getIdempotencyKey().strip(), requestHash,
                    "REJECTED", varianceReason);
            for (StockDocumentItem item : items) {
                BigDecimal proposed = item.getQty();
                StockDocumentItem residualItem = copyFinishedInboundResidualItem(
                        item, residualDocument, proposed);
                itemRepo.saveAndFlush(residualItem);
                insertFinishedInboundConfirmationLine(
                        confirmationId, item.getId(), residualItem.getId(),
                        proposed, BigDecimal.ZERO, proposed);
            }
            // 拒收原因只存确认记录：单据备注是生产链守卫的不可变身份列，
            // 详情经 finishedInboundDecision/varianceReason 提供权威展示。
            document.setStatus(STATUS_REVERSED);
            document.setApproverId(currentUser.requireEmployeeId());
            docRepo.saveAndFlush(document);
            chainNotice.notifyFinishedInboundRejected(
                    document.getId(), varianceReason,
                    request.getIdempotencyKey());
            chainNotice.notifyFinishedInboundPending(residualDocument.getId());
            return detail(id);
        }

        lockInventory(items);
        em.createNativeQuery(
                        "SELECT set_config("
                                + "'app.production_finished_in_confirm_doc_id',"
                                + " :documentId, true)")
                .setParameter("documentId", id.toString())
                .getSingleResult();
        StockDocument residualDocument = hasVariance
                ? newFinishedInboundResidual(document)
                : null;
        if (residualDocument != null) {
            docRepo.saveAndFlush(residualDocument);
            linkResidualFinishedInbound(planId, residualDocument.getId());
        }

        UUID confirmationId = UUID.randomUUID();
        insertFinishedInboundConfirmation(
                confirmationId, document, residualDocument,
                request.getIdempotencyKey().strip(), requestHash,
                hasVariance ? "PARTIAL" : "ACCEPTED", varianceReason);
        for (StockDocumentItem item : items) {
            BigDecimal proposed = item.getQty();
            BigDecimal actual = accepted.get(item.getId());
            BigDecimal residual = proposed.subtract(actual);
            item.setReportedQty(proposed);
            StockDocumentItem residualItem = null;
            if (residual.signum() > 0) {
                residualItem = copyFinishedInboundResidualItem(
                        item, residualDocument, residual);
                itemRepo.saveAndFlush(residualItem);
            }
            if (actual.signum() == 0) {
                item.setDeleted(true);
                item.setDeletedAt(OffsetDateTime.now());
            } else {
                applyAcceptedFinishedInboundQuantity(item, actual, proposed);
            }
            itemRepo.save(item);
            insertFinishedInboundConfirmationLine(
                    confirmationId, item.getId(),
                    residualItem == null ? null : residualItem.getId(),
                    proposed, actual, residual);
        }
        itemRepo.flush();
        // 生产成品入库为纯数量单据（金额列已停用，上方已校验为空）：
        // 不回写 total_original/total_local——它们是生产链守卫的不可变列，
        // 且 NULL 即正确值；余量草稿同理。
        em.createNativeQuery(
                        "SELECT set_config("
                                + "'app.production_finished_in_confirm_doc_id',"
                                + " '', true)")
                .getSingleResult();
        if (residualDocument != null) {
            chainNotice.notifyFinishedInboundPending(residualDocument.getId());
        }
        return approveInternal(id, true, false);
    }

    /** 审核：0→1；生产链 DRAW 必须走审核并出库的一段式端点。 */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:approve')")
    public StockDocDetail approve(UUID id) {
        prelockProductionDocument(id);
        return approveInternal(id, false, false);
    }

    private StockDocDetail approveInternal(
            UUID id,
            boolean warehouseQuantityConfirmed,
            boolean allowProductionDrawApproveAndIssue) {
        tx.bind();
        taskClaim.requireNoActiveClaimByOther("FULFILLMENT_TASK_APPROVE", id.toString());
        StockDocument d = requireDocForUpdate(id);
        if ("DRAW".equals(d.getDocType())
                && isProductionLinked(id)
                && !allowProductionDrawApproveAndIssue) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产领料单不能单独审核；请使用“出库”一次完成审核与实物出库");
        }
        requireOperationWritable(
                d, "stock_doc:approve", "无权审核此仓库单据");
        requireBalanceAdjustmentPermission(d);
        if (!warehouseQuantityConfirmed
                && "FINISHED_IN".equals(d.getDocType())
                && isProductionLinked(d.getId())) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产报工生成的成品入库必须由仓库逐行确认实收数量后审核");
        }
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
        captureGoodsSnapshots(
                items,
                StockGoodsSnapshot.MASTER_AT_APPROVAL,
                OffsetDateTime.now());
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
            applyFinishedInChain(d, items, +1); // 业务链：完工入库补预留 + 回写 iqty/produced_qty
        }
        d.setStatus(STATUS_APPROVED);
        d.setApproverId(currentUser.requireEmployeeId()); // 审核=当前登录用户（服务端权威，忽略客户端值）
        docRepo.save(d);
        if ("FINISHED_IN".equals(d.getDocType())) {
            // Flushing the approved status fires the execution-segment completion
            // reconciliation trigger. Recompute the plan only afterwards: the
            // database close guard keeps it open while a segment is IN_PROGRESS.
            em.flush();
            recomputeFinishedInboundPlanClosed(d.getId());
            productionCompletionReverse.afterFinishedInboundApproved(
                    d.getId(), d.getWarehouseId());
            // Freeze notice payload only after all approved business facts exist.
            em.flush();
            chainNotice.notifyFinishedInbound(d.getId()); // 旁路通知：完工/部分完工→销售，提交后发送
        }
        return detail(id);
    }

    /** 红冲：1→-1，反向冲销库存。DRAW 有已出库量时须先取消全部出库。 */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:reverse')")
    public StockDocDetail reverse(UUID id) {
        return reverseInternal(id, false);
    }

    /** Production FINISHED_IN reversal keeps every formerly accepted slice pending. */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:reverse')")
    public StockDocDetail reverseFinishedInbound(UUID id) {
        return reverseInternal(id, true);
    }

    private StockDocDetail reverseInternal(
            UUID id, boolean finishedInboundConfirmationLane) {
        tx.bind();
        prelockProductionDocument(id);
        StockDocument d = requireDocForUpdate(id);
        requireOperationWritable(
                d, "stock_doc:reverse", "无权红冲此仓库单据");
        requireBalanceAdjustmentPermission(d);
        boolean productionLinked = isProductionLinked(d.getId());
        boolean productionFinishedInbound = productionLinked
                && "FINISHED_IN".equals(d.getDocType());
        if (finishedInboundConfirmationLane && !productionFinishedInbound) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "仅仓库已确认的生产成品入库使用专用红冲入口");
        }
        if (!finishedInboundConfirmationLane && productionFinishedInbound) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "生产成品入库必须使用专用红冲入口，以重建已收数量待点收任务");
        }
        if ("DRAW".equals(d.getDocType()) && productionLinked) {
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
        FinishedInboundReversalDraft finishedInboundReversal = null;
        if ("DRAW".equals(d.getDocType())) {
            boolean anyIssued = items.stream().anyMatch(it ->
                    it.getIssuedQty() != null && it.getIssuedQty().signum() > 0);
            if (anyIssued) {
                throw new ApiException(ErrorCode.BUSINESS, "领料单已有出库记录，请先取消全部出库再红冲");
            }
        } else {
            if ("FINISHED_IN".equals(d.getDocType())) {
                // 必须先阻断已经转入正式需求的 PREPLAN_ANALYSIS 归属。此处位于
                // 执行段重开、正式预留释放、计划累计回退和物理库存红冲之前；
                // 缺少一对一可逆链时整个事务保持原状，而不是猜测回退。
                preplanAnalysisPeg.requireFinishedInboundReversible(d.getId());
                productionCompletionReverse.beforeFinishedInboundReversed(d.getId());
                if (productionFinishedInbound) {
                    finishedInboundReversal =
                            createFinishedInboundReversalDraft(d, items);
                }
                applyFinishedInChain(d, items, -1);
            }
            if ("WDRAW".equals(d.getDocType())) {
                applyGoodReturnLedger(d, items, true);
            }
            applyStockEffect(d, items, -1);
        }
        d.setStatus(STATUS_REVERSED);
        docRepo.save(d);
        if ("FINISHED_IN".equals(d.getDocType())) {
            // The wake-up query deliberately accepts only a terminal reversed
            // source. Persist that fact after stock and execution ledgers are
            // reversed, then refresh affected material analyses.
            em.flush();
            productionCompletionReverse.afterFinishedInboundReversed(
                    d.getId(), d.getWarehouseId());
            if (finishedInboundReversal != null) {
                chainNotice.notifyFinishedInboundPending(
                        finishedInboundReversal.documentId());
                chainNotice.notifyFinishedInboundReversed(
                        d.getId(), finishedInboundReversal.documentId());
            }
        }
        return detail(id);
    }

    // ===== DRAW 部分出库（仓库部门需求：领料单引用 + 部分出库 + 未完成保留） =====

    /** Draft DRAW: approval and first issue are atomic; an issue failure rolls approval back. */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:approve') and hasAuthority('stock_doc:issue')")
    public StockDocDetail approveAndIssue(UUID id, StockDocIssueRequest req) {
        prelockProductionDocument(id);
        StockDocument document = requireDocForUpdate(id);
        if (!"DRAW".equals(document.getDocType())
                || document.getStatus() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "只有草稿生产领料单可以直接出库");
        }
        // Response-loss retry: the first atomic call may already have committed
        // approval + issue. The issue ledger owns the idempotency replay, so an
        // approved DRAW must reach it instead of failing on the former draft
        // precondition.
        if (document.getStatus() == STATUS_APPROVED) {
            return issue(id, req);
        }
        if (document.getStatus() != STATUS_DRAFT) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "只有草稿生产领料单可以直接出库");
        }
        approveInternal(id, false, true);
        return issue(id, req);
    }

    /** 分轮领料：先消耗物料占用，再扣物理库存；同事务保证可用量不二次下降。 */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:issue')")
    public StockDocDetail issue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        prelockProductionDocument(id);
        StockDocument d = requireDrawForIssue(id);
        requireOperationWritable(
                d, "stock_doc:issue", "无权发出此生产领料单");
        // 生产链 DRAW：出库即审核口径下必须能证明「已审关联计划 + 逐行唯一执行
        // 工单映射」；手工单（isProductionLinked=false）没有这些事实，不套用
        // 生产侧校验（其可发性由台账层 lockPackageForDraw 的计划包守卫统一收口）。
        if (isProductionLinked(d.getId())) {
            requireApprovedLinkedProductionPlan(d);
            requireExactProductionDrawSegmentMappings(id);
        }
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
        // Notify by exact execution segment after every issue slice. A DRAW may
        // contain several segments; one fully-issued segment must not wait for
        // unrelated rows on the same document.
        chainNotice.notifyProductionDrawIssued(
                d.getId(), req.getIdempotencyKey());
        return detail(id);
    }

    /**
     * A DRAW line deliberately keeps stock_document_items.execution_segment_id
     * null: V157 reserves that column for FINISHED_IN.  Its execution identity
     * is the immutable package-item mapping to one material demand, cross-checked
     * against the DRAW header mapping.  Never fall back to SKU, name or row order.
     */
    private void requireExactProductionDrawSegmentMappings(UUID documentId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT item.id, mapping.id, demand.id,
                                       demand.execution_segment_id,
                                       header.execution_segment_id,
                                       mapping.package_id, demand.package_id,
                                       header.package_id, segment.package_id,
                                       package.status,
                                       package.execution_model_version,
                                       document.warehouse_id,
                                       demand.warehouse_id,
                                       item.goods_id, demand.goods_id,
                                       item.color_id, demand.color_id,
                                       item.unit_id, demand.unit_id,
                                       item.unit_rate,
                                       demand.is_deleted, demand.status,
                                       segment.is_deleted,
                                       demand.plan_id, segment.plan_id,
                                       package.plan_id,
                                       demand.source_plan_item_id,
                                       segment.source_plan_item_id
                                FROM stock_documents document
                                JOIN stock_document_items item
                                  ON item.doc_id = document.id
                                 AND item.is_deleted = FALSE
                                LEFT JOIN production_planning_package_document_items mapping
                                  ON mapping.document_type = 'DRAW'
                                 AND mapping.document_id = document.id
                                 AND mapping.document_item_id = item.id
                                LEFT JOIN production_material_demands demand
                                  ON demand.id = mapping.demand_id
                                LEFT JOIN production_planning_package_documents header
                                  ON header.package_id = mapping.package_id
                                 AND header.document_type = 'DRAW'
                                 AND header.document_id = document.id
                                LEFT JOIN production_planning_packages package
                                  ON package.id = mapping.package_id
                                LEFT JOIN production_execution_segments segment
                                  ON segment.id = demand.execution_segment_id
                                WHERE document.id = :documentId
                                  AND document.doc_type = 'DRAW'
                                  AND document.is_deleted = FALSE
                                ORDER BY item.id, mapping.id
                                """)
                        .setParameter("documentId", documentId));
        if (rows.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产领料单没有可证明执行工单归属的有效明细，禁止出库");
        }
        Set<UUID> mappedItems = new HashSet<>();
        for (Object[] row : rows) {
            UUID itemId = (UUID) row[0];
            if (itemId == null || !mappedItems.add(itemId)) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "生产领料明细存在多个物料需求映射，无法唯一确定执行工单，禁止出库");
            }
            boolean exact = row[1] != null
                    && row[2] != null
                    && row[3] != null
                    && Objects.equals(row[3], row[4])
                    && Objects.equals(row[5], row[6])
                    && Objects.equals(row[5], row[7])
                    && Objects.equals(row[5], row[8])
                    && "CONFIRMED".equals(row[9])
                    && row[10] != null
                    && ((Number) row[10]).intValue() == 1
                    && Objects.equals(row[11], row[12])
                    && Objects.equals(row[13], row[14])
                    && Objects.equals(row[15], row[16])
                    && Objects.equals(row[17], row[18])
                    && row[19] instanceof Number
                    && new BigDecimal(row[19].toString())
                            .compareTo(BigDecimal.ONE) == 0
                    && !Boolean.TRUE.equals(row[20])
                    && !"RELEASED".equals(row[21])
                    && !"REVERSED".equals(row[21])
                    && !Boolean.TRUE.equals(row[22])
                    && Objects.equals(row[23], row[24])
                    && Objects.equals(row[23], row[25])
                    && Objects.equals(row[26], row[27]);
            if (!exact) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "生产领料明细缺少唯一且一致的物料需求→执行工单 UUID 映射，禁止出库");
            }
        }
    }

    /** 取消出库：幂等预检后先恢复物理库存，再对称恢复 allocation.consumed_qty。 */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:reverse_issue')")
    public StockDocDetail reverseIssue(UUID id, StockDocIssueRequest req) {
        tx.bind();
        String cancellationReason = req == null ? null : req.getReason();
        if (cancellationReason == null || cancellationReason.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "取消出库必须填写原因");
        }
        prelockProductionDocument(id);
        StockDocument d = requireDrawForIssue(id);
        boolean wasFullyIssued = d.getIssueStatus() == ISSUE_FULL;
        requireOperationWritable(
                d, "stock_doc:reverse_issue", "无权取消此生产领料单出库");
        List<StockDocumentItem> items = itemRepo.findByDocIdOrderByLineNoAsc(id);
        requireReverseIssueDimensions(d, items, req);
        lockInventory(items);
        ProductionMaterialStockLedgerService.PreparedReverse prepared =
                productionMaterialLedger.prepareReverseIssue(
                        d.getId(), d.getWarehouseId(),
                        issueMaterialLines(d, items, req),
                        req.getIdempotencyKey(), cancellationReason.strip(),
                        currentUser.requireId());
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
        if (wasFullyIssued && d.getIssueStatus() != ISSUE_FULL) {
            chainNotice.notifyProductionDrawIssueReversed(
                    d.getId(), req.getIdempotencyKey());
        }
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
            requirePositiveStockItem(item, reverse ? "取消出库" : "领料出库");
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

    /**
     * Historical rows with an invalid stock dimension cannot be repaired by
     * decrementing issued_qty alone. They need a dedicated, audited
     * reconciliation command that proves whether a physical movement existed.
     */
    private void requireReverseIssueDimensions(
            StockDocument document,
            List<StockDocumentItem> items,
            StockDocIssueRequest request) {
        if (request == null
                || request.getLines() == null
                || request.getLines().isEmpty()) {
            return;
        }
        for (StockDocIssueRequest.Line line : request.getLines()) {
            StockDocumentItem item = findItem(items, line.getItemId());
            BigDecimal rate = unitRateOrOne(item.getUnitRate());
            if (document.getWarehouseId() == null
                    || item.getGoodsId() == null
                    || item.getUnitId() == null
                    || item.getQty() == null
                    || item.getQty().signum() <= 0
                    || rate.signum() <= 0) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "历史领料行缺少仓库、货品、单位、正数数量或有效换算率，"
                                + "禁止普通取消出库；请走专用领料历史对账修复");
            }
        }
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
    private UUID requireApprovedLinkedProductionPlan(StockDocument document) {
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
        return (UUID) row[0];
    }

    static FinishedInboundBatchCommand normalizeFinishedInboundBatchRequest(
            FinishedInboundBatchConfirmRequest request) {
        if (request == null
                || request.getIdempotencyKey() == null
                || request.getDocumentIds() == null
                || request.getDocumentIds().isEmpty()
                || request.getDocumentIds().size() > 50) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "批量点收须包含幂等键和 1 至 50 张单据");
        }
        String key = request.getIdempotencyKey().strip();
        if (key.length() < 8 || key.length() > 128
                || !key.matches("[A-Za-z0-9._:-]+")) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "批量点收幂等键格式无效");
        }
        if (request.getDocumentIds().stream().anyMatch(Objects::isNull)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "批量点收单据不能为空");
        }
        List<UUID> documentIds = request.getDocumentIds().stream()
                .sorted()
                .distinct()
                .toList();
        if (documentIds.size() != request.getDocumentIds().size()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "批量点收不能重复选择同一单据");
        }
        List<String> hashParts = new ArrayList<>();
        hashParts.add("PRODUCTION-FINISHED-IN-CONFIRM-BATCH-V1");
        documentIds.forEach(id -> hashParts.add(id.toString()));
        return new FinishedInboundBatchCommand(
                key,
                documentIds,
                CanonicalFingerprint.sha256(hashParts));
    }

    private void lockFinishedInboundBatchCommand(
            UUID actorUserId, String idempotencyKey) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(:lockKey, CAST(434 AS bigint)))
                        """)
                .setParameter(
                        "lockKey",
                        "PRODUCTION_FINISHED_IN_CONFIRM_BATCH:"
                                + actorUserId + ':' + idempotencyKey)
                .getSingleResult();
    }

    private FinishedInboundBatchConfirmResponse findFinishedInboundBatchReplay(
            UUID actorUserId,
            String idempotencyKey,
            String requestHash) {
        List<Object[]> headers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, request_hash, confirmed_count
                                FROM production_finished_in_confirm_batches
                                WHERE actor_user_id = :actorUserId
                                  AND idempotency_key = :idempotencyKey
                                """)
                        .setParameter("actorUserId", actorUserId)
                        .setParameter("idempotencyKey", idempotencyKey));
        if (headers.isEmpty()) return null;
        Object[] header = headers.getFirst();
        if (!Objects.equals(header[1], requestHash)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该批量点收幂等键已用于不同单据集合");
        }
        UUID batchId = (UUID) header[0];
        int confirmedCount = ((Number) header[2]).intValue();
        List<FinishedInboundBatchConfirmResponse.Item> items =
                NativeQueryResults.objectArrayRows(
                                em.createNativeQuery("""
                                                SELECT stock_document_id,
                                                       bill_no_snapshot,
                                                       status_snapshot
                                                FROM production_finished_in_confirm_batch_items
                                                WHERE batch_id = :batchId
                                                ORDER BY position
                                                """)
                                        .setParameter("batchId", batchId))
                        .stream()
                        .map(row -> new FinishedInboundBatchConfirmResponse.Item(
                                (UUID) row[0],
                                (String) row[1],
                                ((Number) row[2]).shortValue()))
                        .toList();
        if (items.size() != confirmedCount) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "批量点收冻结结果不完整，禁止猜测重放");
        }
        return new FinishedInboundBatchConfirmResponse(
                batchId, true, confirmedCount, items);
    }

    private FinishedInboundConfirmRequest fullFinishedInboundAcceptanceRequest(
            UUID documentId, String idempotencyKey) {
        List<StockDocumentItem> items =
                itemRepo.findByDocIdOrderByLineNoAsc(documentId);
        if (items.isEmpty()) {
            throw new ApiException(ErrorCode.BUSINESS, "成品入库明细为空");
        }
        FinishedInboundConfirmRequest request =
                new FinishedInboundConfirmRequest();
        request.setIdempotencyKey(idempotencyKey);
        List<FinishedInboundConfirmRequest.Line> lines = new ArrayList<>();
        for (StockDocumentItem item : items) {
            if (item.getId() == null || item.getQty() == null) {
                throw new ApiException(
                        ErrorCode.CONFLICT,
                        "成品入库行缺少全量点收身份或数量");
            }
            FinishedInboundConfirmRequest.Line line =
                    new FinishedInboundConfirmRequest.Line();
            line.setItemId(item.getId());
            line.setAcceptedQty(item.getQty());
            lines.add(line);
        }
        request.setLines(lines);
        return request;
    }

    private static String finishedInboundBatchChildKey(
            UUID actorUserId,
            String batchKey,
            UUID documentId) {
        return "FIB-" + CanonicalFingerprint.sha256(List.of(
                "PRODUCTION-FINISHED-IN-CONFIRM-BATCH-ITEM-V1",
                actorUserId.toString(),
                batchKey,
                documentId.toString()));
    }

    private UUID finishedInboundConfirmationId(UUID documentId) {
        List<UUID> ids = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT id
                                FROM production_finished_in_confirmations
                                WHERE stock_document_id = :documentId
                                """, UUID.class)
                        .setParameter("documentId", documentId),
                UUID.class);
        if (ids.size() != 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "批量点收缺少逐单确认结果");
        }
        return ids.getFirst();
    }

    private void insertFinishedInboundBatch(
            UUID batchId,
            UUID actorUserId,
            UUID actorEmployeeId,
            FinishedInboundBatchCommand command,
            List<FinishedInboundBatchConfirmResponse.Item> responseItems,
            List<FinishedInboundBatchItem> persistedItems) {
        String snapshot = finishedInboundBatchResponseSnapshot(
                batchId, responseItems);
        em.createNativeQuery("""
                        INSERT INTO production_finished_in_confirm_batches(
                            id, actor_user_id, actor_employee_id,
                            idempotency_key, request_hash, confirmed_count,
                            response_snapshot)
                        VALUES (
                            :id, :actorUserId, :actorEmployeeId,
                            :idempotencyKey, :requestHash, :confirmedCount,
                            CAST(:responseSnapshot AS jsonb))
                        """)
                .setParameter("id", batchId)
                .setParameter("actorUserId", actorUserId)
                .setParameter("actorEmployeeId", actorEmployeeId)
                .setParameter("idempotencyKey", command.idempotencyKey())
                .setParameter("requestHash", command.requestHash())
                .setParameter("confirmedCount", responseItems.size())
                .setParameter("responseSnapshot", snapshot)
                .executeUpdate();
        for (FinishedInboundBatchItem item : persistedItems) {
            em.createNativeQuery("""
                            INSERT INTO production_finished_in_confirm_batch_items(
                                id, batch_id, confirmation_id,
                                stock_document_id, position,
                                bill_no_snapshot, status_snapshot)
                            VALUES (
                                gen_random_uuid(), :batchId, :confirmationId,
                                :documentId, :position,
                                :billNo, :status)
                            """)
                    .setParameter("batchId", batchId)
                    .setParameter("confirmationId", item.confirmationId())
                    .setParameter("documentId", item.result().documentId())
                    .setParameter("position", item.position())
                    .setParameter("billNo", item.result().billNo())
                    .setParameter("status", item.result().status())
                    .executeUpdate();
        }
    }

    private static String finishedInboundBatchResponseSnapshot(
            UUID batchId,
            List<FinishedInboundBatchConfirmResponse.Item> items) {
        String documentIds = items.stream()
                .map(item -> "\"" + item.documentId() + "\"")
                .reduce((left, right) -> left + "," + right)
                .orElse("");
        return "{\"batchId\":\"" + batchId
                + "\",\"confirmedCount\":" + items.size()
                + ",\"documentIds\":[" + documentIds + "]}";
    }

    private Map<UUID, BigDecimal> normalizeFinishedInboundAccepted(
            FinishedInboundConfirmRequest request) {
        if (request == null
                || request.getIdempotencyKey() == null
                || request.getIdempotencyKey().isBlank()
                || request.getLines() == null
                || request.getLines().isEmpty()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "成品点收缺少幂等键或逐行实收数量");
        }
        Map<UUID, BigDecimal> result = new LinkedHashMap<>();
        request.getLines().stream()
                .sorted(java.util.Comparator.comparing(
                        FinishedInboundConfirmRequest.Line::getItemId,
                        java.util.Comparator.nullsLast(
                                java.util.Comparator.naturalOrder())))
                .forEach(line -> {
                    if (line == null || line.getItemId() == null
                            || line.getAcceptedQty() == null) {
                        throw new ApiException(
                                ErrorCode.VALIDATION_FAILED,
                                "成品点收行缺少明细或实收数量");
                    }
                    BigDecimal qty;
                    try {
                        qty = line.getAcceptedQty().setScale(
                                4, RoundingMode.UNNECESSARY);
                    } catch (ArithmeticException error) {
                        throw new ApiException(
                                ErrorCode.VALIDATION_FAILED,
                                "成品实收数量最多保留四位小数");
                    }
                    if (qty.signum() < 0) {
                        throw new ApiException(
                                ErrorCode.VALIDATION_FAILED,
                                "每行实收数量不能小于 0");
                    }
                    if (result.putIfAbsent(line.getItemId(), qty) != null) {
                        throw new ApiException(
                                ErrorCode.VALIDATION_FAILED,
                                "同一成品入库明细不能重复提交");
                    }
                });
        return Map.copyOf(result);
    }

    private static String normalizeVarianceReason(String value) {
        if (value == null) return null;
        String normalized = value.strip();
        return normalized.isEmpty() ? null : normalized;
    }

    private static String finishedInboundConfirmationHash(
            UUID documentId,
            Map<UUID, BigDecimal> accepted,
            String varianceReason) {
        List<String> parts = new ArrayList<>();
        parts.add("PRODUCTION-FINISHED-IN-CONFIRM-V1");
        parts.add(documentId.toString());
        accepted.entrySet().stream()
                .sorted(Map.Entry.comparingByKey())
                .forEach(entry -> parts.add(
                        entry.getKey() + "|"
                                + entry.getValue().stripTrailingZeros()
                                        .toPlainString()));
        parts.add(Objects.toString(varianceReason, ""));
        return CanonicalFingerprint.sha256(parts);
    }

    private static BigDecimal requirePositiveQuantity(
            BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT, label + "必须大于 0");
        }
        return value.setScale(4, RoundingMode.UNNECESSARY);
    }

    private StockDocument newFinishedInboundResidual(StockDocument source) {
        StockDocument residual = new StockDocument();
        residual.setDocType("FINISHED_IN");
        residual.setBillNo(docNumberService.nextNumber(
                DocNumberPrefix.STOCK_FINISHED_IN));
        residual.setBillDate(BusinessTime.today());
        residual.setWarehouseId(source.getWarehouseId());
        residual.setSupplierId(source.getSupplierId());
        residual.setClientId(source.getClientId());
        residual.setWorkerId(source.getWorkerId());
        residual.setMakerId(source.getMakerId());
        residual.setAssTeam(source.getAssTeam());
        residual.setDepartmentId(source.getDepartmentId());
        residual.setPlanNo(source.getPlanNo());
        residual.setSourceDocNo(source.getSourceDocNo());
        residual.setSourceDailyReportId(source.getSourceDailyReportId());
        residual.setRemark("仓库分批点收余量；来源成品入库单 "
                + source.getBillNo());
        residual.setStatus(STATUS_DRAFT);
        residual.setClosed(false);
        return residual;
    }

    private void linkResidualFinishedInbound(UUID planId, UUID residualId) {
        em.createNativeQuery("""
                        INSERT INTO plan_draw_links(plan_id, draw_id, created_by)
                        VALUES (:planId, :documentId, :actorId)
                        """)
                .setParameter("planId", planId)
                .setParameter("documentId", residualId)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private void insertFinishedInboundConfirmation(
            UUID confirmationId,
            StockDocument source,
            StockDocument residual,
            String idempotencyKey,
            String requestHash,
            String decision,
            String varianceReason) {
        em.createNativeQuery("""
                        INSERT INTO production_finished_in_confirmations(
                            id, stock_document_id, residual_stock_document_id,
                            decision, variance_reason, idempotency_key,
                            request_hash, confirmed_by_employee_id,
                            confirmed_at, created_by)
                        VALUES (
                            :id, :documentId, CAST(:residualId AS uuid),
                            :decision, :reason, :key,
                            :requestHash, :employeeId,
                            now(), :actorId)
                        """)
                .setParameter("id", confirmationId)
                .setParameter("documentId", source.getId())
                .setParameter("residualId",
                        residual == null ? null : residual.getId())
                .setParameter("decision", decision)
                .setParameter("reason", varianceReason)
                .setParameter("key", idempotencyKey)
                .setParameter("requestHash", requestHash)
                .setParameter("employeeId", currentUser.requireEmployeeId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private void insertFinishedInboundConfirmationLine(
            UUID confirmationId,
            UUID stockDocumentItemId,
            UUID residualStockDocumentItemId,
            BigDecimal reportedQty,
            BigDecimal acceptedQty,
            BigDecimal residualQty) {
        em.createNativeQuery("""
                        INSERT INTO production_finished_in_confirmation_items(
                            id, confirmation_id, stock_document_item_id,
                            residual_stock_document_item_id,
                            reported_qty, accepted_qty, residual_qty,
                            created_by)
                        VALUES (
                            gen_random_uuid(), :confirmationId, :itemId,
                            CAST(:residualItemId AS uuid),
                            :reportedQty, :acceptedQty, :residualQty,
                            :actorId)
                        """)
                .setParameter("confirmationId", confirmationId)
                .setParameter("itemId", stockDocumentItemId)
                .setParameter("residualItemId", residualStockDocumentItemId)
                .setParameter("reportedQty", reportedQty)
                .setParameter("acceptedQty", acceptedQty)
                .setParameter("residualQty", residualQty)
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();
    }

    private FinishedInboundReversalDraft createFinishedInboundReversalDraft(
            StockDocument source, List<StockDocumentItem> sourceItems) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT confirmation.id,
                                       confirmation.decision,
                                       confirmed.id,
                                       confirmed.stock_document_item_id,
                                       confirmed.accepted_qty
                                FROM production_finished_in_confirmations
                                     confirmation
                                JOIN production_finished_in_confirmation_items
                                     confirmed
                                  ON confirmed.confirmation_id =
                                     confirmation.id
                                WHERE confirmation.stock_document_id =
                                      :documentId
                                ORDER BY confirmed.id
                                FOR UPDATE OF confirmation, confirmed
                                """)
                        .setParameter("documentId", source.getId()));
        if (rows.isEmpty()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "生产成品入库缺少仓库点收确认，禁止通用红冲");
        }
        UUID confirmationId = (UUID) rows.getFirst()[0];
        String decision = Objects.toString(rows.getFirst()[1], "");
        if ("LEGACY_APPROVED".equals(decision)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "历史成品入库缺少逐行点收来源，须先完成专用来源修复再红冲");
        }
        if (!List.of("ACCEPTED", "PARTIAL").contains(decision)) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "仅已接收或部分接收的点收确认可以专用红冲");
        }
        Number existing = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_finished_in_confirmation_reversals
                        WHERE confirmation_id = :confirmationId
                        """)
                .setParameter("confirmationId", confirmationId)
                .getSingleResult();
        if (existing.longValue() != 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "该成品点收确认已经执行过专用红冲");
        }

        Map<UUID, FinishedInboundAcceptedSlice> acceptedByItem =
                new LinkedHashMap<>();
        for (Object[] row : rows) {
            BigDecimal acceptedQty = row[4] == null
                    ? BigDecimal.ZERO
                    : new BigDecimal(row[4].toString());
            if (acceptedQty.signum() <= 0) continue;
            acceptedByItem.put(
                    (UUID) row[3],
                    new FinishedInboundAcceptedSlice(
                            (UUID) row[2], acceptedQty));
        }
        if (acceptedByItem.size() != sourceItems.size()
                || sourceItems.stream().anyMatch(item -> {
                    FinishedInboundAcceptedSlice slice =
                            acceptedByItem.get(item.getId());
                    return slice == null
                            || item.getQty() == null
                            || item.getQty().compareTo(slice.qty()) != 0
                            || item.getSourceDailyReportItemId() == null;
                })) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "点收确认与当前有效成品入库行不一致，禁止猜测红冲数量");
        }

        UUID planId = requireApprovedLinkedProductionPlan(source);
        StockDocument replacement = newFinishedInboundResidual(source);
        replacement.setRemark(
                "仓库红冲已收数量后重建待点收；来源成品入库单 "
                        + source.getBillNo());
        docRepo.saveAndFlush(replacement);
        linkResidualFinishedInbound(planId, replacement.getId());

        UUID reversalId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO
                            production_finished_in_confirmation_reversals(
                                id, confirmation_id,
                                reversed_stock_document_id,
                                replacement_stock_document_id,
                                idempotency_key,
                                reversed_by_employee_id,
                                reversed_at, created_by)
                        VALUES (
                            :id, :confirmationId, :sourceId, :replacementId,
                            :key, :employeeId, now(), :actorId)
                        """)
                .setParameter("id", reversalId)
                .setParameter("confirmationId", confirmationId)
                .setParameter("sourceId", source.getId())
                .setParameter("replacementId", replacement.getId())
                .setParameter("key",
                        "FINISHED-IN-CONFIRM-REVERSE:" + source.getId())
                .setParameter("employeeId",
                        currentUser.requireEmployeeId())
                .setParameter("actorId", currentUser.requireId())
                .executeUpdate();

        for (StockDocumentItem sourceItem : sourceItems) {
            FinishedInboundAcceptedSlice slice =
                    acceptedByItem.get(sourceItem.getId());
            StockDocumentItem replacementItem =
                    copyFinishedInboundResidualItem(
                            sourceItem, replacement, slice.qty());
            itemRepo.saveAndFlush(replacementItem);
            em.createNativeQuery("""
                            INSERT INTO
                                production_finished_in_confirmation_reversal_items(
                                    id, reversal_id, confirmation_item_id,
                                    replacement_stock_document_item_id,
                                    qty, created_by)
                            VALUES (
                                gen_random_uuid(), :reversalId,
                                :confirmationItemId, :replacementItemId,
                                :qty, :actorId)
                            """)
                    .setParameter("reversalId", reversalId)
                    .setParameter(
                            "confirmationItemId",
                            slice.confirmationItemId())
                    .setParameter(
                            "replacementItemId",
                            replacementItem.getId())
                    .setParameter("qty", slice.qty())
                    .setParameter("actorId", currentUser.requireId())
                    .executeUpdate();
        }
        // 生产成品入库为纯数量单据：total_original/total_local 是生产链守卫的不可变列，
        // 必须保持 NULL（与分批点收余量草稿同口径），不得回写。
        return new FinishedInboundReversalDraft(
                reversalId, replacement.getId());
    }

    private StockDocumentItem copyFinishedInboundResidualItem(
            StockDocumentItem source,
            StockDocument residualDocument,
            BigDecimal residualQty) {
        BigDecimal proposed = source.getQty();
        StockDocumentItem residual = new StockDocumentItem();
        residual.setDocId(residualDocument.getId());
        residual.setBillType("FINISHED_IN");
        residual.setBillNo(residualDocument.getBillNo());
        residual.setBillDate(residualDocument.getBillDate());
        residual.setLineNo(source.getLineNo());
        residual.setGoodsId(source.getGoodsId());
        residual.setGoodsCodeSnapshot(source.getGoodsCodeSnapshot());
        residual.setGoodsNameSnapshot(source.getGoodsNameSnapshot());
        residual.setGoodsSnapshotSource(source.getGoodsSnapshotSource());
        residual.setGoodsSnapshotLockedAt(source.getGoodsSnapshotLockedAt());
        residual.setColorId(source.getColorId());
        residual.setUnitId(source.getUnitId());
        residual.setUnitRate(source.getUnitRate());
        residual.setReportedQty(residualQty);
        residual.setQty(residualQty);
        residual.setBaseQty(residualQty.multiply(unitRateOrOne(
                source.getUnitRate())));
        residual.setPrice(source.getPrice());
        residual.setAmountOriginal(proportional(
                source.getAmountOriginal(), residualQty, proposed));
        residual.setAmountLocal(proportional(
                source.getAmountLocal(), residualQty, proposed));
        residual.setWeight(proportional(
                source.getWeight(), residualQty, proposed));
        residual.setGiftQty(proportional(
                source.getGiftQty(), residualQty, proposed));
        residual.setPlace(source.getPlace());
        residual.setUpstreamItemId(source.getUpstreamItemId());
        residual.setExecutionSegmentId(source.getExecutionSegmentId());
        residual.setExecutionSegmentSalesAllocationId(
                source.getExecutionSegmentSalesAllocationId());
        residual.setSourceDailyReportItemId(source.getSourceDailyReportItemId());
        residual.setSourceDocNo(source.getSourceDocNo());
        residual.setRemark("仓库点收余量；来源行 " + source.getId());
        return residual;
    }

    private void applyAcceptedFinishedInboundQuantity(
            StockDocumentItem item,
            BigDecimal acceptedQty,
            BigDecimal proposedQty) {
        item.setQty(acceptedQty);
        item.setBaseQty(acceptedQty.multiply(unitRateOrOne(
                item.getUnitRate())));
        item.setAmountOriginal(proportional(
                item.getAmountOriginal(), acceptedQty, proposedQty));
        item.setAmountLocal(proportional(
                item.getAmountLocal(), acceptedQty, proposedQty));
        item.setWeight(proportional(
                item.getWeight(), acceptedQty, proposedQty));
        item.setGiftQty(proportional(
                item.getGiftQty(), acceptedQty, proposedQty));
    }

    private static BigDecimal proportional(
            BigDecimal value, BigDecimal part, BigDecimal whole) {
        if (value == null) return null;
        if (whole == null || whole.signum() <= 0) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "成品点收来源数量无效，不能按比例拆分");
        }
        return value.multiply(part).divide(
                whole, 4, RoundingMode.HALF_UP);
    }

    private StockDocumentItem findItem(List<StockDocumentItem> items, UUID itemId) {
        return items.stream().filter(it -> it.getId().equals(itemId)).findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.VALIDATION_FAILED, "明细行不存在于本单: " + itemId));
    }

    /**
     * Canonical production-stock lock prelude:
     * inventory dimensions -&gt; plan/package/segment -&gt; stock document/items.
     *
     * <p>This query phase is intentionally read-only until all advisory and
     * production graph locks are held. Production-linked items are database
     * immutable, so the later document lock can safely revalidate the same
     * identities without accepting a stale mutation.</p>
     */
    private void prelockProductionDocuments(List<UUID> documentIds) {
        List<UUID> orderedIds = documentIds == null
                ? List.of()
                : documentIds.stream()
                .filter(Objects::nonNull)
                .distinct()
                .sorted()
                .toList();
        if (orderedIds.isEmpty()) return;
        // A transaction-scoped lane prevents two overlapping batches from
        // interleaving their per-document canonical preludes in opposite
        // inventory/production-graph orders. Single-document writers still
        // use the same canonical prelude and can only wait on one document.
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(
                                'PRODUCTION_FINISHED_IN_CONFIRM_BATCH_LOCK_ORDER',
                                CAST(434 AS bigint)))
                        """)
                .getSingleResult();
        List<Object[]> documentRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, warehouse_id, doc_type
                                FROM stock_documents
                                WHERE id IN (:documentIds)
                                  AND is_deleted = FALSE
                                ORDER BY id
                                """)
                        .setParameter("documentIds", orderedIds));
        List<Object[]> dimensions = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT DISTINCT goods_id, color_id
                                FROM stock_document_items
                                WHERE doc_id IN (:documentIds)
                                  AND is_deleted = FALSE
                                  AND goods_id IS NOT NULL
                                ORDER BY goods_id, color_id NULLS FIRST
                                """)
                        .setParameter("documentIds", orderedIds));
        stockService.lockInventory(dimensions.stream()
                .map(row -> new InventoryKey(
                        (UUID) row[0], (UUID) row[1]))
                .toList());
        for (Object[] document : documentRows) {
            if ("FINISHED_IN".equals(document[2])) {
                productionCompletionReverse
                        .lockFinishedInboundProductionDimensions(
                                (UUID) document[0], (UUID) document[1]);
            }
        }
        lockProductionDocumentGraphs(orderedIds);
        lockFinishedInboundBatchAllocationGraph(orderedIds);
        lockFinishedInboundBatchDocuments(orderedIds);
    }

    private void lockProductionDocumentGraphs(List<UUID> documentIds) {
        List<UUID> planIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT plan.id
                                FROM plan_draw_links link
                                JOIN production_plans plan
                                  ON plan.id = link.plan_id
                                 AND plan.is_deleted = FALSE
                                WHERE link.draw_id IN (:documentIds)
                                  AND link.is_deleted = FALSE
                                ORDER BY plan.id, link.id
                                FOR UPDATE OF link, plan
                                """, UUID.class)
                        .setParameter("documentIds", documentIds), UUID.class)
                .stream().distinct().toList();
        if (planIds.isEmpty()) return;
        List<UUID> packageIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT package.id
                                FROM production_planning_packages package
                                WHERE package.plan_id IN (:planIds)
                                  AND package.is_deleted = FALSE
                                ORDER BY package.plan_id, package.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("planIds", planIds), UUID.class);
        if (packageIds.isEmpty()) return;
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT segment.id
                                FROM production_execution_segments segment
                                WHERE segment.package_id IN (:packageIds)
                                  AND segment.is_deleted = FALSE
                                ORDER BY segment.package_id, segment.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("packageIds", packageIds), UUID.class);
    }

    private void lockFinishedInboundBatchAllocationGraph(
            List<UUID> documentIds) {
        List<UUID> planItemIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT plan_item.id
                                FROM stock_document_items stock_item
                                JOIN production_plan_items plan_item
                                  ON plan_item.id = stock_item.upstream_item_id
                                 AND plan_item.is_deleted = FALSE
                                WHERE stock_item.doc_id IN (:documentIds)
                                  AND stock_item.is_deleted = FALSE
                                ORDER BY plan_item.id
                                FOR UPDATE OF plan_item
                                """, UUID.class)
                        .setParameter("documentIds", documentIds), UUID.class)
                .stream().distinct().toList();
        if (planItemIds.isEmpty()) return;
        List<Object[]> linkRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT link.id, link.order_item_id
                                FROM plan_order_item_links link
                                WHERE link.plan_item_id IN (:planItemIds)
                                  AND link.is_deleted = FALSE
                                ORDER BY link.id
                                FOR UPDATE
                                """)
                        .setParameter("planItemIds", planItemIds));
        List<UUID> orderItemIds = linkRows.stream()
                .map(row -> (UUID) row[1])
                .filter(Objects::nonNull)
                .distinct()
                .sorted()
                .toList();
        if (orderItemIds.isEmpty()) return;
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT sales_order.id
                                FROM sales_order_items sales_item
                                JOIN sales_orders sales_order
                                  ON sales_order.id = sales_item.order_id
                                WHERE sales_item.id IN (:orderItemIds)
                                ORDER BY sales_order.id, sales_item.id
                                FOR UPDATE OF sales_order
                                """, UUID.class)
                        .setParameter("orderItemIds", orderItemIds), UUID.class);
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT sales_item.id
                                FROM sales_order_items sales_item
                                WHERE sales_item.id IN (:orderItemIds)
                                ORDER BY sales_item.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("orderItemIds", orderItemIds), UUID.class);
    }

    private void lockFinishedInboundBatchDocuments(List<UUID> documentIds) {
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT document.id
                                FROM stock_documents document
                                WHERE document.id IN (:documentIds)
                                  AND document.is_deleted = FALSE
                                ORDER BY document.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("documentIds", documentIds), UUID.class);
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT item.id
                                FROM stock_document_items item
                                WHERE item.doc_id IN (:documentIds)
                                  AND item.is_deleted = FALSE
                                ORDER BY item.doc_id,
                                         item.line_no NULLS LAST,
                                         item.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("documentIds", documentIds), UUID.class);
    }

    private void prelockProductionDocument(UUID documentId) {
        if (!isProductionLinked(documentId)) return;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT document.warehouse_id,
                                       document.doc_type,
                                       item.goods_id,
                                       item.color_id
                                FROM stock_documents document
                                LEFT JOIN stock_document_items item
                                  ON item.doc_id = document.id
                                 AND item.is_deleted = FALSE
                                WHERE document.id = :documentId
                                  AND document.is_deleted = FALSE
                                ORDER BY item.goods_id,
                                         item.color_id NULLS FIRST,
                                         item.id
                                """)
                        .setParameter("documentId", documentId));
        if (rows.isEmpty()) return;
        UUID warehouseId = (UUID) rows.getFirst()[0];
        String documentType = (String) rows.getFirst()[1];
        List<InventoryKey> dimensions = rows.stream()
                .filter(row -> row[2] != null)
                .map(row -> new InventoryKey(
                        (UUID) row[2], (UUID) row[3]))
                .distinct()
                .toList();
        if ("FINISHED_IN".equals(documentType)) {
            productionCompletionReverse.lockFinishedInboundProductionDimensions(
                    documentId, warehouseId);
        } else {
            stockService.lockInventory(dimensions);
        }
        lockProductionDocumentGraph(documentId);
    }

    private void lockProductionDocumentGraph(UUID documentId) {
        List<UUID> planIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT plan.id
                                FROM plan_draw_links link
                                JOIN production_plans plan
                                  ON plan.id = link.plan_id
                                 AND plan.is_deleted = FALSE
                                WHERE link.draw_id = :documentId
                                  AND link.is_deleted = FALSE
                                ORDER BY plan.id, link.id
                                FOR UPDATE OF link, plan
                                """, UUID.class)
                        .setParameter("documentId", documentId), UUID.class)
                .stream().distinct().toList();
        if (planIds.isEmpty()) return;
        List<UUID> packageIds = NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT package.id
                                FROM production_planning_packages package
                                WHERE package.plan_id IN (:planIds)
                                  AND package.is_deleted = FALSE
                                ORDER BY package.plan_id, package.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("planIds", planIds), UUID.class);
        if (packageIds.isEmpty()) return;
        NativeQueryResults.typedRows(
                em.createNativeQuery("""
                                SELECT segment.id
                                FROM production_execution_segments segment
                                WHERE segment.package_id IN (:packageIds)
                                  AND segment.is_deleted = FALSE
                                ORDER BY segment.package_id, segment.id
                                FOR UPDATE
                                """, UUID.class)
                        .setParameter("packageIds", packageIds), UUID.class);
    }

    private void lockInventory(List<StockDocumentItem> items) {
        stockService.lockInventory(items.stream()
                .filter(it -> it.getGoodsId() != null)
                .map(it -> new InventoryKey(it.getGoodsId(), it.getColorId()))
                .toList());
    }

    /**
     * 出库/取消出库库存流水：数量按本次 qty（×unit_rate 转基本量），金额/实际总重量按
     * 本次/行总量比例分摊；重量与数量换算率无关。
     * sign +1=出库（DIR_OUT）/ -1=取消出库（反向 DIR_IN）。
     *
     * <p>正反向都要求完整、正数的库存维度。历史异常不得只减
     * issued_qty；必须走能够证明原物理流水的专用对账修复。</p>
     */
    private void applyIssueMovement(StockDocument d, StockDocumentItem it, BigDecimal issueQty,
                                    OffsetDateTime ts, int sign) {
        BigDecimal rate = it.getUnitRate() == null ? BigDecimal.ONE : it.getUnitRate();
        if (issueQty == null || issueQty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "本次领料数量必须大于 0");
        }
        BigDecimal baseQty = issueQty.multiply(rate);

        if (d.getWarehouseId() == null
                || it.getGoodsId() == null
                || it.getUnitId() == null
                || it.getQty() == null
                || it.getQty().signum() <= 0
                || rate.signum() <= 0
                || baseQty.signum() <= 0) {
            String message = sign < 0
                    ? "历史领料行无法证明原库存流水，禁止普通取消出库；"
                            + "请走专用领料历史对账修复"
                    : "领料行缺少仓库、货品、单位、正数数量或有效换算率，禁止出库";
            throw new ApiException(ErrorCode.CONFLICT, message);
        }

        BigDecimal ratio = it.getQty() == null || it.getQty().signum() == 0
                ? BigDecimal.ZERO
                : issueQty.divide(it.getQty(), 6, java.math.RoundingMode.HALF_UP);
        BigDecimal amount = it.getAmountLocal() == null ? null : it.getAmountLocal().multiply(ratio);
        BigDecimal weight = it.getWeight() == null ? null : it.getWeight().multiply(ratio);
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

    // ===== 业务链：成品入库 ↔ 订单行（docs/07-业务链路/02 §三） =====

    /**
     * 成品入库链联动：
     * <b>审核（+1）</b>——按 plan_draw_links 找到来源计划，把入库量 FIFO 分摊到挂订单行的计划明细：
     * 回写 production_plan_items.iqty 与 links.inbound_qty；
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
                  AND owner_type = 'SALES_ORDER_ITEM'
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
        // 分析备料绑定（V298）：物料分析来源计划的完工入库，未被销售订单链接覆盖的
        // 产出量绑定回来源分析（自制备料回仓）；红冲由 applyFinishedInChain(-1) 的
        // releaseBySourceDoc('PRODUCTION_INBOUND') 对称释放。
        if (sign > 0) {
            List<com.uten.imp.application.port.PreplanAnalysisPegPort
                    .FinishedInboundSlice> pegLines = new ArrayList<>();
            for (PlannedWrite write : writes) {
                BigDecimal linkedQty = write.links().stream()
                        .map(FinishedInboundAllocator.LinkAllocation::quantity)
                        .reduce(BigDecimal.ZERO, BigDecimal::add);
                BigDecimal unlinked = write.planItem().quantity().subtract(linkedQty);
                if (unlinked.signum() > 0) {
                    pegLines.add(new com.uten.imp.application.port
                            .PreplanAnalysisPegPort.FinishedInboundSlice(
                            it.getId(),
                            write.planItem().planItemId(),
                            it.getGoodsId(),
                            it.getColorId(),
                            write.planItem().toBase(unlinked)));
                }
            }
            if (!pegLines.isEmpty()) {
                preplanAnalysisPeg.pegFinishedInbound(
                        d.getId(), planId, d.getWarehouseId(), pegLines);
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

    private void recomputeFinishedInboundPlanClosed(UUID stockDocumentId) {
        List<UUID> planIds = NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT DISTINCT link.plan_id
                FROM plan_draw_links link
                WHERE link.draw_id = :documentId
                  AND link.is_deleted = FALSE
                ORDER BY link.plan_id
                """).setParameter("documentId", stockDocumentId), UUID.class);
        if (planIds.size() > 1) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "成品入库单关联多张生产计划，禁止猜测计划结案归属");
        }
        if (!planIds.isEmpty()) {
            recomputePlanClosed(planIds.getFirst());
        }
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
            // weight 是本行实际总重量，不乘数量换算率；无重量则为 null，余额重量不动。
            BigDecimal actualWeight = actualWeight(it);
            switch (d.getDocType()) {
                case "OTHER_IN" -> move(d, it, T_OTHER_IN, DIR_IN, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "OTHER_OUT", "WASTE" -> move(d, it, T_OTHER_OUT, DIR_OUT, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "DRAW" -> move(d, it, T_DRAW, DIR_OUT, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "WDRAW" -> move(d, it, T_WDRAW, DIR_IN, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "FINISHED_IN" -> move(d, it, T_FINISHED_IN, DIR_IN, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "FINISHED_OUT" -> move(d, it, T_FINISHED_OUT, DIR_OUT, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                case "TRANSFER" -> {
                    if (d.getWarehouseId() != null)
                        move(d, it, T_TRANSFER_OUT, DIR_OUT, baseQty, actualWeight, d.getWarehouseId(), ts, sign);
                    if (d.getToWarehouseId() != null)
                        move(d, it, T_TRANSFER_IN, DIR_IN, baseQty, actualWeight, d.getToWarehouseId(), ts, sign);
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

    /** 本行实际总重量；与单据数量的 unit_rate 无关。 */
    private BigDecimal actualWeight(StockDocumentItem it) {
        return it.getWeight();
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
        // 单据号系统自动生成（服务端权威）：仅新建时按 doc_type 取号；更新保留既有号。
        if (d.getBillNo() == null || d.getBillNo().isBlank()) {
            DocNumberPrefix prefix = DOC_TYPE_TO_PREFIX.get(d.getDocType());
            if (prefix != null) {
                d.setBillNo(docNumberService.nextNumber(prefix));
            }
        }
        d.setBillDate(req.getBillDate());
        // V476 运营红线：仓库单据必须落到具体叶子仓；主仓库只作查询聚合。
        if (warehouseScopes != null) {
            warehouseScopes.requireLeafWarehouse(req.getWarehouseId(), "仓库");
            warehouseScopes.requireLeafWarehouse(req.getToWarehouseId(), "调入仓");
        }
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
        requireCostWritePermission(lines);
        if ("CHECK".equals(d.getDocType())) {
            prepareCheckLines(d, lines);
        } else {
            int lineNo = 1;
            for (StockDocItemLine line : lines) {
                normalizeAndValidateSaveLine(d, line, lineNo);
                lineNo++;
            }
        }
        Map<UUID, StockGoodsSnapshot> goodsSnapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        lines.stream().map(StockDocItemLine::getGoodsId).toList(),
                        StockGoodsSnapshot.MASTER_AT_SAVE);
        List<StockDocItemDto> out = new ArrayList<>(lines.size());
        int auto = 1;
        for (StockDocItemLine l : lines) {
            StockDocumentItem it = new StockDocumentItem();
            it.setDocId(d.getId());
            it.setBillType(d.getDocType());
            it.setBillNo(d.getBillNo());
            it.setBillDate(d.getBillDate());
            it.setLineNo(l.getLineNo() != null ? l.getLineNo() : auto);
            it.setGoodsId(l.getGoodsId());
            StockGoodsSnapshot.require(
                            goodsSnapshots, l.getGoodsId(), "仓库单据明细")
                    .applyTo(it, null);
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
     * 仓库普通制单是数量作业。无 goods:cost:view 时，客户端不得盲写单价或金额；
     * 三个字段全部为 null 的纯数量单据保持原流程。
     */
    private void requireCostWritePermission(List<StockDocItemLine> lines) {
        if (canViewCost() || lines == null) return;
        for (int index = 0; index < lines.size(); index++) {
            StockDocItemLine line = lines.get(index);
            if (line != null && (line.getPrice() != null
                    || line.getAmountOriginal() != null
                    || line.getAmountLocal() != null)) {
                int lineNo = line.getLineNo() == null ? index + 1 : line.getLineNo();
                throw new ApiException(
                        ErrorCode.FORBIDDEN,
                        "第 " + lineNo + " 行无编辑货品成本权限("
                                + StockCostMasker.PERMISSION + ")");
            }
        }
    }

    /**
     * 无成本权限的编辑请求会把隐藏字段回传为 null，而 update 采用删旧重建明细。
     * 历史草稿只要已有任一价格/金额，禁止走通用编辑，避免把真实成本静默清零。
     */
    private void requireExistingItemsCostFreeForMaskedUpdate(UUID documentId) {
        if (canViewCost()) return;
        boolean hasStoredCost = itemRepo.findByDocIdOrderByLineNoAsc(documentId).stream()
                .anyMatch(item -> item.getPrice() != null
                        || item.getAmountOriginal() != null
                        || item.getAmountLocal() != null);
        if (hasStoredCost) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "该仓库单据含成本金额，无查看货品成本权限("
                            + StockCostMasker.PERMISSION + ")时禁止通用编辑");
        }
    }

    private void captureGoodsSnapshots(
            List<StockDocumentItem> items,
            String source,
            OffsetDateTime lockedAt) {
        Map<UUID, StockGoodsSnapshot> snapshots =
                StockGoodsSnapshot.fromMaster(
                        em,
                        items.stream().map(StockDocumentItem::getGoodsId).toList(),
                        source);
        for (StockDocumentItem item : items) {
            StockGoodsSnapshot.require(
                            snapshots, item.getGoodsId(), "仓库单据明细")
                    .applyTo(item, lockedAt);
        }
        itemRepo.saveAll(items);
        itemRepo.flush();
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
                LEFT JOIN units u ON u.id = g.unit_id
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
        boolean canViewCost = canViewCost();
        return new StockDocListItem(d.getId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(),
                canViewCost ? d.getTotalLocal() : null, d.getStatus(),
                d.isClosed(), d.getLegacyId(), d.getDepartmentId(),
                "DRAW".equals(d.getDocType()) ? d.getIssueStatus() : null,
                !canViewCost);
    }

    private StockDocItemDto toItemDto(StockDocumentItem it) {
        return new StockDocItemDto(
                it.getId(), it.getLineNo(), it.getGoodsId(),
                it.getGoodsCodeSnapshot(), it.getGoodsNameSnapshot(),
                it.getGoodsSnapshotSource(), it.getGoodsSnapshotLockedAt(), it.getColorId(),
                it.getUnitId(), it.getUnitRate(), it.getQty(), it.getReportedQty(),
                it.getBaseQty(), it.getPrice(),
                it.getAmountOriginal(), it.getAmountLocal(), it.getWeight(), it.getGiftQty(),
                it.getSurplusQty(), it.getCountQty(), it.getPlace(), it.getUpstreamItemId(),
                it.getExecutionSegmentId(),
                it.getExecutionSegmentSalesAllocationId(),
                it.getSourceDailyReportItemId(), it.getSourceDocNo(), it.getRemark(),
                it.getBillDate(), it.getIssuedQty(), false);
    }

    private StockDocDetail toDetail(StockDocument d, List<StockDocItemDto> items) {
        boolean canViewCost = canViewCost();
        List<StockDocItemDto> visibleItems = canViewCost
                ? items
                : items.stream().map(StockDocService::maskItemCost).toList();
        boolean productionLinked = isProductionLinked(d.getId());
        boolean authorizedBalanceAdjustment = isAuthorizedBalanceAdjustment(d);
        boolean canEdit = !productionLinked && !authorizedBalanceAdjustment && d.getStatus() != null
                && d.getStatus() == STATUS_DRAFT;
        boolean canDelete = !productionLinked && !authorizedBalanceAdjustment && d.getStatus() != null
                && d.getStatus() == STATUS_DRAFT;
        String restrictionReason = authorizedBalanceAdjustment
                ? "该单据是授权库存余额调整的永久审计记录，不能编辑或删除"
                : productionLinked
                ? "生产链自动生成单据由执行计划、物料占用和报工共同维护，"
                  + "请在对应生产任务中执行调整或反向操作"
                : null;
        String decision = null;
        String finishedInboundVarianceReason = null;
        if (productionLinked && "FINISHED_IN".equals(d.getDocType())) {
            List<Object[]> confirmation = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                    SELECT decision, variance_reason
                                    FROM production_finished_in_confirmations
                                    WHERE stock_document_id = :documentId
                                    ORDER BY created_at DESC
                                    LIMIT 1
                                    """)
                            .setParameter("documentId", d.getId()));
            if (!confirmation.isEmpty()) {
                decision = (String) confirmation.getFirst()[0];
                finishedInboundVarianceReason =
                        (String) confirmation.getFirst()[1];
            }
        }
        return new StockDocDetail(d.getId(), d.getLegacyId(), d.getDocType(), d.getBillNo(), d.getBillDate(),
                d.getWarehouseId(), d.getToWarehouseId(), d.getSupplierId(), d.getClientId(),
                d.getWorkerId(), d.getMakerId(), d.getApproverId(), d.getAssTeam(), d.getPlanNo(), d.getRemark(),
                canViewCost ? d.getTotalOriginal() : null,
                canViewCost ? d.getTotalLocal() : null, d.getStatus(), d.isClosed(),
                d.getSourceDocNo(), d.getSourceDailyReportId(),
                d.getDepartmentId(), d.getIssueStatus(), visibleItems,
                nameResolver.nameOf(d.getMakerId()), d.getCreatedAt(),
                productionLinked, canEdit, canDelete, restrictionReason,
                resolveSourcePlanId(d.getId()),
                decision, finishedInboundVarianceReason, !canViewCost);
    }

    private boolean canViewCost() {
        return access.hasAuthority(StockCostMasker.PERMISSION);
    }

    private static StockDocItemDto maskItemCost(StockDocItemDto item) {
        return new StockDocItemDto(
                item.getId(), item.getLineNo(), item.getGoodsId(),
                item.getGoodsCodeSnapshot(), item.getGoodsNameSnapshot(),
                item.getGoodsSnapshotSource(), item.getGoodsSnapshotLockedAt(), item.getColorId(),
                item.getUnitId(), item.getUnitRate(), item.getQty(), item.getReportedQty(),
                item.getBaseQty(), null, null, null, item.getWeight(), item.getGiftQty(),
                item.getSurplusQty(), item.getCountQty(), item.getPlace(), item.getUpstreamItemId(),
                item.getExecutionSegmentId(), item.getExecutionSegmentSalesAllocationId(),
                item.getSourceDailyReportItemId(), item.getSourceDocNo(), item.getRemark(),
                item.getBillDate(), item.getIssuedQty(), true);
    }

    /** 经 plan_draw_links 反查本单据关联的生产计划 id（DRAW/FINISHED_IN 溯源跳转用；多计划取单号最早一张）。 */
    @SuppressWarnings("unchecked")
    private UUID resolveSourcePlanId(UUID documentId) {
        if (documentId == null) return null;
        List<UUID> rows = em.createNativeQuery("""
                        SELECT l.plan_id
                        FROM plan_draw_links l
                        JOIN production_plans p ON p.id = l.plan_id AND p.is_deleted = FALSE
                        WHERE l.draw_id = :docId AND l.is_deleted = FALSE
                        ORDER BY p.bill_no
                        LIMIT 1
                        """)
                .setParameter("docId", documentId)
                .getResultList();
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private boolean isAuthorizedBalanceAdjustment(StockDocument document) {
        return document.getId() != null
                && balanceAdjustmentCommands.existsByStockDocumentId(document.getId());
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

    /**
     * Production-generated warehouse tasks cross maker ownership by design,
     * but never cross the current warehouse-organization object scope. Manual
     * warehouse documents retain maker/data-scope isolation.
     */
    private void requireOperationWritable(
            StockDocument document, String authority, String message) {
        if (isProductionLinked(document.getId())) {
            if (!access.hasAuthority(authority)) {
                throw new ApiException(ErrorCode.FORBIDDEN, message);
            }
            productionStockTaskAccess.requireWarehouseTaskAccess(message);
            return;
        }
        access.requireWritable(document.getMakerId(), message);
    }

    private boolean isProductionLinked(UUID documentId) {
        Object result = em.createNativeQuery(
                        "SELECT fn_is_production_linked_stock_document(CAST(:id AS uuid))")
                .setParameter("id", documentId)
                .getSingleResult();
        return Boolean.TRUE.equals(result);
    }

    record FinishedInboundBatchCommand(
            String idempotencyKey,
            List<UUID> documentIds,
            String requestHash) {

        FinishedInboundBatchCommand {
            documentIds = List.copyOf(documentIds);
        }
    }

    private record FinishedInboundBatchItem(
            int position,
            UUID confirmationId,
            FinishedInboundBatchConfirmResponse.Item result) {
    }

    private record FinishedInboundAcceptedSlice(
            UUID confirmationItemId, BigDecimal qty) {
    }

    private record FinishedInboundReversalDraft(
            UUID reversalId, UUID documentId) {
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
