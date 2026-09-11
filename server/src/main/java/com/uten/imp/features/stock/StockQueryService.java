package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.stock.dto.BalanceRow;
import com.uten.imp.features.stock.dto.InstantInventoryRow;
import com.uten.imp.features.stock.dto.MovementRow;
import jakarta.persistence.EntityManager;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 库存查询服务：余额分页（按仓库/货品过滤）+ 流水分页（按仓库/货品/类型/日期过滤）。
 *
 * <p>名称（仓库/货品/颜色）不在此 JOIN，由前端按 id 用 master dict 解析（与采购单据同款）。
 */
@Service
@RequiredArgsConstructor
public class StockQueryService {

    /** 余额列排序白名单：前端列 key → JPA 实体属性名（数量/重量可排序；否则默认 lastMovementDate DESC）。 */
    private static final Map<String, String> BALANCE_ALLOWED_SORT = Map.of(
            "qty", "qty", "weight", "weight");

    /** 流水列排序白名单：前端列 key → JPA 实体属性名（日期/数量/重量可排序）。 */
    private static final Map<String, String> MOVEMENT_ALLOWED_SORT = Map.of(
            "date", "transactionDate", "qty", "qty", "weight", "weight");

    private final StockBalanceRepository balanceRepo;
    private final StockMovementRepository movementRepo;
    private final EntityManager em;
    private final StockCostMasker costMasker;

    /**
     * warehouseId → 查询范围（V476：自身+全部未软删后代；叶子仓=精确单仓旧行为）。
     * 递归 CTE 直查而不注入 master 侧组件——stock→master 是 ArchitectureBoundary
     * 未放行的新依赖边（ADR-017）。锚点查不到（未知/已软删仓）退化为精确单仓。
     */
    private Set<UUID> warehouseScopeOf(UUID warehouseId) {
        if (warehouseId == null) {
            return null;
        }
        @SuppressWarnings("unchecked")
        List<UUID> ids = em.createNativeQuery("""
                WITH RECURSIVE wh AS (
                    SELECT id FROM warehouses WHERE id = :rootId AND is_deleted = false
                    UNION ALL
                    SELECT w.id FROM warehouses w JOIN wh ON w.parent_id = wh.id
                    WHERE w.is_deleted = false
                )
                SELECT id FROM wh
                """)
                .setParameter("rootId", warehouseId)
                .getResultList();
        return ids.isEmpty() ? Set.of(warehouseId) : Set.copyOf(ids);
    }

