package com.uten.imp.features.master.goods;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.OffsetDateTime;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Deque;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 货品组装信息（BOM）：成品的组件清单 CRUD + 配件清单导出。
 *
 * <p>列表一次性把组件货品信息（编号/名称/型号/规格/单位/颜色/材质）拼好返回，
 * 前端组装树按行懒加载子级（对组件 id 再调本 list 接口）即可。
 *
 * <p>唯一性按 {@code (goods_id, component_goods_id)} 两个 UUID 判断；组件编号只用于搜索/显示，
 * 改号不影响关系。部分唯一索引兜底，service 先查给出友好报错。
 * 金额：total 未传时用 BigDecimal 按 qty*price 重算（两位小数）。
 */
@Service
@RequiredArgsConstructor
public class GoodsBomService {

    private static final Set<String> CONTROL_STAGES = Set.of(
            "START", "ASSEMBLY", "FINISH", "SHIP", "REFERENCE");
    private static final Set<String> HARD_GATE_STAGES = Set.of(
            "START", "ASSEMBLY", "FINISH");

    private final GoodsRepository goodsRepo;
    private final GoodsBomItemRepository bomRepo;
    private final ColorRepository colorRepo;
    private final UnitRepository unitRepo;
    private final TxSessionVars tx;
    private final MasterReferenceValidationPort references;
    private final GoodsMasterRelationshipResolver relationships;
    private final BusinessEventPublisher events;

    // ===== 列表（含组件展示信息 + hasChildren） =====

    @Transactional(readOnly = true)
    public List<BomItemView> list(UUID goodsId) {
        references.requireVisibleGoods(goodsId);
        requireGoods(goodsId);
        List<GoodsBomItem> rows = operationalRows(goodsId);
        if (rows.isEmpty()) return List.of();
        // 组件自身是否有 BOM（展开箭头）：一次批量查。
        Set<UUID> componentIds = rows.stream()
                .map(r -> r.getComponent().getId())
                .collect(Collectors.toSet());
        Set<UUID> visibleComponentIds = componentIds.stream()
                .filter(references::canViewGoods)
                .collect(Collectors.toSet());
        Set<UUID> withChildren = visibleComponentIds.isEmpty() ? Set.of()
                : bomRepo.findByGoods_IdInAndDeletedFalse(visibleComponentIds).stream()
                .filter(this::isOperationalRow)
                .map(r -> r.getGoods().getId())
                .collect(Collectors.toSet());
        // 颜色/供应商/单位均 UUID 优先；legacy 仅在对应 UUID 缺失时兼容旧数据。
        List<BomItemView> views = new ArrayList<>(rows.size());
        for (GoodsBomItem r : rows) {
            Goods c = r.getComponent();
            if (!visibleComponentIds.contains(c.getId())) {
                views.add(redactedView(r, c));
                continue;
            }
            views.add(new BomItemView(
                    r.getId(), c.getId(), c.getCode(), c.getName(), c.getModel(), c.getSpec(),
                    c.getMaterial(),
                    unitNameOf(c), bomColorNameOf(r, c),
                    r.getColor() == null ? null : r.getColor().getId(),
                    r.getColor() == null ? r.getColorLegacyId() : r.getColor().getLegacyId(),
                    r.getDefaultSupplier() == null ? null : r.getDefaultSupplier().getId(),
                    r.getDefaultSupplier() == null
                            ? r.getVendLegacyId()
                            : r.getDefaultSupplier().getLegacyId(),
                    r.getQty(), r.getPrice(), r.getTotal(),
                    r.getSummary(), r.getLegacyId(),
                    withChildren.contains(c.getId()),
                    c.getSourceType(),
                    r.getControlStage(), r.getConsumptionBasis(),
                    r.getBasisOutputQty(), r.isAllowPartialPackage(),
                    r.isHardGate(), r.getAuditedAt()));
        }
        return views;
    }

    // ===== 新增 / 编辑 / 删除（goods:edit） =====

    @Transactional
    public BomItemView create(UUID goodsId, BomItemSaveRequest req) {
        tx.bind();
        references.requireVisibleActiveGoods(goodsId);
        references.requireVisibleActiveGoods(req.getComponentGoodsId());
        Goods parent = requireGoods(goodsId);
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        ensureComponentUnique(goodsId, component.getId());
        ensureNoCycle(goodsId, component.getId());
        GoodsBomItem r = new GoodsBomItem();
        r.setGoods(parent);
        apply(req, r, component);
        r.setSortOrder(nextSortOrder(goodsId));
        bomRepo.save(r);
        recalcSourceE(parent);
        return toView(r, component);
    }

