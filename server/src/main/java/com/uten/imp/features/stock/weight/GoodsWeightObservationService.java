package com.uten.imp.features.stock.weight;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.features.stock.weight.ApwPredictor.Alert;
import com.uten.imp.features.stock.weight.EstimateResult.Tier;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.EstimateRow;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 称重观测的登记与红冲 (ADR-135 §4/§5): 仓库执行单据在同一事务里调用, 只追加观测行并发一条业务事件,
 * 单重在事务提交后由 {@link GoodsWeightEstimateOutboxHandler} 重算 (不拖慢过账, 同一单据的后续行也不会用到
 * 本单据自己刚登记的观测)。
 *
 * <p>防循环 (观测里的数量或重量其实是按单重推出来的, 不能再拿来学单重):
 * <ul>
 *   <li>不登记: 数量是按称重推算的 (qtyFromWeight)、按重量计的货品、单据行单位本身是重量单位、
 *       数量或重量不大于 0、货品关闭了学习;</li>
 *   <li>登记但排除: 实称重量与当时显示的应称重量 4 位小数完全相同 (ECHO, 多半是照抄提示);
 *       估算件数 ≥100 且数量恰好等于 实称/单重 取整 (QTY_ECHO, 多半是按称重填的数)。
 *       被排除的观测管理员可以恢复。</li>
 * </ul>
 * 每条观测都把登记当时的应称重量、偏差、告警级别、依据、可靠度和容差快照下来 (按登记前的单重),
 * 称重异常列表直接读快照, 不回头按今天的单重重算。
 */
@Slf4j
@Service
public class GoodsWeightObservationService {

    public static final String EVENT_OBSERVATION_CHANGED = "STOCK_WEIGHT_OBSERVATION_CHANGED";
    public static final String AGGREGATE_GOODS = "GOODS";

    public static final String EXCLUDED_MANUAL = "MANUAL_EXCLUDE";
    public static final String EXCLUDED_ECHO = "ECHO";
    public static final String EXCLUDED_QTY_ECHO = "QTY_ECHO";

    static final Set<String> COUNTERPART_KINDS = Set.of("WORKSHOP", "SUBCONTRACTOR", "CLIENT", "SUPPLIER");
    /** 只有这几种来源的供应商是「货从哪来」(到货单供应商 / 称样可选 / 其它入库单供应商), 其余一律不记供应商。 */
    static final Set<SourceKind> SUPPLIER_KINDS = Set.of(SourceKind.RECEIPT, SourceKind.SAMPLE, SourceKind.OTHER_IN);
    /** QTY_ECHO 只在估算件数达到这个量级时判断 (件数少时凑巧相等很常见)。 */
    static final double QTY_ECHO_MIN_PIECES = 100.0;
    private static final BigDecimal DEVIATION_LIMIT = new BigDecimal("99999.9999");
    private static final int QTY_SCALE = 4;
    private static final int KG_SCALE = 6;
    private static final int UNIT_WEIGHT_SCALE = 12;

    private final NamedParameterJdbcTemplate db;
    private final GoodsWeightFactsStore facts;
    private final BusinessEventPublisher events;
    private final double scaleResKg;

    public GoodsWeightObservationService(
            NamedParameterJdbcTemplate db,
            GoodsWeightFactsStore facts,
            BusinessEventPublisher events,
            @Value("${uten.stock.weight.scale-resolution-kg:0.00005}") double scaleResKg) {
        this.db = db;
        this.facts = facts;
        this.events = events;
        this.scaleResKg = scaleResKg;
    }

