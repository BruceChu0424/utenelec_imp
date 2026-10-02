package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
import java.util.stream.Collectors;

/**
 * 粘贴组件信息(ADR-111)：一次请求、一个事务，把一组组件行替换或追加到 1~50 个目标货品。
 *
 * <p>取代前端「逐条删现有组件 → 逐条新建、失败 catch 吞掉」的循环：那种写法删完一半、
 * 建到一半失败，BOM 就半新半旧，而物料分析/MRP 直接以 BOM 为输入。这里先把全部目标、
 * 全部行校验完(存在/停用/自身/重复/成环/用量与阶段/目标已被他人改过)，任何一处不合格就
 * 一条都不写并逐条说明；全部合格才动手，写入中途数据库拒绝也整体回滚。
 *
 * <p>查询按批：目标与组件一次取、现有组件一次取、成环检查按层批量下探(不逐个节点查)。
 *
 * <p>替换模式按组件对齐(ADR-129)：目标里已有的同一组件原地覆盖成粘贴行的内容(行 id 不变)，
 * 粘贴清单里没有的组件才删、目标里没有的组件才新建。写入后的清单与「全删再全建」完全一样，
 * 但内容没变的行保留审核标记，系统学习边保留系统所有权(人工删除会让学习不再自动加回该组件)。
 */
@Service
@RequiredArgsConstructor
public class GoodsBomPasteService {

    private final GoodsBomService bom;
    private final GoodsRepository goodsRepo;
    private final GoodsBomItemRepository bomRepo;
    private final MasterReferenceValidationPort references;
    private final MasterObjectAccess access;
    private final TxSessionVars tx;
    private final EntityManager em;

    /** 现有组件行快照。 */
    private record Edge(UUID itemId, UUID parentId, UUID componentId, Integer sortOrder) {
    }

    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public BomPasteResult paste(BomPasteRequest request) {
        return paste(request, null, Map.of());
    }

    /** 导入只有展示列：替换已有组件时未提供的字段保留，不能清颜色/供应商或重置生产控制规则。 */
    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public BomPasteResult pasteImported(BomPasteRequest request, Set<String> columns,
                                        Map<UUID, String> colorNames) {
        if (request.targets().size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次导入分组只能对应一个父件");
        }
        return paste(request, columns, colorNames);
    }