    @Transactional
    public BomItemView update(UUID goodsId, UUID itemId, BomItemSaveRequest req) {
        tx.bind();
        references.requireVisibleGoods(goodsId);
        GoodsBomItem r = requireItem(goodsId, itemId);
        references.requireVisibleActiveGoods(req.getComponentGoodsId());
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        if (!component.getId().equals(r.getComponent().getId())) {
            ensureComponentUnique(goodsId, component.getId());
            ensureNoCycle(goodsId, component.getId());
        }
        apply(req, r, component);
        // 行内容变更后原审计结论作废：清空审计标记。
        r.setAuditedAt(null);
        r.setAuditedBy(null);
        bomRepo.save(r);
        recalcSourceE(r.getGoods());
        return toView(r, component);
    }

    // ===== 审计标记（goods:bom:audit） =====

    /**
     * 审计标记：把某组装行标记为「已核对无误」或取消标记。
     * 不是 BOM 数据变更：不重算 sourceE、不发 GOODS_BOM_UPDATED
     * （避免误触发研发 BOM 任务自动完成与计划员通知）。
     */
    @Transactional
    public BomItemView setAudited(UUID goodsId, UUID itemId, boolean audited, UUID userId) {
        tx.bind();
        references.requireVisibleGoods(goodsId);
        GoodsBomItem r = requireItem(goodsId, itemId);
        if (audited) {
            r.setAuditedAt(OffsetDateTime.now());
            r.setAuditedBy(userId);
        } else {
            r.setAuditedAt(null);
            r.setAuditedBy(null);
        }
        bomRepo.save(r);
        return toView(r, r.getComponent());
    }

    @Transactional
    public void delete(UUID goodsId, UUID itemId) {
        tx.bind();
        references.requireVisibleGoods(goodsId);
        GoodsBomItem r = requireItem(goodsId, itemId);
        Goods parent = r.getGoods();
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        bomRepo.save(r);
        recalcSourceE(parent);
    }

    // ===== 配件清单导出（产品配件清单，对照老系统 003.jpg 列） =====

    /** 树展开深度上限（防历史脏数据 A→B→A 环路死循环）。 */
    private static final int MAX_DEPTH = 10;

    /**
     * 整树展开导出：一级组件无标记，子级编号前加 {@code *}、孙级 {@code **}（星号数=深度）；
     * 序号为级联序号并逐级缩进（1 / └ 3.1 / 　└ 3.1.1，每层一个全角空格 + └ 分支符），
     * 名称列对齐不缩进，与前端 A4 预览/打印件完全一致。
     */
    @Transactional(readOnly = true)
    public ExportPayload exportPayload(UUID goodsId) {
        List<ExportColumn> cols = List.of(
                new ExportColumn("seq", "序号", ExportColumn.TEXT),
                new ExportColumn("code", "物料编号", ExportColumn.TEXT),
                new ExportColumn("name", "物料名称", ExportColumn.TEXT),
                new ExportColumn("spec", "规格", ExportColumn.TEXT),
                new ExportColumn("colorName", "颜色", ExportColumn.TEXT),
                new ExportColumn("qty", "数量", ExportColumn.NUMBER),
                new ExportColumn("material", "材质", ExportColumn.TEXT),
                new ExportColumn("summary", "备注", ExportColumn.TEXT));
        List<Map<String, Object>> rows = new ArrayList<>();
        Set<UUID> path = new java.util.HashSet<>();
        path.add(goodsId);
        expandForExport(goodsId, 0, path, "", rows);
        return new ExportPayload(cols, rows, rows.size());
    }

