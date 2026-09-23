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
        tx.bind();
        boolean replace = request.mode() == BomPasteRequest.Mode.REPLACE;
        if (replace) {
            // 替换 = 删掉现有组件再写入，要同时有删除组件的权限。
            CurrentAuthorityGuard.requireAll("goods:bom:delete");
        }
        Map<UUID, List<UUID>> expected = new LinkedHashMap<>();
        for (BomPasteRequest.Target target : request.targets()) {
            expected.putIfAbsent(target.goodsId(), target.expectedItemIds());
        }
        List<UUID> targetIds = List.copyOf(expected.keySet());
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

        // ---- 组件行 ----
        Set<UUID> seenComponents = new HashSet<>();
        Map<Integer, Goods> lineComponents = new LinkedHashMap<>();
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
                bom.apply(item, new GoodsBomItem(), component);
            } catch (ApiException invalid) {
                problems.add(problem(line, invalid.getMessage()));
                continue;
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

        // ---- 写入(全部合格才到这里) ----
        List<UUID> removing = replace
                ? targets.stream().flatMap(t -> existing.getOrDefault(t.getId(), List.of()).stream())
                        .map(Edge::itemId).toList()
                : List.of();
        if (!removing.isEmpty()) {
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
            int sort = replace ? 0 : current.stream()
                    .mapToInt(edge -> edge.sortOrder() == null ? 0 : edge.sortOrder()).max().orElse(0);
            for (var entry : lineComponents.entrySet()) {
                GoodsBomItem row = new GoodsBomItem();
                row.setGoods(target);
                bom.apply(items.get(entry.getKey()), row, entry.getValue());
                row.setSortOrder(++sort);
                created.add(row);
            }
            results.add(new BomPasteResult.Target(target.getId(), label(target),
                    replace ? current.size() : 0, lineComponents.size()));
        }
        // 新行 id 由 Java 端预生成，走 save 会被当成「可能已存在」先查一次再插；这里直接 persist。
        created.forEach(em::persist);
        targets.forEach(bom::recalcSourceE);
        return new BomPasteResult(targets.size(), created.size(), removing.size(), results);
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
