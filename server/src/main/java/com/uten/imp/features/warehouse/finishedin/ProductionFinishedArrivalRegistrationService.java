package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.application.port.ProductionQualityInspectionPort;
import com.uten.imp.application.port.ProductionQualityInspectionPort.InspectionSheetRef;
import com.uten.imp.application.port.ProductionQualityInspectionPort.InspectionSheetRequest;
import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.weight.GoodsWeightObservationService;
import com.uten.imp.features.stock.weight.SourceKind;
import com.uten.imp.common.production.OutputLotText;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotMemberView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalRegistrationView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationResult;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.InspectionSheetSummaryView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.RegisteredReportView;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.RegistrationBatchView;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;

/**
 * Warehouse-owned destination/placement registration before production FQC.
 *
 * <p>V547：同一登记命令下同一成品仓的 FQC 待检行归入一张品质检查单（展示/办理聚合）。
 * V548：品质未处理的登记批次可撤回，报工行重新回到待登记；「未登记」谓词统一引用
 * 数据库视图 {@code v_production_report_items_pending_registration}。</p>
 *
 * <p>2026-09-27 库位记忆与建议统一：登记(单张/批量)在同一事务里自动把本次新建批次的
 * 库位记进 {@code warehouse_goods_place_preferences}(较新来源胜出、同一命令同仓同货同色
 * 多库位则不记)，不再有页面开关与单独的记忆接口；建议库位改走通用的
 * {@code POST /api/warehouse/place-suggestions}(与采购/委外到货登记同一口径)。</p>
 *
 * <p>V803 / ADR-148 / ADR-151 §5：登记以「实物交接批」为单位(同一报工、同一产出批次、送入仓库的
 * 需求份 / 计划公共 / 实际超产是同一堆货)，一批一个库位、一个实点、一个称重，由服务端展开到各份；
 * 单张与多张报工只有一个命令(批量命令)，服务端按「报工 x 实际入库仓」分组成登记批次。</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionFinishedArrivalRegistrationService {

    private static final org.slf4j.Logger log =
            org.slf4j.LoggerFactory.getLogger(ProductionFinishedArrivalRegistrationService.class);

    static final String SOURCE_ARRIVAL_BATCH = "ARRIVAL_BATCH";
    /** 称重观测的来源单据类型(登记头 id)与幂等键前缀 'FINISHED:' + 登记行 id (ADR-135 §3.2)。 */
    static final String OBSERVATION_SOURCE_TYPE = "PRODUCTION_FINISHED_ARRIVAL";
    static final String FINISHED_CAPTURE_PREFIX = "FINISHED:";
    /** 产成品数量误差: 仓库逐行点过数(先入库后质检)按 0.5%, 只有报工数按 1.5%。 */
    private static final BigDecimal COUNTED_QTY_EPS = new BigDecimal("0.005");
    private static final BigDecimal REPORTED_QTY_EPS = new BigDecimal("0.015");

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    private final ProductionStockTaskAccessPolicy access;
    private final ProductionQualityInspectionPort qualityInspection;
    private final TxSessionVars tx;
    @org.springframework.beans.factory.annotation.Autowired
    private com.uten.imp.features.master.warehouse.WarehouseScopeService warehouseScopes;
    /** 登记称重进单重学习(ADR-135); 可空: 直构测试不注入时只是不登记观测。 */
    @org.springframework.beans.factory.annotation.Autowired(required = false)
    private GoodsWeightObservationService weightObservations;

    /**
     * 先入库后质检(V597)：把未检成品的入库结果先定死在登记的成品仓 + 库位上，
     * 是一个独立的、可回收的决定，不靠 stock_doc:approve 顺带(它同时是登记与点收的按钮码)。
     */
    public static final String BEFORE_INSPECTION_AUTHORITY =
            "production_finished_in:before_inspection";

    private static void requireStockInBeforeInspectionAuthority() {
        var authentication = org.springframework.security.core.context.SecurityContextHolder
                .getContext().getAuthentication();
        boolean granted = authentication != null && authentication.isAuthenticated()
                && authentication.getAuthorities().stream().anyMatch(authority ->
                        BEFORE_INSPECTION_AUTHORITY.equals(authority.getAuthority()));
        if (!granted) {
            throw new ApiException(ErrorCode.FORBIDDEN,
                    "当前账号没有「产成品先入库后质检」权限，请改用「登记并送检」或联系管理员授权");
        }
    }

    /** Read only after the corresponding command lock, before any current warehouse checks. */
    private RegistrationOutcome existingRegistration(
            UUID reportId, NormalizedRequest normalized, UUID actorId) {
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, source_report_id, request_hash,
                                       warehouse_id, warehouse_name_snapshot
                                FROM production_finished_arrival_registrations
                                WHERE created_by = :actorId
                                  AND idempotency_key = :idempotencyKey
                                FOR UPDATE
                                """)
                        .setParameter("actorId", actorId)
                        .setParameter(
                                "idempotencyKey", normalized.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] existing = replay.getFirst();
            if (!Objects.equals(existing[1], reportId)
                    || !Objects.equals(existing[2], normalized.requestHash())) {
                throw conflict("同一防重复提交标识已用于不同的仓库登记请求，请刷新后重试");
            }
            return new RegistrationOutcome(
                    (UUID) existing[0], true, (UUID) existing[3],
                    NativeValueConverters.text(existing[4]), null);
        }
        return null;
    }

    /**
     * 新登记一组(同一报工、同一实际入库仓)：登记头 + 各批展开到各份的登记行 + 逐份 FQC PENDING。
     * 一批的各份同一个库位；先入库后质检时整批实点必须等于本批待登记合计，各份实点 = 各份报工数；
     * 整批称重按各份数量比例分摊(余数落在最后一份)。
     */
    private RegistrationOutcome registerNew(
            UUID reportId, NormalizedRequest normalized, RegistrationReferences references,
            UUID actorId, UUID receiverEmployeeId) {
        Object[] report = references.reports.computeIfAbsent(reportId, this::lockApprovedReport);
        Map<UUID, List<LotMember>> members = pendingLotMembers(reportId, normalized.lots().keySet());
        for (UUID lotId : normalized.lots().keySet()) {
            if (!members.containsKey(lotId)) {
                throw conflict("所选成品批已登记、已进入品质或来源已变化，请刷新后重试");
            }
        }
        if (normalized.stockInBeforeInspection()) {
            for (Map.Entry<UUID, List<LotMember>> lot : members.entrySet()) {
                BigDecimal total = lot.getValue().stream().map(LotMember::qty)
                        .reduce(BigDecimal.ZERO, BigDecimal::add);
                requireCountedLot(total, normalized.lots().get(lot.getKey()).countedQty());
            }
        }

        WarehouseSnapshot warehouse = references.warehouses.computeIfAbsent(normalized.warehouseId(), this::validatedWarehouse);
        if (references.receiver == null) references.receiver = requireReceiver(receiverEmployeeId);
        EmployeeSnapshot receiver = references.receiver;
        UUID registrationId = UUID.randomUUID();
        em.createNativeQuery("""
                        INSERT INTO production_finished_arrival_registrations(
                            id, source_report_id, warehouse_id,
                            warehouse_code_snapshot, warehouse_name_snapshot,
                            receiver_employee_id, receiver_name_snapshot,
                            idempotency_key, request_hash, remark, created_by,
                            stock_in_before_inspection, pre_stocked_at,
                            pre_stocked_by_employee_id)
                        VALUES (
                            :id, :reportId, :warehouseId,
                            :warehouseCode, :warehouseName,
                            :receiverId, :receiverName,
                            :idempotencyKey, :requestHash, :remark, :actorId,
                            :preStock,
                            CASE WHEN :preStock THEN now() END,
                            CASE WHEN :preStock THEN CAST(:preStockBy AS uuid) END)
                        """)
                .setParameter("preStock", normalized.stockInBeforeInspection())
                .setParameter("preStockBy", receiverEmployeeId)
                .setParameter("id", registrationId)
                .setParameter("reportId", reportId)
                .setParameter("warehouseId", normalized.warehouseId())
                .setParameter("warehouseCode", warehouse.code())
                .setParameter("warehouseName", warehouse.name())
                .setParameter("receiverId", receiverEmployeeId)
                .setParameter("receiverName", receiver.name())
                .setParameter("idempotencyKey", normalized.idempotencyKey())
                .setParameter("requestHash", normalized.requestHash())
                .setParameter("remark", normalized.remark())
                .setParameter("actorId", actorId)
                .executeUpdate();

        Map<UUID, WeighedLot> weighed = weighedLots(reportId, normalized.lots(), members);
        List<UUID> reportItemIds = new ArrayList<>();
        Map<UUID, UUID> firstRegistrationItemOfLot = new LinkedHashMap<>();
        for (Map.Entry<UUID, List<LotMember>> lot : members.entrySet()) {
            LotRequest lotRequest = normalized.lots().get(lot.getKey());
            WeighedLot weighedLot = weighed.get(lot.getKey());
            List<BigDecimal> weights = weighedLot == null
                    ? null : splitWeight(weighedLot.weightKg(), lot.getValue());
            for (int index = 0; index < lot.getValue().size(); index++) {
                LotMember member = lot.getValue().get(index);
                UUID registrationItemId = UUID.randomUUID();
                firstRegistrationItemOfLot.putIfAbsent(lot.getKey(), registrationItemId);
                reportItemIds.add(member.reportItemId());
                em.createNativeQuery("""
                                INSERT INTO production_finished_arrival_registration_items(
                                    id, registration_id, source_report_item_id,
                                    place_snapshot, created_by, counted_qty, weight)
                                VALUES (
                                    :id, :registrationId,
                                    :reportItemId, :place, :actorId, :countedQty, :weight)
                                """)
                        .setParameter("id", registrationItemId)
                        .setParameter("registrationId", registrationId)
                        .setParameter("reportItemId", member.reportItemId())
                        .setParameter("place", lotRequest.place())
                        .setParameter("actorId", actorId)
                        .setParameter("countedQty", normalized.stockInBeforeInspection() ? member.qty() : null)
                        .setParameter("weight", weights == null ? null : weights.get(index))
                        .executeUpdate();
            }
        }

        // This selected registration batch and its exact FQC PENDING facts
        // commit or roll back together. Unselected report lots remain pending.
        qualityInspection.registerApprovedReportItems(
                (UUID) report[0],
                reportItemIds.stream().sorted().toList(),
                registrationId);
        recordFinishedObservations(registrationId, normalized, weighed, firstRegistrationItemOfLot, actorId);
        return new RegistrationOutcome(
                registrationId, false, normalized.warehouseId(),
                warehouse.name(), receiver);
    }

    /**
     * 本报工所选批里还没登记的、送入仓库的各份(按批内归属优先级排好)。各份数量来自已审核报工，
     * 报工行已在命令开始时按 UUID 顺序加锁。
     */
    private Map<UUID, List<LotMember>> pendingLotMembers(UUID reportId, Collection<UUID> lotIds) {
        Map<UUID, List<LotMember>> result = new LinkedHashMap<>();
        if (lotIds.isEmpty()) return result;
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT lot.lot_id, lot.report_item_id, lot.qty, lot.slice_rank
                        FROM v_production_output_handoff_lots lot
                        JOIN v_production_report_items_pending_registration pending
                          ON pending.report_item_id = lot.report_item_id
                        WHERE lot.report_id = :reportId
                          AND lot.lot_id IN (:lotIds)
                          AND lot.destination = 'WAREHOUSE'
                        ORDER BY lot.lot_id, lot.lot_position
                        """)
                .setParameter("reportId", reportId)
                .setParameter("lotIds", List.copyOf(lotIds)))) {
            result.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>())
                    .add(new LotMember((UUID) row[1], NativeValueConverters.toBigDecimal(row[2]), ((Number) row[3]).intValue()));
        }
        return result;
    }

    /** 整批称重按各份数量比例分摊到登记行(4 位小数，余数落在最后一份；分到 0 的份记为没称)。 */
    static List<BigDecimal> splitWeight(BigDecimal totalKg, List<LotMember> members) {
        BigDecimal totalQty = members.stream().map(LotMember::qty).reduce(BigDecimal.ZERO, BigDecimal::add);
        List<BigDecimal> result = new ArrayList<>(members.size());
        BigDecimal assigned = BigDecimal.ZERO;
        BigDecimal cumulative = BigDecimal.ZERO;
        for (int index = 0; index < members.size(); index++) {
            cumulative = cumulative.add(members.get(index).qty());
            BigDecimal boundary = index == members.size() - 1 || totalQty.signum() == 0
                    ? totalKg
                    : com.uten.imp.common.finance.MoneyPolicy.quantitySlice(totalKg, totalQty, BigDecimal.ZERO, cumulative);
            BigDecimal share = boundary.subtract(assigned);
            assigned = boundary;
            result.add(share.signum() > 0 ? share : null);
        }
        return result;
    }

    /**
     * V548 登记撤回：仅当该批次每条 FQC 仍 PENDING 且无决定/放行/恢复授权。
     * 追加撤回记录 → 登记行标记 → 逐条 FQC 追加 REGISTRATION_REVERSED 取消事件；
     * 数据库延迟守卫在提交前核对批次无残留未取消 inspection。
     */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve')")
    public ArrivalRegistrationView reverse(
            UUID registrationId,
            ArrivalRegistrationReversalRequest request) {
        tx.bind();
        access.requireWarehouseTaskAccess("无权撤回生产成品送检登记");
        if (registrationId == null || request == null) {
            throw validation("登记撤回请求不能为空");
        }
        NormalizedReversal normalized = normalizeReversal(registrationId, request);
        UUID actorId = currentUser.requireId();
        lockCommand(actorId, "REVERSAL:" + normalized.idempotencyKey());
        List<Object[]> replay = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT reversal.id, reversal.registration_id,
                                       reversal.request_hash,
                                       registration.source_report_id
                                FROM production_finished_arrival_registration_reversals reversal
                                JOIN production_finished_arrival_registrations registration
                                  ON registration.id = reversal.registration_id
                                WHERE reversal.created_by = :actorId
                                  AND reversal.idempotency_key = :idempotencyKey
                                """)
                        .setParameter("actorId", actorId)
                        .setParameter("idempotencyKey", normalized.idempotencyKey()));
        if (!replay.isEmpty()) {
            Object[] existing = replay.getFirst();
            if (!Objects.equals(existing[1], registrationId)
                    || !Objects.equals(existing[2], normalized.requestHash())) {
                throw conflict("同一防重复提交标识已用于不同的登记撤回请求，请刷新后重试");
            }
            return detailInternal((UUID) existing[3], registrationId);
        }

        List<Object[]> registrations = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, source_report_id
                                FROM production_finished_arrival_registrations
                                WHERE id = :registrationId
                                FOR UPDATE
                                """)
                        .setParameter("registrationId", registrationId));
        if (registrations.size() != 1) throw notFound();
        UUID reportId = (UUID) registrations.getFirst()[1];
        lockApprovedReport(reportId);
        Number reversed = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_finished_arrival_registration_reversals
                        WHERE registration_id = :registrationId
                        """)
                .setParameter("registrationId", registrationId)
                .getSingleResult();
        if (reversed != null && reversed.longValue() > 0) {
            throw conflict("该登记批次已撤回，请刷新页面");
        }
        Number blocked = (Number) em.createNativeQuery("""
                        SELECT COUNT(*)
                        FROM production_finished_arrival_registration_items registration_item
                        LEFT JOIN production_fqc_inspections inspection
                          ON inspection.source_report_item_id =
                             registration_item.source_report_item_id
                         AND inspection.status <> 'CANCELLED'
                        WHERE registration_item.registration_id = :registrationId
                          AND registration_item.reversal_id IS NULL
                          AND (inspection.id IS NULL
                               OR inspection.status <> 'PENDING'
                               OR inspection.passed_qty <> 0
                               OR inspection.failed_qty <> 0
                               OR EXISTS (
                                   SELECT 1 FROM production_fqc_decision_events decision
                                   WHERE decision.inspection_id = inspection.id)
                               OR EXISTS (
                                   SELECT 1 FROM production_fqc_release_commands command
                                   WHERE command.inspection_id = inspection.id)
                               OR EXISTS (
                                   SELECT 1 FROM production_fqc_recovery_authorizations
                                                recovery_auth
                                   WHERE recovery_auth.source_inspection_id =
                                         inspection.id))
                        """)
                .setParameter("registrationId", registrationId)
                .getSingleResult();
        if (blocked != null && blocked.longValue() > 0) {
            throw conflict("该登记批次已有品质处理（已决定、已放行或已进入恢复链），不能撤回登记");
        }

        UUID reversalId = UUID.randomUUID();
        em.createNativeQuery("""
                        SELECT set_config(
                            'app.production_finished_arrival_reversal_id',
                            :reversalId, TRUE)
                        """)
                .setParameter("reversalId", reversalId.toString())
                .getSingleResult();
        em.createNativeQuery("""
                        INSERT INTO production_finished_arrival_registration_reversals(
                            id, registration_id, reason, idempotency_key,
                            request_hash, created_by)
                        VALUES (
                            :id, :registrationId, :reason, :idempotencyKey,
                            :requestHash, :actorId)
                        """)
                .setParameter("id", reversalId)
                .setParameter("registrationId", registrationId)
                .setParameter("reason", normalized.reason())
                .setParameter("idempotencyKey", normalized.idempotencyKey())
                .setParameter("requestHash", normalized.requestHash())
                .setParameter("actorId", actorId)
                .executeUpdate();
        int cancelled = qualityInspection.cancelForReversedRegistration(
                registrationId, reversalId);
        if (cancelled == 0) {
            throw conflict("该登记批次没有可取消的待检任务，撤回已中止");
        }
        reverseFinishedObservations(registrationId);
        return detailInternal(reportId, registrationId);
    }

    /**
     * 本次登记里称了重的批(ADR-135 §3.2)，一条 SQL 读出记观测要的货品/单位/换算率/车间。
     * 按重量计的货品(基本单位或报工单位登记了重量单位)丢弃手填重量: 库存账按数量精确换算。
     */
    private Map<UUID, WeighedLot> weighedLots(
            UUID reportId, Map<UUID, LotRequest> lots, Map<UUID, List<LotMember>> members) {
        Map<UUID, UUID> firstItemOfLot = new LinkedHashMap<>();
        for (Map.Entry<UUID, LotRequest> lot : lots.entrySet()) {
            List<LotMember> lotMembers = members.get(lot.getKey());
            if (lot.getValue().weight() != null && lotMembers != null && !lotMembers.isEmpty()) {
                firstItemOfLot.put(lot.getKey(), lotMembers.getFirst().reportItemId());
            }
        }
        if (firstItemOfLot.isEmpty()) return Map.of();
        Map<UUID, Object[]> byItem = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT report_item.id, report_item.goods_id, report_item.color_id,
                               report_item.unit_id, COALESCE(report_item.unit_rate, 1),
                               report.department_id,
                               (goods_profile.mass_unit_code IS NOT NULL
                                OR line_profile.mass_unit_code IS NOT NULL) AS exact_weight
                        FROM production_daily_report_items report_item
                        JOIN production_daily_reports report ON report.id = report_item.report_id
                        JOIN goods goods_row ON goods_row.id = report_item.goods_id
                        LEFT JOIN unit_measurement_profiles goods_profile
                          ON goods_profile.unit_id = goods_row.unit_id
                        LEFT JOIN unit_measurement_profiles line_profile
                          ON line_profile.unit_id = report_item.unit_id
                        WHERE report_item.report_id = :reportId
                          AND report_item.id IN (:ids)
                        """)
                .setParameter("reportId", reportId)
                .setParameter("ids", List.copyOf(firstItemOfLot.values())))) {
            byItem.put((UUID) row[0], row);
        }
        Map<UUID, WeighedLot> result = new LinkedHashMap<>();
        for (Map.Entry<UUID, UUID> lot : firstItemOfLot.entrySet()) {
            Object[] row = byItem.get(lot.getValue());
            if (row == null || Boolean.TRUE.equals(row[6])) continue;
            BigDecimal reported = members.get(lot.getKey()).stream().map(LotMember::qty)
                    .reduce(BigDecimal.ZERO, BigDecimal::add);
            result.put(lot.getKey(), new WeighedLot(
                    lots.get(lot.getKey()).weight(), (UUID) row[1], (UUID) row[2], (UUID) row[3],
                    NativeValueConverters.toBigDecimal(row[4]), reported, (UUID) row[5]));
        }
        return result;
    }

    /**
     * 产成品登记称重进单重学习: 每个称了重的批一条 FINISHED 观测(挂在该批第一份的登记行上), 与登记同事务。
     * 数量 = (整批实点数, 没有则整批报工数) x 换算率; 实点过的数量误差按 0.5%, 只有报工数按 1.5%;
     * 往来方记报工车间。
     */
    private void recordFinishedObservations(
            UUID registrationId, NormalizedRequest normalized,
            Map<UUID, WeighedLot> weighed, Map<UUID, UUID> firstRegistrationItemOfLot, UUID actorId) {
        if (weightObservations == null || weighed.isEmpty()) return;
        OffsetDateTime observedAt = OffsetDateTime.now();
        for (Map.Entry<UUID, WeighedLot> entry : weighed.entrySet()) {
            WeighedLot lot = entry.getValue();
            UUID registrationItemId = firstRegistrationItemOfLot.get(entry.getKey());
            if (registrationItemId == null) continue;
            BigDecimal counted = normalized.stockInBeforeInspection()
                    ? normalized.lots().get(entry.getKey()).countedQty() : null;
            BigDecimal qty = counted != null ? counted : lot.reportedQty();
            weightObservations.record(new GoodsWeightObservationService.ObservationCommand(
                    lot.goodsId(), lot.colorId(), normalized.warehouseId(), SourceKind.FINISHED,
                    qty.multiply(lot.unitRate()), lot.weightKg(), null,
                    lot.departmentId() == null ? null : "WORKSHOP", lot.departmentId(),
                    OBSERVATION_SOURCE_TYPE, registrationId, registrationItemId, null,
                    FINISHED_CAPTURE_PREFIX + registrationItemId, observedAt, null, null,
                    counted != null ? COUNTED_QTY_EPS : REPORTED_QTY_EPS,
                    false, lot.unitId(), false, null, actorId));
        }
    }

    /** 登记撤回 = 这批登记作废, 它记下的 FINISHED 称重观测一并红冲。 */
    private void reverseFinishedObservations(UUID registrationId) {
        if (weightObservations == null) return;
        for (UUID registrationItemId : NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT id FROM production_finished_arrival_registration_items
                        WHERE registration_id = :registrationId AND weight IS NOT NULL
                        ORDER BY id
                        """).setParameter("registrationId", registrationId), UUID.class)) {
            weightObservations.reverseByCaptureKey(FINISHED_CAPTURE_PREFIX + registrationItemId);
        }
    }

    /**
     * 登记即记忆：把本次命令新建的登记批次的库位写进本仓×货品×颜色的记忆库位，
     * 与登记同一事务(登记成功即记住，登记回滚记忆一并回滚)。
     *
     * <ul>
     *   <li>同一命令内同仓同货同色出现多个不同库位 = 无法判断该记哪个，跳过该维度(不报错)；</li>
     *   <li>较新来源胜出：(来源时间, 来源 UUID) 不比现有偏好新则不改(重放天然幂等)；</li>
     *   <li>货品已删除、库位不合规等「记不了」的情形一律静默跳过，绝不挡住登记；
     *       只有真正的数据库错误才会随登记一起失败。</li>
     *   <li>按(仓库, 货品, 颜色)固定顺序 upsert，并发命令不因加锁顺序相反而死锁。</li>
     * </ul>
     */
    private void rememberRegisteredPlaces(Collection<UUID> registrationIds) {
        if (registrationIds == null || registrationIds.isEmpty()) return;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT registration.id,
                                       registration.warehouse_id,
                                       registration.created_at,
                                       report_item.goods_id,
                                       report_item.color_id,
                                       registration_item.place_snapshot,
                                       goods.code,
                                       goods.name
                                FROM production_finished_arrival_registrations registration
                                JOIN production_finished_arrival_registration_items
                                          registration_item
                                  ON registration_item.registration_id = registration.id
                                 AND registration_item.reversal_id IS NULL
                                JOIN production_daily_report_items report_item
                                  ON report_item.id = registration_item.source_report_item_id
                                 AND report_item.is_deleted = FALSE
                                JOIN goods goods
                                  ON goods.id = report_item.goods_id
                                 AND goods.is_deleted = FALSE
                                WHERE registration.id IN (:registrationIds)
                                ORDER BY registration.warehouse_id,
                                         report_item.goods_id,
                                         report_item.color_id NULLS FIRST,
                                         registration.id,
                                         report_item.id
                                """)
                        .setParameter("registrationIds", List.copyOf(registrationIds)));
        if (rows.isEmpty()) return;

        // 同一命令按仓分组；每个维度的来源 = 贡献它的批次里 (created_at, UUID) 最新的一个
        // (UUID 文本序 = PostgreSQL uuid 序，与 upsert 的较新判定同口径)。
        Map<UUID, List<RememberPlaceSource>> sourcesByWarehouse = new LinkedHashMap<>();
        Map<UUID, Map<PlaceDimension, RememberSourceRegistration>> latestByWarehouse =
                new LinkedHashMap<>();
        Comparator<RememberSourceRegistration> newer = Comparator
                .comparing(RememberSourceRegistration::registeredAt)
                .thenComparing(source -> source.registrationId().toString());
        for (Object[] row : rows) {
            UUID warehouseId = (UUID) row[1];
            UUID goodsId = (UUID) row[3];
            UUID colorId = (UUID) row[4];
            sourcesByWarehouse.computeIfAbsent(warehouseId, ignored -> new ArrayList<>())
                    .add(new RememberPlaceSource(
                            goodsId, colorId, NativeValueConverters.text(row[5]), NativeValueConverters.text(row[6]), NativeValueConverters.text(row[7])));
            RememberSourceRegistration candidate = new RememberSourceRegistration(
                    (UUID) row[0], offsetDateTime(row[2]));
            latestByWarehouse.computeIfAbsent(warehouseId, ignored -> new LinkedHashMap<>())
                    .merge(new PlaceDimension(goodsId, colorId), candidate,
                            (left, right) -> newer.compare(left, right) >= 0 ? left : right);
        }

        UUID actorId = currentUser.requireId();
        UUID employeeId = currentUser.requireEmployeeId();
        for (Map.Entry<UUID, List<RememberPlaceSource>> entry : sourcesByWarehouse.entrySet()) {
            UUID warehouseId = entry.getKey();
            RememberPlan plan = buildRememberPlan(entry.getValue());
            if (plan.ambiguous() > 0) {
                log.info("生产成品登记库位未记忆 warehouse={} ambiguous={} detail={}",
                        warehouseId, plan.ambiguous(), plan.warnings());
            }
            Map<PlaceDimension, RememberSourceRegistration> latest =
                    latestByWarehouse.get(warehouseId);
            for (RememberCandidate candidate : plan.candidates()) {
                RememberSourceRegistration source = latest.get(
                        new PlaceDimension(candidate.goodsId(), candidate.colorId()));
                if (source == null || source.registeredAt() == null) continue;
                upsertPlacePreference(warehouseId, candidate, source, employeeId, actorId);
            }
        }
    }

    /** V431/V451 较新来源胜出的 upsert：(来源时间, 来源 UUID) 不比现有偏好新则保持不动。 */
    private void upsertPlacePreference(
            UUID warehouseId, RememberCandidate candidate,
            RememberSourceRegistration source, UUID employeeId, UUID actorId) {
        em.createNativeQuery("""
                        INSERT INTO warehouse_goods_place_preferences(
                            id, warehouse_id, goods_id, color_id, place,
                            selection_count, version,
                            source_kind, source_registration_id,
                            source_iqc_batch_id, source_registered_at,
                            last_selected_by, last_selected_at,
                            created_by, updated_by)
                        VALUES (
                            gen_random_uuid(), :warehouseId, :goodsId,
                            CAST(:colorId AS uuid), :place, 1, 0,
                            'FINISHED_ARRIVAL', :registrationId,
                            NULL, :registeredAt,
                            :employeeId, now(), :actorId, :actorId)
                        ON CONFLICT ON CONSTRAINT
                            warehouse_goods_place_preference_dimension_uk
                        DO UPDATE SET
                            place = EXCLUDED.place,
                            selection_count =
                                warehouse_goods_place_preferences.selection_count + 1,
                            version = warehouse_goods_place_preferences.version + 1,
                            source_kind = EXCLUDED.source_kind,
                            source_registration_id =
                                EXCLUDED.source_registration_id,
                            source_iqc_batch_id =
                                EXCLUDED.source_iqc_batch_id,
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
                            EXCLUDED.source_registration_id
                        )
                        """)
                .setParameter("warehouseId", warehouseId)
                .setParameter("goodsId", candidate.goodsId())
                .setParameter("colorId", candidate.colorId() == null
                        ? null : candidate.colorId().toString())
                .setParameter("place", candidate.place())
                .setParameter("registrationId", source.registrationId())
                .setParameter("registeredAt", source.registeredAt())
                .setParameter("employeeId", employeeId)
                .setParameter("actorId", actorId)
                .executeUpdate();
    }

    private ArrivalRegistrationView detailInternal(UUID reportId) {
        return detailInternal(reportId, null);
    }

    /**
     * Without an exact registration id this is the recoverable work view: if
     * any line is still pending, only those lines are returned and registered
     * is false.  Replays and post-create responses pass the immutable
     * registration id and receive that exact historical batch.
     */
    private ArrivalRegistrationView detailInternal(
            UUID reportId,
            UUID exactRegistrationId) {
        if (reportId == null) throw notFound();
        List<Object[]> headers = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report.id, report.bill_no,
                                        report.bill_date, report.department_id,
                                        report.workshop_name
                                FROM production_daily_reports report
                                WHERE report.id = :reportId
                                  AND report.status = 1
                                  AND report.is_deleted = FALSE
                                """)
                        .setParameter("reportId", reportId));
        if (headers.size() != 1) throw notFound();
        Object[] header = headers.getFirst();

        List<Object[]> rows = exactRegistrationId == null
                ? pendingItemRows(reportId)
                : List.of();
        Object[] registration = null;
        boolean registered = rows.isEmpty();
        if (registered) {
            registration = registrationHeader(reportId, exactRegistrationId);
            if (registration == null) throw notFound();
            rows = NativeQueryResults.objectArrayRows(
                    em.createNativeQuery("""
                                SELECT lot.lot_id, report_item.id, report_item.line_no,
                                        report_item.plan_item_id,
                                        report_item.execution_segment_id,
                                       plan.id, plan.bill_no,
                                       report_item.goods_id,
                                       goods.code, goods.name,
                                       report_item.color_id, color.name,
                                       report_item.unit_id, unit.name,
                                       report_item.qty,
                                       registration_item.place_snapshot,
                                       goods.stock_place,
                                       NULL::uuid AS last_warehouse_id,
                                       NULL::text AS last_warehouse_name,
                                       registration_item.counted_qty,
                                       registration_item.weight,
                                       COALESCE(report_item.unit_rate, 1) AS unit_rate,
                                       lot.slice_rank
                                FROM production_daily_report_items report_item
                                JOIN v_production_output_handoff_lots lot
                                  ON lot.report_item_id = report_item.id
                                 AND lot.report_id = :reportId
                                JOIN production_plan_items plan_item
                                  ON plan_item.id = report_item.plan_item_id
                                 AND plan_item.is_deleted = FALSE
                                JOIN production_plans plan
                                  ON plan.id = plan_item.plan_id
                                 AND plan.is_deleted = FALSE
                                JOIN goods goods ON goods.id = report_item.goods_id
                                LEFT JOIN colors color
                                  ON color.id = report_item.color_id
                                LEFT JOIN units unit
                                  ON unit.id = report_item.unit_id
                                JOIN production_finished_arrival_registration_items
                                          registration_item
                                  ON registration_item.source_report_item_id = report_item.id
                                 AND registration_item.registration_id = :registrationId
                                WHERE report_item.report_id = :reportId
                                  AND report_item.is_deleted = FALSE
                                ORDER BY report_item.line_no NULLS LAST,
                                         report_item.id
                                """)
                            .setParameter("reportId", reportId)
                            .setParameter("registrationId", registration[0]));
        }
        if (rows.isEmpty()) throw notFound();
        EmployeeSnapshot currentReceiver = registered
                ? null
                : requireReceiver(currentUser.requireEmployeeId());
        List<RegistrationBatchView> batches = registrationBatches(reportId);
        RegistrationBatchView current = null;
        if (registered) {
            UUID registrationId = (UUID) registration[0];
            current = batches.stream()
                    .filter(batch -> registrationId.equals(batch.registrationId()))
                    .findFirst()
                    .orElse(null);
        }
        return new ArrivalRegistrationView(
                registered ? (UUID) registration[0] : null,
                registered, (UUID) header[0],
                NativeValueConverters.text(header[1]), NativeValueConverters.toLocalDate(header[2]), (UUID) header[3],
                NativeValueConverters.text(header[4]),
                registered ? (UUID) registration[1] : null,
                registered ? NativeValueConverters.text(registration[2]) : null,
                registered ? NativeValueConverters.text(registration[3]) : null,
                registered ? (UUID) registration[4] : currentReceiver.id(),
                registered ? NativeValueConverters.text(registration[5]) : currentReceiver.name(),
                registered ? NativeValueConverters.text(registration[7]) : null,
                registered ? offsetDateTime(registration[6]) : null,
                mapLots(rows),
                current == null ? null : current.sheetId(),
                current == null ? null : current.sheetNo(),
                current == null ? null : current.reversedAt(),
                current == null ? null : current.reversalReason(),
                current != null && current.reversible(),
                batches,
                registered && Boolean.TRUE.equals(registration[8]));
    }

    /** 同一报工的全部登记批次（含检查单号、撤回态、可撤回判定）；无登记时为空。 */
    private List<RegistrationBatchView> registrationBatches(UUID reportId) {
        return registrationBatches(List.of(reportId)).getOrDefault(reportId, List.of());
    }

    /**
     * 多张报工的登记批次历史一次查完(ADR-151 §5：登记页 1..N 个来源都带回已有批次，部分登记、撤回后
     * 重登的报工照样能在本页看见并撤回)；按报工分组，组内按登记时间。
     */
    private Map<UUID, List<RegistrationBatchView>> registrationBatches(List<UUID> reportIds) {
        Map<UUID, List<RegistrationBatchView>> result = new LinkedHashMap<>();
        if (reportIds.isEmpty()) return result;
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT registration.id,
                                       registration.warehouse_id,
                                       registration.warehouse_name_snapshot,
                                       registration.receiver_name_snapshot,
                                       registration.remark,
                                       registration.created_at,
                                       (SELECT COUNT(*)
                                        FROM production_finished_arrival_registration_items item
                                        WHERE item.registration_id = registration.id),
                                       sheet.id,
                                       sheet.sheet_no,
                                       reversal.created_at,
                                       reversal.reason,
                                       reversal.id IS NULL
                                       AND NOT EXISTS (
                                           SELECT 1
                                           FROM production_finished_arrival_registration_items item
                                           LEFT JOIN production_fqc_inspections inspection
                                             ON inspection.source_report_item_id =
                                                item.source_report_item_id
                                            AND inspection.status <> 'CANCELLED'
                                           WHERE item.registration_id = registration.id
                                             AND item.reversal_id IS NULL
                                             AND (inspection.id IS NULL
                                                  OR inspection.status <> 'PENDING'
                                                  OR inspection.passed_qty <> 0
                                                  OR inspection.failed_qty <> 0
                                                  OR EXISTS (
                                                      SELECT 1
                                                      FROM production_fqc_decision_events decision
                                                      WHERE decision.inspection_id = inspection.id)
                                                  OR EXISTS (
                                                      SELECT 1
                                                      FROM production_fqc_release_commands command
                                                      WHERE command.inspection_id = inspection.id)
                                                  OR EXISTS (
                                                      SELECT 1
                                                      FROM production_fqc_recovery_authorizations
                                                           recovery_auth
                                                      WHERE recovery_auth.source_inspection_id =
                                                            inspection.id))) AS reversible,
                                       registration.source_report_id
                                FROM production_finished_arrival_registrations registration
                                LEFT JOIN production_finished_arrival_registration_reversals reversal
                                  ON reversal.registration_id = registration.id
                                LEFT JOIN LATERAL (
                                    SELECT sheet.id, sheet.sheet_no
                                    FROM production_fqc_inspection_sheet_items sheet_item
                                    JOIN production_fqc_inspection_sheets sheet
                                      ON sheet.id = sheet_item.sheet_id
                                    WHERE sheet_item.registration_id = registration.id
                                    ORDER BY sheet.created_at, sheet.id
                                    LIMIT 1
                                ) sheet ON TRUE
                                WHERE registration.source_report_id IN (:reportIds)
                                ORDER BY registration.source_report_id, registration.created_at, registration.id
                                """)
                        .setParameter("reportIds", reportIds));
        for (Object[] row : rows) {
            result.computeIfAbsent((UUID) row[12], ignored -> new ArrayList<>()).add(new RegistrationBatchView(
                    (UUID) row[0], (UUID) row[1], NativeValueConverters.text(row[2]), NativeValueConverters.text(row[3]),
                    NativeValueConverters.text(row[4]), offsetDateTime(row[5]),
                    ((Number) row[6]).intValue(), (UUID) row[7], NativeValueConverters.text(row[8]),
                    offsetDateTime(row[9]), NativeValueConverters.text(row[10]),
                    Boolean.TRUE.equals(row[11])));
        }
        result.replaceAll((report, batches) -> List.copyOf(batches));
        return result;
    }

    private static final String PENDING_ITEM_COLUMNS = """
            SELECT lot.lot_id, report_item.id, report_item.line_no,
                   report_item.plan_item_id,
                   report_item.execution_segment_id,
                   plan.id, plan.bill_no,
                   report_item.goods_id,
                   goods.code, goods.name,
                   report_item.color_id, color.name,
                   report_item.unit_id, unit.name,
                   report_item.qty,
                   NULL::text AS place_snapshot,
                   goods.stock_place,
                   last_warehouse.id,
                   last_warehouse.name,
                   NULL::numeric AS counted_qty,
                   NULL::numeric AS weight,
                   COALESCE(report_item.unit_rate, 1) AS unit_rate,
                   lot.slice_rank
            """;

    /**
     * 待登记行的默认仓只读货品主档，并校验当前实际仓资格。
     * DTO lastWarehouse 字段保留兼容名称；不再扫描登记历史，也不改历史快照。
     * 只列送入仓库的份(直送车间的份不经仓库登记)，按实物交接批分组。
     */
    private static final String PENDING_ITEM_JOINS = """
            FROM production_daily_report_items report_item
            JOIN v_production_report_items_pending_registration pending
              ON pending.report_item_id = report_item.id
            JOIN v_production_output_handoff_lots lot
              ON lot.report_item_id = report_item.id
             AND lot.report_id = report_item.report_id
            JOIN production_plan_items plan_item
              ON plan_item.id = report_item.plan_item_id
             AND plan_item.is_deleted = FALSE
            JOIN production_plans plan
              ON plan.id = plan_item.plan_id
             AND plan.is_deleted = FALSE
            JOIN goods goods ON goods.id = report_item.goods_id
            LEFT JOIN colors color
              ON color.id = report_item.color_id
            LEFT JOIN units unit
              ON unit.id = report_item.unit_id
            """ + com.uten.imp.features.warehouse.WarehouseMasterDefaultsSql.owningWarehouseJoin("goods", "last_warehouse");

    private List<Object[]> pendingItemRows(UUID reportId) {
        return NativeQueryResults.objectArrayRows(
                em.createNativeQuery(PENDING_ITEM_COLUMNS + PENDING_ITEM_JOINS + """
                                WHERE report_item.report_id = :reportId
                                  AND lot.report_id = :reportId
                                  AND report_item.destination = 'WAREHOUSE'
                                ORDER BY report_item.line_no NULLS LAST,
                                         report_item.id
                                """)
                        .setParameter("reportId", reportId));
    }

    private Object[] registrationHeader(
            UUID reportId,
            UUID exactRegistrationId) {
        String exact = exactRegistrationId == null
                ? ""
                : " AND registration.id = :registrationId ";
        var query = em.createNativeQuery("""
                        SELECT registration.id, registration.warehouse_id,
                               registration.warehouse_code_snapshot,
                               registration.warehouse_name_snapshot,
                               registration.receiver_employee_id,
                               registration.receiver_name_snapshot,
                               registration.created_at,
                               registration.remark,
                               registration.stock_in_before_inspection
                        FROM production_finished_arrival_registrations registration
                        WHERE registration.source_report_id = :reportId
                        """ + exact + """
                        ORDER BY EXISTS (
                                     SELECT 1
                                     FROM production_finished_arrival_registration_reversals reversal
                                     WHERE reversal.registration_id = registration.id),
                                 registration.created_at DESC,
                                 registration.id DESC
                        LIMIT 1
                        """)
                .setParameter("reportId", reportId);
        if (exactRegistrationId != null) {
            query.setParameter("registrationId", exactRegistrationId);
        }
        List<Object[]> rows = NativeQueryResults.objectArrayRows(query);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /**
     * 一份一行的查询结果按实物交接批分组(批的顺序 = 批内第一份的行号顺序)：
     * 合计、按归属拆分与拆分文案由服务端算一次；库位、实点、称重是整批一个。
     */
    static List<ArrivalLotView> mapLots(List<Object[]> rows) {
        Map<UUID, List<Object[]>> byLot = new LinkedHashMap<>();
        for (Object[] row : rows) {
            byLot.computeIfAbsent((UUID) row[0], ignored -> new ArrayList<>()).add(row);
        }
        List<ArrivalLotView> result = new ArrayList<>(byLot.size());
        for (Map.Entry<UUID, List<Object[]>> lot : byLot.entrySet()) {
            List<Object[]> lotRows = new ArrayList<>(lot.getValue());
            lotRows.sort(Comparator
                    .comparingInt((Object[] row) -> ((Number) row[22]).intValue())
                    .thenComparing(row -> integer(row[2]), Comparator.nullsLast(Comparator.naturalOrder()))
                    .thenComparing(row -> row[1].toString()));
            BigDecimal total = BigDecimal.ZERO;
            BigDecimal demand = BigDecimal.ZERO;
            BigDecimal publicQty = BigDecimal.ZERO;
            BigDecimal surplus = BigDecimal.ZERO;
            BigDecimal overLimit = BigDecimal.ZERO;
            BigDecimal counted = BigDecimal.ZERO;
            boolean allCounted = true;
            BigDecimal weight = null;
            Integer lineNo = null;
            List<ArrivalLotMemberView> members = new ArrayList<>(lotRows.size());
            for (Object[] row : lotRows) {
                int rank = ((Number) row[22]).intValue();
                BigDecimal qty = NativeValueConverters.toBigDecimal(row[14]);
                total = total.add(qty);
                switch (rank) {
                    case OutputLotText.RANK_OVER_LIMIT -> {
                        surplus = surplus.add(qty);
                        overLimit = overLimit.add(qty);
                    }
                    case OutputLotText.RANK_ACTUAL_SURPLUS -> surplus = surplus.add(qty);
                    case OutputLotText.RANK_PUBLIC -> publicQty = publicQty.add(qty);
                    default -> demand = demand.add(qty);
                }
                if (row[19] == null) allCounted = false;
                else counted = counted.add((BigDecimal) row[19]);
                if (row[20] != null) weight = (weight == null ? BigDecimal.ZERO : weight).add((BigDecimal) row[20]);
                Integer memberLine = integer(row[2]);
                if (memberLine != null && (lineNo == null || memberLine < lineNo)) lineNo = memberLine;
                members.add(new ArrivalLotMemberView(
                        (UUID) row[1], memberLine, qty, rank, OutputLotText.kind(rank)));
            }
            Object[] first = lotRows.getFirst();
            result.add(new ArrivalLotView(
                    lot.getKey(), lineNo, members,
                    (UUID) first[3], (UUID) first[4], (UUID) first[5], NativeValueConverters.text(first[6]),
                    (UUID) first[7], NativeValueConverters.text(first[8]), NativeValueConverters.text(first[9]),
                    (UUID) first[10], NativeValueConverters.text(first[11]), (UUID) first[12], NativeValueConverters.text(first[13]),
                    total, demand, publicQty, surplus,
                    OutputLotText.split(demand, publicQty, surplus, overLimit),
                    NativeValueConverters.text(first[15]), NativeValueConverters.text(first[16]), (UUID) first[17], NativeValueConverters.text(first[18]),
                    allCounted ? counted : null, weight, NativeValueConverters.toBigDecimal(first[21])));
        }
        return result;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public List<ArrivalRegistrationView> batchDetail(List<UUID> reportIds) {
        access.requireWarehouseTaskAccess("无权查看生产成品送检登记");
        List<UUID> ids = requireReportIds(reportIds);
        List<Object[]> headerRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT report.id, report.bill_no,
                                       report.bill_date, report.department_id,
                                       report.workshop_name
                                FROM production_daily_reports report
                                WHERE report.id IN (:reportIds)
                                  AND report.status = 1
                                  AND report.is_deleted = FALSE
                                """)
                        .setParameter("reportIds", ids));
        Map<UUID, Object[]> headerByReport = new LinkedHashMap<>();
        for (Object[] header : headerRows) {
            headerByReport.put((UUID) header[0], header);
        }

        List<Object[]> itemRows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery(
                        "SELECT report_item.report_id, " + PENDING_ITEM_COLUMNS.substring(7)
                                + PENDING_ITEM_JOINS + """
                                WHERE report_item.report_id IN (:reportIds)
                                  AND lot.report_id IN (:reportIds)
                                  AND report_item.destination = 'WAREHOUSE'
                                ORDER BY report_item.report_id,
                                         report_item.line_no NULLS LAST,
                                         report_item.id
                                """)
                        .setParameter("reportIds", ids));
        Map<UUID, List<Object[]>> itemsByReport = new LinkedHashMap<>();
        for (Object[] row : itemRows) {
            itemsByReport.computeIfAbsent(
                    (UUID) row[0], ignored -> new ArrayList<>())
                    .add(java.util.Arrays.copyOfRange(row, 1, row.length));
        }
        EmployeeSnapshot receiver = itemRows.isEmpty()
                ? null
                : requireReceiver(currentUser.requireEmployeeId());

        // 已有的登记批次(含撤回历史)一次查完：部分登记或撤回过的报工在本页仍能看见并撤回。
        Map<UUID, List<RegistrationBatchView>> batchesByReport = registrationBatches(
                ids.stream().filter(itemsByReport::containsKey).toList());
        List<ArrivalRegistrationView> result = new ArrayList<>();
        for (UUID reportId : ids) {
            Object[] header = headerByReport.get(reportId);
            List<Object[]> items = itemsByReport.get(reportId);
            if (header == null || items == null || items.isEmpty()) {
                // Stale selections are uncommon; preserve the former exact
                // registered-history/not-found behavior without penalizing
                // the normal all-pending batch with N database round trips.
                result.add(detailInternal(reportId));
                continue;
            }
            result.add(new ArrivalRegistrationView(
                    null, false, (UUID) header[0],
                    NativeValueConverters.text(header[1]), NativeValueConverters.toLocalDate(header[2]), (UUID) header[3],
                    NativeValueConverters.text(header[4]), null, null, null,
                    receiver.id(), receiver.name(), null, null,
                    mapLots(items),
                    null, null, null, null, false,
                    batchesByReport.getOrDefault(reportId, List.of()), false));
        }
        return List.copyOf(result);
    }

    /**
     * 产成品入库登记的唯一命令(单张 = 1 个来源, 多选 = N 个来源; ADR-151 §5)：外层一个事务，
     * 按「报工 x 实际入库仓」分组，每组复用同一登记核心(整批展开 + 逐份 FQC)；任一组失败整批回滚。
     * 幂等：批量键 + 报工 + 仓库派生每组子键，重试时已完成的组按原结果重放。
     * V547：本批新建的登记按成品仓分组，每个仓生成一张品质检查单(同键重放不再建单)。
     * 本批新建的登记同事务自动记忆库位；重放的组不再记忆。
     */
    @Transactional
    @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve')")
    public BatchArrivalRegistrationResult batchRegister(
            BatchArrivalRegistrationRequest request) {
        tx.bind();
        access.requireWarehouseTaskAccess("无权登记生产成品送检");
        if (request == null || request.idempotencyKey() == null
                || request.lots() == null || request.lots().isEmpty()) {
            throw validation("入库登记请求不能为空");
        }
        boolean preStock = request.stockInBeforeInspectionRequested();
        if (preStock) {
            requireStockInBeforeInspectionAuthority();
        }
        String batchKey = request.idempotencyKey().strip();
        if (batchKey.length() < 8 || batchKey.length() > 128
                || !batchKey.matches("[A-Za-z0-9._:-]+")) {
            throw validation("入库登记的防重复提交标识格式不正确");
        }
        String remark = normalizeRemark(request.remark());
        Map<UUID, ArrivalLotRequest> requested = normalizeLots(request.lots(), preStock);
        Map<UUID, UUID> reportOfLot = lotReports(requested.keySet());
        if (reportOfLot.size() != requested.size()) {
            throw conflict("所选成品批不存在或来源已变化，请刷新后重试");
        }
        if (reportOfLot.values().stream().distinct().count() > 50) {
            throw validation("一次最多汇总登记 50 张报工单");
        }

        // 「报工 x 实际入库仓」一组 = 一个登记批次；分组、子键与锁顺序都只认服务端排序。
        Map<GroupKey, Map<UUID, LotRequest>> groups = new TreeMap<>();
        requested.forEach((lotId, lot) -> groups
                .computeIfAbsent(new GroupKey(reportOfLot.get(lotId), lot.warehouseId()),
                        ignored -> new TreeMap<>())
                .put(lotId, new LotRequest(lot.place().strip(), lot.countedQty() == null
                        ? null : lot.countedQty().stripTrailingZeros(), normalizedWeight(lot.weight()))));
        Map<GroupKey, NormalizedRequest> normalizedGroups = new LinkedHashMap<>();
        groups.forEach((group, lots) -> normalizedGroups.put(group,
                normalizeGroup(batchKey, group, lots, remark, preStock)));

        UUID actorId = currentUser.requireId();
        UUID receiverEmployeeId = currentUser.requireEmployeeId();
        for (String key : normalizedGroups.values().stream().map(NormalizedRequest::idempotencyKey).sorted().toList()) {
            lockCommand(actorId, key);
        }
        Map<GroupKey, RegistrationOutcome> outcomes = new LinkedHashMap<>();
        for (var entry : normalizedGroups.entrySet()) {
            outcomes.put(entry.getKey(), existingRegistration(entry.getKey().reportId(), entry.getValue(), actorId));
        }
        List<GroupKey> pendingGroups = normalizedGroups.keySet().stream()
                .filter(group -> outcomes.get(group) == null).toList();
        RegistrationReferences references = new RegistrationReferences();
        // Every report/item precedes every warehouse. Otherwise disjoint report
        // batches visiting warehouses A/B in opposite order can deadlock.
        List<UUID> pendingReports = pendingGroups.stream().map(GroupKey::reportId).distinct().sorted().toList();
        for (UUID reportId : pendingReports) {
            references.reports.put(reportId, lockApprovedReport(reportId));
        }
        if (!pendingReports.isEmpty()) {
            em.createNativeQuery("""
                    SELECT id FROM production_daily_report_items
                    WHERE report_id IN (:reportIds)
                    ORDER BY report_id, id FOR UPDATE
                    """).setParameter("reportIds", pendingReports).getResultList();
            for (UUID warehouseId : pendingGroups.stream()
                    .map(GroupKey::warehouseId).distinct().sorted().toList()) {
                references.warehouses.put(warehouseId, validatedWarehouse(warehouseId));
            }
            references.receiver = requireReceiver(receiverEmployeeId);
        }
        for (GroupKey group : pendingGroups) {
            outcomes.put(group, registerNew(group.reportId(), normalizedGroups.get(group), references,
                    actorId, receiverEmployeeId));
        }

        // 同仓新建批次 → 一张检查单；备注与收货人来自本批命令（登记头已分别冻结）。
        Map<UUID, List<RegistrationOutcome>> byWarehouse = new LinkedHashMap<>();
        for (RegistrationOutcome outcome : outcomes.values()) {
            if (outcome.replay()) continue;
            byWarehouse.computeIfAbsent(
                    outcome.warehouseId(), ignored -> new ArrayList<>())
                    .add(outcome);
        }
        for (Map.Entry<UUID, List<RegistrationOutcome>> entry : byWarehouse.entrySet()) {
            RegistrationOutcome first = entry.getValue().getFirst();
            qualityInspection.openInspectionSheet(new InspectionSheetRequest(
                    entry.getKey(), first.warehouseName(),
                    first.receiver().id(), first.receiver().name(),
                    remark, SOURCE_ARRIVAL_BATCH, batchKey,
                    entry.getValue().stream()
                            .map(RegistrationOutcome::registrationId)
                            .toList()));
        }
        rememberRegisteredPlaces(byWarehouse.values().stream()
                .flatMap(List::stream)
                .map(RegistrationOutcome::registrationId)
                .toList());

        List<UUID> registrationIds = outcomes.values().stream()
                .map(RegistrationOutcome::registrationId)
                .toList();
        Map<UUID, Object[]> sheetByRegistration = sheetsByRegistration(registrationIds);
        List<RegisteredReportView> registered = new ArrayList<>();
        Map<UUID, InspectionSheetSummaryView> sheets = new LinkedHashMap<>();
        for (Map.Entry<GroupKey, RegistrationOutcome> entry : outcomes.entrySet()) {
            RegistrationOutcome outcome = entry.getValue();
            Object[] sheet = sheetByRegistration.get(outcome.registrationId());
            String reportNo = NativeValueConverters.text(sheet == null ? null : sheet[5]);
            UUID sheetId = sheet == null ? null : (UUID) sheet[0];
            registered.add(new RegisteredReportView(
                    outcome.registrationId(), entry.getKey().reportId(), reportNo,
                    outcome.warehouseId(), outcome.warehouseName(),
                    sheetId, NativeValueConverters.text(sheet == null ? null : sheet[1])));
            if (sheet != null && !sheets.containsKey(sheetId)) {
                sheets.put(sheetId, new InspectionSheetSummaryView(
                        sheetId, NativeValueConverters.text(sheet[1]), (UUID) sheet[2], NativeValueConverters.text(sheet[3]),
                        ((Number) sheet[4]).intValue()));
            }
        }
        return new BatchArrivalRegistrationResult(
                (int) registered.stream().map(RegisteredReportView::reportId).distinct().count(),
                registered, new ArrayList<>(sheets.values()));
    }

    /** 批 → 报工(批号由报工行生成列算出，身份不随状态变化；只认送入仓库的批)。 */
    private Map<UUID, UUID> lotReports(Collection<UUID> lotIds) {
        Map<UUID, UUID> result = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT DISTINCT item.output_lot_id, item.report_id
                        FROM production_daily_report_items item
                        WHERE item.output_lot_id IN (:lotIds)
                          AND item.destination = 'WAREHOUSE'
                          AND NOT item.is_deleted
                        """).setParameter("lotIds", List.copyOf(lotIds)))) {
            if (result.put((UUID) row[0], (UUID) row[1]) != null) {
                throw conflict("成品批信息异常，请联系管理员核查");
            }
        }
        return result;
    }

    /** 登记批次 → 所属检查单（每个批次恰一张）+ 报工单号；一次有界查询。 */
    private Map<UUID, Object[]> sheetsByRegistration(List<UUID> registrationIds) {
        if (registrationIds.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT DISTINCT ON (registration.id)
                                       sheet.id, sheet.sheet_no, sheet.warehouse_id,
                                       sheet.warehouse_name_snapshot,
                                       (SELECT COUNT(*)
                                        FROM production_fqc_inspection_sheet_items counted
                                        WHERE counted.sheet_id = sheet.id),
                                       report.bill_no,
                                       registration.id
                                FROM production_finished_arrival_registrations registration
                                JOIN production_daily_reports report
                                  ON report.id = registration.source_report_id
                                LEFT JOIN production_fqc_inspection_sheet_items sheet_item
                                  ON sheet_item.registration_id = registration.id
                                LEFT JOIN production_fqc_inspection_sheets sheet
                                  ON sheet.id = sheet_item.sheet_id
                                WHERE registration.id IN (:registrationIds)
                                ORDER BY registration.id, sheet.created_at, sheet.id
                                """)
                        .setParameter("registrationIds", registrationIds));
        Map<UUID, Object[]> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[6], row);
        }
        return result;
    }

    private static List<UUID> requireReportIds(List<UUID> reportIds) {
        if (reportIds == null || reportIds.isEmpty()) {
            throw validation("批量送检登记缺少报工单清单");
        }
        if (reportIds.size() > 50) {
            throw validation("一次最多汇总登记 50 张报工单");
        }
        LinkedHashSet<UUID> distinct = new LinkedHashSet<>();
        for (UUID id : reportIds) {
            if (id == null || !distinct.add(id)) {
                throw validation("批量送检登记的报工单清单不正确或存在重复");
            }
        }
        return List.copyOf(distinct);
    }

    private Object[] lockApprovedReport(UUID reportId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT id, status, is_deleted
                                FROM production_daily_reports
                                WHERE id = :reportId
                                FOR UPDATE
                                """)
                        .setParameter("reportId", reportId));
        if (rows.size() != 1
                || ((Number) rows.getFirst()[1]).shortValue() != 1
                || Boolean.TRUE.equals(rows.getFirst()[2])) {
            throw conflict("仅已审核且未红冲的生产报工可登记送检");
        }
        return rows.getFirst();
    }

    private WarehouseSnapshot lockWarehouse(UUID warehouseId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT code, name
                                FROM warehouses
                                WHERE id = :warehouseId
                                  AND is_deleted = FALSE
                                  AND is_accountable = TRUE
                                  AND NOT is_line_side
                                  AND COALESCE(status, '') <> '禁用'
                                  AND fn_warehouse_is_operational_leaf(warehouses.id)
                                FOR UPDATE
                                """)
                        .setParameter("warehouseId", warehouseId));
        if (rows.size() != 1 || NativeValueConverters.text(rows.getFirst()[1]) == null
                || NativeValueConverters.text(rows.getFirst()[1]).isBlank()) {
            throw validation("目标仓库不存在、已停用、不参与库存核算或不是具体子仓库");
        }
        return new WarehouseSnapshot(
                NativeValueConverters.text(rows.getFirst()[0]), NativeValueConverters.text(rows.getFirst()[1]));
    }

    private EmployeeSnapshot requireReceiver(UUID employeeId) {
        List<?> names = em.createNativeQuery("""
                        SELECT full_name
                        FROM employees
                        WHERE id = :employeeId
                          AND is_deleted = FALSE
                          AND status <> 'resigned'
                        """)
                .setParameter("employeeId", employeeId)
                .getResultList();
        if (names.size() != 1 || NativeValueConverters.text(names.getFirst()) == null
                || NativeValueConverters.text(names.getFirst()).isBlank()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号对应的收货人员信息不正确，请重新登录后再试");
        }
        return new EmployeeSnapshot(employeeId, NativeValueConverters.text(names.getFirst()));
    }

    private WarehouseSnapshot validatedWarehouse(UUID warehouseId) {
        WarehouseSnapshot warehouse = lockWarehouse(warehouseId);
        warehouseScopes.require(warehouseId, "入库仓库", WarehouseUse.GOOD_IN);
        return warehouse;
    }

    private void lockCommand(UUID actorId, String idempotencyKey) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(:lockKey, CAST(430 AS bigint)))
                        """)
                .setParameter("lockKey",
                        "PRODUCTION_FINISHED_ARRIVAL:"
                                + actorId + ':' + idempotencyKey)
                .getSingleResult();
    }

    /** 逐批校验(库位必填、先入库后质检必须带整批实点数、称重格式)，同一批不能出现两次。 */
    static Map<UUID, ArrivalLotRequest> normalizeLots(List<ArrivalLotRequest> lots, boolean preStock) {
        if (lots.size() > com.uten.imp.common.validation.RequestLimits.DOCUMENT_LINES) {
            throw validation("一次登记的成品批过多，请分批登记");
        }
        Map<UUID, ArrivalLotRequest> result = new LinkedHashMap<>();
        for (ArrivalLotRequest lot : lots) {
            if (lot == null || lot.lotId() == null || lot.warehouseId() == null || lot.place() == null) {
                throw validation("入库登记行缺少成品批、入库仓库或库位");
            }
            String place = lot.place().strip();
            if (place.isEmpty() || place.length() > 100) {
                throw validation("库位必须为 1至100 个字符");
            }
            if (preStock) {
                BigDecimal quantity = lot.countedQty() == null ? null : lot.countedQty().stripTrailingZeros();
                if (quantity == null) {
                    throw validation("合格自动入库前必须逐批填写实际点数，请刷新后核对；数量有差异请使用人工点收");
                }
                if (quantity.signum() <= 0 || quantity.scale() > 4
                        || quantity.precision() - quantity.scale() > 14) {
                    throw validation("实际点数必须大于0且最多4位小数；数量有差异请使用人工点收");
                }
            }
            normalizedWeight(lot.weight());
            if (result.putIfAbsent(lot.lotId(), lot) != null) {
                throw validation("同一批实物不能重复登记");
            }
        }
        return result;
    }

    static String normalizeRemark(String raw) {
        String remark = raw == null ? null : raw.strip();
        if (remark != null && remark.isEmpty()) remark = null;
        if (remark != null && remark.length() > 500) {
            throw validation("备注不能超过 500 个字符");
        }
        return remark;
    }

    /**
     * 一组(同一报工、同一实际入库仓)的规范化请求：子键由批量键 + 报工 + 仓库派生(固定长度)，
     * 指纹只看批一级的事实(批号、库位、整批实点、整批称重、备注、路线)，重放时不依赖各份的当前状态。
     */
    static NormalizedRequest normalizeGroup(
            String batchKey, GroupKey group, Map<UUID, LotRequest> lots, String remark, boolean preStock) {
        String childKey = "FAR:" + CanonicalFingerprint.sha256(List.of(
                "PRODUCTION-FINISHED-ARRIVAL-GROUP-V2", batchKey,
                group.reportId().toString(), group.warehouseId().toString())).substring(0, 48);
        List<String> hashParts = new ArrayList<>();
        hashParts.add("PRODUCTION-FINISHED-ARRIVAL-REGISTRATION-V2");
        hashParts.add(group.reportId().toString());
        hashParts.add(group.warehouseId().toString());
        lots.forEach((lotId, lot) -> hashParts.add(lotId + "|" + lot.place()
                + "|" + (lot.countedQty() == null ? "" : lot.countedQty().toPlainString())
                + "|" + (lot.weight() == null ? "" : lot.weight().toPlainString())));
        hashParts.add("remark=" + (remark == null ? "" : remark));
        if (preStock) hashParts.add("stockInBeforeInspection=1");
        return new NormalizedRequest(childKey, group.warehouseId(), Map.copyOf(lots), remark, preStock,
                CanonicalFingerprint.sha256(hashParts));
    }

    /**
     * 登记实称重量: 千克, 非负, 最多 4 位小数、14 位整数; 0 = 没称(null)。
     * 返回去掉尾零的值(哈希与入库口径一致)。
     */
    static BigDecimal normalizedWeight(BigDecimal weight) {
        if (weight == null) return null;
        BigDecimal value = weight.stripTrailingZeros();
        if (value.signum() < 0 || value.scale() > 4 || value.precision() - value.scale() > 14) {
            throw validation("实称重量必须为非负数，最多 14 位整数和 4 位小数(千克)");
        }
        if (value.signum() == 0) return null;
        return value.scale() < 0 ? value.setScale(0) : value;
    }

    /** 先入库后质检：整批实点必须等于本批待登记合计，否则走人工点收。 */
    static void requireCountedLot(BigDecimal reported, BigDecimal counted) {
        if (counted == null || reported == null || counted.compareTo(reported) != 0) {
            throw conflict("实际点数与本批报工量不一致，请使用人工点收登记差异及未收余量");
        }
    }

    static NormalizedReversal normalizeReversal(
            UUID registrationId,
            ArrivalRegistrationReversalRequest request) {
        if (registrationId == null || request == null
                || request.idempotencyKey() == null || request.reason() == null) {
            throw validation("登记撤回缺少登记批次、防重复提交标识或原因");
        }
        String key = request.idempotencyKey().strip();
        if (key.length() < 8 || key.length() > 128
                || !key.matches("[A-Za-z0-9._:-]+")) {
            throw validation("登记撤回的防重复提交标识格式不正确");
        }
        String reason = request.reason().strip();
        if (reason.length() < 2 || reason.length() > 500) {
            throw validation("撤回原因必须为 2 到 500 个字符");
        }
        return new NormalizedReversal(
                key, reason,
                CanonicalFingerprint.sha256(List.of(
                        "PRODUCTION-FINISHED-ARRIVAL-REVERSAL-V1",
                        registrationId.toString(),
                        reason)));
    }

    /**
     * 同一(货品, 颜色)只有一个库位才记；多个不同库位计入 ambiguous 并给出说明。
     * 记忆是登记的附带动作，缺货品或库位不合规的来源直接跳过，不抛错挡住登记。
     */
    static RememberPlan buildRememberPlan(List<RememberPlaceSource> sources) {
        Map<PlaceDimension, RememberAccumulator> grouped = new LinkedHashMap<>();
        if (sources == null) {
            return new RememberPlan(List.of(), 0, List.of());
        }
        for (RememberPlaceSource source : sources) {
            if (source == null || source.goodsId() == null
                    || source.place() == null) {
                continue;
            }
            String place = source.place().strip();
            if (place.isEmpty() || place.length() > 100) {
                continue;
            }
            PlaceDimension dimension = new PlaceDimension(
                    source.goodsId(), source.colorId());
            RememberAccumulator accumulator = grouped.computeIfAbsent(
                    dimension,
                    ignored -> new RememberAccumulator(
                            source.goodsId(), source.colorId(),
                            source.goodsCode(), source.goodsName()));
            accumulator.places().add(place);
        }

        List<RememberCandidate> candidates = new ArrayList<>();
        List<String> warnings = new ArrayList<>();
        int ambiguous = 0;
        for (RememberAccumulator accumulator : grouped.values()) {
            if (accumulator.places().size() == 1) {
                candidates.add(new RememberCandidate(
                        accumulator.goodsId(), accumulator.colorId(),
                        accumulator.places().iterator().next()));
                continue;
            }
            ambiguous++;
            List<String> places = accumulator.places().stream()
                    .sorted()
                    .toList();
            warnings.add("货品 " + accumulator.displayName()
                    + " 在同一登记中存在不同库位 "
                    + String.join(" / ", places)
                    + "，未记忆默认库位");
        }
        return new RememberPlan(candidates, ambiguous, warnings);
    }

    private static OffsetDateTime offsetDateTime(Object value) {
        return value == null ? null
                : NativeValueConverters.toOffsetDateTime(value);
    }

    private static Integer integer(Object value) {
        return value == null ? null : ((Number) value).intValue();
    }

    private static ApiException validation(String message) {
        return new ApiException(ErrorCode.VALIDATION_FAILED, message);
    }

    private static ApiException conflict(String message) {
        return new ApiException(ErrorCode.CONFLICT, message);
    }

    private static ApiException notFound() {
        return new ApiException(ErrorCode.NOT_FOUND, "生产成品送检登记任务不存在");
    }

    record NormalizedRequest(
            String idempotencyKey,
            UUID warehouseId,
            /** 批号 -> 本批登记事实(库位、整批实点、整批称重)。 */
            Map<UUID, LotRequest> lots,
            String remark,
            boolean stockInBeforeInspection,
            String requestHash) {
    }

    /** 一批的登记事实(已去空白、去尾零；没称的批 weight 为空)。 */
    record LotRequest(String place, BigDecimal countedQty, BigDecimal weight) {
    }

    /** 一组 = 同一报工 + 同一实际入库仓(按 UUID 排序：分组、子键与锁顺序都只认它)。 */
    record GroupKey(UUID reportId, UUID warehouseId) implements Comparable<GroupKey> {
        @Override
        public int compareTo(GroupKey other) {
            int report = reportId.compareTo(other.reportId);
            return report != 0 ? report : warehouseId.compareTo(other.warehouseId);
        }
    }

    /** 批内一份：报工行 + 报工数量 + 归属优先级。 */
    record LotMember(UUID reportItemId, BigDecimal qty, int sliceRank) {
    }

    /** 称了重、要记 FINISHED 观测的批。 */
    private record WeighedLot(
            BigDecimal weightKg,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal reportedQty,
            UUID departmentId) {
    }

    record NormalizedReversal(
            String idempotencyKey,
            String reason,
            String requestHash) {
    }

    /** One registration command outcome: the exact batch id plus the snapshot a sheet needs. */
    private record RegistrationOutcome(
            UUID registrationId,
            boolean replay,
            UUID warehouseId,
            String warehouseName,
            EmployeeSnapshot receiver) {
    }

    record RememberPlaceSource(
            UUID goodsId,
            UUID colorId,
            String place,
            String goodsCode,
            String goodsName) {
    }

    record RememberCandidate(UUID goodsId, UUID colorId, String place) {
    }

    /** 记忆来源登记批次：写进偏好的 source_registration_id / source_registered_at。 */
    private record RememberSourceRegistration(UUID registrationId, OffsetDateTime registeredAt) {
    }

    record RememberPlan(
            List<RememberCandidate> candidates,
            int ambiguous,
            List<String> warnings) {

        RememberPlan {
            candidates = List.copyOf(candidates);
            warnings = List.copyOf(warnings);
        }
    }

    private record PlaceDimension(UUID goodsId, UUID colorId) {
    }

    private record RememberAccumulator(
            UUID goodsId,
            UUID colorId,
            String goodsCode,
            String goodsName,
            LinkedHashSet<String> places) {

        RememberAccumulator(
                UUID goodsId,
                UUID colorId,
                String goodsCode,
                String goodsName) {
            this(goodsId, colorId, goodsCode, goodsName,
                    new LinkedHashSet<>());
        }

        String displayName() {
            if (goodsCode != null && !goodsCode.isBlank()) {
                return goodsCode.strip();
            }
            if (goodsName != null && !goodsName.isBlank()) {
                return goodsName.strip();
            }
            return goodsId.toString();
        }
    }

    private record WarehouseSnapshot(String code, String name) {
    }

    /** Command-local snapshots protected by the report/warehouse row locks. */
    private static final class RegistrationReferences {
        private final Map<UUID, Object[]> reports = new LinkedHashMap<>();
        private final Map<UUID, WarehouseSnapshot> warehouses = new LinkedHashMap<>();
        private EmployeeSnapshot receiver;
    }

    private record EmployeeSnapshot(UUID id, String name) {
    }
}