    /** DFS 平铺 BOM 树：[path] = 当前展开路径上的货品（含根，环路防护）；[prefix] = 级联序号前缀。 */
    private void expandForExport(UUID goodsId, int depth, Set<UUID> path, String prefix,
                                 List<Map<String, Object>> rows) {
        if (depth > MAX_DEPTH) return;
        List<BomItemView> items = list(goodsId);
        for (int i = 0; i < items.size(); i++) {
            BomItemView v = items.get(i);
            String seq = prefix.isEmpty() ? String.valueOf(i + 1) : prefix + "." + (i + 1);
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("seq", depth == 0 ? seq : "　".repeat(depth) + "└ " + seq);
            row.put("code", "*".repeat(depth) + (v.getComponentCode() == null ? "" : v.getComponentCode()));
            row.put("name", v.getComponentName());
            row.put("spec", v.getComponentSpec());
            row.put("colorName", v.getComponentColorName());
            row.put("qty", v.getQty());
            row.put("material", v.getComponentMaterial());
            row.put("summary", v.getSummary());
            rows.add(row);
            if (v.isHasChildren() && !path.contains(v.getComponentGoodsId())) {
                Set<UUID> next = new java.util.HashSet<>(path);
                next.add(v.getComponentGoodsId());
                expandForExport(v.getComponentGoodsId(), depth + 1, next, seq, rows);
            }
        }
    }

    // ===== 私有 =====

