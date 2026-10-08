package com.uten.imp.features.master.unit;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.mastercode.MasterCodePrefix;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.report.ReportQueryKit;
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
 * 计量设置(计量维度 + 重量维度下「等于哪种重量单位」)落 unit_measurement_profiles(V743/ADR-135)。
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

    /** 计量维度合法值（unit_measurement_profiles 的 CHECK 约束同口径）。 */
    private static final Set<String> MEASUREMENT_DIMENSIONS =
            Set.of("COUNT", "MASS", "LENGTH", "AREA", "VOLUME", "OTHER");

    private static final String MASS = "MASS";

    /**
     * 重量单位代码 → 中文名(V743/ADR-135; 与 unit_measurement_profiles.mass_unit_code 的 CHECK、
     * common.measure.WeightUnit 同口径)。计量维度为「重量」的单位可以指明「等于哪种重量单位」:
     * 以它为基本单位的货品按数量精确折算重量(仓库称重不再另录)。
     */
    private static final Map<String, String> MASS_UNIT_LABELS = massUnitLabels();

    private static Map<String, String> massUnitLabels() {
        Map<String, String> labels = new LinkedHashMap<>();
        labels.put("G", "克");
        labels.put("KG", "千克");
        labels.put("T", "吨");
        labels.put("JIN", "斤");
        labels.put("LB", "磅");
        labels.put("OZ", "盎司");
        return java.util.Collections.unmodifiableMap(labels);
    }

    /** 409 文案: 已有库存或出入库记录的货品在用, 改维度/重量单位会让既有重量口径前后不一致。 */
    static final String IN_USE_MESSAGE = "该单位已被有库存或出入库记录的货品使用, 不能修改计量维度或重量单位";

    /** 单位的计量设置(计量维度 + 等于哪种重量单位); 未设置维度的单位没有这条记录。 */
    private record MeasurementSetting(String dimension, String massUnitCode) {

        boolean mass() {
            return MASS.equals(dimension);
        }
    }

    /** 批量读取单位计量设置(未设置维度的不出现在结果里)。 */
    private Map<UUID, MeasurementSetting> measurementByUnitId(List<UUID> unitIds) {
        if (unitIds.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        select unit_id, measurement_dimension, mass_unit_code
                        from unit_measurement_profiles
                        where unit_id in (:ids)
                        """)
                        .setParameter("ids", unitIds));
        Map<UUID, MeasurementSetting> result = new LinkedHashMap<>();
        for (Object[] row : rows) {
            result.put((UUID) row[0], setting(row[1], row[2]));
        }
        return result;
    }

    private static MeasurementSetting setting(Object dimension, Object massUnitCode) {
        return new MeasurementSetting(String.valueOf(dimension),
                massUnitCode == null ? null : String.valueOf(massUnitCode));
    }

    /** 大写去空白; 空串视为未填。 */
    private static String normalizedCode(String raw) {
        if (raw == null) return null;
        String value = raw.trim().toUpperCase(java.util.Locale.ROOT);
        return value.isEmpty() ? null : value;
    }

    /**
     * 保存计量设置：请求即完整目标状态——维度为空 = 未设置(删除记录)；合法维度 upsert
     * (provenance=MANUAL_GOVERNANCE，version+1)，同一条语句写 mass_unit_code，
     * 离开「重量」维度即清空。与现状相同则不写。
     *
     * <p>既有单位改动涉及「重量」(改成/改离重量维度或换重量单位)时，若它是有库存或出入库记录的
     * 货品的基本单位，则 409：这些货品已有的库存重量与流水重量按旧口径算出，改了会前后不一致。
     * 只在数量/长度等非重量维度之间调整不影响重量账，放行。
     *
     * @return 保存后的计量设置(未设置维度为 null)，直接回给详情，不再回读
     */
    private MeasurementSetting applyMeasurement(Unit u, UnitSaveRequest req, boolean existingUnit) {
        String dimension = normalizedCode(req.getMeasurementDimension());
        String massUnitCode = normalizedCode(req.getMassUnitCode());
        if (dimension != null && !MEASUREMENT_DIMENSIONS.contains(dimension)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "计量维度只能是数量、重量、长度、面积、体积或其他，请重新选择：" + req.getMeasurementDimension());
        }
        if (massUnitCode != null) {
            if (!MASS_UNIT_LABELS.containsKey(massUnitCode)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "重量单位必须是 克/千克/吨/斤/磅/盎司 之一：" + req.getMassUnitCode());
            }
            if (!MASS.equals(dimension)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "只有计量维度为「重量」的单位才能选择等于哪种重量单位");
            }
        }
        MeasurementSetting before = existingUnit ? lockedMeasurement(u.getId()) : null;
        MeasurementSetting after = dimension == null ? null : new MeasurementSetting(dimension, massUnitCode);
        if (java.util.Objects.equals(before, after)) return after;
        boolean touchesMass = (before != null && before.mass()) || (after != null && after.mass());
        if (existingUnit && touchesMass && usedByStockedGoods(u.getId())) {
            throw new ApiException(ErrorCode.CONFLICT, IN_USE_MESSAGE);
        }
        if (after == null) {
            em.createNativeQuery("""
                    delete from unit_measurement_profiles where unit_id = :id
                    """)
                    .setParameter("id", u.getId())
                    .executeUpdate();
            return null;
        }
        em.createNativeQuery("""
                insert into unit_measurement_profiles(
                    unit_id, measurement_dimension, mass_unit_code, provenance, version,
                    created_at, updated_at)
                values (:id, :dimension, cast(:massUnitCode as varchar), 'MANUAL_GOVERNANCE', 0, now(), now())
                on conflict (unit_id) do update
                    set measurement_dimension = excluded.measurement_dimension,
                        mass_unit_code = excluded.mass_unit_code,
                        provenance = 'MANUAL_GOVERNANCE',
                        version = unit_measurement_profiles.version + 1,
                        updated_at = now()
                """)
                .setParameter("id", u.getId())
                .setParameter("dimension", after.dimension())
                .setParameter("massUnitCode", after.massUnitCode())
                .executeUpdate();
        return after;
    }

    /** 锁住并读取单位现有计量设置(并发改同一单位时后到者读到先到者的结果)；没有记录返回 null。 */
    private MeasurementSetting lockedMeasurement(UUID unitId) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                        select measurement_dimension, mass_unit_code
                        from unit_measurement_profiles
                        where unit_id = :id
                        for update
                        """)
                        .setParameter("id", unitId));
        return rows.isEmpty() ? null : setting(rows.get(0)[0], rows.get(0)[1]);
    }

    /** 该单位是否是「有非零库存或任何出入库流水」的货品的基本单位(含已删货品：历史流水仍按它记重)。 */
    private boolean usedByStockedGoods(UUID unitId) {
        Object hit = em.createNativeQuery("""
                        select exists (
                            select 1 from goods g
                            where g.unit_id = :unitId
                              and (exists (select 1 from stock_balances b
                                           where b.goods_id = g.id and b.qty <> 0)
                                   or exists (select 1 from stock_movements m
                                              where m.goods_id = g.id)))
                        """)
                .setParameter("unitId", unitId)
                .getSingleResult();
        return hit instanceof Boolean flag ? flag : hit instanceof Number n && n.intValue() != 0;
    }

    // ===== 列表（Specification 动态筛选） =====

    @Transactional(readOnly = true)
    public PageResponse<UnitListItem> list(UnitQueryFilter f, int page, int size) {
        // 计量维度存于 unit_measurement_profiles（非实体列）：先取命中单位 id 集合再 IN。
        List<UUID> dimensionIds = dimensionUnitIds(f.dimension());
        List<UUID> allProfileIds = f.nullFields() != null && f.nullFields().contains("dimension")
                ? profileUnitIds()
                : List.of();
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
            if (f.dimension() != null && !f.dimension().isBlank()) {
                // 空集 = 该维度无任何单位，恒 false（而非不过滤）。
                ps.add(dimensionIds.isEmpty()
                        ? cb.disjunction()
                        : root.get("id").in(dimensionIds));
            }
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
                // "筛未设置维度"：不在 unit_measurement_profiles 的单位（非实体列，单独口径）。
                if (f.nullFields().contains("dimension")) {
                    ps.add(allProfileIds.isEmpty()
                            ? cb.conjunction()
                            : cb.not(root.get("id").in(allProfileIds)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.ASC, "code"));
        Page<Unit> p = repo.findAll(spec, pageable);
        List<Unit> content = p.getContent();
        Map<UUID, MeasurementSetting> settings = measurementByUnitId(
                content.stream().map(Unit::getId).toList());
        return new PageResponse<>(
                content.stream()
                        .map(u -> toList(u, settings.get(u.getId())))
                        .toList(),
                p);
    }

    /** 计量维度→单位 id 集合；dimension 空/非法返回 null（不筛）。 */
    private List<UUID> dimensionUnitIds(String dimension) {
        if (dimension == null || dimension.isBlank()) return List.of();
        String dim = dimension.trim().toUpperCase(java.util.Locale.ROOT);
        if (!MEASUREMENT_DIMENSIONS.contains(dim)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "计量维度只能是数量、重量、长度、面积、体积或其他，请重新选择：" + dimension);
        }
        List<?> rows = em.createNativeQuery("""
                        select unit_id from unit_measurement_profiles
                        where measurement_dimension = :dimension
                        """)
                .setParameter("dimension", dim)
                .getResultList();
        return rows.stream()
                .map(value -> (UUID) value)
                .toList();
    }

    /** 已设置计量维度的全部单位 id（"筛未设置维度"的反集）。 */
    private List<UUID> profileUnitIds() {
        List<?> rows = em.createNativeQuery(
                        "select unit_id from unit_measurement_profiles")
                .getResultList();
        return rows.stream()
                .map(value -> (UUID) value)
                .toList();
    }

    private static void addEq(List<Predicate> ps, CriteriaBuilder cb, Root<Unit> root,
                              String field, String value) {
        if (value != null && !value.isBlank()) ps.add(cb.equal(root.get(field), value));
    }

    // ===== 加密 Excel 导出（2026-09-25「表格显示啥导出啥」，V717） =====

    /** 计量维度代码 → 展示文字（与前端 unit_page 的 _dimensionOptions 同口径）。 */
    private static final Map<String, String> DIMENSION_LABELS = Map.of(
            "COUNT", "数量", "MASS", "重量", "LENGTH", "长度",
            "AREA", "面积", "VOLUME", "体积", "OTHER", "其他");

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限防 OOM。
     * 列集与前端单位表格一致：编号 / 单位名称 / 状态 / 计量维度 / 重量单位。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(UnitQueryFilter f, int maxRows) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "编号", ExportColumn.TEXT),
                new ExportColumn("name", "单位名称", ExportColumn.TEXT),
                new ExportColumn("status", "状态", ExportColumn.TEXT),
                new ExportColumn("dimension", "计量维度", ExportColumn.TEXT),
                new ExportColumn("massUnit", "重量单位", ExportColumn.TEXT));
        // 行数上限读系统设置「导出行数上限」(调用方传入), 与报表、审计导出同一口径。
        List<Map<String, Object>> rows = ReportQueryKit.collectPages(
                maxRows, (p, size) -> list(f, p, size), u -> {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("_platformRecordId", u.getId());
                    row.put("code", u.getCode());
                    row.put("name", u.getName());
                    row.put("status", u.getStatus());
                    row.put("dimension", u.getMeasurementDimension() == null
                            ? "未设置"
                            : DIMENSION_LABELS.getOrDefault(u.getMeasurementDimension(),
                                    u.getMeasurementDimension()));
                    row.put("massUnit", massUnitDisplay(u.getMeasurementDimension(), u.getMassUnitCode()));
                    return row;
                });
        return new ExportPayload(cols, rows, rows.size());
    }

    /** 「重量单位」列文字(与前端 unit_page 重量单位列同口径)：重量维度没选时写「未指定」，非重量维度留空。 */
    static String massUnitDisplay(String dimension, String massUnitCode) {
        if (!MASS.equals(dimension)) return "";
        return massUnitCode == null ? "未指定" : MASS_UNIT_LABELS.getOrDefault(massUnitCode, massUnitCode);
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
        // 计量维度（unit_measurement_profiles 关联表）：GROUP BY 维度值 + 未设置计数。
        buckets.put("dimension", dimensionFacet());
        nullCounts.put("dimension", ((Number) em.createNativeQuery(
                "select count(*) from units u "
                        + "where u.is_deleted = false and not exists "
                        + "(select 1 from unit_measurement_profiles p where p.unit_id = u.id)")
                .getSingleResult()).longValue());
        return new UnitFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"),
                buckets.get("dimension"), nullCounts);
    }

    /** 计量维度 facet 桶：按 unit_measurement_profiles.measurement_dimension 分组。 */
    private List<FacetBucket> dimensionFacet() {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "select p.measurement_dimension as v, count(*) as c "
                        + "from units u join unit_measurement_profiles p on p.unit_id = u.id "
                        + "where u.is_deleted = false "
                        + "group by p.measurement_dimension "
                        + "order by c desc, v asc limit " + FACET_LIMIT));
        List<FacetBucket> list = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            list.add(new FacetBucket(String.valueOf(row[0]), ((Number) row[1]).longValue()));
        }
        return list;
    }

    // ===== 详情 / CRUD =====

    /** 全量字典（货品编辑表单选单位用）：返回全部未软删单位，按名称排序。 */
    @Transactional(readOnly = true)
    public List<UnitListItem> dict() {
        Specification<Unit> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        List<Unit> units = repo.findAll(spec, Sort.by(Sort.Direction.ASC, "name"));
        Map<UUID, MeasurementSetting> settings = measurementByUnitId(
                units.stream().map(Unit::getId).toList());
        return units.stream()
                .map(u -> toList(u, settings.get(u.getId())))
                .toList();
    }

    @Transactional(readOnly = true)
    public UnitDetail detail(UUID id) {
        Unit u = requireUnit(id);
        return toDetail(u, measurementByUnitId(List.of(id)).get(id));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('unit:create', 'goods:import')")
    @Transactional
    public UnitDetail create(UnitSaveRequest req) {
        tx.bind();
        if (req.getStatus() != null && !"使用".equals(req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("unit:status");
        }
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
        return toDetail(u, applyMeasurement(u, req, false));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAnyAuthority('unit:edit', 'unit:status')")
    @Transactional
    public UnitDetail update(UUID id, UnitSaveRequest req) {
        tx.bind();
        com.uten.imp.security.CurrentAuthorityGuard.requireAll("unit:edit");
        Unit u = requireUnit(id);
        if (req.getStatus() != null && !java.util.Objects.equals(u.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("unit:status");
        }
        apply(req, u);
        u.setCode(resolveCode(req, u));
        repo.save(u);
        return toDetail(u, applyMeasurement(u, req, true));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('unit:status')")
    @Transactional
    public UnitDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Unit u = requireUnit(id);
        em.refresh(u, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        u.setStatus(req.status());
        repo.save(u);
        return toDetail(u, measurementByUnitId(List.of(id)).get(id));
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

    private UnitDetail toDetail(Unit u, MeasurementSetting setting) {
        return new UnitDetail(u.getId(), u.getCode(), u.getName(), u.getStatus(),
                u.getLegacyId(),
                setting == null ? null : setting.dimension(),
                setting == null ? null : setting.massUnitCode());
    }

    private UnitListItem toList(Unit u, MeasurementSetting setting) {
        return new UnitListItem(u.getId(), u.getCode(), u.getName(), u.getStatus(),
                u.getLegacyId(),
                setting == null ? null : setting.dimension(),
                setting == null ? null : setting.massUnitCode());
    }

    private Unit requireUnit(UUID id) {
        return repo.findById(id)
                .filter(u -> !u.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "单位不存在"));
    }
}