    /**
     * 一次称重观测。
     *
     * @param goodsId         货品
     * @param colorId         颜色 (可空)
     * @param warehouseId     仓库 (可空)
     * @param kind            来源种类 (角色由它决定)
     * @param qtyBase         基本单位数量 (&gt; 0)
     * @param weightKg        净重 kg (&gt; 0)
     * @param supplierId      供应商: 只对 RECEIPT (到货单供应商) / SAMPLE (可选) / OTHER_IN (其它入库单供应商) 有意义,
     *                        其它来源一律丢弃 (委外发料的加工商、出货的客户记在往来方)
     * @param counterpartKind 往来方种类 WORKSHOP / SUBCONTRACTOR / CLIENT / SUPPLIER (可空; 与 counterpartId 同时有值才记)
     * @param counterpartId   往来方 id (车间 = 部门 id, 加工商/供应商 = suppliers.id, 客户 = clients.id)
     * @param sourceDocType   来源单据类型 (与流水 source_doc_type 同口径; 称样为空)
     * @param sourceDocId     来源单据头 id
     * @param sourceItemId    来源行 id
     * @param movementId      对应的库存流水 id (可空)
     * @param captureKey      幂等键, 全局唯一 (如 'RECEIPT:' + 到货明细 id, 'DRAW:' + 流水 id)
     * @param observedAt      称重时间 (空取当前时间)
     * @param grossKg         毛重 (可空)
     * @param tareKg          皮重合计 (可空)
     * @param qtyEps          数量相对误差覆盖 (产成品有仓库点数 0.005 / 只有报工数 0.015; 可空)
     * @param qtyFromWeight   数量是按称重推算的 → 不登记
     * @param lineUnitId      单据行单位 (是重量单位时不登记)
     * @param newRegime       称样勾选「从本次起作为新批次」: 货品手动批次起点设为本次称重时间
     * @param remark          备注
     * @param recordedBy      登记人 (users.id)
     */
    public record ObservationCommand(
            UUID goodsId,
            UUID colorId,
            UUID warehouseId,
            SourceKind kind,
            BigDecimal qtyBase,
            BigDecimal weightKg,
            UUID supplierId,
            String counterpartKind,
            UUID counterpartId,
            String sourceDocType,
            UUID sourceDocId,
            UUID sourceItemId,
            UUID movementId,
            String captureKey,
            OffsetDateTime observedAt,
            BigDecimal grossKg,
            BigDecimal tareKg,
            BigDecimal qtyEps,
            boolean qtyFromWeight,
            UUID lineUnitId,
            boolean newRegime,
            String remark,
            UUID recordedBy) {
    }

