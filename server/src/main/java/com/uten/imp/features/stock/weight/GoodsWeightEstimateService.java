package com.uten.imp.features.stock.weight;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.stock.weight.EstimateResult.Evidence;
import com.uten.imp.features.stock.weight.EstimateResult.Row;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.EstimateRow;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.Profile;
import com.uten.imp.features.stock.weight.dto.BalanceWeightView;
import com.uten.imp.features.stock.weight.dto.GoodsWeightView;
import com.uten.imp.features.stock.weight.dto.WeightObservationRow;
import com.uten.imp.features.stock.weight.dto.WeightParams;
import com.uten.imp.features.stock.weight.dto.WeightParamsRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.domain.PageRequest;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * 单重学习结果 (ADR-135 §5/§7.2): 重算与落库、读时解析 (库存账估重、/params、货品概况)、称重记录列表。
 *
 * <p>重算: 在货品级咨询锁 pg_advisory_xact_lock(hashtextextended('goods_weight:'||goods_id, 0)) 下读窗口内观测,
 * 跑 {@link ApwEstimator}, 整体幂等地 upsert 货品级行与供应商行, 删除本次没有产出的供应商行; 没有可学数据时删除全部行。
 * 触发: 观测变化事件 (业务事件派发任务)、称样等同步操作 (提交后另起事务)、夜间刷新 (算法升级或漏算的货品)。
 *
 * <p>供应商/往来方名称只给持有 stock_report:view 或 stock:weight:manage 的人 (同 StockCostMasker 的判断方式)。
 */
@Slf4j
@Service
public class GoodsWeightEstimateService implements UnitWeightLookup {

    public static final String PERMISSION_REPORT_VIEW = "stock_report:view";
    public static final String PERMISSION_WEIGHT_MANAGE = "stock:weight:manage";

    private static final int UNIT_WEIGHT_SCALE = 12;
    private static final Set<String> KNOWN_SOURCE_DOC_TYPES = Set.of(
            "PURCHASE_RECEIPT", "SUBCONTRACT_RECEIPT", "STOCK_DOC", "SUBCONTRACT_MATERIAL_ISSUE",
            "SALES_SHIPMENT", "PRODUCTION_FINISHED_ARRIVAL");

    private final NamedParameterJdbcTemplate db;
    private final GoodsWeightFactsStore facts;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate requiresNew;
    private final double scaleResKg;

    public GoodsWeightEstimateService(
            NamedParameterJdbcTemplate db,
            GoodsWeightFactsStore facts,
            SecurityContextCurrentUser currentUser,
            ObjectMapper objectMapper,
            PlatformTransactionManager transactionManager,
            @Value("${uten.stock.weight.scale-resolution-kg:0.00005}") double scaleResKg) {
        this.db = db;
        this.facts = facts;
        this.currentUser = currentUser;
        this.objectMapper = objectMapper;
        this.requiresNew = new TransactionTemplate(transactionManager);
        this.requiresNew.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        this.scaleResKg = scaleResKg;
    }

    // ================================================================== 重算

    /** 在调用方事务里重算一个货品 (业务事件派发任务调用)。 */
    @Transactional
    public void recompute(UUID goodsId) {
        if (goodsId == null) {
            return;
        }
        db.getJdbcTemplate().queryForObject("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))::text",
                String.class, "goods_weight:" + goodsId);
        GoodsWeightFacts goods = facts.load(goodsId);
        if (!goods.exists()) {
            return;
        }
        Profile profile = goods.profile();
        EstimatorConfig cfg = EstimatorConfig.forProfile(profile.pieceCvPct(), profile.tolerancePct(), scaleResKg);
        List<WeightObservation> observations = loadWindow(goodsId, cfg);
        EstimateResult result;
        try {
            result = ApwEstimator.estimate(observations, cfg,
                    profile.manualRegimeStartAt() == null ? null : profile.manualRegimeStartAt().toInstant(),
                    profile.autoRegime());
        } catch (RuntimeException badData) {
            log.warn("单重学习重算失败(保留原结果): goods={} {}", goodsId, badData.toString());
            return;
        }
        MapSqlParameterSource goodsArg = new MapSqlParameterSource("goods", goodsId);
        if (result.evidence() == Evidence.NONE || result.pool() == null) {
            db.update("DELETE FROM goods_weight_estimates WHERE goods_id = :goods", goodsArg);
            return;
        }
        List<Row> rows = new ArrayList<>();
        rows.add(result.pool());
        rows.addAll(result.suppliers());
        if (!rows.stream().allMatch(GoodsWeightEstimateService::persistable)) {
            log.warn("单重学习结果含非有限数值(保留原结果): goods={}", goodsId);
            return;
        }
        for (Row row : rows) {
            upsert(goodsId, row, result.asOf());
        }
        List<UUID> keep = result.suppliers().stream().map(Row::supplierId).toList();
        if (keep.isEmpty()) {
            db.update("DELETE FROM goods_weight_estimates WHERE goods_id = :goods AND supplier_id IS NOT NULL",
                    goodsArg);
        } else {
            db.update("""
                    DELETE FROM goods_weight_estimates
                    WHERE goods_id = :goods AND supplier_id IS NOT NULL AND supplier_id NOT IN (:keep)
                    """, new MapSqlParameterSource("goods", goodsId).addValue("keep", keep));
        }
    }

