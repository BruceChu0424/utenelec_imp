package com.uten.imp.features.master.color;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.color.dto.ColorFacets;
import com.uten.imp.features.master.color.dto.ColorListItem;
import com.uten.imp.features.master.color.dto.ColorQueryFilter;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.color.dto.FacetBucket;
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
 * 颜色主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（color:edit）。
 *
 * <p>范式同 {@code GoodsService}，去掉 categoryId/子树（颜色扁平无分类）。
 * 列表用 {@link Specification}：keyword 多字段 OR + 字段精确等值 + {@code nullFields} 空值白名单。
 * facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 */
@Service
@RequiredArgsConstructor
public class ColorService {

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of("code", "name", "status");

    /** facet 截断阈值。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("status", "status");
    }

    private final ColorRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<ColorListItem> list(ColorQueryFilter f, int page, int size) {
        Specification<Color> spec = (Root<Color> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            if (f.keyword() != null && !f.keyword().isBlank()) {
                String like = "%" + f.keyword().toLowerCase() + "%";
                ps.add(cb.or(
                        cb.like(cb.lower(root.get("name")), like),
                        cb.like(cb.lower(root.get("code")), like)));
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "status", f.status());
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
        Page<Color> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Color> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== facets（各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public ColorFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from colors "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .getResultList();
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from colors where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new ColorFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"), nullCounts);
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（货品编辑表单选颜色用）：返回全部未软删颜色，按名称排序。 */
    @Transactional(readOnly = true)
    public List<ColorListItem> dict() {
        Specification<Color> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "name")).stream()
                .map(this::toList).toList();
    }

    @Transactional(readOnly = true)
    public ColorDetail detail(UUID id) {
        return toDetail(requireColor(id));
    }

    @Transactional
    public ColorDetail create(ColorSaveRequest req) {
        tx.bind();
        Color c = new Color();
        apply(req, c);
        repo.save(c);
        return toDetail(c);
    }

    @Transactional
    public ColorDetail update(UUID id, ColorSaveRequest req) {
        tx.bind();
        Color c = requireColor(id);
        apply(req, c);
        repo.save(c);
        return toDetail(c);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Color c = requireColor(id);
        c.setDeleted(true);
        c.setDeletedAt(OffsetDateTime.now());
        repo.save(c);
    }

    private void apply(ColorSaveRequest req, Color c) {
        c.setName(req.getName());
        c.setCode(req.getCode());
        c.setStatus(req.getStatus());
    }

    private ColorDetail toDetail(Color c) {
        return new ColorDetail(c.getId(), c.getCode(), c.getName(), c.getStatus(), c.getLegacyId());
    }

    private ColorListItem toList(Color c) {
        return new ColorListItem(c.getId(), c.getCode(), c.getName(), c.getStatus(), c.getLegacyId());
    }

    private Color requireColor(UUID id) {
        return repo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "颜色不存在"));
    }
}
