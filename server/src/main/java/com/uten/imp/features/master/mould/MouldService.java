package com.uten.imp.features.master.mould;

import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.CategoryKeywordSearch;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.report.ReportQueryKit;
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

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。含有数据的字符串 8 列。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "code", "name", "qty", "place", "mstatus", "remark", "status", "manufacturer");

    /** facet 截断阈值（高基数列如 name/remark 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /**
     * facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     * 模数（qty，老库 QTY "1+1"）是低基数字符串进 facet；套数（tqty）为数值列
     * 不进（同货品库存量口径）；模具类型无数据源不参与。
     */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("code", "code");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("qty", "qty");
        FACET_COLUMNS.put("place", "place");
        FACET_COLUMNS.put("mstatus", "mstatus");
        FACET_COLUMNS.put("remark", "remark");
        FACET_COLUMNS.put("status", "status");
        FACET_COLUMNS.put("manufacturer", "manufacturer");
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
        var keyword = keywordPlan(f.keyword());
        Sort defaultSort = Sort.by(Sort.Direction.ASC, "code").and(Sort.by(Sort.Direction.ASC, "id"));
        Sort requestedSort = defaultSort;
        Specification<Mould> spec = (Root<Mould> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            // The new series/category label uses a to-one fetch only on data
            // queries, avoiding one lazy category request per displayed row.
            if (q != null && q.getResultType() != Long.class && q.getResultType() != long.class) {
                root.fetch("category", jakarta.persistence.criteria.JoinType.LEFT);
            }
            ps.add(cb.isFalse(root.get("deleted")));
            ps.add(com.uten.imp.features.master.search.MasterColumnSearch.predicate(cb, root.get("id"),
                    com.uten.imp.features.master.search.MasterColumnSearch.Domain.MOULD, f.columnSearch()));
            if (subtreeIds != null) {
                ps.add(root.get("category").get("id").in(subtreeIds));
            }
            if (!KeywordSearch.terms(f.keyword()).isEmpty()) {
                List<jakarta.persistence.criteria.Expression<String>> visible = List.of(root.get("name"), root.get("code"), root.get("manufacturer"), root.get("place"));
                ps.add(keyword.predicate(cb, root.get("category").get("id"), visible,
                        List.of(root.get("remark"))));
                if (q != null && q.getResultType() != Long.class) {
                    CategoryKeywordSearch.order(q, cb, root,
                            keyword.rank(cb, root.get("category").get("id"), root.get("code"), root.get("name"), visible), requestedSort);
                }
            }
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "qty", f.qty());
            addEq(ps, cb, root, "place", f.place());
            addEq(ps, cb, root, "mstatus", f.mstatus());
            addEq(ps, cb, root, "manufacturer", f.manufacturer());
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
        Pageable pageable = Pageables.of(page, size, keyword.active() ? Sort.unsorted() : requestedSort);
        Page<Mould> p = com.uten.imp.common.export.MasterExportSource.page(repo, em, Mould.class, spec, pageable, f);
        return new PageResponse<>(
                p.map(this::toList).getContent(), p);
    }

    private CategoryKeywordSearch.Plan keywordPlan(String query) {
        return CategoryKeywordSearch.plan(query, KeywordSearch.terms(query).isEmpty() ? List.of()
                : categoryRepo.findByDeletedFalseOrderBySortOrderAscNameAsc().stream()
                .map(node -> new CategoryKeywordSearch.Node(node.getId(), node.getParent() == null ? null : node.getParent().getId(),
                        node.getName(), node.getCode())).toList());
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Mould> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    private List<UUID> resolveSubtreeIds(UUID categoryId) {
        return categoryRepo.findSubtree(categoryId).stream().map(MouldCategory::getId).toList();
    }

    // ===== 加密 Excel 导出（2026-09-25「表格显示啥导出啥」） =====

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限防 OOM。
     * 列集与前端模具表格一致——模数/套数（老库 QTY/TQTY）随行导出；
     * 模具类型无数据源（表格恒"—"）不带；实际字段及真实系列分类名称同源导出。
     */
    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ExportPayload export(MouldQueryFilter f, int maxRows) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "模具编号", ExportColumn.TEXT),
                new ExportColumn("name", "模具名称", ExportColumn.TEXT),
                new ExportColumn("qty", "模数", ExportColumn.TEXT),
                new ExportColumn("tqty", "套数", ExportColumn.TEXT),
                new ExportColumn("categoryName", "系列 / 分类", ExportColumn.TEXT),
                new ExportColumn("place", "存放位置", ExportColumn.TEXT),
                new ExportColumn("mstatus", "制造年月", ExportColumn.TEXT),
                new ExportColumn("manufacturer", "制造商", ExportColumn.TEXT),
                new ExportColumn("remark", "备注", ExportColumn.TEXT),
                new ExportColumn("status", "状态", ExportColumn.TEXT));
        // 行数上限读系统设置「导出行数上限」(调用方传入), 与报表、审计导出同一口径。
        return com.uten.imp.common.export.MasterExportSource.exportEntities(em, cols,
                maxRows, (p, size) -> list(f, p, size), m -> {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("_platformRecordId", m.getId());
                    row.put("code", m.getCode());
                    row.put("name", m.getName());
                    row.put("qty", m.getQty());
                    row.put("tqty", m.getTqty() == null ? null : m.getTqty().stripTrailingZeros().toPlainString());
                    row.put("categoryName", m.getCategoryName());
                    row.put("place", m.getPlace());
                    row.put("mstatus", m.getMstatus());
                    row.put("manufacturer", m.getManufacturer());
                    row.put("remark", m.getRemark());
                    row.put("status", m.getStatus());
                    return row;
                });
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public MouldFacets facets(UUID categoryId) {
        List<UUID> ids = categoryId == null ? null : resolveSubtreeIds(categoryId);
        String categoryClause = ids == null ? "" : " and category_id in (:ids)";
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            var fq = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from moulds "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is not null "
                            + "group by " + col + " order by c desc, v asc limit " + FACET_LIMIT);
            if (ids != null) fq.setParameter("ids", ids);
            List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                bucketList.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
            }
            buckets.put(field, bucketList);
            var nq = em.createNativeQuery(
                    "select count(*) from moulds "
                            + "where is_deleted = false" + categoryClause + " and " + col + " is null");
            if (ids != null) nq.setParameter("ids", ids);
            Long nc = ((Number) nq.getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new MouldFacets(
                buckets.get("code"), buckets.get("name"), buckets.get("qty"), buckets.get("place"),
                buckets.get("mstatus"), buckets.get("remark"), buckets.get("status"),
                buckets.get("manufacturer"),
                nullCounts);
    }

    // ===== 详情 / CRUD（不变） =====

    @Transactional(readOnly = true)
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('mould:view')")
    public List<String> manufacturerSuggestions(String query) {
        String needle = query == null ? "" : query.strip().toLowerCase(java.util.Locale.ROOT);
        if (needle.length() > 200) throw new ApiException(ErrorCode.VALIDATION_FAILED, "制造商搜索不能超过200字符");
        var search = em.createNativeQuery("""
                SELECT btrim(manufacturer) AS value, count(*) AS uses FROM moulds
                WHERE is_deleted=false AND manufacturer IS NOT NULL AND btrim(manufacturer)<>''
                  AND (:q='' OR position(:q IN lower(manufacturer))>0 OR EXISTS(
                    SELECT 1 FROM generate_series(1,length(CAST(:q AS text))-1) n
                    WHERE position(substring(CAST(:q AS text) from n for 2) IN lower(manufacturer))>0))
                GROUP BY btrim(manufacturer)
                ORDER BY CASE WHEN lower(btrim(manufacturer))=:q THEN 0
                  WHEN position(:q IN lower(btrim(manufacturer)))>0 THEN 1 ELSE 2 END, uses DESC, value
                LIMIT 100
                """);
        search.setParameter("q", needle);
        List<Object[]> rows = NativeQueryResults.objectArrayRows(search);
        return rows.stream().sorted(java.util.Comparator
                .comparingInt((Object[] row) -> String.valueOf(row[0]).toLowerCase(java.util.Locale.ROOT).equals(needle) ? 0
                        : String.valueOf(row[0]).toLowerCase(java.util.Locale.ROOT).contains(needle) ? 1 : 2)
                .thenComparing(java.util.Comparator.comparingDouble((Object[] row) -> needle.isEmpty() ? 0
                        : com.uten.imp.common.text.IntakeTextNormalizer.bigramDice(
                                String.valueOf(row[0]).toLowerCase(java.util.Locale.ROOT), needle)).reversed())
                .thenComparing(java.util.Comparator.comparingLong((Object[] row) -> ((Number)row[1]).longValue()).reversed())
                .thenComparing(row -> String.valueOf(row[0])))
                .limit(20).map(row -> String.valueOf(row[0])).toList();
    }

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
        req.requireValidStatus();
        tx.bind();
        Mould m = requireMould(id);
        com.uten.imp.common.concurrency.MasterRowWriteLock.refreshActive(em, m, m::isDeleted, "模具不存在");
        m.setStatus(req.status());
        repo.save(m);
        return toDetail(m);
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
        // 缺省/旧控件空值保留历史年月；只有新键显式提供才能主动清空。
        if (req.isMstatusProvided()) {
            m.setMstatus(MouldManufacturingMonth.normalize(req.getMstatus(), m.getMstatus()));
        }
        // 旧版客户端没有此字段，整表保存也不能抹掉新版维护的制造商。
        if (req.isManufacturerProvided()) {
            m.setManufacturer(req.getManufacturer() == null || req.getManufacturer().isBlank()
                    ? null : req.getManufacturer().strip());
        }
        m.setStatus(req.getStatus());
        m.setRemark(req.getRemark());
        // 车间/保管人：id 优先；文本列由 id 解析补名（前端 picker 只传 id），保留文本作 fallback 显示。
        if (req.isDepartmentIdProvided() || req.isPlaceProvided()) {
            UUID departmentId = req.isDepartmentIdProvided() ? req.getDepartmentId() : m.getDepartmentId();
            m.setDepartmentId(departmentId);
            m.setPlace(resolvePlace(req.isPlaceProvided() ? req.getPlace() : m.getPlace(), departmentId));
        }
        if (req.isKeeperIdProvided() || req.isKeeperProvided()) {
            UUID keeperId = req.isKeeperIdProvided() ? req.getKeeperId() : m.getKeeperId();
            m.setKeeperId(keeperId);
            m.setKeeper(resolveKeeper(req.isKeeperProvided() ? req.getKeeper() : m.getKeeper(), keeperId));
        }
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
                m.getKeeperId(), resolveKeeper(null, m.getKeeperId()), m.getManufacturer());
    }

    private MouldListItem toList(Mould m) {
        return new MouldListItem(
                m.getId(), m.getCode(), m.getName(), m.getQty(), m.getTqty(), m.getPlace(), m.getMstatus(),
                m.getStatus(), m.getRemark(), m.getLegacyId(),
                m.getCategory() == null ? null : m.getCategory().getId(), m.getManufacturer(),
                m.getCategory() == null || m.getCategory().isDeleted() ? null : m.getCategory().getName());
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