    /** 另起事务立即重算 (称样、设置、排除等同步操作在自己的写事务提交之后调用, 用户等着看新单重)。 */
    public void recomputeCommitted(UUID goodsId) {
        requiresNew.executeWithoutResult(status -> recompute(goodsId));
    }

    /**
     * 夜间刷新: 算法版本落后、学习结果早于最近一次观测变化或设置变化、或有可学观测却没有结果的货品逐个重算
     * (每个货品独立事务, 单个失败不影响其它)。返回重算的货品数。
     */
    public int refreshStale(int limit) {
        List<UUID> goodsIds = db.queryForList("""
                WITH changed AS (
                    SELECT o.goods_id,
                           max(GREATEST(o.created_at, COALESCE(o.reversed_at, o.created_at),
                                        COALESCE(o.excluded_at, o.created_at))) AS changed_at,
                           bool_or(o.stage = 'ACTIVE' AND o.excluded_reason IS NULL
                                   AND (o.role = 'REFERENCE' OR o.source_kind = 'DRAW')
                                   AND o.observed_at >= COALESCE(lp.manual_regime_start_at,
                                                                 '-infinity'::timestamptz)) AS learnable
                    FROM goods_weight_observations o
                    LEFT JOIN goods_weight_profiles lp ON lp.goods_id = o.goods_id
                    GROUP BY o.goods_id
                )
                SELECT c.goods_id
                FROM changed c
                JOIN goods g ON g.id = c.goods_id AND NOT g.is_deleted
                LEFT JOIN goods_weight_estimates e ON e.goods_id = c.goods_id AND e.supplier_id IS NULL
                LEFT JOIN goods_weight_profiles p ON p.goods_id = c.goods_id
                WHERE (e.goods_id IS NULL AND c.learnable)
                   OR e.algorithm_version < :version
                   OR e.computed_at < c.changed_at
                   OR e.computed_at < p.updated_at
                ORDER BY c.goods_id
                LIMIT :limit
                """, new MapSqlParameterSource("version", ApwEstimator.ALGORITHM_VERSION)
                .addValue("limit", Math.max(1, limit)), UUID.class);
        int done = 0;
        for (UUID goodsId : goodsIds) {
            try {
                recomputeCommitted(goodsId);
                done++;
            } catch (RuntimeException error) {
                log.warn("单重学习夜间刷新失败: goods={} {}", goodsId, error.toString());
            }
        }
        return done;
    }

    // ================================================================== 读时解析

    /**
     * 库存账估重用的货品级单重 (人工设定 &gt; 学到的货品级 &gt; 设计单重)。按重量计的货品由库存账自己按换算系数算,
     * 这里返回空; 没有任何依据也返回空。
     */
    @Override
    public Optional<UnitWeightRef> goodsLevel(UUID goodsId) {
        if (goodsId == null) {
            return Optional.empty();
        }
        GoodsWeightFacts goods = facts.load(goodsId);
        if (!goods.exists() || goods.exact()) {
            return Optional.empty();
        }
        try {
            WeightParamsResolver.Resolution resolution =
                    WeightParamsResolver.resolve(goods, null, null, Instant.now(), scaleResKg);
            BigDecimal kg = resolution.params().unitWeightKg();
            if (resolution.predictor() == null || kg == null || kg.signum() <= 0) {
                return Optional.empty();
            }
            return Optional.of(new UnitWeightRef(kg, resolution.basis(),
                    resolution.tier() == null ? EstimateResult.Tier.RED.name() : resolution.tier().name()));
        } catch (RuntimeException badData) {
            log.warn("单重解析失败(按没有单重处理): goods={} {}", goodsId, badData.toString());
            return Optional.empty();
        }
    }

