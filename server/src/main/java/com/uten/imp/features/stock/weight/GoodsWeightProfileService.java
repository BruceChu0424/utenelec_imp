package com.uten.imp.features.stock.weight;

import com.uten.imp.common.measure.WeightUnit;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.weight.GoodsWeightFacts.Profile;
import com.uten.imp.features.stock.weight.GoodsWeightObservationService.ObservationCommand;
import com.uten.imp.features.stock.weight.dto.GoodsWeightView;
import com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest;
import com.uten.imp.features.stock.weight.dto.WeightSampleRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * 单重学习的人工操作 (ADR-135 §7.2): 称样校准、称重设置、排除/恢复称重记录、从今天起重新学习。
 *
 * <p>每个操作先在自己的事务里写完并提交, 再另起事务立即重算该货品的单重, 最后返回刷新后的货品概况
 * (用户点完就要看到新单重, 不等业务事件派发)。
 */
@Service
public class GoodsWeightProfileService {

    private static final int UNIT_WEIGHT_SCALE = 12;
    private static final int KG_SCALE = 6;

    private final NamedParameterJdbcTemplate db;
    private final GoodsWeightFactsStore facts;
    private final GoodsWeightObservationService observations;
    private final GoodsWeightEstimateService estimates;
    private final SecurityContextCurrentUser currentUser;
    private final TransactionTemplate writeTx;

    public GoodsWeightProfileService(
            NamedParameterJdbcTemplate db,
            GoodsWeightFactsStore facts,
            GoodsWeightObservationService observations,
            GoodsWeightEstimateService estimates,
            SecurityContextCurrentUser currentUser,
            PlatformTransactionManager transactionManager) {
        this.db = db;
        this.facts = facts;
        this.observations = observations;
        this.estimates = estimates;
        this.currentUser = currentUser;
        this.writeTx = new TransactionTemplate(transactionManager);
        this.writeTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    }

