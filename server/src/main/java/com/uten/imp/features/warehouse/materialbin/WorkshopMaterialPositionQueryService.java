package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BadgeCounts;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.LeafStockView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialStockOption;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionRow;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PositionView;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * 车间内料仓页 (ADR-131 §5.2、§5.8): 每种料的账面、上次实盘、本期进出、按报工估算已用、估计还剩、
 * 仓库还能发多少; 顶部是盘点与结算状态和"差什么、谁来补"。数字全部由 {@code fn_workshop_material_bin_position}
 * 在库里算一次。另给工作台徽章的计数 (待发料、待收退回、盘点中)。
 */
@Service
public class WorkshopMaterialPositionQueryService {

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final WorkshopMaterialPeriodViews periodViews;

    public WorkshopMaterialPositionQueryService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                                WorkshopMaterialScope scope, WorkshopMaterialPermissions permissions,
                                                WorkshopMaterialPeriodViews periodViews) {
        this.db = db;
        this.bins = bins;
        this.scope = scope;
        this.permissions = permissions;
        this.periodViews = periodViews;
    }

    @Transactional(readOnly = true)
    public PositionView position(UUID binWarehouseId) {
        Settings settings = binWarehouseId == null ? null : bins.settingsByBin(binWarehouseId);
        if (settings == null) throw new ApiException(ErrorCode.NOT_FOUND, "这个仓库不是开启了整批领料的车间内料仓");
        scope.requireWorkshop(settings.workshopDepartmentId());
        List<PositionRow> rows = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT position.*, goods.code AS goods_code, goods.name AS goods_name, color.name AS color_name,
                       unit.name AS unit_name, goods.bulk_package_qty
                FROM fn_workshop_material_bin_position(:bin) position
                JOIN goods ON goods.id = position.goods_id
                LEFT JOIN colors color ON color.id = position.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                ORDER BY goods.code, color.name
                """, Map.of("bin", binWarehouseId))) {
            rows.add(new PositionRow((UUID) row.get("goods_id"), (String) row.get("goods_code"),
                    (String) row.get("goods_name"), (UUID) row.get("color_id"), (String) row.get("color_name"),
                    (String) row.get("unit_name"), WorkshopMaterialBinSupport.decimal(row.get("bulk_package_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("book_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("last_count_qty")),
                    WorkshopMaterialBinSupport.date(row.get("last_count_date")),
                    WorkshopMaterialBinSupport.decimal(row.get("period_in_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("period_return_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("period_other_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("estimated_used_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("estimated_remaining_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("warehouse_available_qty")),
                    WorkshopMaterialBinSupport.number(row.get("missing_weight_products")).intValue(),
                    WorkshopMaterialBinSupport.number(row.get("draft_report_count")).intValue()));
        }
        Period open = null;
        Period pending = null;
        for (Period period : bins.periodsOf(binWarehouseId)) {
            if ("OPEN".equals(period.status())) open = period;
            if (pending == null && ("COUNTING".equals(period.status()) || "COUNTED".equals(period.status()))) {
                pending = period;
            }
        }
        Period headline = pending != null ? pending : open;
        PeriodView headlineView = headline == null ? null : periodViews.view(headline.id());
        List<String> actions = new ArrayList<>();
        boolean enabled = settings.enabled();
        if (enabled && permissions.has(WorkshopMaterialPermissions.REQUEST)) {
            actions.add("REQUEST");
            actions.add("RETURN");
            actions.add("OTHER_ISSUE");
        }
        if (enabled && permissions.has(WorkshopMaterialPermissions.ISSUE)) actions.add("DIRECT_ISSUE");
        if (headlineView != null) {
            for (String action : headlineView.allowedActions()) {
                if (!actions.contains(action)) actions.add(action);
            }
        }
        return new PositionView(binWarehouseId, bins.warehouseName(binWarehouseId), settings.workshopDepartmentId(),
                settings.workshopName(), headline == null ? null : headline.status(),
                headlineView == null ? null : headlineView.closeState(),
                headlineView == null ? List.of() : headlineView.closeBlockers(),
                headlineView == null ? null : headlineView.heldUntil(),
                open == null ? null : open.ref(), pending == null ? null : pending.ref(), rows, actions);
    }

    /** 下拉最多列出的料数 (整批领料的料通常几十种; 防异常数据拖慢页面)。 */
    private static final int MATERIAL_LIMIT = 500;

    /** 整批领料的料、这些料在记账叶仓里的余额 (叶仓判定每个仓只算一次)。 */
    private static final String PERIODIC_STOCK_CTES = """
            WITH periodic AS MATERIALIZED (
                SELECT goods.id, goods.color_id FROM goods
                WHERE goods.issue_method = 'PERIODIC' AND NOT goods.is_deleted
            ), balances AS MATERIALIZED (
                SELECT balance.warehouse_id, balance.goods_id, balance.color_id, balance.qty
                FROM stock_balances balance JOIN periodic ON periodic.id = balance.goods_id
                WHERE balance.qty <> 0
            ), accounting AS MATERIALIZED (
                SELECT leaf.warehouse_id FROM (SELECT DISTINCT warehouse_id FROM balances) leaf
                WHERE fn_warehouse_is_active_accounting_leaf(leaf.warehouse_id)
            ), stocked AS MATERIALIZED (
                SELECT balances.* FROM balances JOIN accounting ON accounting.warehouse_id = balances.warehouse_id
            )
            """;

    private record MaterialKey(UUID goodsId, UUID colorId) {}

    /**
     * 新建补料申请的候选：可选尚未接入整批方式的重量物料，申请阶段不转换货品或库存。
     * 逐材料/颜色分页，goodsIds 在库存查询前精确过滤；普通叶仓供货量不包含任何车间内料仓。
     */
    @Transactional(readOnly = true)
    public PageResponse<MaterialStockOption> requestMaterials(UUID workshopDepartmentId, String keyword,
            List<UUID> goodsIds, int page, int size) {
        if (workshopDepartmentId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshopDepartmentId);
        Settings settings = bins.settings(workshopDepartmentId);
        UUID bin = settings == null ? null : settings.binWarehouseId();
        var paging = Pageables.of(page, size);
        List<UUID> ids = goodsIds == null ? List.of() : goodsIds.stream().filter(Objects::nonNull).distinct().toList();
        MapSqlParameterSource params = new MapSqlParameterSource("bin", bin == null ? null : bin.toString())
                .addValue("keyword", keyword == null || keyword.isBlank() ? null : keyword.strip())
                .addValue("limit", paging.getPageSize()).addValue("offset", paging.getOffset());
        if (!ids.isEmpty()) params.addValue("goodsIds", ids);
        String candidates = WorkshopMaterialRequestCandidateSql.candidates(!ids.isEmpty());
        Long count = db.queryForObject(candidates + " SELECT count(*) FROM candidates", params, Long.class);
        long total = count == null ? 0 : count;
        int pages = (int) Math.ceil((double) total / paging.getPageSize());
        if (total == 0) return new PageResponse<>(List.of(), paging.getPageNumber() + 1, paging.getPageSize(), total, pages);

        Map<MaterialKey, Map<String, Object>> heads = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList(candidates + WorkshopMaterialRequestCandidateSql.HEADS, params)) {
            heads.put(new MaterialKey((UUID) row.get("goods_id"), (UUID) row.get("color_id")), row);
        }
        if (heads.isEmpty()) return new PageResponse<>(List.of(), paging.getPageNumber() + 1, paging.getPageSize(), total, pages);
        // 只读本页材料的各普通叶仓，不为一个小页再扫全部候选的余额。
        Map<MaterialKey, List<LeafStockView>> leaves = new LinkedHashMap<>();
        MapSqlParameterSource leafParams = new MapSqlParameterSource("goodsIds",
                heads.keySet().stream().map(MaterialKey::goodsId).distinct().toList());
        for (Map<String, Object> row : db.queryForList(WorkshopMaterialRequestCandidateSql.stock(true)
                + WorkshopMaterialRequestCandidateSql.LEAVES, leafParams)) {
            MaterialKey key = new MaterialKey((UUID) row.get("goods_id"), (UUID) row.get("color_id"));
            if (!heads.containsKey(key)) continue;
            leaves.computeIfAbsent(key, ignored -> new ArrayList<>()).add(new LeafStockView(
                    (UUID) row.get("warehouse_id"), (String) row.get("warehouse_name"),
                    WorkshopMaterialBinSupport.zero(row.get("available"))));
        }
        List<MaterialStockOption> options = new ArrayList<>();
        for (Map.Entry<MaterialKey, Map<String, Object>> entry : heads.entrySet()) {
            Map<String, Object> row = entry.getValue();
            UUID defaultLeaf = (UUID) row.get("owning_warehouse_id");
            List<LeafStockView> stock = new ArrayList<>(leaves.getOrDefault(entry.getKey(), List.of()));
            if (defaultLeaf != null && stock.stream().noneMatch(leaf -> defaultLeaf.equals(leaf.warehouseId()))) {
                stock.add(0, new LeafStockView(defaultLeaf, (String) row.get("owning_name"), BigDecimal.ZERO));
            }
            options.add(new MaterialStockOption(entry.getKey().goodsId(), (String) row.get("code"),
                    (String) row.get("name"), entry.getKey().colorId(), (String) row.get("color_name"),
                    (String) row.get("unit_name"), WorkshopMaterialBinSupport.decimal(row.get("bulk_package_qty")),
                    (String) row.get("periodic_cost_basis"), defaultLeaf, (String) row.get("owning_name"),
                    WorkshopMaterialBinSupport.zero(row.get("available")), List.copyOf(stock)));
        }
        return new PageResponse<>(List.copyOf(options), paging.getPageNumber() + 1, paging.getPageSize(), total, pages);
    }

    /**
     * 可发到某车间内料仓的料: 全部整批领料的料 (按货品资料的颜色), 加上记账叶仓里有货的颜色、这个内料仓进出过的颜色;
     * 进过这个内料仓的排在前面。每种料带每袋净重、分摊方式、默认出库叶仓、各叶仓还能发多少与合计 (合计与内料仓页
     * 「仓库可发」同一口径: 叶仓余额 - 未了结的占用 - 最低库存)。车间成员只能查本车间。
     */
    @Transactional(readOnly = true)
    public List<MaterialStockOption> materials(UUID workshopDepartmentId) {
        if (workshopDepartmentId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshopDepartmentId);
        Settings settings = bins.settings(workshopDepartmentId);
        UUID bin = settings == null ? null : settings.binWarehouseId();
        MapSqlParameterSource params = new MapSqlParameterSource("bin", bin == null ? null : bin.toString())
                .addValue("limit", MATERIAL_LIMIT);
        Map<MaterialKey, Map<String, Object>> heads = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList(PERIODIC_STOCK_CTES + """
                , used AS MATERIALIZED (
                    SELECT DISTINCT ledger.goods_id, ledger.color_id FROM v_workshop_material_bin_ledger ledger
                    WHERE ledger.bin_warehouse_id = CAST(:bin AS uuid)
                ), candidates AS (
                    SELECT periodic.id AS goods_id, periodic.color_id FROM periodic
                    UNION SELECT stocked.goods_id, stocked.color_id FROM stocked WHERE stocked.qty > 0
                    UNION SELECT used.goods_id, used.color_id FROM used JOIN periodic ON periodic.id = used.goods_id
                )
                SELECT candidate.goods_id, candidate.color_id, goods.code, goods.name, color.name AS color_name,
                       unit.name AS unit_name, goods.bulk_package_qty, goods.periodic_cost_basis,
                       goods.owning_warehouse_id, owning.name AS owning_name,
                       EXISTS (SELECT 1 FROM used WHERE used.goods_id = candidate.goods_id
                                 AND used.color_id IS NOT DISTINCT FROM candidate.color_id) AS used,
                       GREATEST(
                           COALESCE((SELECT sum(stocked.qty) FROM stocked
                                     WHERE stocked.goods_id = candidate.goods_id
                                       AND stocked.color_id IS NOT DISTINCT FROM candidate.color_id), 0)
                           - COALESCE((SELECT sum(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                                       FROM stock_reservations reservation
                                       WHERE NOT reservation.is_deleted AND reservation.status = 0
                                         AND reservation.goods_id = candidate.goods_id
                                         AND reservation.color_id IS NOT DISTINCT FROM candidate.color_id
                                         AND (reservation.warehouse_id IS NULL
                                              OR fn_warehouse_is_active_accounting_leaf(reservation.warehouse_id))), 0)
                           - GREATEST(COALESCE(goods.min_qty::numeric, 0), 0),
                           0) AS available
                FROM candidates candidate
                JOIN goods ON goods.id = candidate.goods_id
                LEFT JOIN colors color ON color.id = candidate.color_id
                LEFT JOIN units unit ON unit.id = goods.unit_id
                LEFT JOIN warehouses owning ON owning.id = goods.owning_warehouse_id
                ORDER BY used DESC, goods.code, color.name NULLS FIRST, candidate.goods_id, candidate.color_id
                LIMIT :limit
                """, params)) {
            heads.put(new MaterialKey((UUID) row.get("goods_id"), (UUID) row.get("color_id")), row);
        }
        if (heads.isEmpty()) return List.of();
        Map<MaterialKey, List<LeafStockView>> leaves = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList(PERIODIC_STOCK_CTES + """
                SELECT stocked.goods_id, stocked.color_id, stocked.warehouse_id, warehouse.name AS warehouse_name,
                       GREATEST(stocked.qty
                           - COALESCE((SELECT sum(reservation.qty - reservation.consumed_qty - reservation.released_qty)
                                       FROM stock_reservations reservation
                                       WHERE NOT reservation.is_deleted AND reservation.status = 0
                                         AND reservation.goods_id = stocked.goods_id
                                         AND reservation.color_id IS NOT DISTINCT FROM stocked.color_id
                                         AND (reservation.warehouse_id IS NULL
                                              OR reservation.warehouse_id = stocked.warehouse_id)), 0),
                           0) AS available
                FROM stocked JOIN warehouses warehouse ON warehouse.id = stocked.warehouse_id
                WHERE stocked.qty > 0
                  AND stocked.warehouse_id IS DISTINCT FROM CAST(:bin AS uuid)
                ORDER BY stocked.goods_id, stocked.color_id, warehouse.name, stocked.warehouse_id
                """, params)) {
            MaterialKey key = new MaterialKey((UUID) row.get("goods_id"), (UUID) row.get("color_id"));
            if (!heads.containsKey(key)) continue;
            leaves.computeIfAbsent(key, ignored -> new ArrayList<>()).add(new LeafStockView(
                    (UUID) row.get("warehouse_id"), (String) row.get("warehouse_name"),
                    WorkshopMaterialBinSupport.zero(row.get("available"))));
        }
        List<MaterialStockOption> out = new ArrayList<>();
        for (Map.Entry<MaterialKey, Map<String, Object>> entry : heads.entrySet()) {
            Map<String, Object> row = entry.getValue();
            UUID owning = (UUID) row.get("owning_warehouse_id");
            UUID defaultLeaf = Objects.equals(owning, bin) ? null : owning;
            List<LeafStockView> stock = new ArrayList<>(leaves.getOrDefault(entry.getKey(), List.of()));
            if (defaultLeaf != null && stock.stream().noneMatch(leaf -> defaultLeaf.equals(leaf.warehouseId()))) {
                // 默认出库叶仓即使没货也列出, 仓库照样可以选。
                stock.add(0, new LeafStockView(defaultLeaf, (String) row.get("owning_name"), BigDecimal.ZERO));
            }
            out.add(new MaterialStockOption(entry.getKey().goodsId(), (String) row.get("code"),
                    (String) row.get("name"), entry.getKey().colorId(), (String) row.get("color_name"),
                    (String) row.get("unit_name"), WorkshopMaterialBinSupport.decimal(row.get("bulk_package_qty")),
                    (String) row.get("periodic_cost_basis"), defaultLeaf,
                    defaultLeaf == null ? null : (String) row.get("owning_name"),
                    WorkshopMaterialBinSupport.zero(row.get("available")), List.copyOf(stock)));
        }
        return out;
    }

    /** 工作台徽章: 待发料、待收退回 (红), 盘点中 (黄); 车间成员只数本车间。 */
    @Transactional(readOnly = true)
    public BadgeCounts badgeCounts() {
        MapSqlParameterSource params = new MapSqlParameterSource();
        String inScope = scope.predicate("workshop_department_id", params);
        Map<String, Object> row = db.queryForMap("""
                SELECT (SELECT count(*) FROM workshop_material_requisitions
                        WHERE status = 'PENDING' AND kind = 'ISSUE'
                        """ + " AND " + inScope + """
                ) AS pending_issue,
                       (SELECT count(*) FROM workshop_material_requisitions
                        WHERE status = 'PENDING' AND kind = 'RETURN'
                        """ + " AND " + inScope + """
                ) AS pending_return,
                       (SELECT count(*) FROM workshop_material_periods
                        WHERE status = 'COUNTING'
                        """ + " AND " + inScope + """
                ) AS counting
                """, params);
        return new BadgeCounts(WorkshopMaterialBinSupport.number(row.get("pending_issue")).longValue(),
                WorkshopMaterialBinSupport.number(row.get("pending_return")).longValue(),
                WorkshopMaterialBinSupport.number(row.get("counting")).longValue());
    }
}
