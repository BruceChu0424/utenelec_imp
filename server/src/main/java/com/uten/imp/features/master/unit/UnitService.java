package com.uten.imp.features.master.unit;

import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.unit.dto.FacetBucket;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.unit.dto.UnitFacets;
import com.uten.imp.features.master.unit.dto.UnitListItem;
import com.uten.imp.features.master.unit.dto.UnitQueryFilter;
import com.uten.imp.features.master.unit.dto.UnitSaveRequest;
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
 * 基本单位主档：扁平列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（unit:edit）。
 *
 * <p>范式同 {@code GoodsService}，去掉 categoryId/子树（单位扁平无分类）。
 * 列表用 {@link Specification}：keyword 多字段 OR + 字段精确等值 + {@code nullFields} 空值白名单。
 * facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 */
@Service
@RequiredArgsConstructor
public class UnitService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.UNIT;

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

    private final UnitRepository repo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final MasterCodeService masterCodeService;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<UnitListItem> list(UnitQueryFilter f, int page, int size) {
        Specification<Unit> spec = (Root<Unit> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
        Page<Unit> p = repo.findAll(spec, pageable);
        return new PageResponse<>(
                p.map(this::toList).getContent(), page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Unit> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== facets（各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public UnitFacets facets() {
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from units "
                            + "where is_deleted = false and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT));
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from units where is_deleted = false and " + col + " is null")
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new UnitFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"), nullCounts);
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（货品编辑表单选单位用）：返回全部未软删单位，按名称排序。 */
    @Transactional(readOnly = true)
    public List<UnitListItem> dict() {
        Specification<Unit> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        return repo.findAll(spec, Sort.by(Sort.Direction.ASC, "name")).stream()
                .map(this::toList).toList();
    }

    @Transactional(readOnly = true)
    public UnitDetail detail(UUID id) {
        return toDetail(requireUnit(id));
    }

    @Transactional
    public UnitDetail create(UnitSaveRequest req) {
        tx.bind();
        Unit u = new Unit();
        apply(req, u);
        String name = u.getName();
        if (name == null || name.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单位名称不能为空");
        }
        if (repo.existsByNameIgnoreCaseAndDeletedFalse(name)) {
            throw new ApiException(ErrorCode.CONFLICT, "该单位已存在：" + name);
        }
        u.setCode(resolveCode(req, null));
        if (u.getStatus() == null) u.setStatus("使用");
        // legacy_id 只保存旧库 B_Unit.ID。在线新建保持 null，关系只使用 UUID。
        repo.save(u);
        return toDetail(u);
    }

    @Transactional
    public UnitDetail update(UUID id, UnitSaveRequest req) {
        tx.bind();
        Unit u = requireUnit(id);
        apply(req, u);
        u.setCode(resolveCode(req, u));
        repo.save(u);
        return toDetail(u);
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Unit u = requireUnit(id);
        u.setDeleted(true);
        u.setDeletedAt(OffsetDateTime.now());
        repo.save(u);
    }

    private void apply(UnitSaveRequest req, Unit u) {
        u.setName(req.getName() == null ? null : req.getName().trim());
        u.setStatus(req.getStatus());
    }

    /**
     * 编号解析：留空→新建自动生成兜底 / 编辑保留原值；非空→查重命中抛 409（前端编号字段描红）。
     * 服务层当前行查重用于友好文案；V279 全局预约触发器最终保证跨域、历史及软删后终身不复用。
     */
    private String resolveCode(UnitSaveRequest req, Unit existing) {
        String code = req.getCode() == null ? null : req.getCode().trim();
        if (code == null || code.isEmpty()) {
            return existing == null ? masterCodeService.nextCode(CODE_PREFIX) : existing.getCode();
        }
        boolean dup = existing == null
                ? repo.existsByCodeAndDeletedFalse(code)
                : repo.existsByCodeAndDeletedFalseAndIdNot(code, existing.getId());
        if (dup) {
            throw new ApiException(ErrorCode.CONFLICT, "编号已存在：" + code);
        }
        return code;
    }

    private UnitDetail toDetail(Unit u) {
        return new UnitDetail(u.getId(), u.getCode(), u.getName(), u.getStatus(), u.getLegacyId());
    }

    private UnitListItem toList(Unit u) {
        return new UnitListItem(u.getId(), u.getCode(), u.getName(), u.getStatus(), u.getLegacyId());
    }

    private Unit requireUnit(UUID id) {
        return repo.findById(id)
                .filter(u -> !u.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "单位不存在"));
    }
}