    private void apply(BomItemSaveRequest req, GoodsBomItem r, Goods component) {
        r.setComponent(component);
        BigDecimal qty = req.getQty() == null ? BigDecimal.ONE : req.getQty();
        if (qty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "用量必须大于 0");
        }
        r.setQty(qty);
        String controlStage = validChoice(
                req.getControlStage(), r.getControlStage(), "START",
                CONTROL_STAGES,
                "使用阶段只能选择开工前、装配、完工/包装、发货参考或仅参考");
        r.setControlStage(controlStage);
        r.setConsumptionBasis(validChoice(
                req.getConsumptionBasis(), r.getConsumptionBasis(), "PER_UNIT",
                Set.of("PER_UNIT", "PER_PACKAGE", "FIXED_BATCH"),
                "计量方式只能选择按每件、按包装或固定批耗"));
        BigDecimal basisOutputQty = req.getBasisOutputQty();
        if (basisOutputQty == null) {
            basisOutputQty = r.getBasisOutputQty() == null
                    ? BigDecimal.ONE : r.getBasisOutputQty();
        }
        if (basisOutputQty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "基准产量必须大于 0");
        }
        r.setBasisOutputQty(basisOutputQty);
        if (req.getAllowPartialPackage() != null) {
            r.setAllowPartialPackage(req.getAllowPartialPackage());
        }
        boolean hardGate = req.getHardGate() == null
                ? r.isHardGate() : req.getHardGate();
        if (hardGate && !HARD_GATE_STAGES.contains(controlStage)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "发货参考或仅参考不能设为缺料硬门槛；"
                            + "纸箱/包装若生产包装必须消耗，请选择 FINISH，"
                            + "并使用 PER_PACKAGE 或 FIXED_BATCH");
        }
        r.setHardGate(hardGate);
        r.setPrice(req.getPrice());
        // 金额：显式传入优先，否则 qty*price 兜底（无单价则 null）
        BigDecimal total = req.getTotal();
        if (total == null && req.getPrice() != null) {
            total = qty.multiply(req.getPrice()).setScale(2, RoundingMode.HALF_UP);
        }
        r.setTotal(total);
        if (req.hasColorReference()) {
            if (clearsReference(req.getColorId(), req.getColorLegacyId())) {
                r.setColor(null);
                r.setColorLegacyId(null);
            } else {
                Color target = relationships.color(req.getColorId());
                r.setColor(target);
                r.setColorLegacyId(target.getLegacyId());
            }
        }
        if (req.hasDefaultSupplierReference()) {
            if (clearsReference(req.getDefaultSupplierId(), req.getVendLegacyId())) {
                r.setDefaultSupplier(null);
                r.setVendLegacyId(null);
            } else {
                var target = relationships.supplier(req.getDefaultSupplierId());
                r.setDefaultSupplier(target);
                r.setVendLegacyId(target.getLegacyId());
            }
        }
        r.setSummary(req.getSummary());
    }

    private static String validChoice(
            String requested,
            String current,
            String fallback,
            Set<String> allowed,
            String errorMessage) {
        String value;
        if (requested == null) {
            value = current == null || current.isBlank() ? fallback : current;
        } else {
            value = requested.strip().toUpperCase(Locale.ROOT);
        }
        if (!allowed.contains(value)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, errorMessage);
        }
        return value;
    }

    private static boolean clearsReference(UUID id, Integer legacyId) {
        return id == null && (legacyId == null || legacyId == 0);
    }

    private BomItemView toView(GoodsBomItem r, Goods component) {
        boolean hasChildren = !operationalRows(component.getId()).isEmpty();
        return new BomItemView(
                r.getId(), component.getId(), component.getCode(), component.getName(),
                component.getModel(), component.getSpec(), component.getMaterial(),
                unitNameOf(component), bomColorNameOf(r, component),
                r.getColor() == null ? null : r.getColor().getId(),
                r.getColor() == null ? r.getColorLegacyId() : r.getColor().getLegacyId(),
                r.getDefaultSupplier() == null ? null : r.getDefaultSupplier().getId(),
                r.getDefaultSupplier() == null
                        ? r.getVendLegacyId()
                        : r.getDefaultSupplier().getLegacyId(),
                r.getQty(), r.getPrice(), r.getTotal(),
                r.getSummary(), r.getLegacyId(), hasChildren, component.getSourceType(),
                r.getControlStage(), r.getConsumptionBasis(),
                r.getBasisOutputQty(), r.isAllowPartialPackage(), r.isHardGate(),
                r.getAuditedAt());
    }

    /** Preserve relationship identity for cleanup while hiding an unauthorized target's data. */
    private BomItemView redactedView(GoodsBomItem r, Goods component) {
        return new BomItemView(
                r.getId(), component.getId(), null, null, null, null, null,
                null, null, null, null, null, null,
                r.getQty(), r.getPrice(), r.getTotal(), r.getSummary(), r.getLegacyId(),
                false, null, r.getControlStage(), r.getConsumptionBasis(),
                r.getBasisOutputQty(), r.isAllowPartialPackage(), r.isHardGate(),
                r.getAuditedAt());
    }

    private int nextSortOrder(UUID goodsId) {
        return operationalRows(goodsId).stream()
                .mapToInt(r -> r.getSortOrder() == null ? 0 : r.getSortOrder())
                .max().orElse(0) + 1;
    }

    private void ensureComponentUnique(UUID goodsId, UUID componentId) {
        if (bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(goodsId, componentId).isPresent()) {
            throw new ApiException(ErrorCode.CONFLICT, "该组件已在组装清单中（组件编号必须唯一）");
        }
    }

    /**
     * DAG 环检测：加边 parentGoodsId → componentId 会成环，当且仅当 componentId 的（传递）组件子树
     * 里已包含 parentGoodsId。BFS 下溯组件子树（深度上限 MAX_DEPTH，防脏数据死循环），命中即 409。
     */
    private void ensureNoCycle(UUID parentGoodsId, UUID componentId) {
        Set<UUID> visited = new HashSet<>();
        Deque<UUID> queue = new ArrayDeque<>();
        queue.add(componentId);
        visited.add(componentId);
        int depth = 0;
        while (!queue.isEmpty() && depth <= MAX_DEPTH) {
            for (int size = queue.size(); size > 0; size--) {
                UUID cur = queue.poll();
                if (cur.equals(parentGoodsId)) {
                    throw new ApiException(ErrorCode.CONFLICT, "不能添加：该组件的子组件已包含本货品，会形成组装环路");
                }
                for (GoodsBomItem child : operationalRows(cur)) {
                    if (visited.add(child.getComponent().getId())) {
                        queue.add(child.getComponent().getId());
                    }
                }
            }
            depth++;
        }
    }

    /**
     * BOM 增删改后重算父货品「材料合计」sourceE 并写回 goods：
     * 直接组件中，来源=自制 或 自身有 BOM（半成品）的取其成本价 cTotal×qty（其下级成本已含），
     * 其余（采购/委外/未设）取 price×qty。求和（两位小数）。
     * 前端成本 Tab 的 sourceE 只读显示此值；下游成本（成品价/成本价/出厂价）由前端据此级联。
     */
    private void recalcSourceE(Goods parent) {
        List<GoodsBomItem> rows = operationalRows(parent.getId());
        Set<UUID> componentIds = rows.stream()
                .map(r -> r.getComponent().getId())
                .collect(Collectors.toSet());
        Set<UUID> withChildren = componentIds.isEmpty() ? Set.of()
                : bomRepo.findByGoods_IdInAndDeletedFalse(componentIds).stream()
                        .filter(this::isOperationalRow)
                        .map(r -> r.getGoods().getId())
                        .collect(Collectors.toSet());
        BigDecimal sum = BigDecimal.ZERO;
        for (GoodsBomItem r : rows) {
            Goods c = r.getComponent();
            boolean selfMade = "自制".equals(c.getSourceType()) || withChildren.contains(c.getId());
            BigDecimal unit;
            if (selfMade && c.getCTotal() != null) {
                unit = c.getCTotal();
            } else {
                unit = c.getPrice();
            }
            if (unit != null && r.getQty() != null) {
                sum = sum.add(unit.multiply(r.getQty()));
            }
        }
        parent.setSourceE(sum.setScale(2, RoundingMode.HALF_UP));
        goodsRepo.save(parent);
        // BOM 变更 → 通知旁路：触发研发 BOM 任务自动完成 + 通知所有已登记等待的生产转发人
        // （ChainNoticeService.notifyBomUpdated 经 outbox 原子送达）。create/update/delete 三处共用此钩子。
        // 用 publish（每次维护独立事件）而非 publishOnce：publishOnce 的终生去重键会让同一货品
        // 第二次维护 BOM 时事件被静默吞掉，研发维护后不再通知计划部、rd_task 永不自动完成。
        // 重复通知由 notifyBomUpdated 自身防御（resolveOpenBomTasksForGoods 返回 0 即早退）。
        events.publish(
                "GOODS_BOM_UPDATED", "GOODS_BOM", parent.getId(), Map.of());
    }

    private Goods requireGoods(UUID id) {
        return goodsRepo.findById(id)
                .filter(g -> !g.isDeleted() && !g.isAutoCreated())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
    }

    private Goods requireComponent(UUID componentId, UUID goodsId) {
        if (componentId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "组件货品必填");
        }
        if (componentId.equals(goodsId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "组件不能是货品自身");
        }
        Goods component = goodsRepo.findById(componentId)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "组件货品不存在"));
        if (component.isAutoCreated()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "迁移占位货品只用于历史引用，不能加入当前组装清单");
        }
        return component;
    }

    /**
     * 当前可运营 BOM 只允许真实货品作为父件和组件。auto_created 货品是老库悬空引用的
     * 历史外键锚，不属于当前主档/BOM/MRP；这里做查询侧兜底，数据库清理。
     */
    private List<GoodsBomItem> operationalRows(UUID goodsId) {
        return bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(goodsId).stream()
                .filter(this::isOperationalRow)
                .toList();
    }

    private boolean isOperationalRow(GoodsBomItem row) {
        return !row.getGoods().isAutoCreated() && !row.getComponent().isAutoCreated();
    }

    private GoodsBomItem requireItem(UUID goodsId, UUID itemId) {
        return bomRepo.findById(itemId)
                .filter(r -> !r.isDeleted() && r.getGoods().getId().equals(goodsId))
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "组装行不存在"));
    }

    private Map<Integer, String> colorNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream().filter(Objects::nonNull).collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return colorRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(c -> c.getLegacyId() != null)
                .collect(Collectors.toMap(Color::getLegacyId,
                        c -> c.getName() == null ? "" : c.getName(), (a, b) -> a));
    }

    private Map<Integer, String> unitNamesFor(Collection<Integer> legacyIds) {
        Set<Integer> distinct = legacyIds.stream().filter(Objects::nonNull).collect(Collectors.toSet());
        if (distinct.isEmpty()) return Map.of();
        return unitRepo.findByLegacyIdInAndDeletedFalse(distinct).stream()
                .filter(u -> u.getLegacyId() != null)
                .collect(Collectors.toMap(Unit::getLegacyId,
                        u -> u.getName() == null ? "" : u.getName(), (a, b) -> a));
    }

    private String bomColorNameOf(GoodsBomItem row, Goods component) {
        if (row.getColor() != null) {
            return row.getColor().isDeleted() ? null : row.getColor().getName();
        }
        if (row.getColorLegacyId() != null) {
            return colorNameOf(row.getColorLegacyId());
        }
        if (component.getColor() != null) {
            return component.getColor().isDeleted() ? null : component.getColor().getName();
        }
        return colorNameOf(component.getColorLegacyId());
    }

    private String unitNameOf(Goods component) {
        if (component.getUnit() != null) {
            return component.getUnit().isDeleted() ? null : component.getUnit().getName();
        }
        return unitNameOf(component.getUnitLegacyId());
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
}
