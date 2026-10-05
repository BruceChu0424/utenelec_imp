package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.util.PostgresUuidOrder;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 货品主档「所属仓库」回写 (V587)：计划员在物料分析各表里直接改这批货平时归哪个
 * 仓管，改完写回 goods 主档，下次加载就是最新值。
 *
 * <p>语义边界：owning_warehouse_id 是**主档归属**，既不是单据落点仓 (各单据自己的
 * warehouse_id)，也不是本次分析的范围仓 (分析的 warehouse_id / participating
 * warehouses)。命名一律 owning_ 前缀，避免三个语义在同一屏里撞名。
 *
 * <p>为什么走 JdbcTemplate 原生 SQL 而不是 goods 的 JPA 仓储：本类在 production
 * 包里写 master 表，直接 import master 的仓储会踩 ArchitectureBoundaryTest 的跨
 * feature 边界 (production-&gt;master 不在白名单)。仓库侧「货品资料学习回写」
 * (ProcurementArrivalControlService#applyGoodsProfileHints) 就是这个先例，本类
 * 逐条对齐它的防御性写法：单次上限、按货品去重、先读后写、无变化不落盘。
 *
 * <p>审计：goods 带行级审计触发器，按整行 to_jsonb 记快照，新列自动进快照；写前
 * tx.bind() 绑定 app.actor_id，触发器才记得到是谁改的。
 */
@Service
@RequiredArgsConstructor
public class GoodsOwningWarehouseWriteService {

    /** 单次回写上限：与仓库侧货品资料回写同口径，防止一次请求扫全表主档。 */
    private static final int MAX_ROWS = 200;

    private final JdbcTemplate jdbc;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    /**
     * 单条回写条目：owningWarehouseId 为 null = 清空该货品的所属仓库 (合法操作，
     * 不是「跳过」)。
     */
    public record OwningWarehouseRequest(
            @NotNull UUID goodsId,
            UUID owningWarehouseId) {
    }

    /**
     * 批量回写所属仓库，返回 {updated, skipped}。
     *
     * <p>规则：按 goodsId 去重 (同一货品重复出现以最后一行为准)；货品不存在或已软删
     * 跳过 (页面上的行可能刚被他人删掉，不因此整批失败)；与主档现值相同跳过；目标仓库
     * 校验不过则整批 VALIDATION_FAILED (fail-closed，宁可全不落盘也不落一半)。
     */
    @Transactional
    public Map<String, Integer> applyOwningWarehouses(
            List<OwningWarehouseRequest> requests) {
        tx.bind();
        if (requests == null || requests.isEmpty()) {
            return Map.of("updated", 0, "skipped", 0);
        }
        if (requests.size() > MAX_ROWS) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "单次回写不能超过 " + MAX_ROWS + " 条");
        }
        // 同一货品可能在一屏里出现多行 (多颜色/多来源)，以最后一行为准。
        Map<UUID, OwningWarehouseRequest> byGoods = new LinkedHashMap<>();
        for (OwningWarehouseRequest request : requests) {
            if (request == null || request.goodsId() == null) {
                continue;
            }
            byGoods.put(request.goodsId(), request);
        }
        if (byGoods.isEmpty()) {
            return Map.of("updated", 0, "skipped", 0);
        }

        List<UUID> ids = byGoods.keySet().stream().sorted(PostgresUuidOrder.INSTANCE).toList();
        String placeholders = String.join(", ", Collections.nCopies(ids.size(), "?"));
        // 现值：用于「无变化不落盘」以及区分「货品不存在」(containsKey 为 false)
        // 与「现值为空」(value 为 null)。
        Map<UUID, UUID> current = new HashMap<>();
        jdbc.query("SELECT id, owning_warehouse_id FROM goods WHERE id IN ("
                + placeholders + ") AND is_deleted = FALSE ORDER BY id FOR UPDATE", rs -> {
            current.put(
                    rs.getObject("id", UUID.class),
                    rs.getObject("owning_warehouse_id", UUID.class));
        }, ids.toArray());

        // ADR-145: 只有值真的变化的行才按「可选良品子仓」校验(原样带回的旧值不重新判定)。
        List<OwningWarehouseRequest> changing = byGoods.values().stream()
                .filter(request -> current.containsKey(request.goodsId())
                        && !Objects.equals(current.get(request.goodsId()), request.owningWarehouseId()))
                .toList();
        requireWarehousesSelectable(changing);

        UUID actor = currentUser.requireId();
        int updated = 0;
        int skipped = 0;
        for (Map.Entry<UUID, OwningWarehouseRequest> entry : byGoods.entrySet().stream()
                .sorted(Map.Entry.comparingByKey(PostgresUuidOrder.INSTANCE)).toList()) {
            if (!current.containsKey(entry.getKey())) {
                skipped++;
                continue;
            }
            UUID target = entry.getValue().owningWarehouseId();
            if (Objects.equals(current.get(entry.getKey()), target)) {
                skipped++;
                continue;
            }
            // CAST(? AS uuid)：清空时参数为 null，显式声明类型免得驱动推不出参数类型。
            jdbc.update("""
                    UPDATE goods
                    SET owning_warehouse_id = CAST(? AS uuid),
                        version = version + 1,
                        updated_at = now(),
                        updated_by = ?
                    WHERE id = ? AND is_deleted = FALSE
                    """, target, actor, entry.getKey());
            updated++;
        }
        return Map.of("updated", updated, "skipped", skipped);
    }

    /**
     * 目标仓库校验(ADR-145): 所属仓库只能是启用中的良品子仓, 与仓库字典 selectableForNew 同一个
     * SQL 定义 fn_warehouse_is_good_stock_leaf(不能是主仓、停用仓、不良品仓、车间内料仓)。
     * null 目标 = 清空，不参与校验; 数据库守卫 fn_guard_goods_ordinary_owning_warehouse 兜底。
     */
    private void requireWarehousesSelectable(
            Collection<OwningWarehouseRequest> requests) {
        Set<UUID> targets = new LinkedHashSet<>();
        for (OwningWarehouseRequest request : requests) {
            if (request.owningWarehouseId() != null) {
                targets.add(request.owningWarehouseId());
            }
        }
        if (targets.isEmpty()) {
            return;
        }
        List<UUID> ids = List.copyOf(targets);
        String placeholders = String.join(", ", Collections.nCopies(ids.size(), "?"));
        Set<UUID> selectable = new LinkedHashSet<>();
        jdbc.query("SELECT id FROM warehouses WHERE id IN (" + placeholders
                + ") AND fn_warehouse_is_good_stock_leaf(id)", rs -> {
            selectable.add(rs.getObject("id", UUID.class));
        }, ids.toArray());
        if (selectable.size() != ids.size()) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "所属仓库只能选启用中的良品子仓，不能是主仓、停用仓、不良品仓或车间内料仓");
        }
    }
}
