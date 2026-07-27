package com.uten.imp.features.production.plancost;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.production.plancost.dto.PlanCostAggregation;
import com.uten.imp.features.production.plancost.dto.PlanCostQueryFilter;
import com.uten.imp.features.production.plancost.dto.PlanCostRow;
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
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 生产计划成本 / BOM 展开查询服务（<b>只读</b>）。
 *
 * <p>本期"保数据完整 + 只读查询"（design §3.5/§4.2）：
 * <ul>
 *   <li>不重算 BOM（TRI_F_PlanCostItem_Update 父×DQTY → 子，归未来成本/MRP 模块）</li>
 *   <li>不展开 BOM（TRI_F_PlanCostItem_Insert，归未来 BOM/MRP 模块）</li>
 *   <li>不计算 MRP 需购量（View_F_PlanCostItem 三分支 CASE，归未来 MRP 模块）</li>
 *   <li>不提供 save/update/delete（design §3.5 BOM 展开 1.36M 行本期不编辑）</li>
 * </ul>
 *
 * <p>聚合查询走 {@link EntityManager} 原生 SQL（按 master_goods_id 或 goods_id 上卷）。
 */
@Service
@RequiredArgsConstructor
public class ProductionPlanCostService {

    private final ProductionPlanCostRepository repo;
    private final EntityManager em;

    /** 列排序白名单：前端列 key → JPA 实体属性名（日期/金额/数量可排序；命中才排序，否则默认 level ASC, billNo ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of(
            "billDate", "billDate",
            "qty", "qty",
            "dqty", "dqty",
            "price", "price",
            "total", "total");

    /** 分页查询（design §6.2）：按计划明细/成品/货品/父节点/供应商/日期过滤。 */
    @Transactional(readOnly = true)
    public PageResponse<PlanCostRow> list(PlanCostQueryFilter f, int page, int size, String sort, String order) {
        Specification<ProductionPlanCost> spec = (Root<ProductionPlanCost> root,
                                                  jakarta.persistence.criteria.CriteriaQuery<?> q,
                                                  CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            // 软删过滤（is_deleted DEFAULT false，但分区表迁移可能保 NULL，COALESCE 兜底）
            ps.add(cb.or(cb.isFalse(root.get("isDeleted")), cb.isNull(root.get("isDeleted"))));
            if (f.planItemId() != null) ps.add(cb.equal(root.get("billItemId"), f.planItemId()));
            if (f.masterGoodsId() != null) ps.add(cb.equal(root.get("masterGoodsId"), f.masterGoodsId()));
            if (f.goodsId() != null) ps.add(cb.equal(root.get("goodsId"), f.goodsId()));
            if (f.parentId() != null) ps.add(cb.equal(root.get("parentId"), f.parentId()));
            if (f.supplierId() != null) ps.add(cb.equal(root.get("supplierId"), f.supplierId()));
            if (f.salesOrderCostItemId() != null)
                ps.add(cb.equal(root.get("salesOrderCostItemId"), f.salesOrderCostItemId()));
            if (f.dateFrom() != null) ps.add(cb.greaterThanOrEqualTo(root.get("billDate"), f.dateFrom()));
            if (f.dateTo() != null) ps.add(cb.lessThanOrEqualTo(root.get("billDate"), f.dateTo()));
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "level", "billNo"), ALLOWED_SORT));
        Page<ProductionPlanCost> p = repo.findAll(spec, pageable);
        return new PageResponse<>(p.map(this::toRow).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    /** 单行详情（只读）。 */
    @Transactional(readOnly = true)
    public PlanCostRow detail(UUID id) {
        return repo.findById(id).map(this::toRow)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "BOM 展开行不存在"));
    }

    /**
     * 按顶层成品（master_goods_id）汇总 BOM 物料需求与金额（design §6.2 聚合视图）。
     *
     * <p>本期不建 BOM 成本上卷物化视图（design §6.1 末，归未来成本模块），
     * 此处用 GROUP BY 现算，适用于小范围（单成品/单计划/单月）查询；大范围汇总建议未来建 MV。
     */
    @Transactional(readOnly = true)
    public List<PlanCostAggregation> aggregateByMaster(UUID masterGoodsId, UUID planItemId,
                                                       java.time.LocalDate dateFrom,
                                                       java.time.LocalDate dateTo, int limit) {
        var q = em.createNativeQuery("""
                SELECT COALESCE(master_goods_id, goods_id) AS master_goods_id,
                       goods_id,
                       COALESCE(SUM(qty), 0)   AS qty_sum,
                       COALESCE(SUM(pqty), 0)  AS pqty_sum,
                       COALESCE(SUM(total), 0) AS total_sum,
                       COUNT(*)                AS line_cnt
                FROM production_plan_costs
                WHERE COALESCE(is_deleted, false) = false
                  AND (CAST(:master AS uuid) IS NULL OR master_goods_id = :master)
                  AND (CAST(:planItem AS uuid) IS NULL OR bill_item_id = :planItem)
                  AND (CAST(:from AS date) IS NULL OR bill_date >= :from)
                  AND (CAST(:to AS date) IS NULL OR bill_date <= :to)
                GROUP BY 1, 2
                ORDER BY total_sum DESC NULLS LAST
                LIMIT :limit
                """);
        q.setParameter("master", masterGoodsId);
        q.setParameter("planItem", planItemId);
        q.setParameter("from", dateFrom);
        q.setParameter("to", dateTo);
        q.setParameter("limit", limit);
        @SuppressWarnings("unchecked")
        List<Object[]> rows = q.getResultList();
        return rows.stream().map(r -> new PlanCostAggregation(
                (java.util.UUID) r[0],
                (java.util.UUID) r[1],
                (BigDecimal) r[2],
                (BigDecimal) r[3],
                (BigDecimal) r[4],
                ((Number) r[5]).longValue()
        )).toList();
    }

    private PlanCostRow toRow(ProductionPlanCost c) {
        return new PlanCostRow(c.getId(), c.getLegacyId(), c.getBillItemId(), c.getBillNo(), c.getBillDate(),
                c.getParentId(), c.getParentLegacyId(), c.getLevel(), c.getNodeClass(),
                c.getGoodsId(), c.getColorId(), c.getMasterGoodsId(), c.getMasterColorId(),
                c.getSalesOrderCostItemId(),
                c.getQty(), c.getDqty(), c.getPqty(), c.getLqty(), c.getSlqty(), c.getRqty(),
                c.getOrderQty(), c.getInQty(), c.getPdrawQty(), c.getOwdrawQty(), c.getPwdrawQty(),
                c.getEoQty(), c.getEiQty(), c.getEwQty(), c.getMqty(), c.getPaQty(),
                c.getPrice(), c.getTotal(), c.getSupplierId(), c.getAssTeamLegacyId(),
                c.getSourceDocNo(), c.getLstatus(), c.getSummary());
    }
}
