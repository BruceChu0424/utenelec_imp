package com.uten.imp.features.master.goods;

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
 * 货品组装信息（BOM）：成品的组件清单 CRUD + 配件清单导出。
 *
 * <p>列表一次性把组件货品信息（编号/名称/型号/规格/单位/颜色/材质）拼好返回，
 * 前端组装树按行懒加载子级（对组件 id 再调本 list 接口）即可。
 *
 * <p>唯一性：同一成品下组件货品唯一（V79 部分唯一索引兜底，service 先查给出友好报错）。
 * 金额：total 未传时按 qty*price 重算（两位小数）。
 */
@Service
@RequiredArgsConstructor
public class GoodsBomService {

    private final GoodsRepository goodsRepo;
    private final GoodsBomItemRepository bomRepo;
    private final ColorRepository colorRepo;
    private final UnitRepository unitRepo;
    private final TxSessionVars tx;

    // ===== 列表（含组件展示信息 + hasChildren） =====

    @Transactional(readOnly = true)
    public List<BomItemView> list(UUID goodsId) {
        requireGoods(goodsId);
        List<GoodsBomItem> rows = bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(goodsId);
        if (rows.isEmpty()) return List.of();
        // 组件自身是否有 BOM（展开箭头）：一次批量查。
        Set<UUID> componentIds = rows.stream()
                .map(r -> r.getComponent().getId())
                .collect(Collectors.toSet());
        Set<UUID> withChildren = bomRepo.findByGoods_IdInAndDeletedFalse(componentIds).stream()
                .map(r -> r.getGoods().getId())
                .collect(Collectors.toSet());
        // 颜色：行级 color_legacy_id 优先，空回落组件主颜色；单位：组件 unit_legacy_id。
        Map<Integer, String> colorNames = colorNamesFor(rows.stream()
                .map(r -> r.getColorLegacyId() != null ? r.getColorLegacyId()
                        : r.getComponent().getColorLegacyId())
                .toList());
        Map<Integer, String> unitNames = unitNamesFor(rows.stream()
                .map(r -> r.getComponent().getUnitLegacyId())
                .toList());
        List<BomItemView> views = new ArrayList<>(rows.size());
        for (GoodsBomItem r : rows) {
            Goods c = r.getComponent();
            Integer colorId = r.getColorLegacyId() != null ? r.getColorLegacyId() : c.getColorLegacyId();
            views.add(new BomItemView(
                    r.getId(), c.getId(), c.getCode(), c.getName(), c.getModel(), c.getSpec(),
                    c.getMaterial(),
                    c.getUnitLegacyId() == null ? null : unitNames.get(c.getUnitLegacyId()),
                    colorId == null ? null : colorNames.get(colorId),
                    r.getColorLegacyId(), r.getQty(), r.getPrice(), r.getTotal(),
                    r.getSummary(), r.getLegacyId(),
                    withChildren.contains(c.getId())));
        }
        return views;
    }

    // ===== 新增 / 编辑 / 删除（goods:edit） =====

    @Transactional
    public BomItemView create(UUID goodsId, BomItemSaveRequest req) {
        tx.bind();
        Goods parent = requireGoods(goodsId);
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        ensureComponentUnique(goodsId, component.getId());
        GoodsBomItem r = new GoodsBomItem();
        r.setGoods(parent);
        apply(req, r, component);
        r.setSortOrder(nextSortOrder(goodsId));
        bomRepo.save(r);
        return toView(r, component);
    }

    @Transactional
    public BomItemView update(UUID goodsId, UUID itemId, BomItemSaveRequest req) {
        tx.bind();
        GoodsBomItem r = requireItem(goodsId, itemId);
        Goods component = requireComponent(req.getComponentGoodsId(), goodsId);
        if (!component.getId().equals(r.getComponent().getId())) {
            ensureComponentUnique(goodsId, component.getId());
        }
        apply(req, r, component);
        bomRepo.save(r);
        return toView(r, component);
    }

    @Transactional
    public void delete(UUID goodsId, UUID itemId) {
        tx.bind();
        GoodsBomItem r = requireItem(goodsId, itemId);
        r.setDeleted(true);
        r.setDeletedAt(OffsetDateTime.now());
        bomRepo.save(r);
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
        r.setPrice(req.getPrice());
        // 金额：显式传入优先，否则 qty*price 兜底（无单价则 null）
        BigDecimal total = req.getTotal();
        if (total == null && req.getPrice() != null) {
            total = qty.multiply(req.getPrice()).setScale(2, RoundingMode.HALF_UP);
        }
        r.setTotal(total);
        r.setColorLegacyId(req.getColorLegacyId());
        r.setSummary(req.getSummary());
    }

    private BomItemView toView(GoodsBomItem r, Goods component) {
        Integer colorId = r.getColorLegacyId() != null ? r.getColorLegacyId() : component.getColorLegacyId();
        boolean hasChildren = !bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(
                component.getId()).isEmpty();
        return new BomItemView(
                r.getId(), component.getId(), component.getCode(), component.getName(),
                component.getModel(), component.getSpec(), component.getMaterial(),
                unitNameOf(component.getUnitLegacyId()), colorNameOf(colorId),
                r.getColorLegacyId(), r.getQty(), r.getPrice(), r.getTotal(),
                r.getSummary(), r.getLegacyId(), hasChildren);
    }

    private int nextSortOrder(UUID goodsId) {
        return bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(goodsId).stream()
                .mapToInt(r -> r.getSortOrder() == null ? 0 : r.getSortOrder())
                .max().orElse(0) + 1;
    }

    private void ensureComponentUnique(UUID goodsId, UUID componentId) {
        if (bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(goodsId, componentId).isPresent()) {
            throw new ApiException(ErrorCode.CONFLICT, "该组件已在组装清单中（组件编号必须唯一）");
        }
    }

    private Goods requireGoods(UUID id) {
        return goodsRepo.findById(id)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "货品不存在"));
    }

    private Goods requireComponent(UUID componentId, UUID goodsId) {
        if (componentId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "组件货品必填");
        }
        if (componentId.equals(goodsId)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "组件不能是货品自身");
        }
        return goodsRepo.findById(componentId)
                .filter(g -> !g.isDeleted())
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "组件货品不存在"));
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