    /**
     * 登记一次称重观测 (加入调用方事务)。不满足学习条件时不登记, 返回空; 同一 captureKey 重放返回已有观测 id。
     * 本方法不会因为数据本身挡住调用方的过账: 数值越界的观测一律不登记。
     */
    @Transactional
    public Optional<UUID> record(ObservationCommand cmd) {
        if (cmd == null || cmd.goodsId() == null || cmd.kind() == null
                || cmd.captureKey() == null || cmd.captureKey().isBlank()) {
            return Optional.empty();
        }
        BigDecimal qty = scaled(cmd.qtyBase(), QTY_SCALE);
        BigDecimal weight = scaled(cmd.weightKg(), KG_SCALE);
        if (skipBeforeLookup(cmd.qtyFromWeight(), qty, weight)) {
            return Optional.empty();
        }
        String captureKey = cmd.captureKey().strip();
        Optional<UUID> existing = findByCaptureKey(captureKey);
        if (existing.isPresent()) {
            return existing;
        }
        GoodsWeightFacts goods = facts.load(cmd.goodsId());
        if (!goods.exists() || goods.exact() || !goods.profile().learningEnabled()) {
            return Optional.empty();
        }
        if (cmd.lineUnitId() != null && facts.massCodeOfUnit(cmd.lineUnitId()) != null) {
            return Optional.empty();
        }
        UUID supplierId = SUPPLIER_KINDS.contains(cmd.kind()) ? cmd.supplierId() : null;
        EstimateRow supplierRow = supplierId == null ? null
                : facts.supplierRows(List.of(cmd.goodsId()), List.of(supplierId))
                .get(GoodsWeightFactsStore.supplierKey(cmd.goodsId(), supplierId));
        OffsetDateTime observedAt = cmd.observedAt() == null ? OffsetDateTime.now() : cmd.observedAt();
        BigDecimal qtyEps = qtyEps(cmd.qtyEps());
        double eps = qtyEps != null ? qtyEps.doubleValue() : cmd.kind().eps();
        String basis;
        Snapshot snapshot;
        try {
            WeightParamsResolver.Resolution resolution = WeightParamsResolver.resolve(
                    goods, supplierRow, null, observedAt.toInstant(), scaleResKg);
            basis = resolution.basis();
            snapshot = snapshot(resolution, qty, weight, eps);
        } catch (RuntimeException badEstimate) {
            // 学习结果异常 (如历史行数值损坏) 只影响快照, 观测照登记, 绝不挡过账。
            log.warn("称重观测快照计算失败(观测照常登记): goods={} {}", cmd.goodsId(), badEstimate.toString());
            basis = WeightParamsResolver.BASIS_NONE;
            snapshot = new Snapshot(null, null, null, Alert.NONE, null,
                    goods.profile().effectiveTolerancePct(), null);
        }
        String excluded = exclusionReason(qty, weight, snapshot.expectedWeightKg(), snapshot.servedUnitWeightKg());

        String counterpartKind = cmd.counterpartId() != null && cmd.counterpartKind() != null
                && COUNTERPART_KINDS.contains(cmd.counterpartKind()) ? cmd.counterpartKind() : null;
        UUID id = UUID.randomUUID();
        MapSqlParameterSource args = new MapSqlParameterSource()
                .addValue("id", id)
                .addValue("goods", cmd.goodsId())
                .addValue("color", cmd.colorId())
                .addValue("warehouse", cmd.warehouseId())
                .addValue("supplier", supplierId)
                .addValue("counterpartKind", counterpartKind)
                .addValue("counterpart", counterpartKind == null ? null : cmd.counterpartId())
                .addValue("kind", cmd.kind().name())
                .addValue("role", cmd.kind().role().name())
                .addValue("qty", qty)
                .addValue("weight", weight)
                .addValue("gross", nonNegative(cmd.grossKg()))
                .addValue("tare", nonNegative(cmd.tareKg()))
                .addValue("qtyEps", qtyEps)
                .addValue("observedAt", observedAt)
                .addValue("sourceDocType", blankToNull(cmd.sourceDocType()))
                .addValue("sourceDoc", cmd.sourceDocId())
                .addValue("sourceItem", cmd.sourceItemId())
                .addValue("movement", cmd.movementId())
                .addValue("captureKey", captureKey)
                .addValue("excluded", excluded)
                .addValue("expectedUnit", snapshot.expectedUnitWeightKg())
                .addValue("expectedWeight", snapshot.expectedWeightKg())
                .addValue("deviation", snapshot.deviationPct())
                .addValue("alert", snapshot.alert().name())
                .addValue("basis", basis)
                .addValue("tier", snapshot.tier() == null ? null : snapshot.tier().name())
                .addValue("tolerance", snapshot.tolerancePct())
                .addValue("newRegime", cmd.kind() == SourceKind.SAMPLE && cmd.newRegime())
                .addValue("remark", truncate(blankToNull(cmd.remark()), 500))
                .addValue("recordedBy", cmd.recordedBy());
        List<UUID> inserted = db.queryForList("""
                INSERT INTO goods_weight_observations(
                    id, goods_id, color_id, warehouse_id, supplier_id, counterpart_kind, counterpart_id,
                    source_kind, role, qty_base, weight_kg, gross_kg, tare_kg, qty_eps, observed_at,
                    source_doc_type, source_doc_id, source_item_id, movement_id, capture_key,
                    excluded_reason, excluded_at,
                    expected_unit_weight_kg, expected_weight_kg, deviation_pct, alert_level,
                    estimate_basis_used, estimate_tier_used, tolerance_pct_used, new_regime, remark, recorded_by)
                VALUES (
                    :id, :goods, :color, :warehouse, :supplier, :counterpartKind, :counterpart,
                    :kind, :role, :qty, :weight, :gross, :tare, :qtyEps, :observedAt,
                    :sourceDocType, :sourceDoc, :sourceItem, :movement, :captureKey,
                    :excluded, CASE WHEN CAST(:excluded AS text) IS NULL THEN NULL ELSE now() END,
                    :expectedUnit, :expectedWeight, :deviation, :alert,
                    :basis, :tier, :tolerance, :newRegime, :remark, :recordedBy)
                ON CONFLICT (capture_key) DO NOTHING
                RETURNING id
                """, args, UUID.class);
        if (inserted.isEmpty()) {
            return findByCaptureKey(captureKey);
        }
        if (cmd.kind() == SourceKind.SAMPLE && cmd.newRegime()) {
            startManualRegime(cmd.goodsId(), observedAt, cmd.recordedBy());
        }
        if (excluded == null || (cmd.kind() == SourceKind.SAMPLE && cmd.newRegime())) {
            publish(cmd.goodsId(), id, "RECORDED");
        }
        return Optional.of(id);
    }

