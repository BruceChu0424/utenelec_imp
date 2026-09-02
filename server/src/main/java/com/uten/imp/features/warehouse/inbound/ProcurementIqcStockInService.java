package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.finance.ProcurementOrderClosurePolicy;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.InventoryKey;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmEntry;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmEntryResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.BatchConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmResult;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ReleasedSlice;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.StockInHistoryItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.TaskDetail;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/** Warehouse authority for turning IQC-released quantities into usable stock. */
@Service
@RequiredArgsConstructor
public class ProcurementIqcStockInService {

    private static final String PURCHASE = ProcurementInspectionPort.PURCHASE;
    private static final String SUBCONTRACT = ProcurementInspectionPort.SUBCONTRACT;
    private static final Pattern IDEMPOTENCY_KEY =
            Pattern.compile("[A-Za-z0-9._:-]{8,128}");

    private final EntityManager em;
    private final StockService stockService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProductionSupplyTransitionPort purchaseSupply;
    private final ProductionSubcontractSupplyTransitionPort subcontractSupply;
    private final PreplanAnalysisPegPort preplanAnalysisPeg;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')")
    public TaskDetail detail(String receiptType, UUID receiptId) {
        String type = normalizeReceiptType(receiptType);
        Object[] header = receiptHeader(type, receiptId);
        List<PassSlice> pendingSlices = passSlices(type, receiptId, false).stream()
                .filter(slice -> slice.remainingBaseQty().signum() > 0)
                .toList();
        List<ReleasedSlice> items = pendingSlices.stream()
                .map(this::toView)
                .toList();
        List<StockInHistoryItem> history = history(type, receiptId);
        // 单人维护场景允许同人完成「品质放行 + 仓库确认」：不再阻断；同人复核提示
        // 由合并页详情的 containsOwnRelease 标记承担（WarehouseQualityResultService）。
        boolean canConfirm = hasAuthority(ProcurementIqcStockInPermissions.CONFIRM);
        return new TaskDetail(
                type, receiptId, str(header[0]), localDate(header[1]),
                uuid(header[2]), str(header[3]), uuid(header[4]), str(header[5]),
                qualityStatus(type, receiptId), items.size(), items.isEmpty(),
                canConfirm && !items.isEmpty() ? List.of("CONFIRM") : List.of(),
                items, history);
    }

