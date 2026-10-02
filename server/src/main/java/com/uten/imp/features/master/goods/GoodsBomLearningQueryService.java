package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.annotation.JsonUnwrapped;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomItemUsage;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.function.Predicate;

/**
 * 「BOM 学习记录」(ADR-129)：父件档案 + 逐组件的设计使用数量与真实使用数量。
 *
 * <p>组装边取自 v_goods_bom_item_usage，BOM 外实际用过的料取自 v_goods_bom_actual_usage(状态与
 * 重新学习后的窗口只在这个视图里定义)；两种行都经同一个映射 {@link BomItemUsage}，JSON 字段与组装信息
 * 页签一致。平均值由数据库算，Java 不重算。用量只读主档聚合，不扫历史生产样本；
 * 选料证据另沿父件索引读取，尚无学习样本时也能说明材料已记录在哪一步。
 */
@Service
@RequiredArgsConstructor
public class GoodsBomLearningQueryService {
    private final EntityManager em;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final GoodsBomMaterialEvidenceQuery materialEvidence;

    /** 「从现在起重新学习」要的权限：接口鉴权与下发给页面的 canRelearn 用同一个。 */
    static final String RELEARN_PERMISSION = "goods:bom:edit";

    /**
     * 父件学习档案；blockedReason 只说明「系统新建学习边」为什么被挡住，不影响真实使用数量累计。
     * totalOutputQty 是已学良品产量，totalDefectQty 是同一批族的报工不良数(只作说明，不进平均值)。
     */
    public record Profile(BigDecimal totalOutputQty, BigDecimal totalDefectQty, long sampleCount,
                          String blockedReason, String outputUnitName) { }

    /**
     * 一个组件：inBom=true 是有效组装边(designQty 与 usage 的计算采用值有值)；inBom=false 是 BOM 外实际
     * 用过的料(没有设计使用数量、不参与计算)，released=true 表示它的组装边被人删过、学习不再自动加回。
     * usage 在 JSON 里平铺成与组装信息页签同名的字段。数量都按该行 unitId 的基本单位。
     */
    public record Component(UUID componentGoodsId, String componentCode, String componentName, UUID unitId,
                            String unitName, boolean inBom, UUID bomItemId, boolean released,
                            BigDecimal designQty, @JsonUnwrapped BomItemUsage usage) { }

    /**
     * profile 为 null = 该父件还没有任何学习样本(组装边照样列出，真实使用数量为没有数据)。
     * canRelearn = 当前账号能否「从现在起重新学习」，页面据此显示按钮。
     * materialEvidence 是已保存的认料/申请/仓库配置，不代表实际耗用或正式 BOM 边。
     */
    public record Summary(Profile profile, List<Component> components, boolean canRelearn,
                          List<GoodsBomMaterialEvidenceQuery.Evidence> materialEvidence) { }

    @Transactional(readOnly = true)
    public Summary summary(UUID goodsId) {
        references.requireVisibleGoods(goodsId);
        return load(goodsId);
    }

