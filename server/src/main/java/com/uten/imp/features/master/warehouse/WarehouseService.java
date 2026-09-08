package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.application.port.OrganizationReferencePort.DepartmentReference;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
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
import com.uten.imp.features.master.warehouse.dto.WarehouseWorkshopOption;
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
import java.util.stream.Collectors;

/**
 * 仓库主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（warehouse:edit）。
 *
 * <p>范式同 {@code CurrencyService}，加 location/remark/isAccountable/workshopDepartment 字段。
 * 仓库供采购收货/退货单据选择，并作为库存 stock_movements/balances 的记账维度。
 */
@Service
@RequiredArgsConstructor
public class WarehouseService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.WAREHOUSE;

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
    private final MasterCodeService masterCodeService;
    private final OrganizationReferencePort organizationReferences;

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
        Map<UUID, String> workshopNames = workshopNames(p.getContent());
        Map<UUID, String> parentNames = parentNames(p.getContent());
        return new PageResponse<>(
                p.getContent().stream().map(row -> toList(row, workshopNames, parentNames)).toList(),
                p);
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
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from warehouses "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT));
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
        List<Warehouse> rows = repo.findAll(spec, Sort.by(Sort.Direction.ASC, "code"));
        Map<UUID, String> workshopNames = workshopNames(rows);
        Map<UUID, String> parentNames = parentNames(rows);
        return rows.stream().map(row -> toList(row, workshopNames, parentNames)).toList();
    }

    /** Minimal workshop dictionary for warehouse create/edit. */
    @Transactional(readOnly = true)
    public List<WarehouseWorkshopOption> workshopOptions() {
        organizationReferences.findActiveDepartmentByCode("DEPT_PROD")
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "生产部组织节点不存在"));
        return organizationReferences.findActiveChildrenOfDepartmentCode("DEPT_PROD")
                .stream()
                .map(row -> new WarehouseWorkshopOption(
                        row.id(), row.code(), row.name()))
                .toList();
    }

    @Transactional(readOnly = true)
    public WarehouseDetail detail(UUID id) {
        return toDetail(requireWarehouse(id));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('warehouse:create')")
    @Transactional
    public WarehouseDetail create(WarehouseSaveRequest req) {
        tx.bind();
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("warehouse:status");
        }
        Warehouse w = new Warehouse();
        apply(req, w);
        w.setCode(masterCodeService.nextCode(CODE_PREFIX));
        if (w.getStatus() == null) w.setStatus("使用");
        repo.save(w);
        em.flush();
        syncLegacyWorkshopLink(w);
        return toDetail(w);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('warehouse:edit', 'warehouse:status')")
    @Transactional
    public WarehouseDetail update(UUID id, WarehouseSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("warehouse:edit");
        Warehouse w = requireWarehouse(id);
        if (req.getStatus() != null && !java.util.Objects.equals(w.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("warehouse:status");
        }
        apply(req, w);
        repo.save(w);
        em.flush();
        syncLegacyWorkshopLink(w);
        return toDetail(w);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('warehouse:status')")
    @Transactional
    public WarehouseDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Warehouse w = requireWarehouse(id);
        em.refresh(w, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        w.setStatus(req.status());
        repo.save(w);
        return toDetail(w);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('warehouse:delete')")
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
        w.setLocation(req.getLocation());
        w.setRemark(req.getRemark());
        if (req.getAccountable() != null) w.setAccountable(req.getAccountable());
        if (req.hasWorkshopDepartmentReference()) {
            DepartmentReference workshop = requireWorkshop(req.getWorkshopDepartmentId());
            w.setWorkshopDepartmentId(workshop == null ? null : workshop.id());
        }
        if (req.hasParentReference()) {
            w.setParentId(requireValidParent(w, req.getParentId()));
        }
        w.setStatus(req.getStatus());
    }

    /**
     * 上级仓库校验（V476）：存在且未软删、不能是自己、不能落在自己的后代链上（防环）。
     * 返回 null = 清空回独立顶层。
     */
    private UUID requireValidParent(Warehouse self, UUID parentId) {
        if (parentId == null) return null;
        if (self.getId() != null && self.getId().equals(parentId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "上级仓库不能是自己");
        }
        Warehouse parent = repo.findById(parentId)
                .filter(p -> !p.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "上级仓库不存在"));
        // 沿 parent 的上级链上溯：途中遇到自己 = 会成环，拒绝。
        UUID cursor = parent.getParentId();
        int depth = 0;
        while (cursor != null && depth++ < 64) {
            if (cursor.equals(self.getId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "上级仓库不能是自己的子仓库");
            }
            Warehouse up = repo.findById(cursor).orElse(null);
            cursor = up == null ? null : up.getParentId();
        }
        return parentId;
    }

    private WarehouseDetail toDetail(Warehouse w) {
        UUID workshopId = w.getWorkshopDepartmentId();
        String workshopName = organizationReferences.findActiveDepartment(workshopId)
                .map(DepartmentReference::name)
                .orElse(null);
        return new WarehouseDetail(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), workshopId, workshopName, w.getLegacyOperatorId(),
                w.getWorkshopLegacyId(),
                w.getStatus(), w.getLegacyId(), w.getParentId());
    }

    private WarehouseListItem toList(Warehouse w, Map<UUID, String> workshopNames,
                                     Map<UUID, String> parentNames) {
        UUID workshopId = w.getWorkshopDepartmentId();
        // Map.copyOf 返回的不可变 Map 对 null key 的 get 会抛 NPE，车间未设置时需先判空。
        String workshopName = workshopId == null ? null : workshopNames.get(workshopId);
        return new WarehouseListItem(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), workshopId, workshopName, w.getLegacyOperatorId(),
                w.getWorkshopLegacyId(),
                w.getStatus(), w.getLegacyId(), w.getParentId(), parentNames.get(w.getParentId()));
    }

    /** 上级仓库名称（V476 层级列表列）：仓库量级个位数，全量载入一次建 id→name。 */
    private Map<UUID, String> parentNames(List<Warehouse> rows) {
        Set<UUID> parentIds = rows.stream()
                .map(Warehouse::getParentId)
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toSet());
        if (parentIds.isEmpty()) return Map.of();
        Map<UUID, String> names = new java.util.HashMap<>();
        for (Warehouse w : repo.findAll()) {
            if (parentIds.contains(w.getId())) names.put(w.getId(), w.getName());
        }
        return names;
    }

    private DepartmentReference requireWorkshop(UUID id) {
        if (id == null) return null;
        DepartmentReference workshop = organizationReferences.findActiveDepartment(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "所属车间不存在"));
        if (!"DEPT_PROD".equals(workshop.parentCode())) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "所属车间必须是生产部直属且未删除的车间");
        }
        return workshop;
    }

    /**
     * Keep an explicit B_Storage.ID -> workshop UUID crosswalk for destructive
     * legacy reimports. The misnamed B_Storage.WorkID snapshot is never used.
     */
    private void syncLegacyWorkshopLink(Warehouse warehouse) {
        Integer legacyId = warehouse.getLegacyId();
        if (legacyId == null || legacyId == 0) return;
        UUID workshopId = warehouse.getWorkshopDepartmentId();
        if (workshopId == null) {
            em.createNativeQuery("""
                    DELETE FROM legacy_warehouse_workshop_links
                    WHERE warehouse_legacy_id = :legacyId
                    """)
                    .setParameter("legacyId", legacyId)
                    .executeUpdate();
            return;
        }
        em.createNativeQuery("""
                INSERT INTO legacy_warehouse_workshop_links (
                    warehouse_legacy_id, workshop_department_id)
                VALUES (:legacyId, :workshopId)
                ON CONFLICT (warehouse_legacy_id) DO UPDATE
                SET workshop_department_id = EXCLUDED.workshop_department_id,
                    updated_at = now()
                WHERE legacy_warehouse_workshop_links.workshop_department_id
                      IS DISTINCT FROM EXCLUDED.workshop_department_id
                """)
                .setParameter("legacyId", legacyId)
                .setParameter("workshopId", workshopId)
                .executeUpdate();
    }

    private Map<UUID, String> workshopNames(List<Warehouse> warehouses) {
        Set<UUID> ids = warehouses.stream()
                .map(Warehouse::getWorkshopDepartmentId)
                .filter(java.util.Objects::nonNull)
                .collect(Collectors.toSet());
        return organizationReferences.findActiveDepartmentNames(ids);
    }

    private Warehouse requireWarehouse(UUID id) {
        return repo.findById(id)
                .filter(w -> !w.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "仓库不存在"));
    }
}