    @Transactional
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')"
            + " and hasAuthority('" + ProcurementIqcStockInPermissions.CONFIRM + "')")
    public ConfirmResult confirm(
            String receiptType, UUID receiptId, ConfirmRequest request) {
        tx.bind();
        String type = normalizeReceiptType(receiptType);
        NormalizedCommand command = normalize(type, receiptId, request);
        return confirmOne(type, receiptId, command);
    }

    /**
     * 跨收货单批量入库（合并页多选后一键办理）：整批同事务——先按稳定顺序规范化全部
     * 命令，再逐张执行；任一行版本、状态、仓库或数量变化时整批回滚，不允许客户端
     * 循环单张接口伪装批量成功。已完成的幂等键安全重放并计入结果。
     */
    @Transactional
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')"
            + " and hasAuthority('" + ProcurementIqcStockInPermissions.CONFIRM + "')")
    public BatchConfirmResult batchConfirm(BatchConfirmRequest request) {
        tx.bind();
        if (request == null || request.batches() == null
                || request.batches().isEmpty() || request.batches().size() > 20) {
            throw validation("批量入库必须包含 1 至 20 张收货单");
        }
        int totalItems = request.batches().stream()
                .mapToInt(entry -> entry.items() == null ? 0 : entry.items().size())
                .sum();
        if (totalItems < 1 || totalItems > 300) {
            throw validation("批量入库明细总数必须在 1 至 300 条之间");
        }
        // 稳定顺序（类型 + 收货单号）锁定，降低并发批量的死锁概率。
        List<BatchConfirmEntry> ordered = request.batches().stream()
                .sorted(Comparator
                        .comparing((BatchConfirmEntry entry) ->
                                normalizeReceiptType(entry.receiptType()))
                        .thenComparing(entry -> entry.receiptId().toString()))
                .toList();
        Set<String> seenKeys = new HashSet<>();
        Set<String> seenReceipts = new HashSet<>();
        List<NormalizedBatch> commands = new ArrayList<>();
        for (BatchConfirmEntry entry : ordered) {
            String type = normalizeReceiptType(entry.receiptType());
            if (!seenKeys.add(entry.idempotencyKey())) {
                throw validation("批量入库中存在重复幂等键");
            }
            if (!seenReceipts.add(type + '|' + entry.receiptId())) {
                throw validation("批量入库中同一收货单只能出现一次");
            }
            ConfirmRequest single = new ConfirmRequest(
                    entry.idempotencyKey(), entry.items());
            commands.add(new NormalizedBatch(
                    type, entry.receiptId(), normalize(type, entry.receiptId(), single)));
        }
        List<BatchConfirmEntryResult> results = new ArrayList<>();
        int confirmedItemCount = 0;
        for (NormalizedBatch batch : commands) {
            ConfirmResult result = confirmOne(
                    batch.type(), batch.receiptId(), batch.command());
            results.add(new BatchConfirmEntryResult(
                    batch.type(), batch.receiptId(), result.batchId(),
                    result.replayed(), result.confirmedCount(), result.confirmedAt()));
            confirmedItemCount += result.confirmedCount();
        }
        return new BatchConfirmResult(results, results.size(), confirmedItemCount);
    }

    private ConfirmResult confirmOne(
            String type, UUID receiptId, NormalizedCommand command) {
        UUID actorUserId = currentUser.requireId();
        UUID actorEmployeeId = currentUser.requireEmployeeId();

        lockCommand(actorUserId, command.idempotencyKey());
        ExistingBatch existing = existingBatch(actorUserId, command.idempotencyKey());
        if (existing != null) {
            if (!existing.requestHash().equals(command.requestHash())) {
                throw conflict("该入库幂等键已用于不同的数量、库位或任务，请更换后重试");
            }
            return new ConfirmResult(
                    existing.id(), true, existing.confirmedCount(), existing.confirmedAt());
        }

        receiptHeader(type, receiptId);
        lockReceiptMutationDimensions(type, receiptId);
        Map<UUID, PassSlice> locked = new LinkedHashMap<>();
        for (PassSlice slice : passSlices(type, receiptId, true)) {
            locked.put(slice.passEventId(), slice);
        }
        for (NormalizedItem item : command.items()) {
            PassSlice slice = locked.get(item.passEventId());
            if (slice == null || slice.remainingBaseQty().signum() <= 0) {
                throw conflict("部分品质放行任务已不存在、已撤销或已由同事完成，请刷新");
            }
            if (slice.remainingBaseQty().compareTo(item.expectedRemainingBaseQty()) != 0) {
                throw conflict("品质放行待入库余量已变化，请刷新后重新确认");
            }
            if (item.baseQty().compareTo(slice.remainingBaseQty()) > 0) {
                throw conflict("本次入库数量不得超过品质放行待入库余量");
            }
        }
        stockService.lockInventory(command.items().stream()
                .map(item -> locked.get(item.passEventId()))
                .map(slice -> new InventoryKey(slice.goodsId(), slice.colorId()))
                .toList());

        UUID batchId = UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.now();
        em.createNativeQuery("""
                        INSERT INTO procurement_iqc_stock_in_batches(
                            id, actor_user_id, actor_employee_id,
                            receipt_type, receipt_id, idempotency_key,
                            request_hash, confirmed_count, confirmed_at)
                        VALUES (
                            :id, :userId, :employeeId,
                            :receiptType, :receiptId, :key,
                            :hash, :count, :at)
                        """)
                .setParameter("id", batchId)
                .setParameter("userId", actorUserId)
                .setParameter("employeeId", actorEmployeeId)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .setParameter("key", command.idempotencyKey())
                .setParameter("hash", command.requestHash())
                .setParameter("count", command.items().size())
                .setParameter("at", now)
                .executeUpdate();

        int position = 0;
        Set<UUID> inspectionItemIds = new LinkedHashSet<>();
        for (NormalizedItem item : command.items()) {
            position++;
            PassSlice slice = locked.get(item.passEventId());
            Allocation eventAllocation = allocation(slice);
            BigDecimal amount = ProcurementInspectionService.proratedIncrement(
                    eventAllocation.amount(), slice.releasedBaseQty(),
                    slice.stockedForReleaseBaseQty(), item.baseQty());
            BigDecimal weight = eventAllocation.weight() == null ? null
                    : ProcurementInspectionService.proratedIncrement(
                            eventAllocation.weight(), slice.releasedBaseQty(),
                            slice.stockedForReleaseBaseQty(), item.baseQty());

            UUID stockInItemId = UUID.randomUUID();
            UUID movementId = stockService.recordMovement(new StockService.MovementRequest(
                    now, movementType(type), sourceDocType(type),
                    receiptId, stockInItemId,
                    slice.goodsId(), slice.colorId(), slice.warehouseId(),
                    StockService.DIR_IN, item.baseQty(),
                    slice.unitId(), slice.unitRate(), amount,
                    "仓库确认 IQC 合格品入库；库位：" + item.place(),
                    weight, slice.weightUnitId()));

            insertStockInItem(
                    stockInItemId, batchId, position, slice, movementId,
                    item, amount, weight, now);
            incrementStockedProjection(slice, item.baseQty(), amount, weight, now);

            preplanAnalysisPeg.attributeInspectionStockIn(
                    type, receiptId, slice.inspectionItemId(),
                    slice.passEventId(), stockInItemId,
                    item.baseQty(), slice.warehouseId());
            inspectionItemIds.add(slice.inspectionItemId());
        }
        // 生产联动整批一次：明细全部落账后再唤醒/推进（每条一次时同一分析
        // 被整棵重建 O(明细数) 遍、领料单按条裂开，最终数据与一次推进完全
        // 一致——分析刷新是当前库态的全量重算，事件按批聚合）。
        advanceProductionAfterStockIn(type, receiptId, batchId, inspectionItemIds);
        recalculateOrderClosure(type, receiptId);
        rememberConfirmedPlaces(locked, command, batchId, now, actorUserId, actorEmployeeId);
        return new ConfirmResult(batchId, false, command.items().size(), now);
    }

    /**
     * IQC 确认入库成功后的库位学习（V451）：
     * - 仓库×货品×颜色 维度 upsert {@code warehouse_goods_place_preferences}
     *   （source_kind=IQC_STOCK_IN），下次待入库 placeHint 自动带出本次库位；
     * - 同一维度本次出现多个不同库位时不学习（与产成品到货登记同口径，防误记）；
     * - 货品主档 {@code stock_place} 与本次不同才回写，让货架目视化清单、即时库存
     *   等按主档展示库位的页面同步最新建议库位；
     * - 幂等重放在 {@link #confirmOne} 开头已提前返回，不会重复学习或计数。
     */
    private void rememberConfirmedPlaces(
            Map<UUID, PassSlice> locked, NormalizedCommand command,
            UUID batchId, OffsetDateTime confirmedAt,
            UUID actorUserId, UUID actorEmployeeId) {
        Map<PlaceLearnDimension, LinkedHashSet<String>> places = new LinkedHashMap<>();
        for (NormalizedItem item : command.items()) {
            PassSlice slice = locked.get(item.passEventId());
            places.computeIfAbsent(
                    new PlaceLearnDimension(
                            slice.warehouseId(), slice.goodsId(), slice.colorId()),
                    ignored -> new LinkedHashSet<>())
                    .add(item.place());
        }
        for (Map.Entry<PlaceLearnDimension, LinkedHashSet<String>> entry
                : places.entrySet()) {
            if (entry.getValue().size() != 1) {
                continue;
            }
            String place = entry.getValue().iterator().next();
            learnWarehousePreference(
                    entry.getKey(), place, batchId, confirmedAt, actorUserId, actorEmployeeId);
            learnGoodsMasterPlace(entry.getKey().goodsId(), place, actorUserId);
        }
    }

    private void learnWarehousePreference(
            PlaceLearnDimension dimension, String place, UUID batchId,
            OffsetDateTime confirmedAt, UUID actorUserId, UUID actorEmployeeId) {
        em.createNativeQuery("""
                        INSERT INTO warehouse_goods_place_preferences(
                            id, warehouse_id, goods_id, color_id, place,
                            selection_count, version,
                            source_kind, source_registration_id, source_iqc_batch_id,
                            source_registered_at,
                            last_selected_by, last_selected_at, created_by, updated_by)
                        VALUES (
                            gen_random_uuid(), :warehouseId, :goodsId, :colorId, :place,
                            1, 0,
                            'IQC_STOCK_IN', NULL, :batchId,
                            :confirmedAt,
                            :employeeId, now(), :userId, :userId)
                        ON CONFLICT ON CONSTRAINT
                            warehouse_goods_place_preference_dimension_uk
                        DO UPDATE SET
                            place = EXCLUDED.place,
                            selection_count =
                                warehouse_goods_place_preferences.selection_count + 1,
                            version = warehouse_goods_place_preferences.version + 1,
                            source_kind = EXCLUDED.source_kind,
                            source_registration_id = EXCLUDED.source_registration_id,
                            source_iqc_batch_id = EXCLUDED.source_iqc_batch_id,
                            source_registered_at = EXCLUDED.source_registered_at,
                            last_selected_by = EXCLUDED.last_selected_by,
                            last_selected_at = now(),
                            updated_by = EXCLUDED.updated_by
                        WHERE (
                            warehouse_goods_place_preferences.source_registered_at,
                            COALESCE(
                                warehouse_goods_place_preferences.source_registration_id,
                                warehouse_goods_place_preferences.source_iqc_batch_id)
                        ) < (
                            EXCLUDED.source_registered_at,
                            EXCLUDED.source_iqc_batch_id)
                        """)
                .setParameter("warehouseId", dimension.warehouseId())
                .setParameter("goodsId", dimension.goodsId())
                .setParameter("colorId", dimension.colorId())
                .setParameter("place", place)
                .setParameter("batchId", batchId)
                .setParameter("confirmedAt", confirmedAt)
                .setParameter("employeeId", actorEmployeeId)
                .setParameter("userId", actorUserId)
                .executeUpdate();
    }

    /** 主档库位回写：与到货登记 applyGoodsProfileHints 同口径——不同才更新，失败不阻断入库。 */
    private void learnGoodsMasterPlace(UUID goodsId, String place, UUID actorUserId) {
        em.createNativeQuery("""
                        UPDATE goods
                        SET stock_place = :place,
                            version = version + 1,
                            updated_at = now(),
                            updated_by = :userId
                        WHERE id = :goodsId
                          AND is_deleted = FALSE
                          AND COALESCE(NULLIF(BTRIM(stock_place), ''), '')
                              IS DISTINCT FROM :place
                        """)
                .setParameter("place", place)
                .setParameter("userId", actorUserId)
                .setParameter("goodsId", goodsId)
                .executeUpdate();
    }

    private record PlaceLearnDimension(
            UUID warehouseId, UUID goodsId, UUID colorId) {
    }

    private void insertStockInItem(
            UUID stockInItemId,
            UUID batchId,
            int position,
            PassSlice slice,
            UUID movementId,
            NormalizedItem item,
            BigDecimal amount,
            BigDecimal weight,
            OffsetDateTime now) {
        em.createNativeQuery("""
                        INSERT INTO procurement_iqc_stock_in_batch_items(
                            id, batch_id, position, inspection_item_id,
                            pass_event_id, stock_movement_id,
                            warehouse_id, goods_id, color_id,
                            expected_remaining_base_qty, base_qty,
                            amount_local, weight, weight_unit_id,
                            place_snapshot, created_at)
                        VALUES (
                            :id, :batchId, :position, :inspectionItemId,
                            :passEventId, :movementId,
                            :warehouseId, :goodsId, :colorId,
                            :expectedRemaining, :baseQty,
                            :amount, :weight, :weightUnitId,
                            :place, :at)
                        """)
                .setParameter("id", stockInItemId)
                .setParameter("batchId", batchId)
                .setParameter("position", position)
                .setParameter("inspectionItemId", slice.inspectionItemId())
                .setParameter("passEventId", slice.passEventId())
                .setParameter("movementId", movementId)
                .setParameter("warehouseId", slice.warehouseId())
                .setParameter("goodsId", slice.goodsId())
                .setParameter("colorId", slice.colorId())
                .setParameter("expectedRemaining", item.expectedRemainingBaseQty())
                .setParameter("baseQty", item.baseQty())
                .setParameter("amount", amount)
                .setParameter("weight", weight)
                .setParameter("weightUnitId", slice.weightUnitId())
                .setParameter("place", item.place())
                .setParameter("at", now)
                .executeUpdate();
    }

    private void incrementStockedProjection(
            PassSlice slice,
            BigDecimal baseQty,
            BigDecimal amount,
            BigDecimal weight,
            OffsetDateTime now) {
        int updated = em.createNativeQuery("""
                        UPDATE procurement_inspection_items
                        SET warehouse_stocked_base_qty =
                                warehouse_stocked_base_qty + :baseQty,
                            warehouse_stocked_amount_local =
                                warehouse_stocked_amount_local + :amount,
                            warehouse_stocked_weight = CASE
                                WHEN CAST(:weight AS numeric) IS NULL
                                THEN warehouse_stocked_weight
                                ELSE COALESCE(warehouse_stocked_weight, 0)
                                    + CAST(:weight AS numeric)
                            END,
                            updated_at = :at
                        WHERE id = :id
                          AND status <> 'REVERSED'
                          AND warehouse_stocked_base_qty + :baseQty
                                <= passed_base_qty
                        """)
                .setParameter("baseQty", baseQty)
                .setParameter("amount", amount)
                .setParameter("weight", weight)
                .setParameter("at", now)
                .setParameter("id", slice.inspectionItemId())
                .executeUpdate();
        if (updated != 1) {
            throw conflict("IQC 待入库数量已变化，请刷新后重试");
        }
    }

    private List<PassSlice> passSlices(
            String receiptType, UUID receiptId, boolean lockInspectionRows) {
        String lock = lockInspectionRows ? " FOR UPDATE OF inspection" : "";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT event.id,
                               inspection.id,
                               inspection.warehouse_id,
                               inspection.goods_id,
                               inspection.color_id,
                               inspection.unit_id,
                               inspection.unit_rate,
                               inspection.received_base_qty,
                               inspection.received_amount_local,
                               inspection.received_weight,
                               event.released_weight_unit_id,
                               inspection.passed_base_qty,
                               inspection.warehouse_stocked_base_qty,
                               event.base_qty,
                               event.released_amount_local,
                               event.released_weight,
                               COALESCE(event_stocked.stocked_qty, 0),
                               event.base_qty - COALESCE(event_stocked.stocked_qty, 0),
                               event.reason,
                               event.occurred_at,
                               goods.code,
                               goods.name,
                               color.name,
                               COALESCE(base_unit.name, source_unit.name),
                               weight_unit.name,
                               COALESCE(preference.place,
                                        NULLIF(BTRIM(goods.stock_place), '')),
                               employee.full_name,
                               COALESCE(purchase_order.bill_no,
                                        subcontract_order.bill_no),
                               COALESCE(goods.unit_id, inspection.unit_id),
                               event.actor_employee_id
                        FROM procurement_inspection_events event
                        JOIN procurement_inspection_items inspection
                          ON inspection.id = event.inspection_item_id
                        LEFT JOIN LATERAL (
                            SELECT COALESCE(SUM(item.base_qty), 0) AS stocked_qty
                            FROM procurement_iqc_stock_in_batch_items item
                            WHERE item.pass_event_id = event.id
                        ) event_stocked ON TRUE
                        LEFT JOIN goods ON goods.id = inspection.goods_id
                        LEFT JOIN colors color ON color.id = inspection.color_id
                        LEFT JOIN units source_unit
                          ON source_unit.id = inspection.unit_id
                        LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                        LEFT JOIN units weight_unit
                          ON weight_unit.id = event.released_weight_unit_id
                        LEFT JOIN warehouse_goods_place_preferences preference
                          ON preference.warehouse_id = inspection.warehouse_id
                         AND preference.goods_id = inspection.goods_id
                         AND preference.color_id
                             IS NOT DISTINCT FROM inspection.color_id
                        LEFT JOIN employees employee
                          ON employee.id = event.actor_employee_id
                        LEFT JOIN purchase_receipt_items purchase_item
                          ON inspection.receipt_type = 'PURCHASE'
                         AND purchase_item.id = inspection.receipt_item_id
                        LEFT JOIN purchase_order_items purchase_order_item
                          ON purchase_order_item.id = purchase_item.order_item_id
                        LEFT JOIN purchase_orders purchase_order
                          ON purchase_order.id = purchase_order_item.order_id
                        LEFT JOIN subcontract_receipt_items subcontract_item
                          ON inspection.receipt_type = 'SUBCONTRACT'
                         AND subcontract_item.id = inspection.receipt_item_id
                        LEFT JOIN subcontract_order_items subcontract_order_item
                          ON subcontract_order_item.id = subcontract_item.order_item_id
                        LEFT JOIN subcontract_orders subcontract_order
                          ON subcontract_order.id = subcontract_order_item.order_id
                        WHERE inspection.receipt_type = :receiptType
                          AND inspection.receipt_id = :receiptId
                          AND inspection.status <> 'REVERSED'
                          AND event.action = 'PASS'
                          AND event.requires_warehouse_stock_in = TRUE
                        ORDER BY event.occurred_at, event.id
                        """ + lock)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        return rows.stream().map(row -> new PassSlice(
                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]), uuid(row[4]),
                uuid(row[5]), decimal(row[6]), decimal(row[7]), decimal(row[8]),
                nullableDecimal(row[9]), uuid(row[10]), decimal(row[11]), decimal(row[12]),
                decimal(row[13]), decimal(row[14]), nullableDecimal(row[15]),
                decimal(row[16]), decimal(row[17]), str(row[18]),
                offsetDateTime(row[19]), str(row[20]), str(row[21]), str(row[22]),
                str(row[23]), str(row[24]), str(row[25]), str(row[26]), str(row[27]),
                uuid(row[28]), uuid(row[29])))
                .toList();
    }

    private ReleasedSlice toView(PassSlice slice) {
        Allocation allocation = allocation(slice);
        return new ReleasedSlice(
                slice.passEventId(), slice.inspectionItemId(), slice.goodsId(),
                slice.goodsCode(), slice.goodsName(), slice.colorName(),
                slice.displayUnitId(), slice.unitName(), slice.sourceOrderNo(),
                slice.receivedBaseQty(), slice.qualityPassedBaseQty(),
                slice.warehouseStockedBaseQty(), slice.releasedBaseQty(),
                slice.stockedForReleaseBaseQty(), slice.remainingBaseQty(),
                allocation.weight(), slice.weightUnitId(), slice.weightUnitName(),
                slice.placeHint(), slice.releaseNote(), slice.releasedBy(),
                slice.releasedAt());
    }

    private Allocation allocation(PassSlice slice) {
        if (slice.releasedAmountLocal() == null) {
            throw conflict("品质合格事件缺少冻结金额切片，请联系管理员");
        }
        return new Allocation(
                slice.releasedAmountLocal(), slice.releasedWeight());
    }

    private List<StockInHistoryItem> history(String receiptType, UUID receiptId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT item.id, batch.id, item.pass_event_id,
                               item.goods_id, goods.code, goods.name,
                               color.name, COALESCE(base_unit.name, source_unit.name),
                               item.base_qty, item.weight, weight_unit.name,
                               item.place_snapshot, employee.full_name,
                               batch.confirmed_at
                        FROM procurement_iqc_stock_in_batch_items item
                        JOIN procurement_iqc_stock_in_batches batch
                          ON batch.id = item.batch_id
                        JOIN procurement_inspection_items inspection
                          ON inspection.id = item.inspection_item_id
                        LEFT JOIN goods ON goods.id = item.goods_id
                        LEFT JOIN colors color ON color.id = item.color_id
                        LEFT JOIN units source_unit
                          ON source_unit.id = inspection.unit_id
                        LEFT JOIN units base_unit ON base_unit.id = goods.unit_id
                        LEFT JOIN units weight_unit
                          ON weight_unit.id = item.weight_unit_id
                        LEFT JOIN employees employee
                          ON employee.id = batch.actor_employee_id
                        WHERE batch.receipt_type = :receiptType
                          AND batch.receipt_id = :receiptId
                        ORDER BY batch.confirmed_at DESC, item.position
                        LIMIT 200
                        """)
                .setParameter("receiptType", receiptType)
                .setParameter("receiptId", receiptId)
                .getResultList();
        return rows.stream().map(row -> new StockInHistoryItem(
                uuid(row[0]), uuid(row[1]), uuid(row[2]), uuid(row[3]),
                str(row[4]), str(row[5]), str(row[6]), str(row[7]),
                decimal(row[8]), nullableDecimal(row[9]), str(row[10]),
                str(row[11]), str(row[12]), offsetDateTime(row[13]))).toList();
    }

    private Object[] receiptHeader(String type, UUID receiptId) {
        if (receiptId == null) {
            throw validation("收货单 UUID 不能为空");
        }
        String table = PURCHASE.equals(type) ? "purchase_receipts" : "subcontract_receipts";
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT receipt.bill_no, receipt.bill_date,
                               receipt.supplier_id, supplier.name,
                               receipt.warehouse_id, warehouse.name
                        FROM %s receipt
                        LEFT JOIN suppliers supplier
                          ON supplier.id = receipt.supplier_id
                        LEFT JOIN warehouses warehouse
                          ON warehouse.id = receipt.warehouse_id
                        WHERE receipt.id = :receiptId
                          AND COALESCE(receipt.is_deleted, FALSE) = FALSE
                        """.formatted(table))
                .setParameter("receiptId", receiptId)
                .getResultList();
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "收货单不存在");
        }
        return rows.getFirst();
    }

    private String qualityStatus(String type, UUID receiptId) {
        Object[] row = (Object[]) em.createNativeQuery("""
                        SELECT COUNT(*),
                               COUNT(*) FILTER (WHERE status = 'PENDING'),
                               COUNT(*) FILTER (WHERE status = 'PARTIAL'),
                               COUNT(*) FILTER (WHERE status = 'RESOLVED'),
                               COUNT(*) FILTER (WHERE status = 'REVERSED')
                        FROM procurement_inspection_items
                        WHERE receipt_type = :receiptType
                          AND receipt_id = :receiptId
                        """)
                .setParameter("receiptType", type)
                .setParameter("receiptId", receiptId)
                .getSingleResult();
        if (number(row[0]).longValue() == 0) return "UNKNOWN";
        if (number(row[4]).longValue() > 0) return "REVERSED";
        if (number(row[1]).longValue() > 0 || number(row[2]).longValue() > 0) {
            return "IN_PROGRESS";
        }
        return "RESOLVED";
    }

    private NormalizedCommand normalize(
            String receiptType, UUID receiptId, ConfirmRequest request) {
        if (receiptId == null || request == null || request.items() == null
                || request.items().isEmpty() || request.items().size() > 100) {
            throw validation("入库任务必须包含 1 至 100 条明细");
        }
        String key = request.idempotencyKey() == null
                ? "" : request.idempotencyKey().strip();
        if (!IDEMPOTENCY_KEY.matcher(key).matches()) {
            throw validation("入库幂等键必须为 8 至 128 位字母、数字或 ._:-");
        }
        Set<UUID> seen = new HashSet<>();
        List<NormalizedItem> items = new ArrayList<>();
        for (ConfirmItem raw : request.items()) {
            if (raw == null || raw.passEventId() == null
                    || !seen.add(raw.passEventId())) {
                throw validation("同一品质放行切片在一批入库中只能出现一次");
            }
            BigDecimal quantity = quantity(raw.baseQty(), "本次入库数量");
            BigDecimal expected = quantity(
                    raw.expectedRemainingBaseQty(), "期望待入库余量");
            if (quantity.compareTo(expected) > 0) {
                throw validation("本次入库数量不能超过页面显示的待入库余量");
            }
            String place = raw.place() == null ? "" : raw.place().strip();
            if (place.isEmpty() || place.length() > 100) {
                throw validation("实际库位必须为 1 至 100 个字符");
            }
            items.add(new NormalizedItem(raw.passEventId(), quantity, expected, place));
        }
        items.sort(Comparator.comparing(item -> item.passEventId().toString()));
        List<String> fingerprint = new ArrayList<>();
        fingerprint.add("receiptType=" + receiptType);
        fingerprint.add("receiptId=" + receiptId);
        for (NormalizedItem item : items) {
            fingerprint.add(item.passEventId() + "|" + item.baseQty().toPlainString()
                    + "|" + item.expectedRemainingBaseQty().toPlainString()
                    + "|" + item.place());
        }
        return new NormalizedCommand(
                key, CanonicalFingerprint.sha256(fingerprint), List.copyOf(items));
    }

    private void lockCommand(UUID actorUserId, String key) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(:lockKey, 0))
                        """)
                .setParameter("lockKey", "IQC_STOCK_IN|" + actorUserId + "|" + key)
                .getSingleResult();
    }

    private ExistingBatch existingBatch(UUID actorUserId, String key) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, request_hash, confirmed_count, confirmed_at
                        FROM procurement_iqc_stock_in_batches
                        WHERE actor_user_id = :actorUserId
                          AND idempotency_key = :key
                        """)
                .setParameter("actorUserId", actorUserId)
                .setParameter("key", key)
                .getResultList();
        if (rows.isEmpty()) return null;
        Object[] row = rows.getFirst();
        return new ExistingBatch(
                uuid(row[0]), str(row[1]), number(row[2]).intValue(),
                offsetDateTime(row[3]));
    }

    private void lockReceiptMutationDimensions(String type, UUID receiptId) {
        if (PURCHASE.equals(type)) {
            purchaseSupply.lockPurchaseReceiptMutationDimensions(receiptId);
        } else {
            subcontractSupply.lockSubcontractReceiptMutationDimensions(receiptId);
        }
    }

    private void advanceProductionAfterStockIn(
            String type, UUID receiptId, UUID batchId,
            Set<UUID> inspectionItemIds) {
        if (PURCHASE.equals(type)) {
            purchaseSupply.afterPurchaseInspectionStockInConfirmed(
                    receiptId, batchId, inspectionItemIds);
        } else {
            subcontractSupply.afterSubcontractInspectionStockInConfirmed(
                    receiptId, batchId, inspectionItemIds);
        }
    }

    private void recalculateOrderClosure(String type, UUID receiptId) {
        String receiptItemTable = PURCHASE.equals(type)
                ? "purchase_receipt_items"
                : "subcontract_receipt_items";
        @SuppressWarnings("unchecked")
        List<UUID> orderItemIds = em.createNativeQuery("""
                        SELECT DISTINCT order_item_id
                        FROM %s
                        WHERE receipt_id=:receiptId
                          AND order_item_id IS NOT NULL
                          AND COALESCE(is_deleted,FALSE)=FALSE
                        ORDER BY order_item_id
                        """.formatted(receiptItemTable))
                .setParameter("receiptId", receiptId)
                .getResultList();
        for (UUID orderItemId : orderItemIds) {
            ProcurementOrderClosurePolicy.recalculate(em, type, orderItemId);
        }
    }

    private static short movementType(String type) {
        return PURCHASE.equals(type)
                ? StockService.TYPE_PURCHASE_RECEIPT
                : StockService.TYPE_SUBCONTRACT_RECEIPT;
    }

    private static String sourceDocType(String type) {
        return PURCHASE.equals(type)
                ? StockService.SRC_PURCHASE_RECEIPT
                : StockService.SRC_SUBCONTRACT_RECEIPT;
    }

    private static String normalizeReceiptType(String value) {
        String type = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (!PURCHASE.equals(type) && !SUBCONTRACT.equals(type)) {
            throw validation("收货单类型仅支持 PURCHASE 或 SUBCONTRACT");
        }
        return type;
    }

    private static BigDecimal quantity(BigDecimal value, String label) {
        if (value == null || value.signum() <= 0) {
            throw validation(label + "必须大于 0");
        }
        try {
            return value.setScale(4, RoundingMode.UNNECESSARY);
        } catch (ArithmeticException error) {
            throw validation(label + "最多保留 4 位小数");
        }
    }

    private static boolean hasAuthority(String authority) {
        Authentication authentication =
                SecurityContextHolder.getContext().getAuthentication();
        return authentication != null && authentication.isAuthenticated()
                && authentication.getAuthorities().stream()
                .anyMatch(granted -> authority.equals(granted.getAuthority()));
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static UUID uuid(Object value) {
        return value == null ? null : (UUID) value;
    }

    private static String str(Object value) {
        return value == null ? "" : value.toString();
    }

    private static Number number(Object value) {
        return value == null ? 0L : (Number) value;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static BigDecimal nullableDecimal(Object value) {
        return value == null ? null : (BigDecimal) value;
    }

    private static LocalDate localDate(Object value) {
        if (value == null) return null;
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        return LocalDate.parse(value.toString());
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        if (value == null) return null;
        if (value instanceof OffsetDateTime dateTime) return dateTime;
        if (value instanceof java.time.Instant instant) return instant.atOffset(ZoneOffset.UTC);
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().atOffset(ZoneOffset.UTC);
        }
        return OffsetDateTime.parse(value.toString());
    }

    private record NormalizedItem(
            UUID passEventId,
            BigDecimal baseQty,
            BigDecimal expectedRemainingBaseQty,
            String place) {
    }

    private record NormalizedCommand(
            String idempotencyKey,
            String requestHash,
            List<NormalizedItem> items) {
    }

    private record NormalizedBatch(
            String type,
            UUID receiptId,
            NormalizedCommand command) {
    }

    private record ExistingBatch(
            UUID id, String requestHash, int confirmedCount,
            OffsetDateTime confirmedAt) {
    }

    private record Allocation(BigDecimal amount, BigDecimal weight) {
    }

    private record PassSlice(
            UUID passEventId,
            UUID inspectionItemId,
            UUID warehouseId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal receivedBaseQty,
            BigDecimal receivedAmountLocal,
            BigDecimal receivedWeight,
            UUID weightUnitId,
            BigDecimal qualityPassedBaseQty,
            BigDecimal warehouseStockedBaseQty,
            BigDecimal releasedBaseQty,
            BigDecimal releasedAmountLocal,
            BigDecimal releasedWeight,
            BigDecimal stockedForReleaseBaseQty,
            BigDecimal remainingBaseQty,
            String releaseNote,
            OffsetDateTime releasedAt,
            String goodsCode,
            String goodsName,
            String colorName,
            String unitName,
            String weightUnitName,
            String placeHint,
            String releasedBy,
            String sourceOrderNo,
            UUID displayUnitId,
            UUID releasedByEmployeeId) {
    }
}
