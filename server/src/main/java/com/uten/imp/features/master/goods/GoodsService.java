package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.FacetBucket;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsFacets;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
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

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 货品主档：子树范围列表（动态筛选）+ facets + 详情 + 新建/编辑/删除（goods:edit）。
 *
 * <p>列表用 {@link Specification} 复刻 {@code EmployeeQueryService.list} 范式：子树 id 集合（复用
 * {@link MaterialCategoryRepository#findSubtree} 递归 CTE）+ keyword 多字段 OR + 字段精确等值 +
 * {@code nullFields} 空值白名单。
 *
 * <p>facets 用原生 SQL 聚合（字段→列名硬编码白名单，防注入；列名非用户输入）。
 *
 * <p>price 在 entity 是 Double（DOUBLE PRECISION 列），DTO 用 BigDecimal 便于前端精度展示，
 * apply/toDetail 做双向转换。
 *
 * <p>颜色/单位名称解析：goods 只存 color_legacy_id/unit_legacy_id（老库主键），列表与详情在
 * Service 层按 legacy_id 批量/单条查 colors/units 取 name（表小，内存关联，不动货品查询）。
 * 解析不到（软删或孤儿引用）返回 null，前端回落显 #legacyId。
 */
@Service
@RequiredArgsConstructor
public class GoodsService {

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "series", "model", "material", "code", "name", "spec",
            "cNumber", "requireRemark", "colorLegacyId", "unitLegacyId");

    /** facet 截断阈值（高基数列如 name 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("series", "series");
        FACET_COLUMNS.put("model", "model");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("spec", "spec");
        FACET_COLUMNS.put("material", "material");
        FACET_COLUMNS.put("requireRemark", "require_remark");
        FACET_COLUMNS.put("colorLegacyId", "color_legacy_id");
        FACET_COLUMNS.put("unitLegacyId", "unit_legacy_id");
    }

    private final GoodsRepository repo;
    private final MaterialCategoryRepository categoryRepo;
    private final ColorRepository colorRepo;
    private final UnitRepository unitRepo;
    private final TxSessionVars tx;
    private final EntityManager em;

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<GoodsListItem> list(GoodsQueryFilter f, int page, int size) {
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        Specification<Goods> spec = (Root<Goods> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
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
                        cb.like(cb.lower(root.get("model")), like),
                        cb.like(cb.lower(root.get("spec")), like),
                        cb.like(cb.lower(root.get("series")), like)));
            }
            addEq(ps, cb, root, "series", f.series());
            addEq(ps, cb, root, "model", f.model());
            addEq(ps, cb, root, "material", f.material());
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "spec", f.spec());
            addEq(ps, cb, root, "cNumber", f.cNumber());
            addEq(ps, cb, root, "requireRemark", f.requireRemark());
            if (f.colorLegacyId() != null) ps.add(cb.equal(root.get("colorLegacyId"), f.colorLegacyId()));
            if (f.unitLegacyId() != null) ps.add(cb.equal(root.get("unitLegacyId"), f.unitLegacyId()));
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "id"));
        Page<Goods> p = repo.findAll(spec, pageable);
        List<Goods> content = p.getContent();
        // 批量解析颜色/单位名（按本页出现的 legacy_id 一次性查 colors/units，避免 N+1）。
        Map<Integer, String> colorNames = colorNamesFor(
                content.stream().map(Goods::getColorLegacyId).toList());
        Map<Integer, String> unitNames = unitNamesFor(
                content.stream().map(Goods::getUnitLegacyId).toList());
        List<GoodsListItem> items = content.stream()
                .map(g -> toList(g, colorNames, unitNames))
                .toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Goods> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    private List<UUID> resolveSubtreeIds(UUID categoryId) {
        return categoryRepo.findSubtree(categoryId).stream().map(MaterialCategory::getId).toList();
    }

    /** 批量按 legacy_id 查 colors 取 name（仅未软删）。空集合返回空 map。 */
    private Map<Integer, String> colorNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream()
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return colorRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(c -> c.getLegacyId() != null)
                .collect(Collectors.toMap(Color::getLegacyId, Color::getName, (a, b) -> a));
    }

    /** 批量按 legacy_id 查 units 取 name（仅未软删）。空集合返回空 map。 */
    private Map<Integer, String> unitNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream()
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return unitRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(u -> u.getLegacyId() != null)
                .collect(Collectors.toMap(Unit::getLegacyId, Unit::getName, (a, b) -> a));
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public GoodsFacets facets(UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "categoryId 必填");
        }
        List<UUID> ids = resolveSubtreeIds(categoryId);
        // 颜色/单位 legacy_id → name（全量，表小）；颜色/单位桶 label 用名展示，筛选仍按 legacy id 回传。
        Map<Integer, String> colorNames = allColorNames();
        Map<Integer, String> unitNames = allUnitNames();
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            List<Object[]> rows = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from goods "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids)
                    .getResultList();
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                String v = String.valueOf(row[0]);
                long c = ((Number) row[1]).longValue();
                bucketList.add(new FacetBucket(v, c, labelFor(field, v, colorNames, unitNames)));
            }
            buckets.put(field, bucketList);
            Long nc = ((Number) em.createNativeQuery(
                    "select count(*) from goods "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is null")
                    .setParameter("ids", ids)
                    .getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new GoodsFacets(
                buckets.get("code"), buckets.get("series"), buckets.get("model"),
                buckets.get("name"), buckets.get("spec"), buckets.get("material"),
                buckets.get("requireRemark"), buckets.get("colorLegacyId"), buckets.get("unitLegacyId"),
                nullCounts);
    }

    /** facets 桶展示标签：颜色/单位字段用解析名（解析不到回落 #id），其余字段=label=value。 */
    private static String labelFor(String field, String value,
                                   Map<Integer, String> colorNames, Map<Integer, String> unitNames) {
        if (value == null || value.isEmpty()) return value;
        try {
            Integer id = Integer.valueOf(value);
            if ("colorLegacyId".equals(field)) {
                String n = colorNames.get(id);
                return (n != null && !n.isEmpty()) ? n : "#" + value;
            }
            if ("unitLegacyId".equals(field)) {
                String n = unitNames.get(id);
                return (n != null && !n.isEmpty()) ? n : "#" + value;
            }
        } catch (NumberFormatException ignored) {
            // 非数字值（不应出现在 legacy id 列），回落原值
        }
        return value;
    }

    /** 全量颜色 legacy_id → name（未软删）。 */
    private Map<Integer, String> allColorNames() {
        return colorRepo.findAll().stream()
                .filter(c -> !c.isDeleted() && c.getLegacyId() != null)
                .collect(Collectors.toMap(Color::getLegacyId,
                        c -> c.getName() == null ? "" : c.getName(), (a, b) -> a));
    }

    /** 全量单位 legacy_id → name（未软删）。 */
    private Map<Integer, String> allUnitNames() {
        return unitRepo.findAll().stream()
                .filter(u -> !u.isDeleted() && u.getLegacyId() != null)
                .collect(Collectors.toMap(Unit::getLegacyId,
                        u -> u.getName() == null ? "" : u.getName(), (a, b) -> a));
    }

    // ===== 详情 / CRUD（不变） =====

    @Transactional(readOnly = true)
    public GoodsDetail detail(UUID id) {
        Goods g = requireGoods(id);
        return toDetail(g, colorNameOf(g.getColorLegacyId()), unitNameOf(g.getUnitLegacyId()));
    }

    @Transactional
    public GoodsDetail create(GoodsSaveRequest req) {
        tx.bind();
        Goods g = new Goods();
        apply(req, g);
        repo.save(g);
        return toDetail(g, null, null);
    }

    @Transactional
    public GoodsDetail update(UUID id, GoodsSaveRequest req) {
        tx.bind();
        Goods g = requireGoods(id);
        apply(req, g);
        repo.save(g);
        return toDetail(g, colorNameOf(g.getColorLegacyId()), unitNameOf(g.getUnitLegacyId()));
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Goods g = requireGoods(id);
        g.setDeleted(true);
        g.setDeletedAt(OffsetDateTime.now());
        repo.save(g);
    }

    private String colorNameOf(Integer legacyId) {
        if (legacyId == null) return null;
        return colorRepo.findByLegacyId(legacyId)
                .filter(c -> !c.isDeleted())
                .map(Color::getName)
                .orElse(null);
    }

    private String unitNameOf(Integer legacyId) {
        if (legacyId == null) return null;
        return unitRepo.findByLegacyId(legacyId)
                .filter(u -> !u.isDeleted())
                .map(Unit::getName)
                .orElse(null);
    }

    private void apply(GoodsSaveRequest req, Goods g) {
        g.setCategory(requireCategory(req.getCategoryId()));
        g.setName(req.getName());
        g.setCode(req.getCode());
        g.setShortName(req.getShortName());
        g.setModel(req.getModel());
        g.setSpec(req.getSpec());
        g.setPrice(req.getPrice() == null ? null : req.getPrice().doubleValue());
        g.setMaterial(req.getMaterial());
        g.setThickness(req.getThickness());
        g.setMWeight(req.getMWeight());
        g.setPack(req.getPack());
        g.setPieces(req.getPieces());
        g.setStatus(req.getStatus());
        g.setColorLegacyId(req.getColorLegacyId());
        g.setUnitLegacyId(req.getUnitLegacyId());
    }

    private GoodsDetail toDetail(Goods g, String colorName, String unitName) {
        UUID categoryId = g.getCategory() == null ? null : g.getCategory().getId();
        String categoryName = g.getCategory() == null ? null : g.getCategory().getName();
        return new GoodsDetail(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                toPrice(g.getPrice()), g.getStatus(), g.getLegacyId(),
                g.getShortName(), categoryId, categoryName, g.getPack(),
                g.getMaterial(), g.getThickness(), g.getUnitLegacyId(),
                g.getMWeight(), g.getPieces(), colorName, unitName, g.getColorLegacyId());
    }

    private GoodsListItem toList(Goods g, Map<Integer, String> colorNames, Map<Integer, String> unitNames) {
        return new GoodsListItem(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                toPrice(g.getPrice()), g.getStatus(), g.getLegacyId(),
                g.getSeries(), g.getMaterial(), g.getCNumber(), g.getRequireRemark(),
                g.getColorLegacyId(), g.getUnitLegacyId(),
                g.getColorLegacyId() == null ? null : colorNames.get(g.getColorLegacyId()),
                g.getUnitLegacyId() == null ? null : unitNames.get(g.getUnitLegacyId()));
    }

    private static BigDecimal toPrice(Double p) {
        return p == null ? null : BigDecimal.valueOf(p);
    }

    private MaterialCategory requireCategory(UUID id) {
        return categoryRepo.findById(id)
                .filter(c -> !c.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品分类不存在"));
    }

    private Goods requireGoods(UUID id) {
        return repo.findById(id)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
    }
}