    /**
     * 从现在起重新学习：该组件当前累计记为基线，之后只用新数据；新数据出来前按设计使用数量计算。
     * 开启新一轮学习(fn_relearn_bom_actual_usage，与学习引擎在同一父件的学习锁上串行)，操作人取本事务绑定的账号。
     */
    @PreAuthorize("hasAuthority('" + RELEARN_PERMISSION + "')")
    @Transactional
    public Summary relearn(UUID goodsId, UUID componentGoodsId) {
        tx.bind();
        references.requireVisibleGoods(goodsId);
        Number affected = (Number) em.createNativeQuery("""
                        SELECT fn_relearn_bom_actual_usage(:goods, :component,
                            CAST(NULLIF(current_setting('app.actor_id', true), '') AS uuid))
                        """)
                .setParameter("goods", goodsId)
                .setParameter("component", componentGoodsId)
                .getSingleResult();
        if (affected == null || affected.intValue() == 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "这个组件还没有真实使用数据，不需要重新学习");
        }
        return load(goodsId);
    }

    private Summary load(UUID goodsId) {
        var profiles = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT profile.total_output_qty, profile.total_defect_qty, profile.sample_count,
                       profile.blocked_reason, unit.name
                FROM goods_bom_learning_profiles profile LEFT JOIN units unit ON unit.id = profile.output_unit_id
                WHERE profile.goods_id = :goods
                """).setParameter("goods", goodsId));
        Profile profile = profiles.isEmpty() ? null : profileOf(profiles.getFirst());
        Predicate<UUID> visible = access.visibleGoodsOwner();
        List<Component> components = new ArrayList<>();
        // 有效组装边(可运营口径同组装信息页签)：看不到的组件整行不列。
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT edge.id, component.id, component.code, component.name, component.unit_id, unit.name,
                       component.owner_employee_id, u.design_qty, %s
                FROM goods_bom_items edge
                JOIN goods parent ON parent.id = edge.goods_id AND NOT parent.auto_created
                JOIN goods component ON component.id = edge.component_goods_id AND NOT component.auto_created
                JOIN v_goods_bom_item_usage u ON u.bom_item_id = edge.id
                LEFT JOIN units unit ON unit.id = component.unit_id
                WHERE edge.goods_id = :goods AND NOT edge.is_deleted
                ORDER BY edge.sort_order, edge.id
                """.formatted(BomItemUsage.COLUMNS)).setParameter("goods", goodsId))) {
            if (!visible.test((UUID) row[6])) continue;
            components.add(new Component((UUID) row[1], (String) row[2], (String) row[3], (UUID) row[4],
                    (String) row[5], true, (UUID) row[0], false, decimal(row[7]), BomItemUsage.of(row, 8)));
        }
        // BOM 外实际用过的料：没有对上任何有效组装边(组件+组件当前单位)的累计。
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT a.component_goods_id, component.code, component.name, a.unit_id, unit.name,
                       component.owner_employee_id,
                       EXISTS(SELECT 1 FROM goods_bom_items released
                              WHERE released.goods_id = a.goods_id
                                AND released.component_goods_id = a.component_goods_id
                                AND released.is_deleted AND released.learning_released_at IS NOT NULL),
                       %s
                FROM v_goods_bom_actual_usage a
                JOIN goods component ON component.id = a.component_goods_id
                LEFT JOIN units unit ON unit.id = a.unit_id
                WHERE a.goods_id = :goods
                  AND NOT EXISTS(SELECT 1 FROM goods_bom_items live
                                 WHERE live.goods_id = a.goods_id
                                   AND live.component_goods_id = a.component_goods_id
                                   AND NOT live.is_deleted AND a.unit_id = component.unit_id)
                ORDER BY component.code, a.component_goods_id, a.unit_id
                """.formatted(BomItemUsage.OFF_BOM_COLUMNS)).setParameter("goods", goodsId))) {
            if (!visible.test((UUID) row[5])) continue;
            components.add(new Component((UUID) row[0], (String) row[1], (String) row[2], (UUID) row[3],
                    (String) row[4], false, null, Boolean.TRUE.equals(row[6]), null, BomItemUsage.of(row, 7)));
        }
        return new Summary(profile, components, canRelearn(), materialEvidence.list(goodsId, visible));
    }

    /** 与 relearn 的 @PreAuthorize 同一规则：当前登录账号的权限里有 {@link #RELEARN_PERMISSION}。 */
    private boolean canRelearn() {
        return currentUser.get()
                .map(user -> user.getAuthorities().stream()
                        .anyMatch(granted -> RELEARN_PERMISSION.equals(granted.getAuthority())))
                .orElse(false);
    }

    private static Profile profileOf(Object[] row) {
        return new Profile(decimal(row[0]), decimal(row[1]), ((Number) row[2]).longValue(),
                (String) row[3], (String) row[4]);
    }

    private static BigDecimal decimal(Object value) {
        return value == null ? null : NativeValueConverters.toBigDecimal(value);
    }
}
