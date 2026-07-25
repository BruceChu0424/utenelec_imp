package com.uten.imp.features.master.warehouse;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.warehouse.dto.FacetBucket;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseFacets;
import com.uten.imp.features.master.warehouse.dto.WarehouseListItem;
import com.uten.imp.features.master.warehouse.dto.WarehouseQueryFilter;
import com.uten.imp.features.master.warehouse.dto.WarehouseSaveRequest;
import com.uten.imp.security.TxSessionVars;
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

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 仓库主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（warehouse:edit）。
 *
 * <p>范式同 {@code CurrencyService}，加 location/remark/isAccountable/workshopLegacyId 字段。
 * 仓库供采购收货/退货单据选择，并作为库存 stock_movements/balances 的记账维度。
 */
@Service
@RequiredArgsConstructor
public class WarehouseService {

    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of("code", "name", "status", "location");

    private static final int FACET_LIMIT = 50;

    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("status", "status");
    }

    private final WarehouseRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;

    @Transactional(readOnly = true)
    public PageResponse<WarehouseListItem> list(WarehouseQueryFilter f, int page, int size) {
        Specification<Warehouse> spec = (Root<Warehouse> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                         CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like),
                        cb.like(cb.lower(root.get("location")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "status", f.status());
            addEq(ps, cb, root, "location", f.location());
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
        Page<Warehouse> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Warehouse> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    @Transactional(readOnly = true)
    public WarehouseFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            String col = e.getValue();
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from warehouses "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .getResultList();
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from warehouses where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new WarehouseFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"), nullCounts);
    }

    /** 全量字典（采购单据/库存选仓库用）：返回全部未软删仓库，按编号排序。 */
    @Transactional(readOnly = true)
    public List<WarehouseListItem> dict() {
        Specification<Warehouse> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "code")).stream()
                .map(this::toList).toList();
    }

    @Transactional(readOnly = true)
    public WarehouseDetail detail(UUID id) {
        return toDetail(requireWarehouse(id));
    }

    @Transactional
    public WarehouseDetail create(WarehouseSaveRequest req) {
        tx.bind();
        Warehouse w = new Warehouse();
        apply(req, w);
        repo.save(w);
        return toDetail(w);
    }

    @Transactional
    public WarehouseDetail update(UUID id, WarehouseSaveRequest req) {
        tx.bind();
        Warehouse w = requireWarehouse(id);
        apply(req, w);
        repo.save(w);
        return toDetail(w);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Warehouse w = requireWarehouse(id);
        w.setDeleted(true);
        w.setDeletedAt(OffsetDateTime.now());
        repo.save(w);
    }

    private void apply(WarehouseSaveRequest req, Warehouse w) {
        w.setName(req.getName());
        w.setCode(req.getCode());
        w.setLocation(req.getLocation());
        w.setRemark(req.getRemark());
        if (req.getAccountable() != null) w.setAccountable(req.getAccountable());
        w.setWorkshopLegacyId(req.getWorkshopLegacyId());
        w.setStatus(req.getStatus());
    }

    private WarehouseDetail toDetail(Warehouse w) {
        return new WarehouseDetail(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), w.getWorkshopLegacyId(), w.getStatus(), w.getLegacyId());
    }

    private WarehouseListItem toList(Warehouse w) {
        return new WarehouseListItem(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), w.getWorkshopLegacyId(), w.getStatus(), w.getLegacyId());
    }

    private Warehouse requireWarehouse(UUID id) {
        return repo.findById(id)
                .filter(w -> !w.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "仓库不存在"));
    }
}
