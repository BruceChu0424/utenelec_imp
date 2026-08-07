package com.uten.imp.features.master.goods;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.common.web.TableSort;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.FacetBucket;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsDictItem;
import com.uten.imp.features.master.goods.dto.GoodsFacets;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsQueryFilter;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.goods.dto.GoodsStockSummary;
import com.uten.imp.features.master.goods.dto.GoodsStockRow;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
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
 * <p>价格从 API、业务计算到 PostgreSQL 均使用 BigDecimal / NUMERIC(18,4)，
 * 不经过二进制浮点转换。
 *
 * <p>颜色/单位名称解析：goods 只存 color_legacy_id/unit_legacy_id（老库主键），列表与详情在
 * Service 层按 legacy_id 批量/单条查 colors/units 取 name（表小，内存关联，不动货品查询）。
 * 解析不到（软删或孤儿引用）返回 null，前端回落显 #legacyId。
 */
@Service
@RequiredArgsConstructor
public class GoodsService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.GOODS;

    /** nullFields 白名单（实体属性名），防 JPA 任意属性路径。 */
    private static final Set<String> ALLOWED_NULL_FIELDS = Set.of(
            "series", "model", "material", "code", "name", "spec",
            "cNumber", "requireRemark", "colorLegacyId", "unitLegacyId", "sourceType");

    /** 列排序白名单：前端列 key → JPA 实体属性名（金额/编号等可排序列；命中才排序，否则默认 id ASC）。 */
    private static final Map<String, String> ALLOWED_SORT = Map.of("price", "price", "code", "code");

    /** facet 截断阈值（高基数列如 name 取前 N）。 */
    private static final int FACET_LIMIT = 50;

    /** facet 字段→物理列名白名单（列名硬编码、非用户输入，可安全拼入 SQL）。
     *  注意：code（编号）不在此列——编号是唯一标识，值筛选无意义，改为表头排序（见 ALLOWED_SORT）。 */
    private static final LinkedHashMap<String, String> FACET_COLUMNS = new LinkedHashMap<>();
    static {
        FACET_COLUMNS.put("series", "series");
        FACET_COLUMNS.put("model", "model");
        FACET_COLUMNS.put("name", "name");
        FACET_COLUMNS.put("spec", "spec");
        FACET_COLUMNS.put("material", "material");
        FACET_COLUMNS.put("requireRemark", "require_remark");
        FACET_COLUMNS.put("colorLegacyId", "color_legacy_id");
        FACET_COLUMNS.put("unitLegacyId", "unit_legacy_id");
        FACET_COLUMNS.put("sourceType", "source_type");
    }

    private final GoodsRepository repo;
    private final MaterialCategoryRepository categoryRepo;
    private final ColorRepository colorRepo;
    private final UnitRepository unitRepo;
    private final TxSessionVars tx;
    private final EntityManager em;
    private final MasterCodeService masterCodeService;
    private final com.uten.imp.security.OwnerVisibility ownerVisibility;
    private final SecurityContextCurrentUser currentUser;
    private final GoodsCostMasker costMasker;            // goods:cost:view 成本可见性

    /**
     * 货品归属隔离总开关（uten.features.goods-owner-scope-enabled，默认 false）。
     * 2026-07-31 决策：货品暂不按外贸归属人隔离，全员可见全部货品；代码保留，置 true 即恢复。
     */
    @org.springframework.beans.factory.annotation.Value("${uten.features.goods-owner-scope-enabled:false}")
    private boolean goodsOwnerScopeEnabled;

    // ===== 归属可见性（外贸系列按员工授权，V85；判定逻辑统一在 OwnerVisibility） =====

    private final GoodsMasterRelationshipResolver relationships;
    /** 货品归属可见性判定唯一入口：开关关闭时直接放行（seeAll），开启时走 OwnerVisibility 三态。 */
    private com.uten.imp.security.OwnerVisibility.OwnerScope goodsScope() {
        if (!goodsOwnerScopeEnabled) {
            return new com.uten.imp.security.OwnerVisibility.OwnerScope(true, java.util.Set.of());
        }
        return ownerVisibility.evaluate("goods", "goods:view:all");
    }

    /** facets 原生 SQL 片段：归属过滤 AND 子句（参数名 :__ownerEmp；无需绑参时 bindEmp[0]=false）。 */
    private String ownerClause(boolean[] bindEmp) {
        var scope = goodsScope();
        if (scope.seeAll()) { bindEmp[0] = false; return ""; }
        if (scope.visibleOwners().isEmpty()) { bindEmp[0] = false; return " and owner_employee_id is null"; }
        bindEmp[0] = true;
        return " and (owner_employee_id is null or owner_employee_id in (:__ownerEmp))";
    }

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<GoodsListItem> list(GoodsQueryFilter f, int page, int size, String sort, String order) {
        List<UUID> subtreeIds = (f.categoryId() == null) ? null : resolveSubtreeIds(f.categoryId());
        Specification<Goods> spec = (Root<Goods> root, jakarta.persistence.criteria.CriteriaQuery<?> q,
                                     CriteriaBuilder cb) -> {
            List<Predicate> ps = new ArrayList<>();
            ps.add(cb.isFalse(root.get("deleted")));
            // 归属可见性（外贸按人授权）：公共货品或可见归属人；超管/goods:view:all 全见；
            // 2026-07-31 起经 goodsScope() 总开关默认放行（全员可见全部货品）
            var scope = goodsScope();
            if (!scope.seeAll()) {
                if (scope.visibleOwners().isEmpty()) {
                    ps.add(cb.isNull(root.get("ownerEmployeeId")));
                } else {
                    ps.add(cb.or(cb.isNull(root.get("ownerEmployeeId")),
                            root.get("ownerEmployeeId").in(scope.visibleOwners())));
                }
            }
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
                        cb.like(cb.lower(root.get("series")), like),
                        cb.like(cb.lower(root.get("cNumber")), like),
                        cb.like(cb.lower(root.get("material")), like),
                        cb.like(cb.lower(root.get("requireRemark")), like)));
            }
            addEq(ps, cb, root, "series", f.series());
            addEq(ps, cb, root, "model", f.model());
            addEq(ps, cb, root, "material", f.material());
            addEq(ps, cb, root, "code", f.code());
            addEq(ps, cb, root, "name", f.name());
            addEq(ps, cb, root, "spec", f.spec());
            addEq(ps, cb, root, "cNumber", f.cNumber());
            addEq(ps, cb, root, "requireRemark", f.requireRemark());
            addEq(ps, cb, root, "sourceType", f.sourceType());
            if (f.colorLegacyId() != null) ps.add(cb.equal(root.get("colorLegacyId"), f.colorLegacyId()));
            if (f.unitLegacyId() != null) ps.add(cb.equal(root.get("unitLegacyId"), f.unitLegacyId()));
            // 滑窗选货品默认隐藏已禁用（status='禁用'）；保留 null/其他状态避免误伤（货品资料管理页不传此参数，仍显示全部）。
            if (Boolean.TRUE.equals(f.excludeDisabled())) {
                ps.add(cb.or(cb.isNull(root.get("status")), cb.notEqual(root.get("status"), "禁用")));
            }
            // V177：stub（auto_created）隔离——滑窗默认隐藏兜底货品，集合行只看兜底货品。
            // auto_created 是 NOT NULL BOOLEAN，用 isFalse/isTrue 安全（无 null 三态）。
            if (Boolean.TRUE.equals(f.excludeStub())) {
                ps.add(cb.isFalse(root.get("autoCreated")));
            }
            if (Boolean.TRUE.equals(f.stubOnly())) {
                ps.add(cb.isTrue(root.get("autoCreated")));
            }
            // V177：只看禁用（货品页"禁用货品集合"用）；status 可空，equal 不命中 null（stub 不算禁用）。
            if (Boolean.TRUE.equals(f.disabledOnly())) {
                ps.add(cb.equal(root.get("status"), "禁用"));
            }
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size,
                TableSort.resolve(sort, order, Sort.by(Sort.Direction.ASC, "id"), ALLOWED_SORT));
        Page<Goods> p = repo.findAll(spec, pageable);
        List<Goods> content = p.getContent();
        // 批量解析颜色/单位名（按本页出现的 legacy_id 一次性查 colors/units，避免 N+1）。
        Map<Integer, String> colorNames = colorNamesFor(
                content.stream().map(Goods::getColorLegacyId).toList());
        Map<Integer, String> unitNames = unitNamesFor(
                content.stream().map(Goods::getUnitLegacyId).toList());
        Map<UUID, BigDecimal> stockByGoods = stockQuantitiesFor(
                content.stream().map(Goods::getId).toList());
        List<GoodsListItem> items = content.stream()
                .map(g -> toList(g, colorNames, unitNames, stockByGoods))
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

    /**
     * 批量按 legacy_id 查 colors 取 name（仅未软删）。空集合返回空 map。
     * 历史迁移允许颜色名称为 null；此类记录不放入名称 map，调用方保留 legacy id 并按未解析处理。
     */
    private Map<Integer, String> colorNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream()
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return colorRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(c -> c.getLegacyId() != null && c.getName() != null)
                .collect(Collectors.toMap(Color::getLegacyId, Color::getName, (a, b) -> a));
    }

    /**
     * 批量按 legacy_id 查 units 取 name（仅未软删）。空集合返回空 map。
     * 历史迁移允许单位名称为 null；此类记录不放入名称 map，调用方保留 legacy id 并按未解析处理。
     */
    private Map<Integer, String> unitNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream()
                .filter(Objects::nonNull)
                .collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return unitRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(u -> u.getLegacyId() != null && u.getName() != null)
                .collect(Collectors.toMap(Unit::getLegacyId, Unit::getName, (a, b) -> a));
    }

    /**
     * 批量按 goods_id 聚合即时库存（仅参与核算仓库 is_accountable），列表「库存量」列用。
     * 口径同即时库存/货品详情。空集合返回空 map（toList 对缺省键回落 BigDecimal.ZERO）。
     */
    private Map<UUID, BigDecimal> stockQuantitiesFor(Collection<UUID> goodsIds) {
        Set<UUID> distinct = goodsIds.stream().filter(Objects::nonNull).collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        String sql = """
                SELECT b.goods_id, SUM(b.qty) AS qty
                FROM stock_balances b
                JOIN warehouses w ON w.id = b.warehouse_id
                WHERE w.is_accountable AND b.goods_id IN (:ids)
                GROUP BY b.goods_id
                """;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("ids", distinct)
                .getResultList();
        Map<UUID, BigDecimal> out = new java.util.HashMap<>();
        for (Object[] r : rows) {
            Object gid = r[0];
            UUID id = gid instanceof UUID u ? u : UUID.fromString(gid.toString());
            Object q = r[1];
            BigDecimal qty = q == null ? BigDecimal.ZERO
                    : (q instanceof BigDecimal bd ? bd : new BigDecimal(q.toString()));
            out.put(id, qty);
        }
        return out;
    }

    /**
     * 单货品即时库存汇总（货品详情「库存量」用）：聚合 stock_balances（仅 warehouses.is_accountable
     * 参与核算仓库），返回合计数量/重量 + 按仓库（×颜色）明细。口径同即时库存。
     * 直接查 stock_balances 表（表访问非跨特性 Java 依赖，规避 master→stock 架构边界）。
     */
    private GoodsStockSummary stockSummaryForGoods(UUID goodsId) {
        String sql = """
                SELECT b.warehouse_id, w.code AS warehouse_code, w.name AS warehouse_name,
                       c.name AS color_name,
                       SUM(b.qty) AS qty, SUM(b.weight) AS weight
                FROM stock_balances b
                JOIN warehouses w ON w.id = b.warehouse_id
                LEFT JOIN colors c ON c.id = b.color_id
                WHERE b.goods_id = :goodsId AND w.is_accountable
                GROUP BY b.warehouse_id, w.code, w.name, c.name
                ORDER BY w.code
                """;
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("goodsId", goodsId)
                .getResultList();
        BigDecimal totalQty = BigDecimal.ZERO;
        BigDecimal totalWeight = BigDecimal.ZERO;
        List<GoodsStockRow> out = new ArrayList<>();
        for (Object[] r : rows) {
            BigDecimal qty = toBd(r[4]);
            BigDecimal weight = toBd(r[5]);
            totalQty = totalQty.add(qty);
            totalWeight = totalWeight.add(weight);
            out.add(new GoodsStockRow(toUuid(r[0]), (String) r[1], (String) r[2],
                    (String) r[3], qty, weight));
        }
        return new GoodsStockSummary(totalQty, totalWeight, out);
    }

    private static BigDecimal toBd(Object o) {
        if (o == null) return BigDecimal.ZERO;
        if (o instanceof BigDecimal bd) return bd;
        return new BigDecimal(o.toString());
    }

    private static UUID toUuid(Object o) {
        if (o == null) return null;
        if (o instanceof UUID u) return u;
        return UUID.fromString(o.toString());
    }

    // ===== 加密 Excel 导出（服务端权威列定义） =====

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限 1000 页=10万行防 OOM。
     * 列定义服务端权威（不信任前端传列）；过滤/排序走 TableSort 白名单（list 已接 sort/order）。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(GoodsQueryFilter f, String sort, String order) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "编号", ExportColumn.TEXT),
                new ExportColumn("series", "系列", ExportColumn.TEXT),
                new ExportColumn("model", "型号", ExportColumn.TEXT),
                new ExportColumn("name", "货品名称", ExportColumn.TEXT),
                new ExportColumn("spec", "规格", ExportColumn.TEXT),
                new ExportColumn("material", "材质", ExportColumn.TEXT),
                new ExportColumn("cNumber", "客户型号", ExportColumn.TEXT),
                new ExportColumn("requireRemark", "备注", ExportColumn.TEXT),
                new ExportColumn("colorName", "主颜色", ExportColumn.TEXT),
                new ExportColumn("unitName", "单位", ExportColumn.TEXT),
                new ExportColumn("sourceType", "来源", ExportColumn.TEXT),
                new ExportColumn("price", "价格", ExportColumn.MONEY),
                new ExportColumn("status", "状态", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        int pageSize = 100;
        int maxPages = 1000; // 10 万行硬上限，防 OOM
        long total = -1;
        for (int p = 1; p <= maxPages; p++) {
            PageResponse<GoodsListItem> page = list(f, p, pageSize, sort, order);
            if (total < 0) total = page.getTotal();
            for (GoodsListItem g : page.getItems()) {
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("code", g.getCode());
                row.put("series", g.getSeries());
                row.put("model", g.getModel());
                row.put("name", g.getName());
                row.put("spec", g.getSpec());
                row.put("material", g.getMaterial());
                row.put("cNumber", g.getCNumber());
                row.put("requireRemark", g.getRequireRemark());
                row.put("colorName", g.getColorName());
                row.put("unitName", g.getUnitName());
                row.put("sourceType", g.getSourceType());
                row.put("price", g.getPrice());
                row.put("status", g.getStatus());
                rows.add(row);
            }
            if (page.getItems().size() < pageSize) break;   // 末页
            if (rows.size() >= total) break;                // 已达 total
            if (p == maxPages && rows.size() < total) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "导出数据超过 10 万行上限，请收窄筛选条件后重试");
            }
        }
        return new ExportPayload(cols, rows, rows.size());
    }

    // ===== facets（子树范围内各字段 distinct + 空值计数） =====

    @Transactional(readOnly = true)
    public GoodsFacets facets(UUID categoryId) {
        if (categoryId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "categoryId 必填");
        }
        List<UUID> ids = resolveSubtreeIds(categoryId);
        // 归属可见性（外贸按人授权）：与 list() 同规则
        boolean[] bindEmp = new boolean[1];
        String ownerClause = ownerClause(bindEmp);
        java.util.Set<java.util.UUID> ownerEmps = goodsScope().visibleOwners();
        // 颜色/单位 legacy_id → name（全量，表小）；颜色/单位桶 label 用名展示，筛选仍按 legacy id 回传。
        Map<Integer, String> colorNames = allColorNames();
        Map<Integer, String> unitNames = allUnitNames();
        Map<String, List<FacetBucket>> buckets = new LinkedHashMap<>();
        Map<String, Long> nullCounts = new LinkedHashMap<>();
        for (Map.Entry<String, String> e : FACET_COLUMNS.entrySet()) {
            String field = e.getKey();
            // 列名来自硬编码白名单（非用户输入），可安全拼入 SQL。
            String col = e.getValue();
            var fq = em.createNativeQuery(
                    "select " + col + " as v, count(*) as c from goods "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is not null "
                            + ownerClause
                            + " group by " + col + " order by c desc, v asc limit " + FACET_LIMIT)
                    .setParameter("ids", ids);
            if (bindEmp[0]) fq.setParameter("__ownerEmp", ownerEmps);
            List<Object[]> rows = NativeQueryResults.objectArrayRows(fq);
            List<FacetBucket> bucketList = new ArrayList<>(rows.size());
            for (Object[] row : rows) {
                String v = String.valueOf(row[0]);
                long c = ((Number) row[1]).longValue();
                bucketList.add(new FacetBucket(v, c, labelFor(field, v, colorNames, unitNames)));
            }
            buckets.put(field, bucketList);
            var nq = em.createNativeQuery(
                    "select count(*) from goods "
                            + "where is_deleted = false and category_id in (:ids) and " + col + " is null"
                            + ownerClause)
                    .setParameter("ids", ids);
            if (bindEmp[0]) nq.setParameter("__ownerEmp", ownerEmps);
            Long nc = ((Number) nq.getSingleResult()).longValue();
            nullCounts.put(field, nc);
        }
        return new GoodsFacets(
                buckets.get("code"), buckets.get("series"), buckets.get("model"),
                buckets.get("name"), buckets.get("spec"), buckets.get("material"),
                buckets.get("requireRemark"), buckets.get("colorLegacyId"), buckets.get("unitLegacyId"),
                buckets.get("sourceType"),
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

    /**
     * 按 id 批量解析货品名（采购单据明细展示用）。货品约 3.5 万条不能全量拉，
     * 故仅按传入的 id 集合查 id/编号/名称；软删的过滤掉。
     */
    @Transactional(readOnly = true)
    public List<GoodsDictItem> lookup(Set<UUID> ids) {
        if (ids == null || ids.isEmpty()) return List.of();
        var scope = goodsScope();
        return repo.findAllById(ids).stream()
                .filter(g -> !g.isDeleted())
                .filter(g -> scope.seeAll() || g.getOwnerEmployeeId() == null
                        || scope.visibleOwners().contains(g.getOwnerEmployeeId()))
                .map(g -> new GoodsDictItem(g.getId(), g.getCode(), g.getName()))
                .toList();
    }

    /**
     * 归属可见性守卫（详情/编辑前调用）：归属货品非本人且未授权 → 404（不透出存在性）。
     */
    private void requireVisible(Goods g) {
        var scope = goodsScope();
        if (scope.seeAll() || g.getOwnerEmployeeId() == null) return;
        if (!scope.visibleOwners().contains(g.getOwnerEmployeeId())) {
            throw new ApiException(ErrorCode.NOT_FOUND, "货品不存在");
        }
    }

    @Transactional(readOnly = true)
    public GoodsDetail detail(UUID id) {
        Goods g = requireGoods(id);
        requireVisible(g);
        return toDetail(g, colorNameOf(g), unitNameOf(g));
    }

    @Transactional
    public GoodsDetail create(GoodsSaveRequest req) {
        tx.bind();
        ensurePriceEditIfTouched(null, req);   // 新建：oldGoods=null，提交了价/折扣即视为触碰
        Goods g = new Goods();
        apply(req, g);
        g.setCode(masterCodeService.nextCode(CODE_PREFIX));
        if (g.getStatus() == null) g.setStatus("使用");
        repo.save(g);
        return toDetail(g, colorNameOf(g), unitNameOf(g));
    }

    @Transactional
    public GoodsDetail update(UUID id, GoodsSaveRequest req) {
        tx.bind();
        Goods g = requireGoods(id);
        requireVisible(g);
        ensurePriceEditIfTouched(g, req);      // 编辑：与既有值比对，未改价/折扣则放行
        apply(req, g);
        repo.save(g);
        return toDetail(g, colorNameOf(g), unitNameOf(g));
    }

    /**
     * 售价/折扣仅在持有 {@code goods:price:edit} 时可改（写侧字段级权限，仿 V141 employee:pii:edit）。
     * 新建 oldGoods=null：提交了非空价/折扣即视为触碰；编辑则与既有值比对。未触碰（含原样回传）放行。
     */
    private void ensurePriceEditIfTouched(Goods oldGoods, GoodsSaveRequest req) {
        if (hasPriceEdit()) return;
        BigDecimal oldPrice = oldGoods == null ? null : oldGoods.getPrice();
        BigDecimal oldDiscount = oldGoods == null ? null : oldGoods.getDiscount();
        // 售价人人可见，触碰恒判。
        if (bigDecimalChanged(oldPrice, req.getPrice())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无编辑货品售价/折扣权限（goods:price:edit）");
        }
        // 折扣仅可查看者（goods:discount:view）才参与触碰判定——不可查看者前端隐藏折扣字段、
        // 不提交折扣（req.discount=null 是脱敏产物而非改价意图），若仍判触碰会把他们改名字等
        // 正常编辑一并 403。apply 同步对不可查看者保留原折扣（见 apply）。
        if (canViewDiscount() && bigDecimalChanged(oldDiscount, req.getDiscount())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "无编辑货品售价/折扣权限（goods:price:edit）");
        }
    }

    private boolean hasPriceEdit() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains("goods:price:edit"))
                .orElse(false);
    }

    /** 折扣可见性（goods:discount:view）：未授权者后端折扣置 null、前端隐藏字段/列。 */
    private boolean canViewDiscount() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains("goods:discount:view"))
                .orElse(false);
    }

    /** BigDecimal 变更判定用 compareTo，避免 1.0 vs 1.00 的 scale 差异误判触碰。 */
    private static boolean bigDecimalChanged(BigDecimal a, BigDecimal b) {
        if (a == null && b == null) return false;
        if (a == null || b == null) return true;
        return a.compareTo(b) != 0;
    }

    @Transactional
    public void delete(UUID id) {
        tx.bind();
        Goods g = requireGoods(id);
        requireVisible(g);
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

    private String colorNameOf(Goods goods) {
        if (goods.getColor() != null) {
            return goods.getColor().isDeleted() ? null : goods.getColor().getName();
        }
        return colorNameOf(goods.getColorLegacyId());
    }

    private String unitNameOf(Goods goods) {
        if (goods.getUnit() != null) {
            return goods.getUnit().isDeleted() ? null : goods.getUnit().getName();
        }
        return unitNameOf(goods.getUnitLegacyId());
    }

    private static boolean clearsReference(UUID id, Integer legacyId) {
        return id == null && (legacyId == null || legacyId == 0);
    }

    private void applyColorReference(GoodsSaveRequest req, Goods goods) {
        if (!req.hasColorReference()) return;
        if (clearsReference(req.getColorId(), req.getColorLegacyId())) {
            goods.setColor(null);
            goods.setColorLegacyId(null);
            return;
        }
        Color target = relationships.color(req.getColorId(), req.getColorLegacyId());
        goods.setColor(target);
        goods.setColorLegacyId(target.getLegacyId());
    }

    private void apply(GoodsSaveRequest req, Goods g) {
        g.setCategory(requireCategory(req.getCategoryId()));
        g.setName(req.getName());
        g.setShortName(req.getShortName());
        g.setModel(req.getModel());
        g.setSpec(req.getSpec());
        g.setPrice(req.getPrice());
        // 折扣（goods.zk）：仅可查看折扣者（goods:discount:view）提交的折扣才落库。
        // 不可查看者前端隐藏折扣字段不提交——保留原值，避免误清；亦防 V226 遗漏 setDiscount
        // 导致折扣任何人都存不进。
        if (canViewDiscount()) {
            g.setDiscount(req.getDiscount());
        }
        g.setMaterial(req.getMaterial());
        g.setThickness(req.getThickness());
        g.setThicknessUnitLegacyId(req.getThicknessUnitLegacyId());
        g.setMWeight(req.getMWeight());
        g.setMWeightUnitLegacyId(req.getMWeightUnitLegacyId());
        g.setPack(req.getPack());
        g.setPieces(req.getPieces());
        g.setStatus(req.getStatus());
        applyColorReference(req, g);
        if (req.hasUnitReference()) {
            if (clearsReference(req.getUnitId(), req.getUnitLegacyId())) {
                g.setUnit(null);
                g.setUnitLegacyId(null);
            } else {
                Unit target = relationships.unit(req.getUnitId(), req.getUnitLegacyId());
                g.setUnit(target);
                g.setUnitLegacyId(target.getLegacyId());
            }
        }
        if (req.hasMouldReference()) {
            if (clearsReference(req.getMouldId(), req.getMouldLegacyId())) {
                g.setMould(null);
                g.setMouldLegacyId(null);
            } else {
                var target = relationships.mould(req.getMouldId(), req.getMouldLegacyId());
                g.setMould(target);
                g.setMouldLegacyId(target.getLegacyId());
            }
        }
        if (req.hasClientReference()) {
            if (clearsReference(req.getClientId(), req.getClientLegacyId())) {
                g.setClient(null);
                g.setClientLegacyId(null);
            } else {
                var target = relationships.client(req.getClientId(), req.getClientLegacyId());
                g.setClient(target);
                g.setClientLegacyId(target.getLegacyId());
            }
        }
        if (req.hasDefaultSupplierReference()) {
            if (clearsReference(req.getDefaultSupplierId(), req.getVendLegacyId())) {
                g.setDefaultSupplier(null);
                g.setVendLegacyId(null);
            } else {
                var target = relationships.supplier(req.getDefaultSupplierId(), req.getVendLegacyId());
                g.setDefaultSupplier(target);
                g.setVendLegacyId(target.getLegacyId());
            }
        }
        if (req.hasSecondarySupplierReference()) {
            if (clearsReference(req.getSecondarySupplierId(), req.getVend2LegacyId())) {
                g.setSecondarySupplier(null);
                g.setVend2LegacyId(null);
            } else {
                var target = relationships.supplier(req.getSecondarySupplierId(), req.getVend2LegacyId());
                g.setSecondarySupplier(target);
                g.setVend2LegacyId(target.getLegacyId());
            }
        }
        g.setSourceType(req.getSourceType());
        // 成本预算（「成本预算」页签字段；前端表单全量回传，null 即清空）
        g.setSourceE(req.getSourceE());
        g.setMachiningE(req.getMachiningE());
        g.setIncidentalE(req.getIncidentalE());
        g.setLacquerE(req.getLacquerE());
        g.setPlatingE(req.getPlatingE());
        g.setCasingE(req.getCasingE());
        g.setPolishE(req.getPolishE());
        g.setTotal(req.getTotal());
        g.setWorkRate(req.getWorkRate());
        g.setWorkE(req.getWorkE());
        g.setLostRate(req.getLostRate());
        g.setLostE(req.getLostE());
        g.setRentRate(req.getRentRate());
        g.setRentE(req.getRentE());
        g.setMakeRate(req.getMakeRate());
        g.setMakeE(req.getMakeE());
        g.setCTotal(req.getCTotal());
        g.setGTotal(req.getGTotal());
    }

    private GoodsDetail toDetail(Goods g, String colorName, String unitName) {
        UUID categoryId = g.getCategory() == null ? null : g.getCategory().getId();
        String categoryName = g.getCategory() == null ? null : g.getCategory().getName();
        GoodsStockSummary stock = stockSummaryForGoods(g.getId());
        GoodsDetail d = new GoodsDetail(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                g.getPrice(), g.getDiscount(), g.getStatus(), g.getLegacyId(),
                g.getShortName(), categoryId, categoryName, g.getPack(),
                g.getMaterial(), g.getThickness(),
                g.getUnit() == null ? null : g.getUnit().getId(),
                g.getUnit() == null ? g.getUnitLegacyId() : g.getUnit().getLegacyId(),
                g.getMWeight(), g.getPieces(), colorName, unitName,
                g.getColor() == null ? null : g.getColor().getId(),
                g.getColor() == null ? g.getColorLegacyId() : g.getColor().getLegacyId(),
                g.getMould() == null ? null : g.getMould().getId(),
                g.getMould() == null ? g.getMouldLegacyId() : g.getMould().getLegacyId(),
                g.getClient() == null ? null : g.getClient().getId(),
                g.getClient() == null ? g.getClientLegacyId() : g.getClient().getLegacyId(),
                g.getDefaultSupplier() == null ? null : g.getDefaultSupplier().getId(),
                g.getDefaultSupplier() == null ? g.getVendLegacyId() : g.getDefaultSupplier().getLegacyId(),
                g.getSecondarySupplier() == null ? null : g.getSecondarySupplier().getId(),
                g.getSecondarySupplier() == null ? g.getVend2LegacyId() : g.getSecondarySupplier().getLegacyId(),
                g.getSourceE(), g.getMachiningE(), g.getIncidentalE(), g.getLacquerE(),
                g.getPlatingE(), g.getCasingE(), g.getPolishE(), g.getTotal(),
                g.getWorkRate(), g.getWorkE(), g.getLostRate(), g.getLostE(),
                g.getRentRate(), g.getRentE(), g.getMakeRate(), g.getMakeE(),
                g.getCTotal(), g.getGTotal(), g.getSourceType(),
                g.getThicknessUnitLegacyId(), g.getMWeightUnitLegacyId(),
                false, false, stock.getTotalQty(), stock.getRows());
        // 成本可见性（goods:cost:view）：未授权清空 18 个成本字段 + 置 costMasked（前端隐藏成本 Tab）
        if (!costMasker.canView()) {
            d.setSourceE(null); d.setMachiningE(null); d.setIncidentalE(null); d.setLacquerE(null);
            d.setPlatingE(null); d.setCasingE(null); d.setPolishE(null); d.setTotal(null);
            d.setWorkRate(null); d.setWorkE(null); d.setLostRate(null); d.setLostE(null);
            d.setRentRate(null); d.setRentE(null); d.setMakeRate(null); d.setMakeE(null);
            d.setCTotal(null); d.setGTotal(null);
            d.setCostMasked(true);
        }
        // 折扣可见性（goods:discount:view）：未授权 discount 置 null + 置 discountMasked（前端隐藏折扣字段/列）
        if (!canViewDiscount()) {
            d.setDiscount(null);
            d.setDiscountMasked(true);
        }
        return d;
    }

    private GoodsListItem toList(Goods g, Map<Integer, String> colorNames, Map<Integer, String> unitNames,
                                 Map<UUID, BigDecimal> stockByGoods) {
        return new GoodsListItem(
                g.getId(), g.getCode(), g.getName(), g.getSpec(), g.getModel(),
                g.getPrice(), canViewDiscount() ? g.getDiscount() : null, g.getStatus(), g.getLegacyId(),
                g.getSeries(), g.getMaterial(), g.getCNumber(), g.getRequireRemark(),
                g.getColor() == null ? g.getColorLegacyId() : g.getColor().getLegacyId(),
                g.getUnit() == null ? g.getUnitLegacyId() : g.getUnit().getLegacyId(),
                g.getColor() == null
                        ? (g.getColorLegacyId() == null ? null : colorNames.get(g.getColorLegacyId()))
                        : (g.getColor().isDeleted() ? null : g.getColor().getName()),
                g.getUnit() == null
                        ? (g.getUnitLegacyId() == null ? null : unitNames.get(g.getUnitLegacyId()))
                        : (g.getUnit().isDeleted() ? null : g.getUnit().getName()),
                g.getSourceType(),
                g.getCategory() == null ? null : g.getCategory().getId(),
                g.isAutoCreated(),
                stockByGoods.getOrDefault(g.getId(), BigDecimal.ZERO));
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
