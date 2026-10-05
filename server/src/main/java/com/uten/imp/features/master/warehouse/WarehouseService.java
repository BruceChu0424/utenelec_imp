package com.uten.imp.features.master.warehouse;

import com.uten.imp.application.port.OrganizationReferencePort;
import com.uten.imp.application.port.OrganizationReferencePort.DepartmentReference;

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
import com.uten.imp.features.master.warehouse.dto.FacetBucket;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.master.warehouse.dto.WarehouseFacets;
import com.uten.imp.features.master.warehouse.dto.WarehouseKeeperAssignment;
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

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 仓库主档：列表(动态筛选)+ facets + 详情 + 新建/编辑/启停(warehouse:edit / warehouse:status)。
 *
 * <p>主档形态(ADR-145): 全公司只有一个主仓(编号 001), 只作汇总、负责人范围和导航;
 * 其余仓都是它的直属子仓。新建/编辑时上级仓库由服务端补成主仓, 名称按比对键不许重名;
 * 停用前置条件、仓库用途(良品/不良品)变更条件由 {@link WarehouseMasterRules} 预检成中文原因,
 * 数据库守卫 fn_guard_warehouse_master_lifecycle 兜底。车间内料仓由车间内料仓页管理, 这里不能改。
 */
@Service
@RequiredArgsConstructor
public class WarehouseService {

    private static final MasterCodePrefix CODE_PREFIX = MasterCodePrefix.WAREHOUSE;

    private static final Set<String> ALLOWED_NULL_FIELDS =
            Set.of("code", "name", "status", "location", "parentId");

    private static final int FACET_LIMIT = 50;

    /**
     * 主仓(唯一没有上级的仓)在最前, 子仓按编号排。Hibernate 的 Criteria 不支持 NULLS FIRST,
     * 用 CASE 表达式排序; 计数查询(结果类型 Long)不加排序。
     */
    private static Specification<Warehouse> masterOrder(Specification<Warehouse> filter) {
        return (root, q, cb) -> {
            if (q != null && !Long.class.equals(q.getResultType())) {
                q.orderBy(
                        cb.asc(cb.selectCase().when(cb.isNull(root.get("parentId")), 0).otherwise(1)),
                        cb.asc(root.get("code")),
                        cb.asc(root.get("id")));
            }
            return filter.toPredicate(root, q, cb);
        };
    }

    private static final String LINE_SIDE_MANAGED_ELSEWHERE =
            "车间内料仓由「车间内料仓」页开通和撤销, 仓库资料里不能新建或改成内料仓";
    private static final String LINE_SIDE_READ_ONLY =
            "车间内料仓由「车间内料仓」页开通和管理, 仓库资料里只读; 要撤销请在「车间内料仓」里撤销开通";

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
    private final WarehouseKeeperService keeperService;
    private final WarehouseMasterRules rules;

    // ===== 加密 Excel 导出（2026-09-25「表格显示啥导出啥」，V717） =====