    /** 一页表格的单重参数, 与请求行同序。 */
    @Transactional(readOnly = true)
    public List<WeightParams> params(List<WeightParamsRequest.Line> lines) {
        if (lines == null || lines.isEmpty()) {
            return List.of();
        }
        Set<UUID> goodsIds = new LinkedHashSet<>();
        Set<UUID> supplierIds = new LinkedHashSet<>();
        for (WeightParamsRequest.Line line : lines) {
            goodsIds.add(line.goodsId());
            if (line.supplierId() != null) supplierIds.add(line.supplierId());
        }
        Map<UUID, GoodsWeightFacts> byGoods = facts.loadAll(goodsIds);
        Map<String, EstimateRow> supplierRows = facts.supplierRows(goodsIds, supplierIds);
        Instant now = Instant.now();
        List<WeightParams> items = new ArrayList<>(lines.size());
        for (WeightParamsRequest.Line line : lines) {
            GoodsWeightFacts goods = byGoods.getOrDefault(line.goodsId(), GoodsWeightFacts.missing(line.goodsId()));
            EstimateRow supplierRow = line.supplierId() == null ? null
                    : supplierRows.get(GoodsWeightFactsStore.supplierKey(line.goodsId(), line.supplierId()));
            items.add(WeightParamsResolver.resolve(goods, supplierRow, line.key(), now, scaleResKg).params());
        }
        return items;
    }