    /** 按 captureKey 红冲一条观测 (单据撤销时调用); 返回红冲条数。 */
    @Transactional
    public int reverseByCaptureKey(String captureKey) {
        if (captureKey == null || captureKey.isBlank()) {
            return 0;
        }
        return reverseRows(db.query("""
                UPDATE goods_weight_observations
                SET stage = 'REVERSED', reversed_at = now()
                WHERE capture_key = :key AND stage = 'ACTIVE'
                RETURNING id, goods_id
                """, new MapSqlParameterSource("key", captureKey.strip()), (rs, i) -> new ReversedRow(
                rs.getObject("id", UUID.class), rs.getObject("goods_id", UUID.class))));
    }

    /** 红冲某来源行上某种来源的全部有效观测 (到货登记撤销、单据红冲等); 返回红冲条数。 */
    @Transactional
    public int reverseBySourceItem(String sourceDocType, UUID sourceItemId, SourceKind kind) {
        if (sourceItemId == null || kind == null) {
            return 0;
        }
        return reverseRows(db.query("""
                UPDATE goods_weight_observations
                SET stage = 'REVERSED', reversed_at = now()
                WHERE source_item_id = :item AND source_kind = :kind AND stage = 'ACTIVE'
                  AND source_doc_type IS NOT DISTINCT FROM CAST(:docType AS text)
                RETURNING id, goods_id
                """, new MapSqlParameterSource("item", sourceItemId)
                .addValue("kind", kind.name())
                .addValue("docType", blankToNull(sourceDocType)), (rs, i) -> new ReversedRow(
                rs.getObject("id", UUID.class), rs.getObject("goods_id", UUID.class))));
    }

    /**
     * 领料部分取消出库: 从最近一次起倒序红冲该领料行的 DRAW 观测, 直到红冲数量覆盖取消数量
     * (部分覆盖的那条也红冲)。返回红冲条数。
     */
    @Transactional
    public int reverseDrawLifo(UUID drawItemId, BigDecimal qtyBase) {
        if (drawItemId == null || qtyBase == null || qtyBase.signum() <= 0) {
            return 0;
        }
        List<LifoCandidate> active = db.query("""
                SELECT id, goods_id, qty_base
                FROM goods_weight_observations
                WHERE source_item_id = :item AND source_kind = 'DRAW' AND stage = 'ACTIVE'
                ORDER BY observed_at DESC, id DESC
                FOR UPDATE
                """, new MapSqlParameterSource("item", drawItemId), (rs, i) -> new LifoCandidate(
                rs.getObject("id", UUID.class), rs.getObject("goods_id", UUID.class), rs.getBigDecimal("qty_base")));
        List<UUID> ids = lifoToReverse(active, qtyBase);
        if (ids.isEmpty()) {
            return 0;
        }
        return reverseRows(db.query("""
                UPDATE goods_weight_observations
                SET stage = 'REVERSED', reversed_at = now()
                WHERE id IN (:ids) AND stage = 'ACTIVE'
                RETURNING id, goods_id
                """, new MapSqlParameterSource("ids", ids), (rs, i) -> new ReversedRow(
                rs.getObject("id", UUID.class), rs.getObject("goods_id", UUID.class))));
    }

    // ------------------------------------------------------------------ pure helpers (unit-tested)

    /** 不需要查库就能判定不登记的情形: 数量按称重推算、数量或重量不大于 0。 */
    static boolean skipBeforeLookup(boolean qtyFromWeight, BigDecimal qty, BigDecimal weight) {
        return qtyFromWeight || qty == null || weight == null || qty.signum() <= 0 || weight.signum() <= 0;
    }