    @Transactional(readOnly = true)
    public PageResponse<BalanceRow> balances(UUID warehouseId, UUID goodsId, int page, int size,
                                             String sort, String order) {
        // V476：选父仓=自身+全部后代聚合；叶子仓为单元素集合，等价旧精确匹配。
        Set<UUID> warehouseScope = warehouseScopeOf(warehouseId);
        Specification<StockBalance> spec = (Root<StockBalance> root,
                                            jakarta.persistence.criteria.CriteriaQuery<?> q,
                                            CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseScope != null) ps.add(root.get("warehouseId").in(warehouseScope));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "lastMovementDate"), BALANCE_ALLOWED_SORT));
        Page<StockBalance> p = balanceRepo.findAll(spec, pageable);
        boolean canViewCost = costMasker.canView();
        return new PageResponse<>(p.map(balance -> toBalanceRow(balance, canViewCost)).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PageResponse<MovementRow> movements(UUID warehouseId, UUID goodsId, Short movementType,
                                               OffsetDateTime dateFrom, OffsetDateTime dateTo,
                                               int page, int size, String sort, String order) {
        // V476：同 balances——父仓查询按子树聚合。
        Set<UUID> warehouseScope = warehouseScopeOf(warehouseId);
        Specification<StockMovement> spec = (Root<StockMovement> root,
                                            jakarta.persistence.criteria.CriteriaQuery<?> q,
                                            CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseScope != null) ps.add(root.get("warehouseId").in(warehouseScope));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            if (movementType != null) ps.add(cb.equal(root.get("movementType"), movementType));
            if (dateFrom != null) ps.add(cb.greaterThanOrEqualTo(root.get("transactionDate"), dateFrom));
            if (dateTo != null) ps.add(cb.lessThanOrEqualTo(root.get("transactionDate"), dateTo));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "transactionDate"), MOVEMENT_ALLOWED_SORT));
        Page<StockMovement> p = movementRepo.findAll(spec, pageable);
        boolean canViewCost = costMasker.canView();
        return new PageResponse<>(p.map(movement -> toMovementRow(movement, canViewCost)).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    // ======================== 即时库存（对标老系统「即时库存」窗口） ========================

    /**
     * 即时库存列排序白名单：前端列 key → SQL 投影别名（命中才排序，否则默认 qty DESC + name ASC）。
     * 防注入：仅白名单值进入 ORDER BY。
     */
    private static final Map<String, String> INSTANT_ALLOWED_SORT = Map.of(
            "qty", "qty",
            "weight", "weight",
            "costAmount", "cost_amount",
            "moreQty", "more_qty",
            "pendingQty", "pending_qty",
            "pendingStockInQty", "pending_stock_in_qty",
            "name", "name");

    /**
     * 即时库存查询：**货品驱动**（对标老系统「分类下全是内容」——零库存货品也列出来，
     * 库存列显示 0，与老系统截图一致），LEFT JOIN stock_balances 聚合（仓库=全部时只算
     * 「参与核算」仓库），JOIN goods 出型号/客户型号/名称/规格/备注/分类，颜色/单位顺带解析名，
     * 多排数量 = production_plan_items 可排余量（老库 View_ProductMore 同口径）。
     *
     * <p>行粒度 = 货品×（有余额的颜色）；无余额货品一行、颜色空、库存 0。
     * 数据量：goods 3.5 万 LEFT JOIN 余额聚合（8.6k→按仓+货+色）+ 计划明细 7 万预聚合，
     * 全部走 (goods_id) 索引，分页 LIMIT/OFFSET——毫秒级。
     * 可选过滤（categoryId 子树 / warehouseId / keyword）为 null 时不拼对应子句
     * （避免 native query null 参数类型推断问题，也让执行计划更干净）。
     *
     * @param categoryId 货品分类 id（含全部后代，递归 CTE）；null=全部
     * @param warehouseId 仓库 id；null=全部（仅 is_accountable 参与核算仓库）；
     *                    V476 起选父仓=自身+全部子仓聚合（核算/不良仓口径同「全部」）
     * @param includeDefective 是否含不良品仓（仓库=全部**或父仓聚合**时生效，默认 true=老系统口径）
     * @param keyword 名称/编号/型号/客户型号 模糊；null=不筛
     */
    @Transactional(readOnly = true)
    public PageResponse<InstantInventoryRow> instantInventory(UUID categoryId, UUID warehouseId,
                                                              boolean includeDefective,
                                                              String keyword, int page, int size,
                                                              String sort, String order) {
        boolean canViewCost = costMasker.canView();
        if (!canViewCost && "costAmount".equals(sort)) {
            throw new ApiException(
                    ErrorCode.FORBIDDEN,
                    "无查看货品成本权限(" + StockCostMasker.PERMISSION + ")");
        }
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        // ---- 条件拼接（参数化，值永远走 setParameter） ----
        StringBuilder balWhere = new StringBuilder(" WHERE 1=1");
        StringBuilder iqcWhere = new StringBuilder();
        StringBuilder stockInWhere = new StringBuilder();
        // V476：warehouseId 展开成查询范围——叶子仓=精确单仓（旧行为），父仓=子树聚合。
        Set<UUID> warehouseScope = warehouseScopeOf(warehouseId);
        if (warehouseScope != null && warehouseScope.size() == 1) {
            balWhere.append(" AND b.warehouse_id = :warehouseId");
            iqcWhere.append(" AND i.warehouse_id = :warehouseId");
            stockInWhere.append(" AND i.warehouse_id = :warehouseId");
        } else if (warehouseScope != null) {
            balWhere.append(" AND b.warehouse_id IN (:scopeIds) AND w.is_accountable");
            iqcWhere.append(" AND i.warehouse_id IN (:scopeIds) AND w.is_accountable");
            stockInWhere.append(" AND i.warehouse_id IN (:scopeIds) AND w.is_accountable");
            // 父仓聚合与「全部」同口径：开关关掉则剔除不良品子仓。
            if (!includeDefective) {
                balWhere.append(" AND NOT w.is_defective");
                iqcWhere.append(" AND NOT w.is_defective");
                stockInWhere.append(" AND NOT w.is_defective");
            }
        } else {
            // 仓库=全部：只统计参与库存核算的仓库（老库 B_Storage.IsCal=0 口径）。
            balWhere.append(" AND w.is_accountable");
            iqcWhere.append(" AND w.is_accountable");
            stockInWhere.append(" AND w.is_accountable");
            // 「含不良品仓」开关：关掉则剔除不良品仓（默认开=老系统口径，不良仓计入全部）。
            if (!includeDefective) {
                balWhere.append(" AND NOT w.is_defective");
                iqcWhere.append(" AND NOT w.is_defective");
                stockInWhere.append(" AND NOT w.is_defective");
            }
        }
        iqcWhere.insert(0, " AND i.received_base_qty - i.passed_base_qty - i.failed_base_qty > 0");
        stockInWhere.insert(0,
                " AND i.passed_base_qty - i.warehouse_stocked_base_qty > 0");
        StringBuilder goodsWhere = new StringBuilder(" WHERE g.is_deleted = false");
        if (categoryId != null) {
            goodsWhere.append(" AND g.category_id IN (SELECT id FROM cat)");
        }
        if (keyword != null && !keyword.isBlank()) {
            goodsWhere.append(
                    " AND (g.name ILIKE :kw OR g.code ILIKE :kw OR g.model ILIKE :kw OR g.c_number ILIKE :kw)");
        }

        // 递归 CTE：仅 categoryId 过滤时才声明（锚为参数，无过滤时整段不出现，计划更简）。
        String cte = categoryId == null ? "" : """
                WITH RECURSIVE cat AS (
                    SELECT id FROM material_categories WHERE id = :categoryId AND is_deleted = false
                    UNION ALL
                    SELECT c.id FROM material_categories c JOIN cat s ON c.parent_id = s.id
                    WHERE c.is_deleted = false
                )
                """;

        String costExpression = canViewCost
                ? "COALESCE(base.amount_local, 0)"
                : "CAST(NULL AS NUMERIC)";
        String core = cte + """
                SELECT g.id AS goods_id, base.color_id, mc.name AS category_name,
                       g.model, g.c_number, g.name, g.spec,
                       c.name AS color_name, u.name AS unit_name, g.paper AS remark,
                       COALESCE(base.weight, 0) AS weight,
                       COALESCE(base.qty, 0) AS qty,
                """ + costExpression + """
                       AS cost_amount,
                       COALESCE(pm.more_qty, 0) AS more_qty,
                       g.code AS goods_code, g.series, g.stock_place,
                       COALESCE(iqc.pending_qty, 0) AS pending_qty,
                       COALESCE(stock_in.pending_stock_in_qty, 0)
                           AS pending_stock_in_qty
                FROM goods g
                LEFT JOIN (
                    SELECT u.goods_id, u.color_id,
                           SUM(u.qty) AS qty,
                           SUM(u.weight) AS weight,
                           SUM(u.amount_local) AS amount_local
                    FROM (
                        (SELECT b.goods_id, b.color_id, b.qty, b.weight, b.amount_local
                         FROM stock_balances b
                         JOIN warehouses w ON w.id = b.warehouse_id
                """ + balWhere + """
                        )
                        UNION ALL
                        -- 待检品尚无余额行：并入 0 量占位行，保证「货在待检」在即时库存可见(行粒度=货品×颜色)。
                        (SELECT i.goods_id, i.color_id, 0, 0, 0
                         FROM procurement_inspection_items i
                         JOIN warehouses w ON w.id = i.warehouse_id
                """ + iqcWhere + """
                        )
                        UNION ALL
                        -- 品质已放行但仓库尚未确认：仍无余额行，也必须留在即时库存视图。
                        (SELECT i.goods_id, i.color_id, 0, 0, 0
                         FROM procurement_inspection_items i
                         JOIN warehouses w ON w.id = i.warehouse_id
                """ + stockInWhere + """
                        )
                    ) u
                    GROUP BY u.goods_id, u.color_id
                ) base ON base.goods_id = g.id
                LEFT JOIN material_categories mc ON mc.id = g.category_id
                LEFT JOIN colors c ON c.id = base.color_id
                LEFT JOIN units u
                  ON (u.id = g.unit_id
                      OR (g.unit_id IS NULL
                          AND u.legacy_id = NULLIF(g.unit_legacy_id, 0)))
                LEFT JOIN (
                    SELECT i.goods_id, i.color_id,
                           SUM(i.received_base_qty - i.passed_base_qty - i.failed_base_qty) AS pending_qty
                    FROM procurement_inspection_items i
                    JOIN warehouses w ON w.id = i.warehouse_id
                """ + iqcWhere + """
                    GROUP BY i.goods_id, i.color_id
                ) iqc ON iqc.goods_id = g.id AND iqc.color_id IS NOT DISTINCT FROM base.color_id
                LEFT JOIN (
                    SELECT i.goods_id, i.color_id,
                           SUM(i.passed_base_qty - i.warehouse_stocked_base_qty)
                               AS pending_stock_in_qty
                    FROM procurement_inspection_items i
                    JOIN warehouses w ON w.id = i.warehouse_id
                """ + stockInWhere + """
                    GROUP BY i.goods_id, i.color_id
                ) stock_in ON stock_in.goods_id = g.id
                    AND stock_in.color_id IS NOT DISTINCT FROM base.color_id
                LEFT JOIN (
                    SELECT goods_id, color_id,
                           SUM(CASE WHEN qty - oqty > iqty THEN qty - oqty - iqty ELSE 0 END) AS more_qty
                    FROM production_plan_items
                    WHERE is_deleted = false AND qty > oqty AND qty - lqty > iqty
                    GROUP BY goods_id, color_id
                ) pm ON pm.goods_id = g.id AND pm.color_id IS NOT DISTINCT FROM base.color_id
                """ + goodsWhere;

        String orderBy = "qty DESC, name ASC";
        if (sort != null && INSTANT_ALLOWED_SORT.containsKey(sort)) {
            String dir = "asc".equalsIgnoreCase(order) ? "ASC" : "DESC";
            orderBy = INSTANT_ALLOWED_SORT.get(sort) + " " + dir + " NULLS LAST, name ASC";
        }

        var dataQ = em.createNativeQuery(
                core + " ORDER BY " + orderBy + " LIMIT :__limit OFFSET :__offset");
        var countQ = em.createNativeQuery("SELECT COUNT(*) FROM (" + core + ") t");
        for (var q : List.of(dataQ, countQ)) {
            if (warehouseScope != null && warehouseScope.size() == 1) {
                q.setParameter("warehouseId", warehouseId);
            }
            if (warehouseScope != null && warehouseScope.size() > 1) {
                q.setParameter("scopeIds", warehouseScope);
            }
            if (categoryId != null) q.setParameter("categoryId", categoryId);
            if (keyword != null && !keyword.isBlank()) q.setParameter("kw", "%" + keyword.trim() + "%");
        }
        dataQ.setParameter("__limit", safeSize);
        dataQ.setParameter("__offset", offset);

        @SuppressWarnings("unchecked")
        List<Object[]> rows = dataQ.getResultList();
        List<InstantInventoryRow> items = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            items.add(new InstantInventoryRow(
                    (UUID) r[0], (UUID) r[1],
                    (String) r[2], (String) r[3], (String) r[4], (String) r[5], (String) r[6],
                    (String) r[7], (String) r[8], (String) r[9],
                    (BigDecimal) r[10], (BigDecimal) r[11],
                    canViewCost ? (BigDecimal) r[12] : null, (BigDecimal) r[13],
                    (String) r[14], (String) r[15], (String) r[16],
                    (BigDecimal) r[17], (BigDecimal) r[18],
                    !canViewCost));
        }
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);

        // 表格下方合计：把 core（= 列表查询本体，已含分类子树/仓库范围/含不良品仓开关/关键字
        // 全部过滤条件）原样包成派生表再聚合——**和表格显示的是同一批行**，不带 LIMIT/OFFSET，
        // 所以是整个结果集的合计而不是当前这一页。绑定参数与 dataQ/countQ 逐个对齐，
        // 任何一个筛选变化都会同时改变列表和合计，不可能对不上。
        List<com.uten.imp.common.report.ReportTotal> totals =
                com.uten.imp.common.report.ReportTotalsCalculator.compute(
                        em, core, "", "",
                        q -> {
                            if (warehouseScope != null && warehouseScope.size() == 1) {
                                q.setParameter("warehouseId", warehouseId);
                            }
                            if (warehouseScope != null && warehouseScope.size() > 1) {
                                q.setParameter("scopeIds", warehouseScope);
                            }
                            if (categoryId != null) q.setParameter("categoryId", categoryId);
                            if (keyword != null && !keyword.isBlank()) {
                                q.setParameter("kw", "%" + keyword.trim() + "%");
                            }
                        },
                        INSTANT_TOTAL_SPECS);
        return new com.uten.imp.common.web.TotaledPageResponse<>(
                new PageResponse<>(items, safePage, safeSize, total, totalPages), totals);
    }

    /**
     * 即时库存合计声明（列名 = core 派生表里的投影别名）。
     *
     * <p><b>为什么只有这三个数量 + 重量</b>：
     * <ul>
     *   <li>库存数量 / 待检量 / 合格待入库 都是<b>基本单位</b>量（stock_balances.qty 由单据
     *       base_qty 累加，procurement_inspection_items 存的就是 *_base_qty），与行上的
     *       「单位」列（货品主档单位）同一口径，所以按 unit_name 分组相加成立；</li>
     *   <li>库存重量只有一个口径（kg），不分组；</li>
     *   <li><b>多排数量不声明</b>：它来自 production_plan_items 的 qty/oqty/iqty，是<b>计划行单位</b>
     *       的量，与本行「单位」列（货品主档单位）不是同一口径，按 unit_name 分组会贴错单位标签；</li>
     *   <li><b>库存金额不声明</b>：该列受 goods:cost:view 脱敏（无权限时投影为 NULL），
     *       合计一旦下发就绕过了列脱敏，等于把成本总额漏给没权限的人。</li>
     * </ul>
     */
    private static final List<com.uten.imp.common.report.ReportTotalsCalculator.Spec> INSTANT_TOTAL_SPECS =
            List.of(
                    new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                            "weight", "合计库存重量", "number", null),
                    new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                            "qty", "合计库存数量", "number", "unit_name"),
                    new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                            "pending_qty", "合计待检量", "number", "unit_name"),
                    new com.uten.imp.common.report.ReportTotalsCalculator.Spec(
                            "pending_stock_in_qty", "合计合格待入库", "number", "unit_name"));

    /**
     * 即时库存统一搜索的轻量分类定位。
     *
     * <p>关键词只匹配右侧列表支持的 name/code/model/c_number，删除口径同样仅排除
     * is_deleted；因此禁用或 autoCreated 货品不会出现“右侧能搜、左侧不能定位”的错位。
     * categoryRootIds 是当前树的显式范围，空/过多根 fail-closed。
     */
    @Transactional(readOnly = true)
    public List<UUID> instantInventoryMatchingCategoryIds(
            String keyword, Set<UUID> categoryRootIds) {
        if (keyword == null || keyword.isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "keyword 必填");
        }
        if (categoryRootIds == null || categoryRootIds.isEmpty() || categoryRootIds.size() > 32) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "categoryRootIds 必须包含 1-32 个分类");
        }
        @SuppressWarnings("unchecked")
        List<Object> rawIds = em.createNativeQuery("""
                WITH RECURSIVE cat AS (
                    SELECT id
                      FROM material_categories
                     WHERE id IN (:categoryRootIds) AND is_deleted = false
                    UNION
                    SELECT c.id
                      FROM material_categories c
                      JOIN cat p ON c.parent_id = p.id
                     WHERE c.is_deleted = false
                )
                SELECT DISTINCT g.category_id
                  FROM goods g
                 WHERE g.is_deleted = false
                   AND g.category_id IN (SELECT id FROM cat)
                   AND (g.name ILIKE :kw OR g.code ILIKE :kw
                     OR g.model ILIKE :kw OR g.c_number ILIKE :kw)
                 ORDER BY g.category_id
                """)
                .setParameter("categoryRootIds", categoryRootIds)
                .setParameter("kw", "%" + keyword.trim() + "%")
                .getResultList();
        return rawIds.stream()
                .filter(java.util.Objects::nonNull)
                .map(value -> value instanceof UUID id ? id : UUID.fromString(value.toString()))
                .toList();
    }

    // ======================== 货架目视化清单（货架图 + 统一表格 / 打印 / 导出） ========================

    /**
     * 货架清单行：已维护库位号的货品（未软删；默认排除禁用），库位号按「库行-层-位」三段解析
     * （{@link ShelfPlaceParser}，Java 侧为 DTO 真值，SQL 侧同口径只用于筛选/排序/布局），
     * 并 LEFT JOIN 余额汇总与单位。SQL 见 {@link ShelfLabelSql#rows}。
     *
     * @param rack            库行（如 A31）；null=全部。只对已分层行生效
     * @param keyword         名称/编号/系列/库位号模糊；null=不筛
     * @param warehouseId     仓库（含子仓）；非空时库位号取本仓树偏好优先、库存按该仓树汇总；
     *                        null=库位号只读主档、库存按全部核算仓汇总
     * @param includeDisabled 是否包含 status='禁用' 的货品（默认 false）
     */
    @Transactional(readOnly = true)
    public List<com.uten.imp.features.stock.dto.ShelfLabelRow> shelfLabelRows(
            String rack, String keyword, UUID warehouseId, boolean includeDisabled) {
        boolean hasRack = rack != null && !rack.isBlank();
        boolean hasKw = keyword != null && !keyword.isBlank();
        var q = em.createNativeQuery(
                ShelfLabelSql.rows(warehouseId != null, includeDisabled, hasRack, hasKw));
        if (warehouseId != null) q.setParameter("warehouseId", warehouseId);
        if (hasRack) q.setParameter("rack", rack.trim());
        if (hasKw) q.setParameter("kw", "%" + keyword.trim() + "%");
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        List<com.uten.imp.features.stock.dto.ShelfLabelRow> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            String place = (String) r[1];
            ShelfPlaceParser.ShelfPlace parsed = ShelfPlaceParser.parse(place);
            out.add(new com.uten.imp.features.stock.dto.ShelfLabelRow(
                    (UUID) r[0], parsed.rack(), place,
                    (String) r[2], (String) r[3], (String) r[4], (String) r[5], (String) r[6],
                    r[7] == null ? BigDecimal.ZERO : new BigDecimal(r[7].toString()),
                    Boolean.TRUE.equals(r[8]),
                    parsed.level(), parsed.slot(), parsed.parsed()));
        }
        return out;
    }

    /** 已分层库行（去重排序；残值不进下拉）：货架清单页库行下拉数据源。 */
    @Transactional(readOnly = true)
    public List<String> shelfLabelRacks(UUID warehouseId, boolean includeDisabled) {
        var q = em.createNativeQuery(ShelfLabelSql.racks(warehouseId != null, includeDisabled));
        if (warehouseId != null) q.setParameter("warehouseId", warehouseId);
        @SuppressWarnings("unchecked")
        List<Object> raw = q.getResultList();
        return raw.stream().filter(java.util.Objects::nonNull)
                .map(Object::toString).toList();
    }

    /**
     * 货架图布局：每个已分层库行的 maxLevel/maxSlot/count；残值数 > 0 时末尾追加
     * rack='' 的未分层桶（{@link com.uten.imp.features.stock.dto.ShelfLayoutRack#unparsedBucket()}）。
     */
    @Transactional(readOnly = true)
    public List<com.uten.imp.features.stock.dto.ShelfLayoutRack> shelfLabelLayout(
            UUID warehouseId, boolean includeDisabled) {
        var q = em.createNativeQuery(ShelfLabelSql.layout(warehouseId != null, includeDisabled));
        if (warehouseId != null) q.setParameter("warehouseId", warehouseId);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        List<com.uten.imp.features.stock.dto.ShelfLayoutRack> out = new ArrayList<>(rows.size());
        for (Object[] r : rows) {
            out.add(new com.uten.imp.features.stock.dto.ShelfLayoutRack(
                    r[0] == null ? "" : r[0].toString(),
                    r[1] == null ? null : ((Number) r[1]).intValue(),
                    r[2] == null ? null : ((Number) r[2]).intValue(),
                    r[3] == null ? 0L : ((Number) r[3]).longValue()));
        }
        return out;
    }

    private BalanceRow toBalanceRow(StockBalance b, boolean canViewCost) {
        return new BalanceRow(b.getId(), b.getWarehouseId(), b.getGoodsId(), b.getColorId(),
                b.getQty(), canViewCost ? b.getAmountLocal() : null,
                b.getWeight(), b.getLastMovementDate(), !canViewCost);
    }

    private MovementRow toMovementRow(StockMovement m, boolean canViewCost) {
        return new MovementRow(m.getId(), m.getTransactionDate(), m.getMovementType(),
                m.getSourceDocType(), m.getSourceDocId(), m.getGoodsId(), m.getColorId(),
                m.getWarehouseId(), m.getDirection(), m.getQty(),
                m.getUnitId(), m.getUnitRate(), m.getWeight(),
                canViewCost ? m.getAmountLocal() : null, m.getRemark(), !canViewCost);
    }
}