    /** 检测阶段用同一颜色解析规则逐行报错；只操作脱离持久化的候选行。提交仍在锁内复检。 */
    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional(readOnly = true)
    public Map<UUID, String> importedColorProblems(UUID parentId, Map<UUID, String> colorNames) {
        references.requireVisibleGoods(parentId);
        Map<UUID, GoodsBomItem> existing = bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parentId)
                .stream().collect(Collectors.toMap(row -> row.getComponent().getId(), row -> row));
        Predicate<UUID> visible = access.visibleGoodsOwner();
        Map<UUID, String> errors = new HashMap<>();
        for (Goods component : goodsRepo.findAllById(colorNames.keySet())) {
            if (!colorNames.containsKey(component.getId())) continue;
            if (!visible.test(component.getOwnerEmployeeId())) {
                errors.put(component.getId(), "组件货品不存在或你看不到它");
                continue;
            }
            GoodsBomItem row = new GoodsBomItem();
            GoodsBomItem prior = existing.get(component.getId());
            if (prior != null) row.takeContentFrom(prior);
            row.setComponent(component);
            try {
                bom.applyImportedColor(row, component, colorNames.get(component.getId()));
            } catch (ApiException error) {
                errors.put(component.getId(), error.getMessage());
            }
        }
        return errors;
    }

    /** 一个数据库快照覆盖全部待改父件、现有边、学习用量和相关主档；返回值只参与哈希、不发给客户端。 */
    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional(readOnly = true)
    public String importStateSnapshot(Set<UUID> parents, Set<UUID> goodsIds, Set<String> colorNames) {
        return String.valueOf(em.createNativeQuery("""
                WITH edges AS (
                    SELECT * FROM goods_bom_items WHERE goods_id IN (:parents) AND NOT is_deleted
                ), involved AS (
                    SELECT id,version,updated_at,code,name,status,is_deleted,auto_created,owner_employee_id,
                           unit_id,unit_legacy_id,color_id,color_legacy_id,issue_method,periodic_cost_basis,
                           price,source_type,m_weight,m_weight_unit_id,m_weight_unit_legacy_id
                    FROM goods WHERE id IN (:goodsIds) OR id IN (SELECT component_goods_id FROM edges)
                )
                SELECT CAST(jsonb_build_object(
                    'goods', (SELECT jsonb_agg(to_jsonb(g) ORDER BY g.id) FROM involved g),
                    'edges', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM edges e),
                    'colors', (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id) FROM colors c
                        WHERE c.id IN (SELECT color_id FROM involved UNION SELECT color_id FROM edges)
                           OR c.legacy_id IN (SELECT color_legacy_id FROM involved UNION SELECT color_legacy_id FROM edges)
                           OR lower(btrim(c.name)) IN (:colorNames)),
                    'units', (SELECT jsonb_agg(to_jsonb(u) ORDER BY u.id) FROM units u
                        WHERE u.id IN (SELECT unit_id FROM involved UNION SELECT m_weight_unit_id FROM involved)
                           OR u.legacy_id IN (SELECT unit_legacy_id FROM involved UNION SELECT m_weight_unit_legacy_id FROM involved)),
                    'suppliers', (SELECT jsonb_agg(jsonb_build_object('id',s.id,'updatedAt',s.updated_at,
                        'isDeleted',s.is_deleted,'code',s.code,'name',s.name,'status',s.status) ORDER BY s.id) FROM suppliers s
                        WHERE s.id IN (SELECT default_supplier_id FROM edges)
                           OR s.legacy_id IN (SELECT vend_legacy_id FROM edges)),
                    'actualUsage', (SELECT jsonb_agg(to_jsonb(a) ORDER BY a.goods_id,a.component_goods_id,a.unit_id)
                        FROM goods_bom_actual_usages a WHERE a.goods_id IN (:parents))
                ) AS text)
                """).setParameter("parents", parents).setParameter("goodsIds", goodsIds)
                .setParameter("colorNames", colorNames.isEmpty() ? Set.of("") : colorNames).getSingleResult());
    }

    /** 即使文件内容未变化，成功导入也推进父件已有版本，旧检测令牌不能再次产生副作用。 */
    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public void markImportApplied(Set<UUID> parents) {
        for (Goods parent : goodsRepo.findAllById(parents)) {
            em.lock(parent, jakarta.persistence.LockModeType.OPTIMISTIC_FORCE_INCREMENT);
        }
    }

    /** 父件先锁，再锁全部引用与数量基准；丢弃锁前解析加载的实体，后续必须重新读最新状态。 */
    @PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public void prepareImportReferences(Set<UUID> involved) {
        goodsRepo.lockForReference(involved);
        references.lockGoodsQuantityBasis(involved);
        em.clear();
    }

    private BomPasteResult paste(BomPasteRequest request, Set<String> importColumns,
                                 Map<UUID, String> colorNames) {
        tx.bind();
        boolean replace = request.mode() == BomPasteRequest.Mode.REPLACE;
        if (replace) {
            // 替换会删掉粘贴清单外的现有组件，要同时有删除组件的权限。
            CurrentAuthorityGuard.requireAll("goods:bom:delete");
        }
        Map<UUID, List<UUID>> expected = new LinkedHashMap<>();
        for (BomPasteRequest.Target target : request.targets()) {
            expected.putIfAbsent(target.goodsId(), target.expectedItemIds());
        }
        List<UUID> targetIds = List.copyOf(expected.keySet());
        goodsRepo.lockBomParents(targetIds);
        List<BomItemSaveRequest> items = request.items();
        Set<UUID> componentIds = items.stream().map(BomItemSaveRequest::getComponentGoodsId)
                .filter(Objects::nonNull).collect(Collectors.toCollection(LinkedHashSet::new));
        Set<UUID> involved = new LinkedHashSet<>(targetIds);
        involved.addAll(componentIds);
        // 先锁再读：与主档删除命令互斥，读到的「是否已删除」一定是最新的。
        goodsRepo.lockForReference(involved);
        references.lockGoodsQuantityBasis(involved);
        Map<UUID, Goods> goods = goodsRepo.findAllById(involved).stream()
                .collect(Collectors.toMap(Goods::getId, g -> g));
        Predicate<UUID> visible = access.visibleGoodsOwner();
        List<ApiError.FieldError> problems = new ArrayList<>();

        // ---- 目标 ----
        List<Goods> targets = new ArrayList<>();
        for (UUID id : targetIds) {
            Goods target = goods.get(id);
            if (target == null || !visible.test(target.getOwnerEmployeeId())) {
                problems.add(problem("目标货品", "目标货品不存在或你看不到它"));
            } else if (!usable(target)) {
                problems.add(problem("目标「" + label(target) + "」", "已删除、停用或仅为迁移占位，不能改组件信息"));
            } else {
                targets.add(target);
            }
        }
        Map<UUID, List<Edge>> existing = new HashMap<>();
        for (Edge edge : edges(targets.stream().map(Goods::getId).toList())) {
            existing.computeIfAbsent(edge.parentId(), ignored -> new ArrayList<>()).add(edge);
        }
        for (Goods target : targets) {
            List<UUID> seenIds = expected.get(target.getId());
            if (seenIds == null) continue;
            Set<UUID> current = existing.getOrDefault(target.getId(), List.of()).stream()
                    .map(Edge::itemId).collect(Collectors.toSet());
            if (!current.equals(new HashSet<>(seenIds))) {
                problems.add(problem("目标「" + label(target) + "」", "组件信息已被他人修改，请刷新后重试"));
            }
        }

        Map<UUID, Map<UUID, GoodsBomItem>> kept = new HashMap<>();
        if (replace) {
            List<UUID> keeping = existing.values().stream().flatMap(List::stream)
                    .filter(edge -> componentIds.contains(edge.componentId())).map(Edge::itemId).toList();
            if (!keeping.isEmpty()) {
                for (GoodsBomItem row : bomRepo.findAllById(keeping)) {
                    kept.computeIfAbsent(row.getGoods().getId(), ignored -> new HashMap<>())
                            .put(row.getComponent().getId(), row);
                }
            }
        }

        // ---- 组件行 ----
        Set<UUID> seenComponents = new HashSet<>();
        Map<Integer, Goods> lineComponents = new LinkedHashMap<>();
        // 期间边 (整批领料的料) 要人确认的事: 异常单重、同一产品第二种料; 没有别的问题时一次问全。
        List<ApiError.FieldError> confirmations = new ArrayList<>();
        for (int index = 0; index < items.size(); index++) {
            BomItemSaveRequest item = items.get(index);
            Goods component = goods.get(item.getComponentGoodsId());
            String line = "第 " + (index + 1) + " 行" + (component == null ? "" : " " + label(component));
            if (component == null || !visible.test(component.getOwnerEmployeeId())) {
                problems.add(problem(line, "组件货品不存在或你看不到它"));
                continue;
            }
            if (!usable(component)) {
                problems.add(problem(line, "组件货品已删除、停用或仅为迁移占位"));
                continue;
            }
            if (!seenComponents.add(component.getId())) {
                problems.add(problem(line, "同一个组件在粘贴清单里出现了两次"));
                continue;
            }
            try {
                GoodsBomItem prior = importColumns == null || targets.isEmpty() ? null
                        : kept.getOrDefault(targets.getFirst().getId(), Map.of()).get(component.getId());
                preparedRow(item, component, prior, importColumns, colorNames);
            } catch (ApiException invalid) {
                if (!GoodsPeriodicMaterialRules.isConfirmation(invalid)) {
                    problems.add(problem(line, invalid.getMessage()));
                    continue;
                }
                // 只是要人确认 (异常单重): 记下来, 行本身照常参与下面的检查。
                for (ApiError.FieldError field : invalid.getFieldErrors()) {
                    confirmations.add(new ApiError.FieldError(field.field(), line + ": " + field.message()));
                }
            }
            lineComponents.put(index, component);
            for (Goods target : targets) {
                if (target.getId().equals(component.getId())) {
                    problems.add(problem(line, "组件不能是目标货品「" + label(target) + "」自身"));
                } else if (!replace && existing.getOrDefault(target.getId(), List.of()).stream()
                        .anyMatch(edge -> edge.componentId().equals(component.getId()))) {
                    problems.add(problem(line, "目标「" + label(target) + "」已有这个组件"));
                }
            }
        }
        problems.addAll(cycleProblems(targets, lineComponents, existing, replace));
        if (!problems.isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "粘贴没有生效：有 " + problems.size()
                    + " 处问题，现有组件没有任何改动", problems);
        }
        confirmations.addAll(secondPeriodicConfirmations(targets, items, lineComponents, replace));
        if (!confirmations.isEmpty()) {
            throw GoodsPeriodicMaterialRules.confirmationRequired(confirmations);
        }

        // ---- 写入(全部合格才到这里) ----
        // 替换：同一组件原地覆盖，粘贴清单里没有的组件才删。
        Set<UUID> pastedComponents = lineComponents.values().stream().map(Goods::getId)
                .collect(Collectors.toSet());
        List<UUID> removing = new ArrayList<>();
        if (replace) {
            for (Goods target : targets) {
                for (Edge edge : existing.getOrDefault(target.getId(), List.of())) {
                    if (!pastedComponents.contains(edge.componentId())) removing.add(edge.itemId());
                }
            }
        }
        if (!removing.isEmpty()) {
            if (bomRepo.findAllById(removing).stream()
                    .anyMatch(row -> !visible.test(row.getComponent().getOwnerEmployeeId()))) {
                throw new ApiException(ErrorCode.FORBIDDEN,
                        "替换范围包含你无权查看的现有组件，现有BOM未改动，请联系有完整权限的人员处理");
            }
            // 原生 UPDATE 立即执行：新行插入(提交前 flush)时部分唯一索引已看不到旧行。
            em.createNativeQuery("""
                            UPDATE goods_bom_items
                            SET is_deleted = TRUE, deleted_at = now(), updated_at = now(),
                                updated_by = COALESCE(
                                    CAST(NULLIF(current_setting('app.actor_id', true), '') AS uuid), updated_by)
                            WHERE id IN (:ids) AND is_deleted = FALSE
                            """)
                    .setParameter("ids", removing)
                    .executeUpdate();
        }
        List<GoodsBomItem> created = new ArrayList<>();
        List<BomPasteResult.Target> results = new ArrayList<>();
        for (Goods target : targets) {
            List<Edge> current = existing.getOrDefault(target.getId(), List.of());
            Map<UUID, GoodsBomItem> same = kept.getOrDefault(target.getId(), Map.of());
            int sort = replace ? 0 : current.stream()
                    .mapToInt(edge -> edge.sortOrder() == null ? 0 : edge.sortOrder()).max().orElse(0);
            for (var entry : lineComponents.entrySet()) {
                GoodsBomItem existingRow = same.get(entry.getValue().getId());
                GoodsBomItem row = preparedRow(items.get(entry.getKey()), entry.getValue(),
                        existingRow, importColumns, colorNames);
                row.setGoods(target);
                row.setSortOrder(++sort);
                if (existingRow == null) {
                    created.add(row);
                    continue;
                }
                // 与新建行同一份内容：内容变了整体覆盖(原审核结论作废)，没变只挪排序。
                if (!existingRow.sameContentAs(row)) existingRow.takeContentFrom(row);
                existingRow.setSortOrder(row.getSortOrder());
            }
            // 替换模式按「原有几个组件被替换、写入几个」报(同一组件原地覆盖也算替换)，与全删再全建同口径。
            results.add(new BomPasteResult.Target(target.getId(), label(target),
                    replace ? current.size() : 0, lineComponents.size()));
        }
        // 新行 id 由 Java 端预生成，走 save 会被当成「可能已存在」先查一次再插；这里直接 persist。
        created.forEach(em::persist);
        List<String> warnings = new ArrayList<>();
        if (created.stream().anyMatch(row -> GoodsPeriodicMaterialRules.isPeriodic(row.getComponent()))) {
            // 期间边的形状守卫与 BOM 接管是行触发器: 当场写库, 拒绝原因原样交给员工。
            try {
                em.flush();
            } catch (RuntimeException error) {
                throw GoodsPeriodicMaterialRules.translate(error);
            }
            for (GoodsBomItem row : created) {
                warnings.addAll(GoodsBomService.periodicWarnings(row.getGoods(), row.getComponent(), row));
            }
        }
        targets.forEach(bom::recalcSourceE);
        int replaced = results.stream().mapToInt(BomPasteResult.Target::removed).sum();
        int written = results.stream().mapToInt(BomPasteResult.Target::added).sum();
        return new BomPasteResult(targets.size(), written, replaced, results, List.copyOf(warnings));
    }

    private GoodsBomItem preparedRow(BomItemSaveRequest item, Goods component, GoodsBomItem prior,
                                      Set<String> importColumns, Map<UUID, String> colorNames) {
        GoodsBomItem row = new GoodsBomItem();
        if (importColumns != null && prior != null) {
            row.takeContentFrom(prior);
            row.setComponent(prior.getComponent());
        }
        bom.apply(item, row, component);
        if (importColumns != null) {
            if (prior != null && !importColumns.contains("summary")) row.setSummary(prior.getSummary());
            // 导入没有单价列，原行未设价也必须保持未设价，不能借此自动换成货品现价。
            if (prior != null) {
                row.setPrice(prior.getPrice());
                if (prior.getPrice() == null) row.setTotal(null);
            }
            // 设计用量不变时也保留历史金额精度；变了才由统一 apply 按保留的行价重算。
            if (prior != null && prior.getQty().compareTo(row.getQty()) == 0) row.setTotal(prior.getTotal());
            if (importColumns.contains("color")) {
                bom.applyImportedColor(row, component, colorNames.get(component.getId()));
            }
        }
        return row;
    }

    /**
     * 粘贴后某个目标会同时有两种整批领料的料 (双色 / 双料) 时要人确认: 粘贴清单里的期间边
     * (追加模式再算上目标现有的期间边) 多于一种, 且相关行没带确认。
     */
    private List<ApiError.FieldError> secondPeriodicConfirmations(List<Goods> targets, List<BomItemSaveRequest> items,
                                                                  Map<Integer, Goods> lineComponents, boolean replace) {
        List<Integer> periodicLines = lineComponents.entrySet().stream()
                .filter(entry -> GoodsPeriodicMaterialRules.isPeriodic(entry.getValue()))
                .map(Map.Entry::getKey).toList();
        if (periodicLines.isEmpty()) return List.of();
        boolean confirmed = periodicLines.stream()
                .allMatch(index -> Boolean.TRUE.equals(items.get(index).getConfirmSecondPeriodicMaterial()));
        if (confirmed) return List.of();
        Set<UUID> withPeriodic = replace ? Set.of() : targetsWithPeriodicEdges(targets);
        List<ApiError.FieldError> out = new ArrayList<>();
        for (Goods target : targets) {
            int count = periodicLines.size() + (withPeriodic.contains(target.getId()) ? 1 : 0);
            if (count > 1) {
                out.add(new ApiError.FieldError(GoodsPeriodicMaterialRules.CONFIRM_SECOND_MATERIAL,
                        GoodsPeriodicMaterialRules.secondMaterialMessage(label(target))));
            }
        }
        return out;
    }

    /** 这些目标里哪些已经有期间边 (组件是整批领料的料)。 */
    private Set<UUID> targetsWithPeriodicEdges(List<Goods> targets) {
        if (targets.isEmpty()) return Set.of();
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT DISTINCT bom.goods_id
                        FROM goods_bom_items bom
                        JOIN goods component ON component.id = bom.component_goods_id
                         AND component.issue_method = 'PERIODIC'
                        WHERE bom.goods_id IN (:ids) AND bom.is_deleted = FALSE
                        """)
                .setParameter("ids", targets.stream().map(Goods::getId).toList())
                .getResultList();
        Set<UUID> out = new HashSet<>();
        for (Object row : rows) out.add((UUID) row);
        return out;
    }

    /**
     * 成环检查：把「目标 → 粘贴组件」这些新边加到现有组装图上(替换模式先摘掉目标的旧边)，
     * 从每个组件出发看能不能走回目标。现有图从组件出发按层批量下探。
     */
    private List<ApiError.FieldError> cycleProblems(List<Goods> targets, Map<Integer, Goods> lineComponents,
                                                    Map<UUID, List<Edge>> existing, boolean replace) {
        if (targets.isEmpty() || lineComponents.isEmpty()) return List.of();
        Map<UUID, Set<UUID>> graph = new HashMap<>();
        Set<UUID> visited = new HashSet<>();
        Set<UUID> frontier = new LinkedHashSet<>();
        for (Goods component : lineComponents.values()) {
            if (visited.add(component.getId())) frontier.add(component.getId());
        }
        for (int depth = 0; depth <= GoodsBomService.MAX_DEPTH + 1 && !frontier.isEmpty(); depth++) {
            Set<UUID> next = new LinkedHashSet<>();
            for (Edge edge : edges(frontier)) {
                graph.computeIfAbsent(edge.parentId(), ignored -> new HashSet<>()).add(edge.componentId());
                if (visited.add(edge.componentId())) next.add(edge.componentId());
            }
            frontier = next;
        }
        for (Goods target : targets) {
            if (replace) graph.remove(target.getId());
            if (!replace) {
                existing.getOrDefault(target.getId(), List.of()).forEach(edge -> graph
                        .computeIfAbsent(target.getId(), ignored -> new HashSet<>()).add(edge.componentId()));
            }
            Set<UUID> outgoing = graph.computeIfAbsent(target.getId(), ignored -> new HashSet<>());
            lineComponents.values().forEach(component -> outgoing.add(component.getId()));
        }
        List<ApiError.FieldError> problems = new ArrayList<>();
        for (var entry : lineComponents.entrySet()) {
            Goods component = entry.getValue();
            for (Goods target : targets) {
                if (component.getId().equals(target.getId())) continue;
                if (reaches(graph, component.getId(), target.getId())) {
                    problems.add(problem("第 " + (entry.getKey() + 1) + " 行 " + label(component),
                            "粘贴到「" + label(target) + "」会形成组装环路：这个组件的下层已经包含「"
                                    + label(target) + "」"));
                }
            }
        }
        return problems;
    }

    private static boolean reaches(Map<UUID, Set<UUID>> graph, UUID from, UUID to) {
        Set<UUID> seen = new HashSet<>();
        Deque<UUID> queue = new ArrayDeque<>();
        queue.add(from);
        seen.add(from);
        while (!queue.isEmpty()) {
            UUID current = queue.poll();
            if (current.equals(to)) return true;
            for (UUID next : graph.getOrDefault(current, Set.of())) {
                if (seen.add(next)) queue.add(next);
            }
        }
        return false;
    }

    private List<Edge> edges(java.util.Collection<UUID> parentIds) {
        if (parentIds.isEmpty()) return List.of();
        List<Edge> out = new ArrayList<>();
        for (Object[] row : bomRepo.findOperationalEdges(parentIds)) {
            out.add(new Edge((UUID) row[0], (UUID) row[1], (UUID) row[2],
                    row[3] == null ? null : ((Number) row[3]).intValue()));
        }
        return out;
    }

    /** 可以作为组装清单父件/组件：未删除、非迁移占位、未停用(口径同单行新增)。 */
    private static boolean usable(Goods goods) {
        return !goods.isDeleted() && !goods.isAutoCreated() && !"禁用".equals(goods.getStatus());
    }

    private static String label(Goods goods) {
        String text = (Objects.toString(goods.getCode(), "") + " " + Objects.toString(goods.getName(), "")).strip();
        return text.isEmpty() ? "(未命名货品)" : text;
    }

    private static ApiError.FieldError problem(String where, String message) {
        return new ApiError.FieldError(where, message);
    }
}
