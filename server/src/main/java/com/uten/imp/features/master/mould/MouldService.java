package com.uten.imp.features.master.mould;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
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

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.MOULD;

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。仅含有数据的 6 列。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "code", "name", "place", "mstatus", "remark", "status");

    /** facet 截断阈值（高基数列如 name/remark 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * 仅含 V34 表中"有数据"的 6 列；模数/套数/模具类型/制造商无对应列，不参与 facet。
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
    private final MasterCodeService masterCodeService;

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
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "id"));
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
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from moulds "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids)
                    .getResultList();
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

    @Transactional
    public MouldDetail create(MouldSaveRequest req) {
        tx.bind();
        Mould m = new Mould();
        apply(req, m);
        m.setCode(masterCodeService.nextCode(CODE_PREFIX));
        if (m.getStatus() == null) m.setStatus("使用");
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public MouldDetail update(UUID id, MouldSaveRequest req) {
        tx.bind();
        Mould m = requireMould(id);
        apply(req, m);
        repo.save(m);
        return toDetail(m);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Mould m = requireMould(id);
        m.setDeleted(true);
        m.setDeletedAt(OffsetDateTime.now());
        repo.save(m);
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
        m.setPlace(req.getPlace());
        m.setKeeper(req.getKeeper());
        m.setRemark(req.getRemark());
    }

    private MouldDetail toDetail(Mould m) {
        UUID categoryId = m.getCategory() == null ? null : m.getCategory().getId();
        String categoryName = m.getCategory() == null ? null : m.getCategory().getName();
        return new MouldDetail(
                m.getId(), m.getCode(), m.getName(), m.getStatus(), m.getPlace(),
                m.getKeeper(), m.getLegacyId(),
                categoryId, categoryName, m.getMnumber(), m.getQty(), m.getTqty(),
                m.getMstatus(), m.getRemark());
    }

    private MouldListItem toList(Mould m) {
        return new MouldListItem(
                m.getId(), m.getCode(), m.getName(), m.getPlace(), m.getMstatus(),
                m.getStatus(), m.getRemark(), m.getLegacyId());
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