    /**
     * 加密 Excel 导出：循环 list 分页累积全部行（size=100），硬上限防 OOM。
     * 列集与前端仓库表格一致：编号 / 仓库名称 / 上级仓库 / 仓库用途 / 位置 / 核算 / 负责人 / 状态。
     * 负责人来自 warehouse_keepers（ADR-115，与列表「负责人」列同一 assignments 查询，
     * 仓库量级个位数，一次带回按仓库分组、「、」连接，无负责人显示「—」）。
     */
    @Transactional(readOnly = true)
    public ExportPayload export(WarehouseQueryFilter f, int maxRows) {
        Map<UUID, String> keepersByWarehouse = new LinkedHashMap<>();
        for (WarehouseKeeperAssignment a : keeperService.assignments()) {
            keepersByWarehouse.merge(a.warehouseId(), a.name(),
                    (left, right) -> left + "、" + right);
        }
        List<ExportColumn> cols = List.of(
                new ExportColumn("code", "编号", ExportColumn.TEXT),
                new ExportColumn("name", "仓库名称", ExportColumn.TEXT),
                new ExportColumn("parentName", "上级仓库", ExportColumn.TEXT),
                new ExportColumn("defective", "仓库用途", ExportColumn.TEXT),
                new ExportColumn("location", "位置", ExportColumn.TEXT),
                new ExportColumn("accountable", "核算", ExportColumn.TEXT),
                new ExportColumn("keepers", "负责人", ExportColumn.TEXT),
                new ExportColumn("status", "状态", ExportColumn.TEXT));
        // 行数上限读系统设置「导出行数上限」(调用方传入), 与报表、审计导出同一口径。
        List<Map<String, Object>> rows = ReportQueryKit.collectPages(
                maxRows, (p, size) -> list(f, p, size), w -> {
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("_platformRecordId", w.getId());
                    row.put("code", w.getCode());
                    row.put("name", w.getName());
                    row.put("parentName", w.getParentName() == null ? "—" : w.getParentName());
                    row.put("defective", useLabel(w.isDefective()));
                    row.put("location", w.getLocation());
                    row.put("accountable", w.isAccountable() ? "是" : "否");
                    row.put("keepers", keepersByWarehouse.getOrDefault(w.getId(), "—"));
                    row.put("status", w.getStatus());
                    return row;
                });
        return new ExportPayload(cols, rows, rows.size());
    }

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
            if (f.parentId() != null) {
                ps.add(cb.equal(root.get("parentId"), f.parentId()));
            }
            if (f.accountable() != null) {
                ps.add(cb.equal(root.get("accountable"), f.accountable()));
            }
            if (f.defective() != null) {
                ps.add(cb.equal(root.get("defective"), f.defective()));
            }
            if (f.nullFields() != null) {
                for (String fld : f.nullFields()) {
                    if (ALLOWED_NULL_FIELDS.contains(fld)) ps.add(cb.isNull(root.get(fld)));
                }
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        // 主仓置顶(唯一没有上级的仓), 子仓按编号紧随其后(排序在 masterOrder 里)。
        Pageable pageable = Pageables.of(page, size, Sort.unsorted());
        Page<Warehouse> p = repo.findAll(masterOrder(spec), pageable);
        Map<UUID, String> workshopNames = workshopNames(p.getContent());
        Map<UUID, String> parentNames = parentNames(p.getContent());
        Selectable selectable = selectable(p.getContent());
        return new PageResponse<>(
                p.getContent().stream()
                        .map(row -> toList(row, workshopNames, parentNames, selectable)).toList(),
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
        // 上级仓库（parent）桶：值=parent_id（UUID）、label=上级仓名；空值=顶层/独立仓。
        List<Object[]> parentRows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "select child.parent_id as v, parent.name as label, count(*) as c "
                        + "from warehouses child join warehouses parent on parent.id = child.parent_id "
                        + "where child.is_deleted = false "
                        + "group by child.parent_id, parent.name "
                        + "order by c desc, label asc limit " + FACET_LIMIT));
        List<FacetBucket> parentBuckets = new ArrayList<>(parentRows.size());
        for (Object[] row : parentRows) {
            parentBuckets.add(new FacetBucket(String.valueOf(row[0]),
                    ((Number) row[2]).longValue(), String.valueOf(row[1])));
        }
        buckets.put("parent", parentBuckets);
        nullCounts.put("parent", ((Number) em.createNativeQuery(
                "select count(*) from warehouses where is_deleted = false and parent_id is null")
                .getSingleResult()).longValue());
        // 核算（accountable）桶：布尔 → true/false，label 出 是/否（列 NOT NULL，无空值桶）。
        List<Object[]> accountableRows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "select is_accountable as v, count(*) as c from warehouses "
                        + "where is_deleted = false "
                        + "group by is_accountable order by c desc limit " + FACET_LIMIT));
        List<FacetBucket> accountableBuckets = new ArrayList<>(accountableRows.size());
        for (Object[] row : accountableRows) {
            String value = String.valueOf(row[0]);
            accountableBuckets.add(new FacetBucket(value, ((Number) row[1]).longValue(),
                    "true".equals(value) ? "是" : "否"));
        }
        buckets.put("accountable", accountableBuckets);
        // 仓库用途(defective, ADR-145)桶：true=不良品仓 / false=良品仓(列 NOT NULL)。
        List<Object[]> defectiveRows = NativeQueryResults.objectArrayRows(em.createNativeQuery(
                "select is_defective as v, count(*) as c from warehouses "
                        + "where is_deleted = false "
                        + "group by is_defective order by c desc limit " + FACET_LIMIT));
        List<FacetBucket> defectiveBuckets = new ArrayList<>(defectiveRows.size());
        for (Object[] row : defectiveRows) {
            String value = String.valueOf(row[0]);
            defectiveBuckets.add(new FacetBucket(value, ((Number) row[1]).longValue(),
                    useLabel("true".equals(value))));
        }
        return new WarehouseFacets(buckets.get("code"), buckets.get("name"), buckets.get("status"),
                buckets.get("parent"), buckets.get("accountable"), defectiveBuckets, nullCounts);
    }

    /**
     * 全量字典(单据选仓/历史单据显示名用)：返回全部未软删仓库(含禁用仓, 历史单据要显示名字)，
     * 主仓在前。每行带服务端算好的 defective 与 selectableForNew, 前端新选入口只认 selectableForNew。
     */
    @Transactional(readOnly = true)
    public List<WarehouseListItem> dict() {
        Specification<Warehouse> spec = (root, q, cb) -> cb.isFalse(root.get("deleted"));
        List<Warehouse> rows = repo.findAll(masterOrder(spec));
        Map<UUID, String> workshopNames = workshopNames(rows);
        Map<UUID, String> parentNames = parentNames(rows);
        Selectable selectable = selectable(rows);
        return rows.stream().map(row -> toList(row, workshopNames, parentNames, selectable)).toList();
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
        if (Boolean.TRUE.equals(req.getIsLineSide())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, LINE_SIDE_MANAGED_ELSEWHERE);
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
        em.refresh(w, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (req.getStatus() != null && !java.util.Objects.equals(w.getStatus(), req.getStatus())) {
            com.uten.imp.security.CurrentAuthorityGuard.requireAll("warehouse:status");
        }
        if (req.getIsLineSide() != null && req.getIsLineSide() != w.isLineSide()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, LINE_SIDE_MANAGED_ELSEWHERE);
        }
        // ADR-147: 内料仓只由「车间内料仓」开通命令建出和撤销, 仓库资料里只读(名称随车间, 状态随开通)。
        if (w.isLineSide()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, LINE_SIDE_READ_ONLY);
        }
        requireCanRetire(w, req.getStatus());
        requireCanLeaveSelection(w, req);
        apply(req, w);
        repo.save(w);
        em.flush();
        syncLegacyWorkshopLink(w);
        return toDetail(w);
    }

    /**
     * 改成「不核算」或改成不良品仓也让这个仓退出新单可选(ADR-145): 与停用同一组前置条件, 逐条列出原因;
     * 数据库守卫 fn_guard_warehouse_master_lifecycle 同一定义兜底。
     */
    private void requireCanLeaveSelection(Warehouse w, WarehouseSaveRequest req) {
        boolean toUnaccountable = w.isAccountable() && Boolean.FALSE.equals(req.getAccountable());
        boolean toDefective = !w.isDefective() && Boolean.TRUE.equals(req.getDefective());
        if (!toUnaccountable && !toDefective) return;
        List<String> reasons = rules.selectionExitBlockers(List.of(w.getId())).get(w.getId());
        if (reasons != null && !reasons.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    WarehouseMasterRules.selectionExitMessage(w.getName(), toDefective, reasons));
        }
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('warehouse:status')")
    @Transactional
    public WarehouseDetail changeStatus(
            UUID id, com.uten.imp.features.master.dto.MasterStatusChangeRequest req) {
        tx.bind();
        Warehouse w = requireWarehouse(id);
        em.refresh(w, jakarta.persistence.LockModeType.PESSIMISTIC_WRITE);
        if (w.isLineSide()) throw new ApiException(ErrorCode.VALIDATION_FAILED, LINE_SIDE_READ_ONLY);
        requireCanRetire(w, req.status());
        w.setStatus(req.status());
        repo.save(w);
        em.flush();
        return toDetail(w);
    }

    /** 停用预检(ADR-145/147): 主仓、还有库存/货品归属/未结预留、已开通的内料仓、内料仓发料来源仓不能停用, 逐条列出原因。 */
    private void requireCanRetire(Warehouse w, String nextStatus) {
        if (!"禁用".equals(nextStatus) || "禁用".equals(w.getStatus())) return;
        List<String> reasons = rules.retirementBlockers(List.of(w.getId())).get(w.getId());
        if (reasons != null && !reasons.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    WarehouseMasterRules.retirementMessage(w.getName(), false, reasons));
        }
    }


    private void apply(WarehouseSaveRequest req, Warehouse w) {
        String duplicate = rules.duplicateName(req.getName(), w.getId());
        if (duplicate != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "已有同名仓库「" + duplicate + "」(名称去掉空格、括号不分全角半角后相同), 请换一个名称");
        }
        w.setName(req.getName());
        w.setLocation(req.getLocation());
        w.setRemark(req.getRemark());
        if (req.getAccountable() != null) w.setAccountable(req.getAccountable());
        if (req.hasWorkshopDepartmentReference()) {
            DepartmentReference workshop = requireWorkshop(req.getWorkshopDepartmentId());
            w.setWorkshopDepartmentId(workshop == null ? null : workshop.id());
        }
        w.setParentId(resolveParent(w, req));
        if (req.getDefective() != null && req.getDefective() != w.isDefective()) {
            requireDefectiveShape(w, req.getDefective());
            w.setDefective(req.getDefective());
        }
        w.setStatus(req.getStatus());
        requireLineSideShape(w);
    }

    /**
     * 上级仓库(ADR-145 单主仓): 主仓自己没有上级; 其余仓一律挂在主仓下, 请求里写别的仓直接拒绝。
     * 还没有任何仓时第一个新建的仓就是主仓; 主档没收敛(多个顶层仓、没有 001)时只允许编辑, 不许新建。
     */
    private UUID resolveParent(Warehouse w, WarehouseSaveRequest req) {
        UUID requested = req.hasParentReference() ? req.getParentId() : null;
        UUID root = rules.rootId();
        if (root == null) {
            if (w.getId() == null && rules.anyOtherWarehouse(null)) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "仓库资料还没有唯一的主仓, 暂时不能新建仓库, 请联系管理员先整理仓库层级");
            }
            if (requested != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "上级仓库只能是主仓");
            }
            return w.getId() == null ? null : w.getParentId();
        }
        if (root.equals(w.getId())) {
            if (requested != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "主仓不能挂到别的仓库下面");
            }
            return null;
        }
        if (requested != null && !requested.equals(root)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "上级仓库只能是主仓「" + rootName(root) + "」, 仓库只有主仓和子仓两层");
        }
        return root;
    }

    /**
     * 仓库用途改成不良品仓(或改回良品仓)的前置条件: 不良品仓只能是子仓、不能是车间内料仓;
     * 有库存或还是货品所属仓库时由数据库守卫 fn_guard_warehouse_master_lifecycle 同一口径拒绝。
     */
    private void requireDefectiveShape(Warehouse w, boolean defective) {
        if (w.isLineSide()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "车间内料仓不能设为不良品仓");
        }
        if (!defective) return;
        boolean isMain = w.getId() == null
                ? rules.rootId() == null
                : w.getId().equals(rules.rootId()) || repo.existsByParentIdAndDeletedFalse(w.getId());
        if (isMain) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "不良品仓只能是子仓, 主仓不能设为不良品仓");
        }
    }

    private String rootName(UUID root) {
        return repo.findById(root).map(Warehouse::getName).orElse("主仓");
    }

    /**
     * 线边仓形状校验（V584）：归属一个车间、参与核算、叶子仓。数据库触发器
     * {@code fn_guard_warehouse_line_side} 兜底同款规则，这里前置成中文报错，
     * 另有「还有余额时不许摘线边标记」仅由触发器把关。
     */
    private void requireLineSideShape(Warehouse w) {
        if (!w.isLineSide()) return;
        if (w.getWorkshopDepartmentId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "车间内料仓必须归属一个生产车间，请先选所属车间");
        }
        if (!w.isAccountable()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "车间内料仓必须参与核算 (库存按它记账, 否则直送和整批领料的成本结不出来)");
        }
        if (w.getId() != null && repo.existsByParentIdAndDeletedFalse(w.getId())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "车间内料仓必须是叶子仓，该仓库下面还有子仓");
        }
    }

    private WarehouseDetail toDetail(Warehouse w) {
        UUID workshopId = w.getWorkshopDepartmentId();
        String workshopName = organizationReferences.findActiveDepartment(workshopId)
                .map(DepartmentReference::name)
                .orElse(null);
        return new WarehouseDetail(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), workshopId, workshopName, w.getLegacyOperatorId(),
                w.getWorkshopLegacyId(),
                w.getStatus(), w.getLegacyId(), w.getParentId(), w.isLineSide(),
                w.isDefective(), rules.isSelectableForNew(w.getId()),
                rules.selectableDefective(List.of(w.getId())).contains(w.getId()));
    }

    /** 两类可选集合(良品子仓 / 不良品子仓), 一批行各查一次。 */
    private record Selectable(Set<UUID> good, Set<UUID> defective) {
    }

    private Selectable selectable(List<Warehouse> rows) {
        List<UUID> ids = rows.stream().map(Warehouse::getId).toList();
        return new Selectable(rules.selectableForNew(ids), rules.selectableDefective(ids));
    }

    private static String useLabel(boolean defective) {
        return defective ? "不良品仓" : "良品仓";
    }

    private WarehouseListItem toList(Warehouse w, Map<UUID, String> workshopNames,
                                     Map<UUID, String> parentNames, Selectable selectable) {
        UUID workshopId = w.getWorkshopDepartmentId();
        // Map.copyOf/Map.of 返回的不可变 Map 对 null key 的 get 会抛 NPE，未设置时一律先判空。
        // 上级仓库这一路 2026-09-22 在服务器上真炸过：本页所有行都没有上级时 parentNames()
        // 返回 Map.of()，再拿 null 的 parentId 去 get 就是 NPE 500(整页仓库列表打不开)。
        // 页里只要有一行带上级就换成 HashMap，get(null) 合法——所以平时翻不出来，
        // 只在「筛选后或小页只剩顶层仓库」时才现形。
        String workshopName = workshopId == null ? null : workshopNames.get(workshopId);
        UUID parentId = w.getParentId();
        String parentName = parentId == null ? null : parentNames.get(parentId);
        return new WarehouseListItem(w.getId(), w.getCode(), w.getName(), w.getLocation(), w.getRemark(),
                w.isAccountable(), workshopId, workshopName, w.getLegacyOperatorId(),
                w.getWorkshopLegacyId(),
                w.getStatus(), w.getLegacyId(), parentId, parentName,
                w.isLineSide(), w.isDefective(), selectable.good().contains(w.getId()),
                selectable.defective().contains(w.getId()));
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
