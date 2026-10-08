package com.uten.imp.features.master.goods;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemUsage;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
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
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
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
    private final SecurityContextCurrentUser currentUser;
    private final MasterReferenceValidationPort references;
    private final GoodsMasterRelationshipResolver relationships;
    private final BusinessEventPublisher events;
    private final MasterObjectAccess access;

    // ===== 列表（含组件展示信息 + hasChildren） =====

    @Transactional(readOnly = true)
    public List<BomItemView> list(UUID goodsId) {
        references.requireVisibleGoods(goodsId);
        requireGoods(goodsId);
        List<GoodsBomItem> rows = operationalRows(goodsId);
        if (rows.isEmpty()) return List.of();
        // 组件可见性按归属人一次判定(口径同 canViewGoods)，组件已随行取回，不逐个查库。
        Predicate<UUID> visible = access.visibleGoodsOwner();
        Set<UUID> visibleComponentIds = rows.stream()
                .map(GoodsBomItem::getComponent)
                .filter(c -> visible.test(c.getOwnerEmployeeId()))
                .map(Goods::getId)
                .collect(Collectors.toSet());
        // 组件自身是否有 BOM（展开箭头）：一次批量查。
        Set<UUID> withChildren = withOperationalRows(visibleComponentIds);
        // 颜色/供应商/单位均 UUID 优先；legacy 仅在对应 UUID 缺失时兼容旧数据，按批一次取名。
        LegacyNames legacy = legacyNames(rows);
        // 真实使用数量/计算采用值：整层一次取(ADR-129)。
        Map<UUID, BomItemUsage> usage = usageOf(rows.stream().map(GoodsBomItem::getId).toList());
        List<BomItemView> views = new ArrayList<>(rows.size());
        for (GoodsBomItem r : rows) {
            Goods c = r.getComponent();
            BomItemUsage rowUsage = usage.getOrDefault(r.getId(), BomItemUsage.NONE);
            if (!visibleComponentIds.contains(c.getId())) {
                views.add(redactedView(r, c, rowUsage));
                continue;
            }
            views.add(new BomItemView(
                    r.getId(), c.getId(), c.getCode(), c.getName(), c.getModel(), c.getSpec(),
                    c.getMaterial(),
                    unitNameOf(c, legacy), bomColorNameOf(r, c, legacy),
                    r.getColor() == null ? null : r.getColor().getId(),
                    r.getColor() == null ? r.getColorLegacyId() : r.getColor().getLegacyId(),
                    r.getDefaultSupplier() == null ? null : r.getDefaultSupplier().getId(),
                    r.getDefaultSupplier() == null
                            ? r.getVendLegacyId()
                            : r.getDefaultSupplier().getLegacyId(),
                    r.getQty(), viewPrice(r.getPrice()), viewTotal(r),
                    r.getSummary(), r.getLegacyId(),
                    withChildren.contains(c.getId()),
                    c.getSourceType(),
                    r.getControlStage(), r.getConsumptionBasis(),
                    r.getBasisOutputQty(), r.isAllowPartialPackage(),
                    r.isHardGate(), r.getAuditedAt(), rowUsage,
                    c.getIssueMethod(), periodicUnitWeightGrams(r, c), List.of()));
        }
        return views;
    }

    // ===== 新增 / 编辑 / 删除（goods:edit） =====

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:create')")
    @Transactional
    public BomItemView create(UUID goodsId, BomItemSaveRequest req) {
        tx.bind();
        lockReferencedGoods(goodsId, req.getComponentGoodsId());
        references.lockGoodsQuantityBasis(java.util.Arrays.asList(goodsId, req.getComponentGoodsId()));
        references.requireVisibleActiveGoods(goodsId);
        references.requireVisibleActiveGoods(req.getComponentGoodsId());
        Goods parent = requireGoods(goodsId);
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        ensureComponentUnique(goodsId, component.getId());
        ensureNoCycle(goodsId, component.getId());
        GoodsBomItem r = new GoodsBomItem();
        r.setGoods(parent);
        applyConfirmed(req, r, parent, component, null);
        r.setSortOrder(nextSortOrder(goodsId));
        bomRepo.save(r);
        flushPeriodicEdge(component);
        recalcSourceE(parent);
        return toView(r, component, periodicWarnings(parent, component, r));
    }

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:edit')")
    @Transactional
    public BomItemView update(UUID goodsId, UUID itemId, BomItemSaveRequest req) {
        tx.bind();
        lockReferencedGoods(goodsId, req.getComponentGoodsId());
        references.lockGoodsQuantityBasis(java.util.Arrays.asList(goodsId, req.getComponentGoodsId()));
        references.requireVisibleGoods(goodsId);
        GoodsBomItem r = requireItem(goodsId, itemId);
        references.requireVisibleActiveGoods(req.getComponentGoodsId());
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        if (!component.getId().equals(r.getComponent().getId())) {
            ensureComponentUnique(goodsId, component.getId());
            ensureNoCycle(goodsId, component.getId());
        }
        applyConfirmed(req, r, r.getGoods(), component, r.getComponent());
        // 行内容变更后原审计结论作废：清空审计标记。
        r.setAuditedAt(null);
        r.setAuditedBy(null);
        bomRepo.save(r);
        flushPeriodicEdge(component);
        recalcSourceE(r.getGoods());
        return toView(r, component, periodicWarnings(r.getGoods(), component, r));
    }

    /**
     * 写入前把要人确认的事一次问全 (期间边: 同一产品第二种整批领料的料、异常单重), 确认过才写。
     *
     * @param previousComponent 编辑前的组件; 新增为 null
     */
    private void applyConfirmed(BomItemSaveRequest req, GoodsBomItem r, Goods parent, Goods component,
                                Goods previousComponent) {
        List<ApiError.FieldError> confirmations = new ArrayList<>();
        boolean newPeriodicMaterial = GoodsPeriodicMaterialRules.isPeriodic(component)
                && (previousComponent == null || !component.getId().equals(previousComponent.getId()));
        if (newPeriodicMaterial && !Boolean.TRUE.equals(req.getConfirmSecondPeriodicMaterial())
                && operationalRows(parent.getId()).stream().anyMatch(row -> row != r
                        && GoodsPeriodicMaterialRules.isPeriodic(row.getComponent())
                        && !component.getId().equals(row.getComponent().getId()))) {
            confirmations.add(new ApiError.FieldError(GoodsPeriodicMaterialRules.CONFIRM_SECOND_MATERIAL,
                    GoodsPeriodicMaterialRules.secondMaterialMessage(GoodsPeriodicMaterialRules.label(parent))));
        }
        try {
            apply(req, r, component);
        } catch (ApiException error) {
            if (!confirmations.isEmpty() && GoodsPeriodicMaterialRules.isConfirmation(error)) {
                confirmations.addAll(error.getFieldErrors());
                throw GoodsPeriodicMaterialRules.confirmationRequired(confirmations);
            }
            throw error;
        }
        if (!confirmations.isEmpty()) {
            throw GoodsPeriodicMaterialRules.confirmationRequired(confirmations);
        }
    }

    /**
     * 期间边当场写库: 形状守卫与 BOM 接管 (作废该产品的认料; 认料勾了"还要按工单领别的料"而产品还没有
     * 按单边时拒绝) 都是行触发器, 在这里把拒绝原因原样交给员工, 不等到提交时变成通用报错。
     */
    private void flushPeriodicEdge(Goods component) {
        if (!GoodsPeriodicMaterialRules.isPeriodic(component)) return;
        try {
            bomRepo.flush();
        } catch (RuntimeException error) {
            throw GoodsPeriodicMaterialRules.translate(error);
        }
    }

    /** 期间边单个重量与产品货品资料单重相差 20% 以上时提醒 (不拦保存)。 */
    static List<String> periodicWarnings(Goods parent, Goods component, GoodsBomItem r) {
        if (!GoodsPeriodicMaterialRules.isPeriodic(component)) return List.of();
        String warning = GoodsPeriodicMaterialRules.differenceWarning(GoodsPeriodicMaterialRules.label(parent),
                periodicUnitWeightGrams(r, component), GoodsPeriodicMaterialRules.goodsWeightGrams(parent));
        return warning == null ? List.of() : List.of(warning);
    }

    // ===== 审计标记（goods:bom:audit） =====

    /**
     * 审计标记：把某组装行标记为「已核对无误」或取消标记。
     * 不是 BOM 数据变更：不重算 sourceE、不发 GOODS_BOM_UPDATED
     * （避免误触发研发 BOM 任务自动完成与计划员通知）。
     */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:audit')")
    @Transactional
    public BomItemView setAudited(UUID goodsId, UUID itemId, boolean audited, UUID userId) {
        tx.bind();
        goodsRepo.lockBomParents(List.of(goodsId));
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

    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:delete')")
    @Transactional
    public void delete(UUID goodsId, UUID itemId) {
        tx.bind();
        goodsRepo.lockBomParents(List.of(goodsId));
        references.requireVisibleGoods(goodsId);
        GoodsBomItem r = requireItem(goodsId, itemId);
        Goods parent = r.getGoods();
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        bomRepo.save(r);
        recalcSourceE(parent);
    }

    /**
     * 批量删除组装行(前端在组装树上勾选多行后一次删完，可以横跨多层)。
     *
     * <p>要么全删要么一条不删：一条查询取回全部仍有效的行和各自父件，任意一条不存在/已删除、
     * 或它的父件不在本货品的组装树里(拿别的货品的行 id 冒充)，整批 404；全部通过后一条 UPDATE
     * 软删，实际删掉的行数对不上(期间被别人删了)也整批 404 回滚。
     *
     * <p>树的范围按层批量取(每层一次查询，最多 {@link #MAX_DEPTH} 层)，每个涉及的父件都要
     * 可见；{@code recalcSourceE} 每个父件只在末尾调一次(它会发 GOODS_BOM_UPDATED 通知)。
     * 语句数与勾选条数无关(500 条也只有取行、下探、UPDATE 各一条)。
     *
     * @return 实际删除条数(已按 id 去重，重复勾选不重复计数)
     */
    @org.springframework.security.access.prepost.PreAuthorize("hasAuthority('goods:bom:delete')")
    @Transactional
    public int deleteAll(UUID goodsId, List<UUID> itemIds) {
        tx.bind();
        references.requireVisibleGoods(goodsId);
        // 去重：组装树上同一行可能被重复提交，删一次、算一次。
        Set<UUID> distinct = new java.util.LinkedHashSet<>();
        for (UUID itemId : itemIds == null ? List.<UUID>of() : itemIds) {
            if (itemId != null) {
                distinct.add(itemId);
            }
        }
        if (distinct.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先选择要删除的组件行");
        }
        List<Object[]> live = bomRepo.findLiveItemParents(distinct);
        if (live.size() != distinct.size()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "组装行不存在");
        }
        Set<UUID> parents = new java.util.LinkedHashSet<>();
        for (Object[] row : live) parents.add((UUID) row[1]);
        goodsRepo.lockBomParents(parents);
        Set<UUID> tree = treeGoodsIds(goodsId, parents);
        for (UUID parent : parents) {
            if (!tree.contains(parent)) {
                throw new ApiException(ErrorCode.NOT_FOUND, "组装行不存在");
            }
            if (!parent.equals(goodsId)) references.requireVisibleGoods(parent);
        }
        if (bomRepo.softDeleteLive(distinct) != distinct.size()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "组装行不存在");
        }
        goodsRepo.findAllById(parents).forEach(this::recalcSourceE);
        return distinct.size();
    }

    /**
     * 本货品组装树里(含自身)的父件 id：逐层批量下探，找齐 {@code wanted} 或到达层数上限即停。
     * 历史脏数据成环时靠 visited 截断。
     */
    private Set<UUID> treeGoodsIds(UUID rootId, Set<UUID> wanted) {
        Set<UUID> visited = new java.util.LinkedHashSet<>();
        visited.add(rootId);
        Set<UUID> frontier = Set.of(rootId);
        for (int depth = 0; depth < MAX_DEPTH && !visited.containsAll(wanted) && !frontier.isEmpty(); depth++) {
            Set<UUID> next = new java.util.LinkedHashSet<>();
            for (Object[] edge : bomRepo.findOperationalEdges(frontier)) {
                UUID child = (UUID) edge[2];
                if (visited.add(child)) next.add(child);
            }
            frontier = next;
        }
        return visited;
    }

    // ===== 配件清单导出（2026-09-25 口径：导出列 = 组装信息表格列） =====

    /** 树展开深度上限（防历史脏数据 A→B→A 环路死循环）。 */
    static final int MAX_DEPTH = 10;

    /** 计量方式代码 → 展示文字（与前端 BomConsumptionBasis.label 同口径）。 */
    private static final Map<String, String> CONSUMPTION_BASIS_LABELS = Map.of(
            "PER_UNIT", "按每件",
            "PER_PACKAGE", "按包装",
            "FIXED_BATCH", "固定批耗");

    /**
     * 导出列 = 组装信息导入的格式(导出的文件原样导回)。列集与前端组装信息表格一致(2026-09-25
     * 用户口径「表格显示啥导出啥」：需求阶段/缺料处理/单价/金额四列已从表格退役，导出同步不带；
     * 已审是审计模式下的交互辅助列，不进导出)。
     * 「设计使用数量」后紧跟只读的「真实使用数量」(ADR-129，没有数据留空；导入时忽略)。
     */
    public static final List<ExportColumn> EXPORT_COLUMNS = List.of(
            new ExportColumn("seq", "序号", ExportColumn.TEXT),
            new ExportColumn("code", "物料编号", ExportColumn.TEXT),
            new ExportColumn("name", "物料名称", ExportColumn.TEXT),
            new ExportColumn("model", "型号", ExportColumn.TEXT),
            new ExportColumn("spec", "规格", ExportColumn.TEXT),
            new ExportColumn("unitName", "单位", ExportColumn.TEXT),
            new ExportColumn("colorName", "颜色", ExportColumn.TEXT),
            new ExportColumn("sourceType", "来源", ExportColumn.TEXT),
            new ExportColumn("consumptionBasis", "计量方式", ExportColumn.TEXT),
            new ExportColumn("basisOutputQty", "基准产量", ExportColumn.QTY),
            new ExportColumn("allowPartialPackage", "尾包", ExportColumn.TEXT),
            new ExportColumn("qty", "设计使用数量", ExportColumn.QTY),
            new ExportColumn("actualQty", "真实使用数量", ExportColumn.QTY),
            new ExportColumn("summary", "备注", ExportColumn.TEXT));

    /** 整树展开导出({@link #EXPORT_COLUMNS})。层级只用级联序号表达(1 / 3.1 / 3.1.1)，不再加缩进与子层星号标记。 */
    @Transactional(readOnly = true, isolation = org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public ExportPayload exportPayload(UUID goodsId) {
        List<Map<String, Object>> rows = new ArrayList<>();
        Set<UUID> path = new java.util.HashSet<>();
        path.add(goodsId);
        expandForExport(goodsId, 0, path, "", rows, new HashMap<>());
        return new ExportPayload(EXPORT_COLUMNS, rows, rows.size());
    }

    /** DFS 平铺 BOM 树：[path] = 当前展开路径上的货品（含根，环路防护）；[prefix] = 级联序号前缀。 */
    private void expandForExport(UUID goodsId, int depth, Set<UUID> path, String prefix,
                                 List<Map<String, Object>> rows, Map<UUID, List<BomItemView>> cache) {
        if (depth >= GoodsBomFileLimits.MAX_LEVELS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "BOM 层级超过完整导出上限，请从下层组件分别导出");
        }
        List<BomItemView> items = cache.computeIfAbsent(goodsId, this::list);
        for (int i = 0; i < items.size(); i++) {
            BomItemView v = items.get(i);
            if (v.getComponentCode() == null || v.getComponentCode().isBlank()) {
                throw new ApiException(ErrorCode.FORBIDDEN, "存在不可见或未编号的组件，无法完整导出，请联系管理员核对权限和货品资料");
            }
            if (rows.size() >= GoodsBomFileLimits.MAX_ROWS) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "BOM 展开超过 " + GoodsBomFileLimits.MAX_ROWS
                        + " 行完整导出上限，请从下层组件分别导出");
            }
            String seq = prefix.isEmpty() ? String.valueOf(i + 1) : prefix + "." + (i + 1);
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("seq", seq);
            row.put("code", v.getComponentCode());
            row.put("name", v.getComponentName());
            row.put("model", v.getComponentModel());
            row.put("spec", v.getComponentSpec());
            row.put("unitName", v.getComponentUnitName());
            row.put("colorName", v.getComponentColorName());
            row.put("sourceType", v.getComponentSourceType());
            row.put("consumptionBasis",
                    CONSUMPTION_BASIS_LABELS.getOrDefault(v.getConsumptionBasis(), v.getConsumptionBasis()));
            row.put("basisOutputQty", v.getBasisOutputQty());
            // 尾包只有「按包装」才有意义（与表格尾包列同口径），其余计量方式显示 —。
            row.put("allowPartialPackage", "PER_PACKAGE".equals(v.getConsumptionBasis())
                    ? (v.isAllowPartialPackage() ? "允许" : "整包") : "—");
            row.put("qty", v.getQty());
            row.put("actualQty", v.getUsage().actualQty());
            row.put("summary", v.getSummary());
            rows.add(row);
            if (v.isHasChildren()) {
                if (path.contains(v.getComponentGoodsId())) {
                    throw new ApiException(ErrorCode.CONFLICT, "BOM 里的组件互相套用形成循环，无法完整导出，请先检查组件结构");
                }
                Set<UUID> next = new java.util.HashSet<>(path);
                next.add(v.getComponentGoodsId());
                expandForExport(v.getComponentGoodsId(), depth + 1, next, seq, rows, cache);
            }
        }
    }

    // ===== 私有 =====

    /** 文件颜色与当前有效颜色相同时保留原关系；真正改色才解析唯一、有效的主档 UUID。 */
    void applyImportedColor(GoodsBomItem row, Goods component, String name) {
        String current = bomColorNameOf(row, component, legacyNames(List.of(row)));
        String requested = name == null ? "" : name.trim();
        if (requested.equalsIgnoreCase(current == null ? "" : current.trim())) return;
        if (requested.isEmpty()) {
            row.setColor(null);
            row.setColorLegacyId(null);
            return;
        }
        List<Color> matches = colorRepo.findByNameIgnoreCaseAndDeletedFalse(requested).stream()
                .filter(color -> !"禁用".equals(color.getStatus()) && !"报废".equals(color.getStatus()))
                .toList();
        if (matches.size() != 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, matches.isEmpty()
                    ? "颜色「" + requested + "」不存在或已停用，请先维护颜色资料"
                    : "颜色「" + requested + "」存在多个同名记录，请先在颜色资料中消除歧义");
        }
        Color color = relationships.color(matches.getFirst().getId());
        row.setColor(color);
        row.setColorLegacyId(color.getLegacyId());
    }

    /** 把请求写到组装行上并校验(用量/阶段/计量方式/硬门槛/颜色/供应商)；粘贴命令逐行复用。 */
    void apply(BomItemSaveRequest req, GoodsBomItem r, Goods component) {
        Goods previousComponent = r.getComponent();
        r.setComponent(component);
        if (GoodsPeriodicMaterialRules.isPeriodic(component)) {
            applyPeriodicEdge(req, r, component, previousComponent);
        } else {
            applyOrderEdge(req, r);
        }
        BigDecimal qty = r.getQty();
        // 单价（goods:price:view，V570）：显式传入优先；null = 不可查看者的脱敏产物
        // （前端隐藏单价，不提交）——新建回退组件货品价（保住「单价取自组件」与成本聚合
        // sourceE 口径），编辑保留行原值，均不误清。金额随实际落库单价重算兜底。
        BigDecimal price = req.getPrice();
        if (price == null) {
            price = r.getPrice() != null ? r.getPrice() : component.getPrice();
        }
        r.setPrice(price);
        // 金额：显式传入优先，否则 qty*price 兜底（无单价则 null）
        BigDecimal total = req.getTotal();
        if (total == null && price != null) {
            total = qty.multiply(price).setScale(2, RoundingMode.HALF_UP);
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

    /** 按单边 (组件按工单领料): 用量、阶段、计量方式、基准产量、尾包、硬门槛照请求校验。 */
    private void applyOrderEdge(BomItemSaveRequest req, GoodsBomItem r) {
        if (req.getUnitWeightGrams() != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "只有整批领料的料才按克填单个重量, 其它组件请填用量");
        }
        // 不传 = 新建按 1(实体默认)、编辑保留原值：系统学习边只在人改了数量时才提交数量(ADR-129)。
        BigDecimal qty = req.getQty() == null ? r.getQty() : req.getQty();
        if (qty == null || qty.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "设计使用数量必须大于 0");
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
    }

    /**
     * 期间边 (组件整批领到车间内料仓, ADR-131 §3.2): 只填单个重量, 形状自动设成开工前、按每件、
     * 基准产量 1、不设齐套门槛。按克填的换成组件基本单位存; 按基本单位填且基准产量不是 1 的
     * (如导入文件里"每 1000 件 12.5 千克") 折成每件用量。辅料 (色母) 不写进 BOM。
     * 改了单个重量且小于 0.1 克或大于 5000 克时要请求带确认。
     */
    private void applyPeriodicEdge(BomItemSaveRequest req, GoodsBomItem r, Goods component,
                                   Goods previousComponent) {
        if (GoodsPeriodicMaterialRules.isSharedBasis(component.getPeriodicCostBasis())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, GoodsPeriodicMaterialRules.SHARED_NOT_IN_BOM);
        }
        if (req.getConsumptionBasis() != null
                && !"PER_UNIT".equals(req.getConsumptionBasis().strip().toUpperCase(Locale.ROOT))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, GoodsPeriodicMaterialRules.SHAPE_ONLY_UNIT_WEIGHT);
        }
        boolean sameComponent = previousComponent != null && component.getId().equals(previousComponent.getId());
        BigDecimal perUnit = periodicQty(req, r, component, sameComponent);
        BigDecimal gramsPerUnit = GoodsPeriodicMaterialRules.gramsPerUnit(component.getUnit());
        boolean weightChanged = r.isNew() || !sameComponent || r.getQty() == null
                || r.getQty().compareTo(perUnit) != 0;
        BigDecimal grams = GoodsPeriodicMaterialRules.toGrams(perUnit, gramsPerUnit);
        if (weightChanged && GoodsPeriodicMaterialRules.unusual(grams)
                && !Boolean.TRUE.equals(req.getConfirmUnusualWeight())) {
            String message = GoodsPeriodicMaterialRules.unusualWeightMessage(
                    GoodsPeriodicMaterialRules.label(component), grams);
            throw GoodsPeriodicMaterialRules.confirmationRequired(List.of(new ApiError.FieldError(
                    GoodsPeriodicMaterialRules.CONFIRM_UNUSUAL_WEIGHT, message)));
        }
        r.setQty(perUnit);
        r.setControlStage("START");
        r.setConsumptionBasis("PER_UNIT");
        r.setBasisOutputQty(BigDecimal.ONE);
        r.setAllowPartialPackage(true);
        r.setHardGate(false);
    }

    /** 期间边每件用量 (组件基本单位, 5 位小数)。 */
    private static BigDecimal periodicQty(BomItemSaveRequest req, GoodsBomItem r, Goods component,
                                          boolean sameComponent) {
        BigDecimal perUnit;
        if (req.getUnitWeightGrams() != null) {
            BigDecimal gramsPerUnit = GoodsPeriodicMaterialRules.gramsPerUnit(component.getUnit());
            if (gramsPerUnit == null) {
                String unit = component.getUnit() == null ? "基本单位" : component.getUnit().getName();
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + GoodsPeriodicMaterialRules.label(component)
                        + "」的基本单位是「" + unit + "」, 不能按克填, 请直接按「" + unit + "」填单个重量");
            }
            if (req.getUnitWeightGrams().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "单个重量必须大于 0 克");
            }
            perUnit = GoodsPeriodicMaterialRules.fromGrams(req.getUnitWeightGrams(), gramsPerUnit);
        } else if (req.getQty() != null) {
            BigDecimal basis = req.getBasisOutputQty() == null ? BigDecimal.ONE : req.getBasisOutputQty();
            if (basis.signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "基准产量必须大于 0");
            }
            perUnit = basis.compareTo(BigDecimal.ONE) == 0
                    ? req.getQty().setScale(GoodsPeriodicMaterialRules.QTY_SCALE, RoundingMode.HALF_UP)
                    : req.getQty().divide(basis, GoodsPeriodicMaterialRules.QTY_SCALE, RoundingMode.HALF_UP);
        } else if (!r.isNew() && sameComponent && r.getQty() != null) {
            perUnit = r.getQty();
        } else {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「" + GoodsPeriodicMaterialRules.label(component) + "」是整批领料的料, 请填单个重量 (克)");
        }
        if (perUnit.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "单个重量太小, 最少 0.01 克");
        }
        return perUnit;
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
        return toView(r, component, List.of());
    }

    private BomItemView toView(GoodsBomItem r, Goods component, List<String> warnings) {
        boolean hasChildren = !withOperationalRows(Set.of(component.getId())).isEmpty();
        LegacyNames legacy = legacyNames(List.of(r));
        // 原生查询前先落库：刚新建/改过的行也按库里的口径读回(学习边被人工接管由触发器改写)。
        BomItemUsage usage = usageOf(List.of(r.getId())).getOrDefault(r.getId(), BomItemUsage.NONE);
        return new BomItemView(
                r.getId(), component.getId(), component.getCode(), component.getName(),
                component.getModel(), component.getSpec(), component.getMaterial(),
                unitNameOf(component, legacy), bomColorNameOf(r, component, legacy),
                r.getColor() == null ? null : r.getColor().getId(),
                r.getColor() == null ? r.getColorLegacyId() : r.getColor().getLegacyId(),
                r.getDefaultSupplier() == null ? null : r.getDefaultSupplier().getId(),
                r.getDefaultSupplier() == null
                        ? r.getVendLegacyId()
                        : r.getDefaultSupplier().getLegacyId(),
                r.getQty(), viewPrice(r.getPrice()), viewTotal(r),
                r.getSummary(), r.getLegacyId(), hasChildren, component.getSourceType(),
                r.getControlStage(), r.getConsumptionBasis(),
                r.getBasisOutputQty(), r.isAllowPartialPackage(), r.isHardGate(),
                r.getAuditedAt(), usage,
                component.getIssueMethod(), periodicUnitWeightGrams(r, component),
                warnings == null ? List.of() : List.copyOf(warnings));
    }

    /** Preserve relationship identity for cleanup while hiding an unauthorized target's data. */
    private BomItemView redactedView(GoodsBomItem r, Goods component, BomItemUsage usage) {
        return new BomItemView(
                r.getId(), component.getId(), null, null, null, null, null,
                null, null, null, null, null, null,
                r.getQty(), viewPrice(r.getPrice()), viewTotal(r), r.getSummary(), r.getLegacyId(),
                false, null, r.getControlStage(), r.getConsumptionBasis(),
                r.getBasisOutputQty(), r.isAllowPartialPackage(), r.isHardGate(),
                r.getAuditedAt(), usage, null, null, List.of());
    }

    /** 这些组装行的真实使用数量/计算采用值：一条查询(v_goods_bom_item_usage)，不逐行查。 */
    private Map<UUID, BomItemUsage> usageOf(Collection<UUID> itemIds) {
        if (itemIds.isEmpty()) return Map.of();
        Map<UUID, BomItemUsage> out = new HashMap<>();
        for (Object[] row : bomRepo.findUsageRows(itemIds)) {
            out.put((UUID) row[0], BomItemUsage.of(row, 1));
        }
        return out;
    }

    /** 期间边的单个重量 (克); 不是期间边或单位不能按克换算时为 null。 */
    private static BigDecimal periodicUnitWeightGrams(GoodsBomItem r, Goods component) {
        if (!GoodsPeriodicMaterialRules.isPeriodic(component)) return null;
        return GoodsPeriodicMaterialRules.toGrams(r.getQty(),
                GoodsPeriodicMaterialRules.gramsPerUnit(component.getUnit()));
    }

    /** 售价可见性（goods:price:view，V570）：未授权者 BOM 行单价/金额置 null（前端隐藏列）。 */
    private BigDecimal viewPrice(BigDecimal price) {
        return canViewPrice() ? price : null;
    }

    private BigDecimal viewTotal(GoodsBomItem r) {
        return canViewPrice() ? r.getTotal() : null;
    }

    private boolean canViewPrice() {
        return currentUser.get()
                .map(AuthUser::getPermissions)
                .map(p -> p.contains("goods:price:view") || p.contains("goods:price:edit"))
                .orElse(false);
    }

    private int nextSortOrder(UUID goodsId) {
        return operationalRows(goodsId).stream()
                .mapToInt(r -> r.getSortOrder() == null ? 0 : r.getSortOrder())
                .max().orElse(0) + 1;
    }

    private void ensureComponentUnique(UUID goodsId, UUID componentId) {
        if (bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(goodsId, componentId).isPresent()) {
            throw new ApiException(ErrorCode.CONFLICT, "该组件已在组装清单中(组件编号必须唯一)");
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
                    throw new ApiException(ErrorCode.CONFLICT, "不能添加：该组件下面已包含本货品，再添加会循环套用");
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
     * 直接组件中，来源=自制 或 自身有 BOM(半成品)的取其成本价 cTotal×设计使用数量(其下级成本已含)，
     * 其余(采购/委外/未设)取 price×设计使用数量。求和(两位小数)。
     * 公式只在数据库函数 fn_goods_bom_material_cost 里定义一次，学习引擎同步学习边后也调它(ADR-129)。
     * 前端成本 Tab 的 sourceE 只读显示此值；下游成本（成品价/成本价/出厂价）由前端据此级联。
     */
    void recalcSourceE(Goods parent) {
        parent.setSourceE(bomRepo.materialCost(parent.getId()));
        goodsRepo.save(parent);
        // BOM 变更 → 通知旁路：触发研发 BOM 任务自动完成 + 通知所有已登记等待的生产转发人
        // （ChainNoticeService.notifyBomUpdated 经 outbox 原子送达）。create/update/delete 三处共用此钩子。
        // 用 publish（每次维护独立事件）而非 publishOnce：publishOnce 的终生去重键会让同一货品
        // 第二次维护 BOM 时事件被静默吞掉，研发维护后不再通知计划部、rd_task 永不自动完成。
        // 重复通知由 notifyBomUpdated 自身防御（resolveOpenBomTasksForGoods 返回 0 即早退）。
        events.publish(
                "GOODS_BOM_UPDATED", "GOODS_BOM", parent.getId(), Map.of());
    }

    /** 父件与组件先加 KEY SHARE 锁再读，与主档删除互斥(见 GoodsRepository.lockForReference)。 */
    private void lockReferencedGoods(UUID goodsId, UUID componentId) {
        if (goodsId != null) goodsRepo.lockBomParents(List.of(goodsId));
        List<UUID> ids = new ArrayList<>(2);
        if (goodsId != null) ids.add(goodsId);
        if (componentId != null) ids.add(componentId);
        if (!ids.isEmpty()) goodsRepo.lockForReference(ids);
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
                    "旧系统导入的占位货品只用于历史记录，不能加入当前组装清单");
        }
        return component;
    }

    /**
     * 当前可运营 BOM 只允许真实货品作为父件和组件。auto_created 货品是老库悬空引用的
     * 历史外键锚，不属于当前主档/BOM/MRP；这里做查询侧兜底，数据库清理。
     */
    List<GoodsBomItem> operationalRows(UUID goodsId) {
        return bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(goodsId).stream()
                .filter(this::isOperationalRow)
                .toList();
    }

    boolean isOperationalRow(GoodsBomItem row) {
        return !row.getGoods().isAutoCreated() && !row.getComponent().isAutoCreated();
    }

    /** 这些货品里哪些自己有可运营组装行：一条查询，不加载实体。 */
    private Set<UUID> withOperationalRows(Collection<UUID> goodsIds) {
        if (goodsIds.isEmpty()) return Set.of();
        return new HashSet<>(bomRepo.findGoodsWithOperationalRows(goodsIds));
    }

    /** 老数据只有 legacy 颜色/单位号、没有 UUID 的行：本批用到的号一次取名。 */
    private record LegacyNames(Map<Integer, String> colors, Map<Integer, String> units) {
    }

    private LegacyNames legacyNames(List<GoodsBomItem> rows) {
        Set<Integer> colors = new HashSet<>();
        Set<Integer> units = new HashSet<>();
        for (GoodsBomItem r : rows) {
            Goods c = r.getComponent();
            if (r.getColor() == null) {
                colors.add(r.getColorLegacyId() != null ? r.getColorLegacyId()
                        : c.getColor() == null ? c.getColorLegacyId() : null);
            }
            if (c.getUnit() == null) units.add(c.getUnitLegacyId());
        }
        return new LegacyNames(colorNamesFor(colors), unitNamesFor(units));
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

    private static String bomColorNameOf(GoodsBomItem row, Goods component, LegacyNames legacy) {
        if (row.getColor() != null) {
            return row.getColor().isDeleted() ? null : row.getColor().getName();
        }
        if (row.getColorLegacyId() != null) {
            return legacy.colors().get(row.getColorLegacyId());
        }
        if (component.getColor() != null) {
            return component.getColor().isDeleted() ? null : component.getColor().getName();
        }
        return component.getColorLegacyId() == null ? null : legacy.colors().get(component.getColorLegacyId());
    }

    private static String unitNameOf(Goods component, LegacyNames legacy) {
        if (component.getUnit() != null) {
            return component.getUnit().isDeleted() ? null : component.getUnit().getName();
        }
        return component.getUnitLegacyId() == null ? null : legacy.units().get(component.getUnitLegacyId());
    }
}