    /**
     * 排除原因: ECHO = 实称与应称 4 位小数相同; QTY_ECHO = 估算件数 ≥100 且数量等于 实称/单重 取整
     * (整数或 4 位小数)。都不是返回 null。
     */
    static String exclusionReason(BigDecimal qty, BigDecimal weightKg, BigDecimal expectedWeightKg,
                                  BigDecimal servedUnitWeightKg) {
        if (expectedWeightKg != null && weightKg != null
                && WeightUnit.KG.toKgLine(expectedWeightKg).compareTo(WeightUnit.KG.toKgLine(weightKg)) == 0) {
            return EXCLUDED_ECHO;
        }
        if (servedUnitWeightKg != null && servedUnitWeightKg.signum() > 0 && qty != null && weightKg != null) {
            double pieces = weightKg.doubleValue() / servedUnitWeightKg.doubleValue();
            if (pieces >= QTY_ECHO_MIN_PIECES && Double.isFinite(pieces)) {
                BigDecimal estimate = BigDecimal.valueOf(pieces);
                BigDecimal whole = estimate.setScale(0, RoundingMode.HALF_EVEN);
                BigDecimal fourDp = estimate.setScale(QTY_SCALE, RoundingMode.HALF_EVEN);
                if (qty.compareTo(whole) == 0 || qty.compareTo(fourDp) == 0) {
                    return EXCLUDED_QTY_ECHO;
                }
            }
        }
        return null;
    }

    /** LIFO 选择: 从最新的起累加数量, 直到覆盖 qtyBase (部分覆盖的那条也选上)。 */
    static List<UUID> lifoToReverse(List<LifoCandidate> newestFirst, BigDecimal qtyBase) {
        List<UUID> ids = new ArrayList<>();
        BigDecimal covered = BigDecimal.ZERO;
        for (LifoCandidate candidate : newestFirst) {
            if (covered.compareTo(qtyBase) >= 0) {
                break;
            }
            ids.add(candidate.id());
            covered = covered.add(candidate.qtyBase() == null ? BigDecimal.ZERO : candidate.qtyBase());
        }
        return ids;
    }

    /**
     * 登记当时的核对快照 (按登记前的单重解析): 应称、偏差、告警、依据、请求可靠度、容差。
     * 告警只对 MANUAL 与有独立点数依据的 LEARNED, 且请求可靠度 (按本次数量) 不是 RED。
     */
    static Snapshot snapshot(WeightParamsResolver.Resolution resolution, BigDecimal qty, BigDecimal weight,
                             double eps) {
        BigDecimal tolerancePct = resolution.params().tolerancePct();
        BigDecimal unitWeight = resolution.params().unitWeightKg();
        if (resolution.predictor() == null || unitWeight == null) {
            return new Snapshot(null, null, null, Alert.NONE, resolution.tier(), tolerancePct, null);
        }
        ApwPredictor.Params params = resolution.predictor();
        ApwPredictor.WeightCheck check = ApwPredictor.checkWeight(params, eps, qty.doubleValue(),
                weight.doubleValue(), tolerancePct.doubleValue());
        Tier requestTier = ApwPredictor.requestTier(params, qty.doubleValue(), resolution.config())
                .worse(resolution.tier());
        Alert alert = resolution.alertsAllowed() && requestTier != Tier.RED ? check.alert() : Alert.NONE;
        BigDecimal deviation = !Double.isFinite(check.deviationPct()) ? null
                : BigDecimal.valueOf(check.deviationPct()).setScale(4, RoundingMode.HALF_EVEN)
                .max(DEVIATION_LIMIT.negate()).min(DEVIATION_LIMIT);
        BigDecimal expectedUnit = unitWeight.setScale(UNIT_WEIGHT_SCALE, RoundingMode.HALF_EVEN);
        BigDecimal expectedWeight = !Double.isFinite(check.expectedWeightKg()) ? null
                : BigDecimal.valueOf(check.expectedWeightKg()).setScale(KG_SCALE, RoundingMode.HALF_EVEN);
        return new Snapshot(fits(expectedUnit, 12) ? expectedUnit : null,
                fits(expectedWeight, 14) ? expectedWeight : null,
                deviation, alert, requestTier, tolerancePct, unitWeight);
    }

