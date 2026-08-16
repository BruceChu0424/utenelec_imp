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

    /** 余额列排序白名单：前端列 key → JPA 实体属性名（数量可排序；命中才排序，否则默认 lastMovementDate DESC）。 */
    private static final Map<String, String> BALANCE_ALLOWED_SORT = Map.of("qty", "qty");

    /** 流水列排序白名单：前端列 key → JPA 实体属性名（日期/数量可排序；命中才排序，否则默认 transactionDate DESC）。 */
    private static final Map<String, String> MOVEMENT_ALLOWED_SORT = Map.of(
            "date", "transactionDate", "qty", "qty");

    private final StockBalanceRepository balanceRepo;
    private final StockMovementRepository movementRepo;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<BalanceRow> balances(UUID warehouseId, UUID goodsId, int page, int size,
                                             String sort, String order) {
        Specification<StockBalance> spec = (Root<StockBalance> root,
                                            jakarta.persistence.criteria.CriteriaQuery<?> q,
                                            CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseId != null) ps.add(cb.equal(root.get("warehouseId"), warehouseId));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "lastMovementDate"), BALANCE_ALLOWED_SORT));
        Page<StockBalance> p = balanceRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toBalanceRow).getContent(), page, size,
                p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    public PageResponse<MovementRow> movements(UUID warehouseId, UUID goodsId, Short movementType,
                                               OffsetDateTime dateFrom, OffsetDateTime dateTo,
                                               int page, int size, String sort, String order) {
        Specification<StockMovement> spec = (Root<StockMovement> root,
                                             jakarta.persistence.criteria.CriteriaQuery<?> q,
                                             CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (warehouseId != null) ps.add(cb.equal(root.get("warehouseId"), warehouseId));
            if (goodsId != null) ps.add(cb.equal(root.get("goodsId"), goodsId));
            if (movementType != null) ps.add(cb.equal(root.get("movementType"), movementType));
            if (dateFrom != null) ps.add(cb.greaterThanOrEqualTo(root.get("transactionDate"), dateFrom));
            if (dateTo != null) ps.add(cb.lessThanOrEqualTo(root.get("transactionDate"), dateTo));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.DESC, "transactionDate"), MOVEMENT_ALLOWED_SORT));
        Page<StockMovement> p = movementRepo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toMovementRow).getContent(), page, size,
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
     * @param warehouseId 仓库 id；null=全部（仅 is_accountable 参与核算仓库）
     * @param includeDefective 是否含不良品仓（仅仓库=全部时生效，默认 true=老系统口径）
     * @param keyword 名称/编号/型号/客户型号 模糊；null=不筛
     */
    @Transactional(readOnly = true)
    public PageResponse<InstantInventoryRow> instantInventory(UUID categoryId, UUID warehouseId,
                                                              boolean includeDefective,
                                                              String keyword, int page, int size,
                                                              String sort, String order) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 500);
        long offset = (long) (safePage - 1) * safeSize;

        // ---- 条件拼接（参数化，值永远走 setParameter） ----
        StringBuilder balWhere = new StringBuilder(" WHERE 1=1");
        StringBuilder iqcWhere = new StringBuilder();
        if (warehouseId != null) {
            balWhere.append(" AND b.warehouse_id = :warehouseId");
            iqcWhere.append(" AND i.warehouse_id = :warehouseId");
        } else {
            // 仓库=全部：只统计参与库存核算的仓库（老库 B_Storage.IsCal=0 口径）。
            balWhere.append(" AND w.is_accountable");
            iqcWhere.append(" AND w.is_accountable");
            // 「含不良品仓」开关：关掉则剔除不良品仓（默认开=老系统口径，不良仓计入全部）。
            if (!includeDefective) {
                balWhere.append(" AND NOT w.is_defective");
                iqcWhere.append(" AND NOT w.is_defective");
            }
        }
        iqcWhere.insert(0, " AND i.received_base_qty - i.passed_base_qty - i.failed_base_qty > 0");
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

        String core = cte + """
                SELECT g.id AS goods_id, base.color_id, mc.name AS category_name,
                       g.model, g.c_number, g.name, g.spec,
                       c.name AS color_name, u.name AS unit_name, g.paper AS remark,
                       COALESCE(base.weight, 0) AS weight,
                       COALESCE(base.qty, 0) AS qty,
                       COALESCE(g.c_total, 0) * COALESCE(base.qty, 0) AS cost_amount,
                       COALESCE(pm.more_qty, 0) AS more_qty,
                       g.code AS goods_code, g.series, g.stock_place,
                       COALESCE(iqc.pending_qty, 0) AS pending_qty
                FROM goods g
                LEFT JOIN (
                    SELECT u.goods_id, u.color_id, SUM(u.qty) AS qty, SUM(u.weight) AS weight
                    FROM (
                        (SELECT b.goods_id, b.color_id, b.qty, b.weight
                         FROM stock_balances b
                         JOIN warehouses w ON w.id = b.warehouse_id
                """ + balWhere + """
                        )
                        UNION ALL
                        -- 待检品尚无余额行：并入 0 量占位行，保证「货在待检」在即时库存可见（行粒度=货品×颜色）。
                        (SELECT i.goods_id, i.color_id, 0, 0
                         FROM procurement_inspection_items i
                         JOIN warehouses w ON w.id = i.warehouse_id
                """ + iqcWhere + """
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
            if (warehouseId != null) q.setParameter("warehouseId", warehouseId);
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
                    (BigDecimal) r[10], (BigDecimal) r[11], (BigDecimal) r[12], (BigDecimal) r[13],
                    (String) r[14], (String) r[15], (String) r[16], (BigDecimal) r[17]));
        }
        long total = ((Number) countQ.getSingleResult()).longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

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

    private BalanceRow toBalanceRow(StockBalance b) {
        return new BalanceRow(b.getId(), b.getWarehouseId(), b.getGoodsId(), b.getColorId(),
                b.getQty(), b.getAmountLocal(), b.getLastMovementDate());
    }

    private MovementRow toMovementRow(StockMovement m) {
        return new MovementRow(m.getId(), m.getTransactionDate(), m.getMovementType(),
                m.getSourceDocType(), m.getSourceDocId(), m.getGoodsId(), m.getColorId(),
                m.getWarehouseId(), m.getDirection(), m.getQty(), m.getAmountLocal(), m.getRemark());
    }
}
