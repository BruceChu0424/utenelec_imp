package com.uten.imp.features.master.mould;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.common.util.DepartmentNameResolver;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.mould.dto.FacetBucket;
import com.uten.imp.features.master.mould.dto.MouldDetail;
import com.uten.imp.features.master.mould.dto.MouldFacets;
import com.uten.imp.features.master.mould.dto.MouldListItem;
import com.uten.imp.features.master.mould.dto.MouldQueryFilter;
import com.uten.imp.features.master.mould.dto.MouldSaveRequest;
import com.uten.imp.features.master.mouldcategory.MouldCategory;
import com.uten.imp.features.master.mouldcategory.MouldCategoryRepository;
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
 * 模具主档：子树范围列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（mould:edit）。
 *
 * <p>读路径照抄 {@code GoodsService} 范式：列表用 {@link Specification}（子树 id 集合，复用
 * {@link MouldCategoryRepository#findSubtree} 递归 CTE + keyword 多字段 OR + 字段精确等值 +
 * {@code nullFields} 空值白名单）；facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入）。
 *
 * <p>写路径仿 {@code MouldCategoryService}：tx.bind 绑审计 actor → repo.save → 软删置 deleted/deletedAt。
 */
@Service
@RequiredArgsConstructor
public class MouldService {

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。仅含有数据的 6 列。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "code", "name", "place", "mstatus", "remark", "status");

    /** facet 截断阈值（高基数列如 name/remark 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * 仅含表中"有数据"的 6 列；模数/套数/模具类型/制造商无对应列，不参与 facet。
     */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("place", "place");
        FACET_COLUMNS.put("mstatus", "mstatus");
        FACET_COLUMNS.put("remark", "remark");
        FACET_COLUMNS.put("status", "status");
    }

    private final MouldRepository repo;
    private final MouldCategoryRepository categoryRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final CategoryDrivenCodeService categoryCodes;
    private final DepartmentNameResolver departmentNameResolver;
    private final EmployeeNameResolver employeeNameResolver;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<MouldListItem> list(MouldQueryFilter f, int page, int size) {
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        Specification<Mould> spec = (Root<Mould> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like),
                        cb.like(cb.lower(root.get("place")), like),
                        cb.like(cb.lower(root.get("remark")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "place", f.place());
            addEq(ps, cb, root, "mstatus", f.mstatus());
            addEq(ps, cb, root, "remark", f.remark());
            addEq(ps, cb, root, "status", f.status());
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        // 默认按编号升序（问题 #8：表头编号列默认应从小到大，不是内部 id 顺序）。
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
        Page<Mould> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Mould> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    private List<UUID> resolveSubtreeIds(UUID categoryId) {
        return categoryRepo.findSubtree(categoryId).stream().map(MouldCategory::getId).toList();
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public MouldFacets facets(UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "categoryId 必填");
        }
        List<UUID> ids = resolveSubtreeIds(categoryId);
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from moulds "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids));
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from moulds "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is null")
                    .setParameter("ids", ids)
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new MouldFacets(
                buckets.get("code"), buckets.get("name"), buckets.get("place"),
                buckets.get("mstatus"), buckets.get("remark"), buckets.get("status"),
                nullCounts);
    }

    // ===== 详情 / CRUD（不变） =====

    @Transactional(readOnly = true)
    public MouldDetail detail(UUID id) {
        return toDetail(requireMould(id));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('mould:create')")
    @Transactional
    public MouldDetail create(MouldSaveRequest req) {
        tx.bind();
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("mould:status");
        }
        Mould m = new Mould();
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocate(
                CategoryDrivenCodeService.MasterType.MOULD,
                m.getCategory().getId(), req.getCode()));
        if (m.getStatus() == null) m.setStatus("使用");
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('mould:edit', 'mould:status')")
    @Transactional
    public MouldDetail update(UUID id, MouldSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("mould:edit");
        Mould m = requireMould(id);
        if (req.getStatus() != null && !java.util.Objects.equals(m.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("mould:status");
        }
        CategoryCodeAllocation currentCode = currentCodeAllocation(m);
        apply(req, m);
        applyCodeAllocation(m, categoryCodes.allocateForUpdate(
                CategoryDrivenCodeService.MasterType.MOULD,
                m.getId(), m.getCategory().getId(), req.getCode(), currentCode));
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('mould:status')")
    @Transactional
    public MouldDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Mould m = requireMould(id);
        em.refresh(m, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        m.setStatus(req.status());
        repo.save(m);
        return toDetail(m);
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('mould:delete')")
    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Mould m = requireMould(id);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
    }

    private static CategoryCodeAllocation currentCodeAllocation(Mould mould) {
        return new CategoryCodeAllocation(
                mould.getCode(), mould.getCodeSequence(),
                mould.getCodePrefixCategoryId(), mould.isCodeManaged());
    }

    private static void applyCodeAllocation(Mould mould, CategoryCodeAllocation allocation) {
        mould.setCode(allocation.code());
        mould.setCodeSequence(allocation.sequence());
        mould.setCodePrefixCategoryId(allocation.prefixCategoryId());
        mould.setCodeManaged(allocation.managed());
    }

    /** 把请求字段覆写到实体（含 category 解析）。 */
    private void apply(MouldSaveRequest req, Mould m) {
        m.setCategory(requireCategory(req.getCategoryId()));
        m.setName(req.getName());
        m.setMnumber(req.getMnumber());
        m.setQty(req.getQty());
        m.setTqty(req.getTqty());
        m.setMstatus(req.getMstatus());
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
        // 车间/保管人：id 优先；文本列由 id 解析补名（前端 picker 只传 id），保留文本作 fallback 显示。
        m.setDepartmentId(req.getDepartmentId());
        m.setKeeperId(req.getKeeperId());
        m.setPlace(resolvePlace(req.getPlace(), req.getDepartmentId()));
        m.setKeeper(resolveKeeper(req.getKeeper(), req.getKeeperId()));
    }

    /** UUID 是关系真源；有 UUID 时名称只由服务端解析，避免 id/text 两套值互相矛盾。 */
    private String resolvePlace(String text, UUID departmentId) {
        if (departmentId != null) return departmentNameResolver.nameOf(departmentId);
        return text == null || text.isBlank() ? null : text.strip();
    }

    /** UUID 是关系真源；文本仅为尚未映射的历史兼容值。 */
    private String resolveKeeper(String text, UUID keeperId) {
        if (keeperId != null) return employeeNameResolver.nameOf(keeperId);
        return text == null || text.isBlank() ? null : text.strip();
    }

    private MouldDetail toDetail(Mould m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        return new MouldDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getKeeper(), m.getLegacyId(),
                categoryId, categoryName, m.getMnumber(), m.getQty(), m.getTqty(),
                m.getMstatus(), m.getRemark(),
                m.getDepartmentId(), resolvePlace(null, m.getDepartmentId()),
                m.getKeeperId(), resolveKeeper(null, m.getKeeperId()));
    }

    private MouldListItem toList(Mould m) {
        return new MouldListItem(
                m.getId(), m.getCode(), m.getName(), m.getPlace(), m.getMstatus(),
                m.getStatus(), m.getRemark(), m.getLegacyId(),
                m.getCategory() == null ? null : m.getCategory().getId());
    }

    private MouldCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "模具分类不存在"));
    }

    private Mould requireMould(UUID id) {
        return repo.findById(id)
                .filter(m -> !m.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "模具不存在"));
    }
}