    record Snapshot(BigDecimal expectedUnitWeightKg, BigDecimal expectedWeightKg, BigDecimal deviationPct,
                    Alert alert, Tier tier, BigDecimal tolerancePct, BigDecimal servedUnitWeightKg) {
    }

    record LifoCandidate(UUID id, UUID goodsId, BigDecimal qtyBase) {
    }

    // ------------------------------------------------------------------ internals

    private Optional<UUID> findByCaptureKey(String captureKey) {
        List<UUID> ids = db.queryForList("SELECT id FROM goods_weight_observations WHERE capture_key = :key",
                new MapSqlParameterSource("key", captureKey), UUID.class);
        return ids.isEmpty() ? Optional.empty() : Optional.of(ids.get(0));
    }

    /** 称样勾选「从本次起作为新批次」: 手动批次起点 = 本次称重时间 (模式不变), 版本 +1。 */
    private void startManualRegime(UUID goodsId, OffsetDateTime at, UUID actor) {
        db.update("""
                INSERT INTO goods_weight_profiles(goods_id, manual_regime_start_at, version, updated_by, updated_at)
                VALUES (:goods, :at, 1, :actor, now())
                ON CONFLICT (goods_id) DO UPDATE
                SET manual_regime_start_at = EXCLUDED.manual_regime_start_at,
                    version = goods_weight_profiles.version + 1,
                    updated_by = EXCLUDED.updated_by,
                    updated_at = now()
                """, new MapSqlParameterSource("goods", goodsId).addValue("at", at).addValue("actor", actor));
    }

    private int reverseRows(List<ReversedRow> rows) {
        Map<UUID, UUID> firstByGoods = new LinkedHashMap<>();
        for (ReversedRow row : rows) {
            firstByGoods.putIfAbsent(row.goodsId(), row.id());
        }
        for (Map.Entry<UUID, UUID> entry : firstByGoods.entrySet()) {
            publish(entry.getKey(), entry.getValue(), "REVERSED");
        }
        return rows.size();
    }

    /**
     * 发「观测变化」事件。去重键按 观测 + 动作 固定 (一条观测只会登记一次、红冲一次): 同一 HTTP 请求里同一货品
     * 登记多条观测时 (请求级幂等键相同) 不会被判成「同键不同事件」而挡住过账, 同一动作重放则自然去重。
     */
    void publish(UUID goodsId, UUID observationId, String action) {
        events.publishOnce(EVENT_OBSERVATION_CHANGED, AGGREGATE_GOODS, goodsId,
                Map.of("observationId", observationId.toString()),
                EVENT_OBSERVATION_CHANGED + ":" + observationId + ":" + action);
    }

    /** 按列精度取位; 整数位超过 14 位 (NUMERIC(18,4) / NUMERIC(20,6) 放不下) 返回 null, 不让观测挡住过账。 */
    static BigDecimal scaled(BigDecimal value, int scale) {
        if (value == null) {
            return null;
        }
        BigDecimal rounded = value.setScale(scale, RoundingMode.HALF_EVEN);
        return fits(rounded, 14) ? rounded : null;
    }

    /** 整数位不超过 intDigits。 */
    static boolean fits(BigDecimal value, int intDigits) {
        return value != null && value.precision() - value.scale() <= intDigits;
    }

    private static BigDecimal nonNegative(BigDecimal kg) {
        BigDecimal value = scaled(kg, KG_SCALE);
        return value == null || value.signum() < 0 ? null : value;
    }

    private static BigDecimal qtyEps(BigDecimal eps) {
        if (eps == null || eps.signum() < 0 || eps.compareTo(new BigDecimal("0.5")) > 0) {
            return null;
        }
        return eps.setScale(5, RoundingMode.HALF_EVEN);
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }

    private static String truncate(String value, int max) {
        return value == null || value.length() <= max ? value : value.substring(0, max);
    }

    private record ReversedRow(UUID id, UUID goodsId) {
    }
}