    /**
     * 称样校准: 数 qty 个称重, 记一条 SAMPLE 观测 (可带供应商、可勾「从本次起作为新批次」), 立即重算。
     * 同一幂等键重放返回同一结果; 同键不同内容 409。
     */
    public GoodsWeightView recordSample(UUID goodsId, WeightSampleRequest req) {
        UUID actor = currentUser.requireId();
        WeightUnit unit = WeightUnit.tryParse(req.weightUnit()).orElseThrow(() ->
                new ApiException(ErrorCode.VALIDATION_FAILED, "不认识的重量单位: " + req.weightUnit()));
        GoodsWeightFacts goods = requireGoods(goodsId);
        if (goods.exact()) {
            throw new ApiException(ErrorCode.CONFLICT, "按重量计量的货品重量随数量自动计算, 不用称样");
        }
        if (!goods.profile().learningEnabled()) {
            throw new ApiException(ErrorCode.CONFLICT, "该货品已关闭单重学习, 请先在称重设置里打开「参与学习」");
        }
        // weight 是已扣皮重的净重(按 weightUnit); tareKg 只作留痕, 不再重复扣减, 毛重 = 净重 + 皮重。
        BigDecimal net = req.weight() == null ? null : unit.toKgPrecise(req.weight());
        if (net == null || net.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "称样净重必须大于 0");
        }
        BigDecimal tare = req.tareKg() == null ? null : req.tareKg().setScale(KG_SCALE, RoundingMode.HALF_EVEN);
        if (tare != null && tare.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "皮重不能为负数");
        }
        BigDecimal gross = tare == null ? net : net.add(tare);
        BigDecimal qty = req.qty().setScale(4, RoundingMode.HALF_EVEN);
        if (req.supplierId() != null && !exists("suppliers", req.supplierId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "供应商不存在或已删除");
        }
        if (req.warehouseId() != null && !exists("warehouses", req.warehouseId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "仓库不存在或已删除");
        }
        String key = req.idempotencyKey() == null || req.idempotencyKey().isBlank()
                ? UUID.randomUUID().toString() : req.idempotencyKey().strip();
        String captureKey = "SAMPLE:" + goodsId + ":" + key;
        boolean newRegime = Boolean.TRUE.equals(req.newRegime());
        writeTx.executeWithoutResult(status -> {
            List<Map<String, Object>> replay = db.queryForList("""
                    SELECT goods_id, qty_base, weight_kg FROM goods_weight_observations WHERE capture_key = :key
                    """, new MapSqlParameterSource("key", captureKey));
            if (!replay.isEmpty()) {
                Map<String, Object> row = replay.get(0);
                if (!goodsId.equals(row.get("goods_id"))
                        || ((BigDecimal) row.get("qty_base")).compareTo(qty) != 0
                        || ((BigDecimal) row.get("weight_kg")).compareTo(net) != 0) {
                    throw new ApiException(ErrorCode.CONFLICT, "同一次提交的称样内容不一致, 请刷新后重新提交");
                }
                return;
            }
            Optional<UUID> recorded = observations.record(new ObservationCommand(
                    goodsId, null, req.warehouseId(), SourceKind.SAMPLE, qty, net, req.supplierId(),
                    null, null, null, null, null, null, captureKey, OffsetDateTime.now(),
                    gross, tare, null, false, null, newRegime, req.remark(), actor));
            if (recorded.isEmpty()) {
                throw new ApiException(ErrorCode.CONFLICT, "这次称样没有记入学习, 请检查数量和重量");
            }
        });
        estimates.recomputeCommitted(goodsId);
        return estimates.goodsView(goodsId);
    }

    /** 修改称重设置 (整份替换, 乐观锁)。 */
    public GoodsWeightView updateProfile(UUID goodsId, WeightProfileUpdateRequest req) {
        UUID actor = currentUser.requireId();
        String reason = trimToNull(req.manualReason());
        if (reason != null && reason.length() < 2) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "设定原因至少 2 个字");
        }
        writeTx.executeWithoutResult(status -> {
            GoodsWeightFacts goods = requireGoods(goodsId);
            Profile current = goods.profile();
            if (req.expectedVersion() == null || current.version() != req.expectedVersion()) {
                throw new ApiException(ErrorCode.CONFLICT, "称重设置已被他人修改, 请刷新后重试");
            }
            BigDecimal manual = req.manualUnitWeightKg() == null ? null
                    : req.manualUnitWeightKg().setScale(UNIT_WEIGHT_SCALE, RoundingMode.HALF_EVEN);
            if (manual != null && goods.exact()) {
                throw new ApiException(ErrorCode.CONFLICT, "按重量计量的货品重量随数量自动计算, 不用设定单重");
            }
            if (manual != null && goods.goodsUnitId() == null) {
                throw new ApiException(ErrorCode.CONFLICT, "货品还没有基本单位, 不能设定单重");
            }
            boolean manualChanged = manual != null && (current.manualUnitWeightKg() == null
                    || current.manualUnitWeightKg().compareTo(manual) != 0
                    || !Objects.equals(current.manualUnitId(), goods.goodsUnitId()));
            MapSqlParameterSource args = new MapSqlParameterSource()
                    .addValue("goods", goodsId)
                    .addValue("expected", req.expectedVersion())
                    .addValue("tare", req.defaultTareKg())
                    .addValue("tolerance", req.tolerancePct())
                    .addValue("pieceCv", req.pieceCvPct())
                    .addValue("manual", manual)
                    .addValue("manualUnit", manual == null ? null : goods.goodsUnitId())
                    .addValue("manualReason", manual == null ? null : reason)
                    .addValue("manualSetBy", manual == null ? null
                            : manualChanged ? actor : current.manualSetBy())
                    .addValue("manualSetAt", manual == null ? null
                            : manualChanged || current.manualSetAt() == null ? OffsetDateTime.now()
                            : current.manualSetAt())
                    .addValue("learning", req.learningEnabled() == null || req.learningEnabled())
                    .addValue("regimeMode", req.regimeMode() == null ? Profile.REGIME_AUTO : req.regimeMode())
                    .addValue("actor", actor);
            int changed;
            if (current.exists()) {
                changed = db.update("""
                        UPDATE goods_weight_profiles
                        SET default_tare_kg = :tare, tolerance_pct = :tolerance, piece_cv_pct = :pieceCv,
                            manual_unit_weight_kg = :manual, manual_unit_id = :manualUnit,
                            manual_reason = :manualReason, manual_set_by = :manualSetBy,
                            manual_set_at = :manualSetAt, learning_enabled = :learning, regime_mode = :regimeMode,
                            version = version + 1, updated_by = :actor, updated_at = now()
                        WHERE goods_id = :goods AND version = :expected
                        """, args);
            } else {
                changed = db.update("""
                        INSERT INTO goods_weight_profiles(
                            goods_id, default_tare_kg, tolerance_pct, piece_cv_pct, manual_unit_weight_kg,
                            manual_unit_id, manual_reason, manual_set_by, manual_set_at, learning_enabled,
                            regime_mode, version, updated_by, updated_at)
                        VALUES (:goods, :tare, :tolerance, :pieceCv, :manual, :manualUnit, :manualReason,
                                :manualSetBy, :manualSetAt, :learning, :regimeMode, 1, :actor, now())
                        ON CONFLICT (goods_id) DO NOTHING
                        """, args);
            }
            if (changed != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "称重设置已被他人修改, 请刷新后重试");
            }
        });
        estimates.recomputeCommitted(goodsId);
        return estimates.goodsView(goodsId);
    }

    /** 排除一条称重记录 (不再参与学习; 已红冲的不用排除, 已排除的原样返回)。 */
    public GoodsWeightView exclude(UUID observationId, String reason) {
        UUID actor = currentUser.requireId();
        String text = trimToNull(reason);
        if (text != null && text.length() < 2) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "排除原因至少 2 个字");
        }
        UUID goodsId = writeTx.execute(status -> {
            ObservationState state = lockObservation(observationId);
            if ("REVERSED".equals(state.stage())) {
                throw new ApiException(ErrorCode.CONFLICT, "这条称重记录已红冲, 不参与学习, 不用排除");
            }
            if (state.excludedReason() == null) {
                db.update("""
                        UPDATE goods_weight_observations
                        SET excluded_reason = :reason, excluded_by = :actor, excluded_at = now(),
                            remark = CASE WHEN CAST(:text AS text) IS NULL THEN remark
                                          ELSE concat_ws(' / ', remark, '排除: ' || CAST(:text AS text)) END
                        WHERE id = :id
                        """, new MapSqlParameterSource("id", observationId)
                        .addValue("reason", GoodsWeightObservationService.EXCLUDED_MANUAL)
                        .addValue("actor", actor)
                        .addValue("text", text));
            }
            return state.goodsId();
        });
        estimates.recomputeCommitted(goodsId);
        return estimates.goodsView(goodsId);
    }

    /** 恢复一条被排除的称重记录 (人工排除或系统判定的照抄/按称重填数都可恢复)。 */
    public GoodsWeightView include(UUID observationId) {
        currentUser.requireId();
        UUID goodsId = writeTx.execute(status -> {
            ObservationState state = lockObservation(observationId);
            if (state.excludedReason() != null) {
                db.update("""
                        UPDATE goods_weight_observations
                        SET excluded_reason = NULL, excluded_by = NULL, excluded_at = NULL
                        WHERE id = :id
                        """, new MapSqlParameterSource("id", observationId));
            }
            return state.goodsId();
        });
        estimates.recomputeCommitted(goodsId);
        return estimates.goodsView(goodsId);
    }

    /** 从今天起重新学习: 手动批次起点 = 现在, 之前的称重不再参与 (仍保留在记录里)。 */
    public GoodsWeightView resetRegime(UUID goodsId) {
        UUID actor = currentUser.requireId();
        writeTx.executeWithoutResult(status -> {
            requireGoods(goodsId);
            db.update("""
                    INSERT INTO goods_weight_profiles(goods_id, manual_regime_start_at, version, updated_by, updated_at)
                    VALUES (:goods, now(), 1, :actor, now())
                    ON CONFLICT (goods_id) DO UPDATE
                    SET manual_regime_start_at = now(),
                        version = goods_weight_profiles.version + 1,
                        updated_by = EXCLUDED.updated_by,
                        updated_at = now()
                    """, new MapSqlParameterSource("goods", goodsId).addValue("actor", actor));
        });
        estimates.recomputeCommitted(goodsId);
        return estimates.goodsView(goodsId);
    }

    private GoodsWeightFacts requireGoods(UUID goodsId) {
        GoodsWeightFacts goods = facts.load(goodsId);
        if (!goods.exists()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
        return goods;
    }

    private ObservationState lockObservation(UUID observationId) {
        List<ObservationState> rows = db.query("""
                SELECT goods_id, stage, excluded_reason
                FROM goods_weight_observations
                WHERE id = :id
                FOR UPDATE
                """, new MapSqlParameterSource("id", observationId), (rs, i) -> new ObservationState(
                rs.getObject("goods_id", UUID.class), rs.getString("stage"), rs.getString("excluded_reason")));
        if (rows.isEmpty()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "称重记录不存在");
        }
        return rows.get(0);
    }

    private boolean exists(String table, UUID id) {
        // table 只来自本类内的常量 (suppliers / warehouses), 不拼接外部输入。
        String sql = switch (table) {
            case "suppliers" -> "SELECT count(*) FROM suppliers WHERE id = :id AND NOT is_deleted";
            case "warehouses" -> "SELECT count(*) FROM warehouses WHERE id = :id AND NOT is_deleted";
            default -> throw new IllegalArgumentException("unsupported table");
        };
        Long count = db.queryForObject(sql, new MapSqlParameterSource("id", id), Long.class);
        return count != null && count > 0;
    }

    private static String trimToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }

    private record ObservationState(UUID goodsId, String stage, String excludedReason) {
    }
}
