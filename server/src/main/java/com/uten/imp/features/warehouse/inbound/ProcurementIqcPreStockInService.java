package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementInspectionPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInResult;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 到货「先入库后质检」(上架待检, ADR-090 / V596)：把仍在等待品质结论的待检明细行先上架到
 * 实际记账叶仓与库位。
 *
 * <p>只写位置事实，不写 {@code stock_balances}、不建入库批次、不动价值账：正式入库在品质
 * PASS 时由 {@link ProcurementInspectionService} 调 {@link ProcurementIqcStockInService}
 * 按这里记录的位置自动完成(V446 同一套批次/流水/守卫)；不合格由仓库从库位取出走 V440 退回链路。
 *
 * <p>两个入口共用同一内核：仓库到货登记页勾选「先入库后质检」(同事务，
 * {@link #applyForReceipt})；品质部检查结果页对「等待检查结果」的收货单补做上架
 * ({@link #preStockIn})。上架只允许在该行尚无任何结论时进行(数据库触发器同样拒绝)。
 */
@Service
@RequiredArgsConstructor
public class ProcurementIqcPreStockInService {

    /** 与 ChainNoticeService.EVENT_IQC_PRE_STOCKED 对齐：上架后通知品质部到库位检验。 */
    public static final String EVENT_IQC_PRE_STOCKED = "PROCUREMENT_IQC_PRE_STOCKED";

    private static final String PURCHASE = ProcurementInspectionPort.PURCHASE;
    private static final String SUBCONTRACT = ProcurementInspectionPort.SUBCONTRACT;

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final ProcurementMutationLocks mutationLocks;
    private final ProductionSupplyTransitionPort purchaseSupply;
    private final ProductionSubcontractSupplyTransitionPort subcontractSupply;
    private final BusinessEventPublisher outbox;

    /** 一行上架命令：待检明细 → 实际叶仓 + 库位(已规范化)。 */
    public record PreStockLine(UUID inspectionItemId, UUID warehouseId, String place) {
    }

    /** 品质部检查结果页 / 待检明细页的显式上架动作。 */
    @Transactional
    @PreAuthorize("hasAuthority('" + ProcurementIqcStockInPermissions.VIEW + "')"
            + " and hasAuthority('" + ProcurementIqcStockInPermissions.BEFORE_INSPECTION + "')")
    public PreStockInResult preStockIn(String receiptType, UUID receiptId, PreStockInRequest request) {
        tx.bind();
        String type = normalizeReceiptType(receiptType);
        if (receiptId == null) throw validation("收货单 UUID 不能为空");
        if (request == null || request.items() == null || request.items().isEmpty()
                || request.items().size() > 100) {
            throw validation("先入库上架必须包含 1 至 100 条待检明细");
        }
        List<PreStockLine> lines = new ArrayList<>(request.items().size());
        for (PreStockInItem item : request.items()) {
            if (item == null || item.inspectionItemId() == null) throw validation("待检明细 UUID 不能为空");
            lines.add(new PreStockLine(item.inspectionItemId(), item.warehouseId(), normalizePlace(item.place())));
        }
        return apply(type, receiptId, lines, currentUser.requireEmployeeId());
    }

    /**
     * 到货登记同事务：收货单刚送检(明细全部 PENDING)，按登记页每行填写的库位上架到
     * 本张收货单的入库仓。调用方已持有收货来源锁；这里只补待检明细行锁。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public PreStockInResult applyForReceipt(String receiptType, UUID receiptId, List<PreStockLine> lines,
                                            UUID actorEmployeeId) {
        return apply(normalizeReceiptType(receiptType), receiptId, lines, actorEmployeeId);
    }

    private PreStockInResult apply(String type, UUID receiptId, List<PreStockLine> lines, UUID actor) {
        if (lines == null || lines.isEmpty()) throw validation("先入库上架必须至少包含一行待检明细");
        Set<UUID> ids = new LinkedHashSet<>();
        for (PreStockLine line : lines) {
            if (line.inspectionItemId() == null || !ids.add(line.inspectionItemId())) {
                throw validation("同一待检明细在一次上架中只能出现一次");
            }
            if (line.warehouseId() == null) throw validation("请为每行选择上架仓库(记账叶仓)");
            if (line.place() == null || line.place().isBlank() || line.place().length() > 100) {
                throw validation("上架库位必须为 1 至 100 个字符");
            }
        }
        var mutationGuard = mutationLocks.inspection(type, receiptId, List.copyOf(ids));
        lockReceiptMutationDimensions(type, receiptId);
        Map<UUID, Object[]> rows = lockRows(type, receiptId);
        mutationGuard.verifyUnchanged();
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "收货单尚未送检或不存在");
        for (PreStockLine line : lines) {
            Object[] row = rows.get(line.inspectionItemId());
            if (row == null) throw new ApiException(ErrorCode.NOT_FOUND, "待检明细不存在或不属于当前收货单");
            if (!"PENDING".equals(row[1]) || decimal(row[2]).signum() != 0 || decimal(row[3]).signum() != 0) {
                throw conflict("待检明细已有品质结论或已撤销，不能再先入库；请按原流程等品质放行后由仓库确认入库");
            }
        }
        Map<UUID, String> warehouseNames = requireLeafWarehouses(
                lines.stream().map(PreStockLine::warehouseId).distinct().toList());
        OffsetDateTime now = OffsetDateTime.now();
        int stocked = 0;
        int replayed = 0;
        UUID firstEvent = null;
        for (PreStockLine line : lines) {
            Object[] row = rows.get(line.inspectionItemId());
            if (Objects.equals(row[5], line.warehouseId()) && Objects.equals(row[6], line.place())) {
                replayed++;
                continue;
            }
            int updated = em.createNativeQuery("""
                    UPDATE procurement_inspection_items
                    SET pre_stocked_warehouse_id = :warehouseId,
                        pre_stocked_place = :place,
                        pre_stocked_at = :now,
                        pre_stocked_by_employee_id = :actor,
                        updated_at = :now
                    WHERE id = :id AND status = 'PENDING'
                      AND passed_base_qty = 0 AND failed_base_qty = 0
                    """)
                    .setParameter("warehouseId", line.warehouseId())
                    .setParameter("place", line.place())
                    .setParameter("now", now)
                    .setParameter("actor", actor)
                    .setParameter("id", line.inspectionItemId())
                    .executeUpdate();
            if (updated != 1) throw conflict("待检状态已变化，请刷新后重试");
            UUID eventId = UUID.randomUUID();
            if (firstEvent == null) firstEvent = eventId;
            ProcurementInspectionEvents.append(em, eventId, line.inspectionItemId(),
                    ProcurementInspectionEvents.PRE_STOCKED, decimal(row[4]),
                    (row[5] == null ? "先入库上架：" : "调整上架位置：")
                            + warehouseNames.getOrDefault(line.warehouseId(), line.warehouseId().toString())
                            + " / " + line.place(),
                    actor, now);
            stocked++;
        }
        if (stocked > 0) {
            // 同一收货单一次上架只投递一条品质部通知；位置调整再投一条(幂等键带首个事件)。
            outbox.publishOnce(
                    EVENT_IQC_PRE_STOCKED,
                    "PROCUREMENT_INSPECTION",
                    receiptId,
                    Map.of("receiptType", type),
                    EVENT_IQC_PRE_STOCKED + ':' + receiptId + ':' + firstEvent);
        }
        return new PreStockInResult(type, receiptId, lines.size(), stocked, replayed, now);
    }

    private Map<UUID, Object[]> lockRows(String type, UUID receiptId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                SELECT id, status, passed_base_qty, failed_base_qty,
                       received_base_qty - passed_base_qty - failed_base_qty,
                       pre_stocked_warehouse_id, pre_stocked_place
                FROM procurement_inspection_items
                WHERE receipt_type = :rt AND receipt_id = :rid
                ORDER BY id
                FOR UPDATE
                """)
                .setParameter("rt", type)
                .setParameter("rid", receiptId)
                .getResultList();
        Map<UUID, Object[]> result = new LinkedHashMap<>();
        for (Object[] row : rows) result.put((UUID) row[0], row);
        return result;
    }

    /**
     * 上架仓必须是启用中的记账叶仓(祖先链全部启用、无子仓、参与核算)，且不能是线边仓(车间料架)。
     * 口径与 V563 入库选仓守卫、V596 数据库触发器同一个 SQL 函数，仓库主档不跨 feature 直连(ADR-017)。
     * 返回仓名供事件文案。
     */
    private Map<UUID, String> requireLeafWarehouses(List<UUID> warehouseIds) {
        Map<UUID, String> names = new HashMap<>();
        for (UUID warehouseId : warehouseIds) {
            @SuppressWarnings("unchecked")
            List<Object[]> rows = em.createNativeQuery("""
                    SELECT name, is_line_side, fn_warehouse_is_active_accounting_leaf(id)
                    FROM warehouses WHERE id = :id AND is_deleted = FALSE
                    """).setParameter("id", warehouseId).getResultList();
            if (rows.isEmpty()) throw validation("上架仓库不存在或已删除，请重新选择");
            Object[] row = rows.getFirst();
            if (!Boolean.TRUE.equals(row[2])) {
                throw validation("上架仓库必须是启用中的记账叶仓(不能是父仓、停用仓或不参与核算的仓)");
            }
            if (Boolean.TRUE.equals(row[1])) {
                throw conflict("线边仓是车间料架，采购/委外到货不能上架到线边仓");
            }
            names.put(warehouseId, row[0] == null ? "" : row[0].toString());
        }
        return names;
    }

    private void lockReceiptMutationDimensions(String type, UUID receiptId) {
        if (PURCHASE.equals(type)) {
            purchaseSupply.lockPurchaseReceiptMutationDimensions(receiptId);
        } else {
            subcontractSupply.lockSubcontractReceiptMutationDimensions(receiptId);
        }
    }

    static String normalizePlace(String raw) {
        return raw == null ? "" : raw.strip();
    }

    private static String normalizeReceiptType(String value) {
        String type = value == null ? "" : value.strip().toUpperCase(Locale.ROOT);
        if (!PURCHASE.equals(type) && !SUBCONTRACT.equals(type)) {
            throw validation("收货单类型仅支持 PURCHASE 或 SUBCONTRACT");
        }
        return type;
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? BigDecimal.ZERO : (BigDecimal) value;
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }
}