    /** 货品单重学习概况。 */
    @Transactional(readOnly = true)
    public GoodsWeightView goodsView(UUID goodsId) {
        GoodsWeightFacts goods = facts.load(goodsId);
        if (!goods.exists()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
        boolean namesVisible = canSeeCounterparties();
        WeightParams resolved = WeightParamsResolver.resolve(goods, null, null, Instant.now(), scaleResKg).params();
        EstimateRow pool = goods.pool();
        List<EstimateRow> supplierEstimates = facts.supplierRowsOf(goodsId);
        Map<UUID, String> supplierNames = namesVisible
                ? names("SELECT id, name FROM suppliers WHERE id IN (:ids)",
                supplierEstimates.stream().map(EstimateRow::supplierId).toList())
                : Map.of();
        List<GoodsWeightView.SupplierRow> supplierRows = new ArrayList<>();
        OffsetDateTime regimeChanged = pool == null ? null : pool.regimeChangedAt();
        for (EstimateRow row : supplierEstimates) {
            Double diffPct = row.logMean() != null && pool != null && pool.logMean() != null
                    ? 100.0 * StrictMath.expm1(row.logMean() - pool.logMean()) : null;
            supplierRows.add(new GoodsWeightView.SupplierRow(row.supplierId(),
                    namesVisible ? supplierNames.get(row.supplierId()) : null,
                    row.unitWeightKg(), diffPct, row.nRef(), row.nInliers(), row.lastObservedAt(), row.tier(),
                    row.relHalfWidth(), row.shrinkWeight(),
                    row.labelBiasLog() == null ? null : 100.0 * StrictMath.expm1(row.labelBiasLog()),
                    row.regimeStartedAt(), row.regimeChangedAt()));
            if (row.regimeChangedAt() != null && (regimeChanged == null || row.regimeChangedAt().isAfter(regimeChanged))) {
                regimeChanged = row.regimeChangedAt();
            }
        }
        List<GoodsWeightView.Outlier> outliers = pool == null ? List.of() : parseOutliers(pool.outliersJson());
        return new GoodsWeightView(goodsId, profileView(goods), resolved, estimateView(pool), supplierRows,
                !namesVisible,
                pool == null || pool.drawBiasLog() == null ? null : 100.0 * StrictMath.expm1(pool.drawBiasLog()),
                pool == null ? null : pool.regimeStartedAt(), regimeChanged, outliers,
                counts(goodsId, outliers.size()));
    }

    /**
     * 称重记录 (最新在前)。
     *
     * @param kind       来源种类过滤 (SAMPLE/COUNT/RECEIPT/...)
     * @param supplierId 供应商过滤
     * @param stage      ACTIVE / REVERSED / EXCLUDED (有效但已排除)
     */
    @Transactional(readOnly = true)
    public PageResponse<WeightObservationRow> observations(UUID goodsId, int page, int size, String kind,
                                                           UUID supplierId, String stage) {
        if (!facts.load(goodsId).exists()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
        StringBuilder where = new StringBuilder("o.goods_id = :goods");
        MapSqlParameterSource args = new MapSqlParameterSource("goods", goodsId);
        if (kind != null && !kind.isBlank()) {
            SourceKind parsed;
            try {
                parsed = SourceKind.parse(kind);
            } catch (IllegalArgumentException unknown) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的称重来源: " + kind.strip());
            }
            where.append(" AND o.source_kind = :kind");
            args.addValue("kind", parsed.name());
        }
        if (supplierId != null) {
            where.append(" AND o.supplier_id = :supplier");
            args.addValue("supplier", supplierId);
        }
        if (stage != null && !stage.isBlank()) {
            switch (stage.strip()) {
                case "ACTIVE" -> where.append(" AND o.stage = 'ACTIVE' AND o.excluded_reason IS NULL");
                case "REVERSED" -> where.append(" AND o.stage = 'REVERSED'");
                case "EXCLUDED" -> where.append(" AND o.stage = 'ACTIVE' AND o.excluded_reason IS NOT NULL");
                default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的状态: " + stage.strip());
            }
        }
        PageRequest pageable = Pageables.of(page, size);
        Long total = db.queryForObject("SELECT count(*) FROM goods_weight_observations o WHERE " + where,
                args, Long.class);
        long count = total == null ? 0L : total;
        args.addValue("limit", pageable.getPageSize()).addValue("offset", pageable.getOffset());
        boolean namesVisible = canSeeCounterparties();
        List<WeightObservationRow> items = db.query("""
                SELECT o.id, o.observed_at, o.source_kind, o.role, o.qty_base, o.weight_kg, o.gross_kg, o.tare_kg,
                       o.warehouse_id, w.name AS warehouse_name, o.color_id, c.name AS color_name,
                       o.supplier_id, s.name AS supplier_name, o.counterpart_kind, o.counterpart_id,
                       CASE o.counterpart_kind WHEN 'WORKSHOP' THEN d.name WHEN 'CLIENT' THEN cl.name
                            ELSE cs.name END AS counterpart_name,
                       o.source_doc_type, o.source_doc_id, o.source_item_id, o.movement_id,
                       src.doc_code, src.bill_no, src.hit AS source_hit,
                       o.stage, o.reversed_at, o.excluded_reason, o.excluded_at, excluder.full_name AS excluded_by_name,
                       o.expected_unit_weight_kg, o.expected_weight_kg, o.deviation_pct, o.alert_level,
                       o.estimate_basis_used, o.estimate_tier_used, o.tolerance_pct_used, o.new_regime,
                       ol.z AS outlier_z, ol.hint AS outlier_hint,
                       GREATEST(CASE WHEN o.role = 'REFERENCE' AND o.supplier_id IS NOT NULL
                                     THEN se.regime_started_at ELSE pe.regime_started_at END,
                                gp.manual_regime_start_at) AS regime_started_at,
                       o.remark, o.recorded_by, recorder.full_name AS recorded_by_name
                FROM goods_weight_observations o
                LEFT JOIN warehouses w ON w.id = o.warehouse_id
                LEFT JOIN colors c ON c.id = o.color_id
                LEFT JOIN suppliers s ON s.id = o.supplier_id
                LEFT JOIN departments d ON o.counterpart_kind = 'WORKSHOP' AND d.id = o.counterpart_id
                LEFT JOIN clients cl ON o.counterpart_kind = 'CLIENT' AND cl.id = o.counterpart_id
                LEFT JOIN suppliers cs ON o.counterpart_kind IN ('SUBCONTRACTOR', 'SUPPLIER') AND cs.id = o.counterpart_id
                LEFT JOIN users ru ON ru.id = o.recorded_by
                LEFT JOIN employees recorder ON recorder.id = ru.employee_id
                LEFT JOIN users xu ON xu.id = o.excluded_by
                LEFT JOIN employees excluder ON excluder.id = xu.employee_id
                LEFT JOIN goods_weight_estimates pe ON pe.goods_id = o.goods_id AND pe.supplier_id IS NULL
                LEFT JOIN goods_weight_estimates se ON se.goods_id = o.goods_id AND se.supplier_id = o.supplier_id
                LEFT JOIN goods_weight_profiles gp ON gp.goods_id = o.goods_id
                LEFT JOIN LATERAL (
                    SELECT x->>'hint' AS hint, (x->>'z')::double precision AS z
                    FROM jsonb_array_elements(pe.outliers) x
                    WHERE x->>'id' = o.id::text
                    LIMIT 1
                ) ol ON true
                LEFT JOIN LATERAL (
                    SELECT u.doc_code, u.bill_no, true AS hit
                    FROM (
                        SELECT NULL::text AS doc_code, pr.bill_no FROM purchase_receipts pr
                         WHERE o.source_doc_type = 'PURCHASE_RECEIPT' AND pr.id = o.source_doc_id
                        UNION ALL
                        SELECT NULL, sr.bill_no FROM subcontract_receipts sr
                         WHERE o.source_doc_type = 'SUBCONTRACT_RECEIPT' AND sr.id = o.source_doc_id
                        UNION ALL
                        SELECT sd.doc_type, sd.bill_no FROM stock_documents sd
                         WHERE o.source_doc_type = 'STOCK_DOC' AND sd.id = o.source_doc_id
                        UNION ALL
                        SELECT NULL, mi.bill_no FROM subcontract_material_issues mi
                         WHERE o.source_doc_type = 'SUBCONTRACT_MATERIAL_ISSUE' AND mi.id = o.source_doc_id
                        UNION ALL
                        SELECT NULL, ss.bill_no FROM sales_shipments ss
                         WHERE o.source_doc_type = 'SALES_SHIPMENT' AND ss.id = o.source_doc_id
                        UNION ALL
                        SELECT NULL, NULL FROM production_finished_arrival_registrations fr
                         WHERE o.source_doc_type = 'PRODUCTION_FINISHED_ARRIVAL' AND fr.id = o.source_doc_id
                    ) u
                    LIMIT 1
                ) src ON true
                """ + "WHERE " + where + "\n" + """
                ORDER BY o.observed_at DESC, o.id DESC
                LIMIT :limit OFFSET :offset
                """, args, (rs, i) -> {
            BigDecimal qty = rs.getBigDecimal("qty_base");
            BigDecimal weight = rs.getBigDecimal("weight_kg");
            String sourceDocType = rs.getString("source_doc_type");
            UUID sourceDocId = rs.getObject("source_doc_id", UUID.class);
            boolean hit = rs.getBoolean("source_hit");
            Boolean cleared = sourceDocId == null || sourceDocType == null
                    || !KNOWN_SOURCE_DOC_TYPES.contains(sourceDocType) ? null : !hit;
            OffsetDateTime observedAt = rs.getObject("observed_at", OffsetDateTime.class);
            OffsetDateTime regimeStart = rs.getObject("regime_started_at", OffsetDateTime.class);
            Double outlierZ = GoodsWeightFactsStore.dbl(rs, "outlier_z");
            String stageValue = rs.getString("stage");
            String excludedReason = rs.getString("excluded_reason");
            String status = "REVERSED".equals(stageValue) ? "REVERSED"
                    : excludedReason != null ? "EXCLUDED"
                    : outlierZ != null ? "OUTLIER" : "NORMAL";
            return new WeightObservationRow(
                    rs.getObject("id", UUID.class), observedAt, rs.getString("source_kind"), rs.getString("role"),
                    qty, weight,
                    qty == null || qty.signum() <= 0 || weight == null ? null
                            : weight.divide(qty, UNIT_WEIGHT_SCALE, RoundingMode.HALF_EVEN),
                    rs.getBigDecimal("gross_kg"), rs.getBigDecimal("tare_kg"),
                    rs.getObject("warehouse_id", UUID.class), rs.getString("warehouse_name"),
                    rs.getObject("color_id", UUID.class), rs.getString("color_name"),
                    rs.getObject("supplier_id", UUID.class), namesVisible ? rs.getString("supplier_name") : null,
                    rs.getString("counterpart_kind"), rs.getObject("counterpart_id", UUID.class),
                    namesVisible ? rs.getString("counterpart_name") : null, !namesVisible,
                    sourceDocType, sourceDocId, rs.getObject("source_item_id", UUID.class),
                    rs.getString("doc_code"), rs.getString("bill_no"), cleared,
                    rs.getObject("movement_id", UUID.class),
                    stageValue, rs.getObject("reversed_at", OffsetDateTime.class), excludedReason,
                    rs.getObject("excluded_at", OffsetDateTime.class), rs.getString("excluded_by_name"),
                    rs.getBigDecimal("expected_unit_weight_kg"), rs.getBigDecimal("expected_weight_kg"),
                    rs.getBigDecimal("deviation_pct"), rs.getString("alert_level"),
                    rs.getString("estimate_basis_used"), rs.getString("estimate_tier_used"),
                    rs.getBigDecimal("tolerance_pct_used"), rs.getBoolean("new_regime"),
                    outlierZ != null, outlierZ, rs.getString("outlier_hint"),
                    regimeStart != null && observedAt != null && observedAt.isBefore(regimeStart),
                    rs.getString("remark"), rs.getObject("recorded_by", UUID.class),
                    rs.getString("recorded_by_name"), status);
        });
        int totalPages = (int) ((count + pageable.getPageSize() - 1) / pageable.getPageSize());
        return new PageResponse<>(items, pageable.getPageNumber() + 1, pageable.getPageSize(), count, totalPages);
    }

    /** 核重后的库存维度 (数量、重量、是否估算)。 */
    @Transactional(readOnly = true)
    public BalanceWeightView balanceWeight(UUID adjustmentId, UUID warehouseId, UUID goodsId, UUID colorId) {
        List<BalanceWeightView> rows = db.query("""
                SELECT qty, weight, weight_estimated
                FROM stock_balances
                WHERE warehouse_id = :warehouse AND goods_id = :goods
                  AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                """, new MapSqlParameterSource("warehouse", warehouseId).addValue("goods", goodsId)
                .addValue("color", colorId), (rs, i) -> new BalanceWeightView(adjustmentId, warehouseId, goodsId,
                colorId, rs.getBigDecimal("qty"), rs.getBigDecimal("weight"), rs.getBoolean("weight_estimated")));
        return rows.isEmpty()
                ? new BalanceWeightView(adjustmentId, warehouseId, goodsId, colorId, BigDecimal.ZERO, null, false)
                : rows.get(0);
    }

    /** 当前用户能看供应商/往来方名称 (stock_report:view 或 stock:weight:manage), 取不到用户时一律不能。 */
    public boolean canSeeCounterparties() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains(PERMISSION_REPORT_VIEW) || p.contains(PERMISSION_WEIGHT_MANAGE))
                .orElse(false);
    }

    // ================================================================== internals

    private List<WeightObservation> loadWindow(UUID goodsId, EstimatorConfig cfg) {
        return db.query("""
                (SELECT id, source_kind, qty_base, weight_kg, observed_at, supplier_id, qty_eps
                 FROM goods_weight_observations
                 WHERE goods_id = :goods AND stage = 'ACTIVE' AND excluded_reason IS NULL AND role = 'REFERENCE'
                 ORDER BY observed_at DESC, id DESC
                 LIMIT :refWindow)
                UNION ALL
                (SELECT id, source_kind, qty_base, weight_kg, observed_at, supplier_id, qty_eps
                 FROM goods_weight_observations
                 WHERE goods_id = :goods AND stage = 'ACTIVE' AND excluded_reason IS NULL AND source_kind = 'DRAW'
                 ORDER BY observed_at DESC, id DESC
                 LIMIT :drawWindow)
                """, new MapSqlParameterSource("goods", goodsId)
                .addValue("refWindow", cfg.refWindow())
                .addValue("drawWindow", cfg.drawWindow()), (rs, i) -> {
            BigDecimal eps = rs.getBigDecimal("qty_eps");
            return new WeightObservation(
                    rs.getObject("id", UUID.class),
                    SourceKind.parse(rs.getString("source_kind")),
                    rs.getBigDecimal("qty_base").doubleValue(),
                    rs.getBigDecimal("weight_kg").doubleValue(),
                    rs.getObject("observed_at", OffsetDateTime.class).toInstant(),
                    rs.getObject("supplier_id", UUID.class),
                    eps == null ? null : eps.doubleValue());
        });
    }

    private void upsert(UUID goodsId, Row row, Instant asOf) {
        Double unitWeight = row.unitWeightKg();
        MapSqlParameterSource args = new MapSqlParameterSource()
                .addValue("id", UUID.randomUUID())
                .addValue("goods", goodsId)
                .addValue("supplier", row.supplierId())
                .addValue("evidence", row.evidence().name())
                .addValue("logMean", row.logMean())
                .addValue("unitWeight", unitWeight == null ? null : WeightParamsResolver.kg(unitWeight))
                .addValue("logSe", row.logSe())
                .addValue("tauLot", row.tauLot())
                .addValue("tauBetween", row.tauBetween())
                .addValue("shrink", row.shrinkWeight())
                .addValue("rawLogMean", row.rawLogMean())
                .addValue("nObs", row.nObs())
                .addValue("nRef", row.nRef())
                .addValue("nInliers", row.nInliers())
                .addValue("nEff", row.nEff())
                .addValue("relHalfWidth", row.relHalfWidth())
                .addValue("tier", row.tier().name())
                .addValue("drawBiasLog", row.drawBiasLog())
                .addValue("drawBiasSe", row.drawBiasSe())
                .addValue("nDraw", row.nDraw())
                .addValue("labelBiasLog", row.labelBiasLog())
                .addValue("labelBiasSe", row.labelBiasSe())
                .addValue("regimeStartedAt", offset(row.regimeStartedAt()))
                .addValue("regimeChangedAt", offset(row.regimeChangedAt()))
                .addValue("lastObservedAt", offset(row.lastObservedAt()))
                .addValue("asOf", offset(asOf))
                .addValue("outliers", outliersJson(row.outliers()))
                .addValue("suggested", row.suggestedSampleSize())
                .addValue("version", ApwEstimator.ALGORITHM_VERSION);
        db.update("""
                INSERT INTO goods_weight_estimates(
                    id, goods_id, supplier_id, evidence, log_mean, unit_weight_kg, log_se, tau_lot, tau_between,
                    shrink_weight, raw_log_mean, n_obs, n_ref, n_inliers, n_eff, rel_half_width, tier,
                    draw_bias_log, draw_bias_se, n_draw, label_bias_log, label_bias_se,
                    regime_started_at, regime_changed_at, last_observed_at, as_of, outliers,
                    suggested_sample_size, algorithm_version, computed_at)
                VALUES (
                    :id, :goods, :supplier, :evidence, :logMean, :unitWeight, :logSe, :tauLot, :tauBetween,
                    :shrink, :rawLogMean, :nObs, :nRef, :nInliers, :nEff, :relHalfWidth, :tier,
                    :drawBiasLog, :drawBiasSe, :nDraw, :labelBiasLog, :labelBiasSe,
                    :regimeStartedAt, :regimeChangedAt, :lastObservedAt, :asOf, CAST(:outliers AS jsonb),
                    :suggested, :version, now())
                ON CONFLICT (goods_id, supplier_id) DO UPDATE SET
                    evidence = EXCLUDED.evidence,
                    log_mean = EXCLUDED.log_mean,
                    unit_weight_kg = EXCLUDED.unit_weight_kg,
                    log_se = EXCLUDED.log_se,
                    tau_lot = EXCLUDED.tau_lot,
                    tau_between = EXCLUDED.tau_between,
                    shrink_weight = EXCLUDED.shrink_weight,
                    raw_log_mean = EXCLUDED.raw_log_mean,
                    n_obs = EXCLUDED.n_obs,
                    n_ref = EXCLUDED.n_ref,
                    n_inliers = EXCLUDED.n_inliers,
                    n_eff = EXCLUDED.n_eff,
                    rel_half_width = EXCLUDED.rel_half_width,
                    tier = EXCLUDED.tier,
                    draw_bias_log = EXCLUDED.draw_bias_log,
                    draw_bias_se = EXCLUDED.draw_bias_se,
                    n_draw = EXCLUDED.n_draw,
                    label_bias_log = EXCLUDED.label_bias_log,
                    label_bias_se = EXCLUDED.label_bias_se,
                    regime_started_at = EXCLUDED.regime_started_at,
                    regime_changed_at = EXCLUDED.regime_changed_at,
                    last_observed_at = EXCLUDED.last_observed_at,
                    as_of = EXCLUDED.as_of,
                    outliers = EXCLUDED.outliers,
                    suggested_sample_size = EXCLUDED.suggested_sample_size,
                    algorithm_version = EXCLUDED.algorithm_version,
                    computed_at = EXCLUDED.computed_at
                """, args);
    }

    private static boolean persistable(Row row) {
        Double[] values = {row.logMean(), row.logSe(), row.tauLot(), row.tauBetween(), row.shrinkWeight(),
                row.rawLogMean(), row.nEff(), row.relHalfWidth(), row.drawBiasLog(), row.drawBiasSe(),
                row.labelBiasLog(), row.labelBiasSe()};
        for (Double value : values) {
            if (value != null && !Double.isFinite(value)) {
                return false;
            }
        }
        Double unit = row.unitWeightKg();
        // NUMERIC(24,12) 且 > 0: 单重在 1e-12 kg 到 1e12 kg 之间才能落库, 超出的是坏数据, 保留原结果。
        return unit == null || (unit >= 1e-12 && unit < 1e12);
    }

    private String outliersJson(List<EstimateResult.Outlier> outliers) {
        List<Map<String, Object>> items = new ArrayList<>();
        for (EstimateResult.Outlier outlier : outliers) {
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("id", outlier.observationId().toString());
            item.put("z", Double.isFinite(outlier.z()) ? outlier.z() : null);
            item.put("hint", outlier.hint());
            items.add(item);
        }
        try {
            return objectMapper.writeValueAsString(items);
        } catch (JsonProcessingException error) {
            throw new IllegalStateException("outliers are not serializable", error);
        }
    }

    private List<GoodsWeightView.Outlier> parseOutliers(String json) {
        if (json == null || json.isBlank()) {
            return List.of();
        }
        try {
            JsonNode root = objectMapper.readTree(json);
            List<GoodsWeightView.Outlier> result = new ArrayList<>();
            for (JsonNode node : root) {
                String id = node.path("id").asText(null);
                if (id == null) continue;
                result.add(new GoodsWeightView.Outlier(UUID.fromString(id), node.path("z").asDouble(0.0),
                        node.path("hint").asText("DEVIATION")));
            }
            return result;
        } catch (JsonProcessingException | IllegalArgumentException error) {
            log.warn("单重学习离群列表无法解析: {}", error.toString());
            return List.of();
        }
    }

    private GoodsWeightView.Profile profileView(GoodsWeightFacts goods) {
        Profile p = goods.profile();
        String setByName = p.manualSetBy() == null ? null
                : names("""
                        SELECT u.id, e.full_name AS name FROM users u JOIN employees e ON e.id = u.employee_id
                        WHERE u.id IN (:ids)
                        """, List.of(p.manualSetBy())).get(p.manualSetBy());
        boolean manualActive = p.manualUnitWeightKg() != null && goods.goodsUnitId() != null
                && goods.goodsUnitId().equals(p.manualUnitId());
        return new GoodsWeightView.Profile(p.exists(), p.defaultTareKg(), p.effectiveTolerancePct(),
                p.effectivePieceCvPct(), p.manualUnitWeightKg(), manualActive, p.manualReason(), p.manualSetBy(),
                setByName, p.manualSetAt(), p.learningEnabled(), p.regimeMode(), p.manualRegimeStartAt(),
                p.version(), p.updatedAt());
    }

    private static GoodsWeightView.EstimateRowView estimateView(EstimateRow row) {
        if (row == null) {
            return null;
        }
        return new GoodsWeightView.EstimateRowView(row.evidence(), row.unitWeightKg(), row.logMean(), row.logSe(),
                row.tauLot(), row.tauBetween(), row.nObs(), row.nRef(), row.nInliers(), row.nEff(),
                row.relHalfWidth(), row.tier(),
                row.drawBiasLog() == null ? null : 100.0 * StrictMath.expm1(row.drawBiasLog()),
                row.drawBiasSe() == null ? null : 100.0 * row.drawBiasSe(),
                row.nDraw(), row.regimeStartedAt(), row.regimeChangedAt(), row.lastObservedAt(), row.asOf(),
                row.suggestedSampleSize(), row.algorithmVersion(), row.computedAt());
    }

    private GoodsWeightView.Counts counts(UUID goodsId, long outliers) {
        return db.queryForObject("""
                SELECT count(*) AS total,
                       count(*) FILTER (WHERE stage = 'ACTIVE') AS active,
                       count(*) FILTER (WHERE stage = 'REVERSED') AS reversed,
                       count(*) FILTER (WHERE stage = 'ACTIVE' AND excluded_reason IS NOT NULL) AS excluded,
                       count(*) FILTER (WHERE stage = 'ACTIVE' AND excluded_reason IS NULL AND role = 'REFERENCE')
                           AS reference,
                       count(*) FILTER (WHERE stage = 'ACTIVE' AND excluded_reason IS NULL AND role = 'CHECK')
                           AS checks
                FROM goods_weight_observations
                WHERE goods_id = :goods
                """, new MapSqlParameterSource("goods", goodsId), (rs, i) -> new GoodsWeightView.Counts(
                rs.getLong("total"), rs.getLong("active"), rs.getLong("reversed"), rs.getLong("excluded"),
                rs.getLong("reference"), rs.getLong("checks"), outliers));
    }

    private Map<UUID, String> names(String sql, List<UUID> ids) {
        Set<UUID> distinct = new HashSet<>(ids);
        distinct.remove(null);
        if (distinct.isEmpty()) {
            return Map.of();
        }
        Map<UUID, String> result = new HashMap<>();
        db.query(sql, new MapSqlParameterSource("ids", distinct),
                rs -> {
                    result.put(rs.getObject("id", UUID.class), rs.getString("name"));
                });
        return result;
    }

    private static OffsetDateTime offset(Instant instant) {
        return instant == null ? null : OffsetDateTime.ofInstant(instant, ZoneOffset.UTC);
    }
}
