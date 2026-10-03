package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.application.port.WorkshopMaterialChoicePort.MaterialRef;
import com.uten.imp.application.port.WorkshopMaterialChoicePort.ProductChoice;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomItemView;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.MaterialOption;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationRow;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationRowInput;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationView;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 上线准备 (ADR-131 §5.1 第 2 步; 规格 §2.1、§2.3): 车间开启整批领料前, 把常做的产品一次填好
 * "用哪种颗粒、单个重量多少克"。
 *
 * <p>列表: 近 12 个月在该车间做过或生产车间为该车间的产品; 每行带老库材质、预填颗粒 (BOM 里已有的料 →
 * 车间认过的料 → 老库材质文字与料名唯一命中)、BOM 里的单个重量、货品资料单重 (按质量单位换成克, 供界面
 * "勾选行用货品资料单重填入") 与状态; 顶部进度"常做的 N 个产品, 已选料 M 个, 已填单重 K 个"。
 *
 * <p>保存: 一次原子请求。填了单个重量的行经 {@link GoodsBomService} 写期间边 (按克换算、形状自动设定、异常单重
 * 与第二种料要确认, 与在 BOM 页签里填完全同一套规则); 只选了料没填单重的行经 {@link WorkshopMaterialChoicePort}
 * 写认料 (ADR-017: 认料属于车间内料仓, 基础资料只经端口写)。
 */
@Service
public class GoodsPeriodicBomPreparationService {

    private static final String STATUS_WEIGHED = "WEIGHED";
    private static final String STATUS_CHOSEN = "CHOSEN";
    private static final String STATUS_NOT_FROM_STORE = "NOT_FROM_STORE";
    private static final String STATUS_PENDING = "PENDING";
    private static final String SOURCE_BOM = "BOM";
    private static final String SOURCE_CHOICE = "CHOICE";
    /**
     * 上线准备列表的行数上限 (常做的产品按次数排前面)。
     * 2026-10-02 从 3000 收敛到 300：全量重导库后候选产品达 3.5 万，前端可编辑表
     * 是 content-tall 全量布局，3000 行会同步构建上万个输入单元直接卡死页面；
     * 进度三数 (total/chosen/weighed) 是独立聚合，不受行数截断影响，截断时前端有提示。
     */
    private static final int ROW_LIMIT = 300;

    private final NamedParameterJdbcTemplate db;
    private final GoodsBomService bom;
    private final GoodsBomItemRepository bomRepo;
    private final WorkshopMaterialChoicePort choices;
    private final GoodsPeriodicCommandLedger commands;
    private final TxSessionVars tx;
    private final GoodsRepository goodsRepo;

    public GoodsPeriodicBomPreparationService(NamedParameterJdbcTemplate db, GoodsBomService bom,
                                              GoodsBomItemRepository bomRepo, WorkshopMaterialChoicePort choices,
                                              GoodsPeriodicCommandLedger commands, TxSessionVars tx,
                                              GoodsRepository goodsRepo) {
        this.db = db;
        this.bom = bom;
        this.bomRepo = bomRepo;
        this.choices = choices;
        this.commands = commands;
        this.tx = tx;
        this.goodsRepo = goodsRepo;
    }

    // ================================================================ 列表

    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('workshop_material:setup')")
    @Transactional(readOnly = true)
    public PreparationView list(UUID workshopDepartmentId) {
        if (workshopDepartmentId == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        }
        List<String> workshop = db.queryForList(
                "SELECT name FROM departments WHERE id = :id AND is_deleted = FALSE",
                Map.of("id", workshopDepartmentId), String.class);
        if (workshop.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "车间不存在");

        List<MaterialOption> materials = materialOptions();
        Map<UUID, List<Map<String, Object>>> byProduct = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList(PRODUCTS_SQL,
                new MapSqlParameterSource("workshop", workshopDepartmentId).addValue("limit", ROW_LIMIT))) {
            byProduct.computeIfAbsent((UUID) row.get("id"), key -> new ArrayList<>()).add(row);
        }
        Map<UUID, List<Map<String, Object>>> choicesByProduct = activeChoices(byProduct.keySet());

        List<PreparationRow> rows = new ArrayList<>();
        int chosen = 0;
        int weighed = 0;
        for (Map.Entry<UUID, List<Map<String, Object>>> entry : byProduct.entrySet()) {
            List<Map<String, Object>> edges = entry.getValue();
            Map<String, Object> product = edges.getFirst();
            BigDecimal goodsGrams = product.get("m_weight") == null ? null
                    : positiveOrNull(GoodsPeriodicMaterialRules.toGrams((BigDecimal) product.get("m_weight"),
                    GoodsPeriodicMaterialRules.gramsPerUnit((String) product.get("weight_unit_name"))));
            boolean hasOrderBom = Boolean.TRUE.equals(product.get("has_order_bom"));
            List<Map<String, Object>> productChoices = choicesByProduct.getOrDefault(entry.getKey(), List.of());
            if (product.get("bom_item_id") != null) {
                chosen++;
                weighed++;
                for (Map<String, Object> edge : edges) {
                    UUID material = (UUID) edge.get("edge_material_id");
                    rows.add(row(product, (UUID) edge.get("bom_item_id"), material, (String) edge.get("edge_material_code"),
                            (String) edge.get("edge_material_name"), (UUID) edge.get("edge_color_id"), SOURCE_BOM,
                            GoodsPeriodicMaterialRules.toGrams((BigDecimal) edge.get("edge_qty"),
                                    GoodsPeriodicMaterialRules.gramsPerUnit((String) edge.get("edge_unit_name"))),
                            goodsGrams, STATUS_WEIGHED, false, hasOrderBom));
                }
            } else if (productChoices.stream().anyMatch(choice -> "MATERIAL".equals(choice.get("kind")))) {
                chosen++;
                for (Map<String, Object> choice : productChoices) {
                    rows.add(row(product, null, (UUID) choice.get("material_goods_id"),
                            (String) choice.get("material_code"), (String) choice.get("material_name"),
                            (UUID) choice.get("material_color_id"), SOURCE_CHOICE, null, goodsGrams, STATUS_CHOSEN,
                            Boolean.TRUE.equals(choice.get("also_order_materials")), hasOrderBom));
                }
            } else if (!productChoices.isEmpty()) {
                rows.add(row(product, null, null, null, null, null, null, null, goodsGrams,
                        STATUS_NOT_FROM_STORE, false, hasOrderBom));
            } else {
                MaterialOption legacy = legacyMatch((String) product.get("material"), materials);
                rows.add(legacy == null
                        ? row(product, null, null, null, null, null, null, null, goodsGrams, STATUS_PENDING,
                        false, hasOrderBom)
                        : row(product, null, legacy.goodsId(), legacy.code(), legacy.name(), null,
                        WorkshopMaterialChoicePort.PREFILL_LEGACY_MATERIAL_TEXT, null, goodsGrams, STATUS_PENDING,
                        false, hasOrderBom));
            }
        }
        return new PreparationView(workshopDepartmentId, workshop.getFirst(), byProduct.size(), chosen, weighed,
                List.copyOf(rows), materials);
    }

    /**
     * 近 12 个月在该车间做过 (按执行段) 或生产车间为该车间的产品, 每个产品带上它的期间边 (没有则一行空边)。
     * 整批领料的料本身不算产品。
     */
    private static final String PRODUCTS_SQL = """
            WITH recent AS (
                SELECT segment.product_goods_id AS goods_id, count(*) AS runs
                FROM production_execution_segments segment
                WHERE segment.workshop_department_id = :workshop AND segment.is_deleted = FALSE
                  AND segment.created_at >= now() - interval '12 months'
                GROUP BY segment.product_goods_id
            ), products AS (
                SELECT source.goods_id, sum(source.runs) AS runs
                FROM (SELECT goods_id, runs FROM recent
                      UNION ALL
                      SELECT owned.id, 0 FROM goods owned
                      WHERE owned.owning_workshop_department_id = :workshop AND owned.is_deleted = FALSE) source
                GROUP BY source.goods_id
            ), picked AS (
                SELECT products.goods_id, products.runs
                FROM products
                JOIN goods product ON product.id = products.goods_id
                WHERE product.is_deleted = FALSE AND product.auto_created = FALSE
                  AND product.issue_method <> 'PERIODIC'
                ORDER BY products.runs DESC, product.code, product.id
                LIMIT :limit
            )
            SELECT product.id, product.code, product.name, product.spec, product.material,
                   product.m_weight, weight_unit.name AS weight_unit_name, picked.runs,
                   fn_goods_has_order_bom(product.id) AS has_order_bom,
                   edge.id AS bom_item_id, edge_material.id AS edge_material_id,
                   edge_material.code AS edge_material_code, edge_material.name AS edge_material_name,
                   COALESCE(edge.color_id, edge_material.color_id) AS edge_color_id, edge.qty AS edge_qty,
                   edge_unit.name AS edge_unit_name
            FROM picked
            JOIN goods product ON product.id = picked.goods_id
            LEFT JOIN units weight_unit ON weight_unit.id = product.m_weight_unit_id AND weight_unit.is_deleted = FALSE
            LEFT JOIN goods_bom_items edge ON edge.goods_id = product.id AND edge.is_deleted = FALSE
             AND EXISTS (SELECT 1 FROM goods periodic
                         WHERE periodic.id = edge.component_goods_id AND periodic.issue_method = 'PERIODIC')
            LEFT JOIN goods edge_material ON edge_material.id = edge.component_goods_id
            LEFT JOIN units edge_unit ON edge_unit.id = edge_material.unit_id AND edge_unit.is_deleted = FALSE
            ORDER BY picked.runs DESC, product.code, product.id, edge.sort_order, edge.id
            """;

    private Map<UUID, List<Map<String, Object>>> activeChoices(Set<UUID> products) {
        if (products.isEmpty()) return Map.of();
        Map<UUID, List<Map<String, Object>>> out = new HashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT choice.product_goods_id, choice.kind, choice.material_goods_id, choice.material_color_id,
                       choice.also_order_materials, material.code AS material_code, material.name AS material_name
                FROM goods_periodic_material_choices choice
                LEFT JOIN goods material ON material.id = choice.material_goods_id
                WHERE choice.product_goods_id IN (:products) AND choice.superseded_at IS NULL
                ORDER BY choice.product_goods_id, material.code, choice.id
                """, Map.of("products", List.copyOf(products)))) {
            out.computeIfAbsent((UUID) row.get("product_goods_id"), key -> new ArrayList<>()).add(row);
        }
        return out;
    }

    /** 可选的料: 整批领料的主料 (分摊方式为主料)。 */
    private List<MaterialOption> materialOptions() {
        List<MaterialOption> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT material.id, material.code, material.name, material.color_id, color.name AS color_name,
                       unit.name AS unit_name
                FROM goods material
                LEFT JOIN colors color ON color.id = material.color_id
                LEFT JOIN units unit ON unit.id = material.unit_id AND unit.is_deleted = FALSE
                WHERE material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN'
                  AND material.is_deleted = FALSE
                ORDER BY material.code, material.id
                LIMIT 500
                """, Map.of())) {
            String unitName = (String) row.get("unit_name");
            out.add(new MaterialOption((UUID) row.get("id"), (String) row.get("code"), (String) row.get("name"),
                    (UUID) row.get("color_id"), (String) row.get("color_name"), unitName,
                    GoodsPeriodicMaterialRules.gramsPerUnit(unitName) != null));
        }
        return out;
    }

    /**
     * 老库材质文字与料名唯一命中 (与开工确认表的预填同一规则: 名称或编号相等, 或名称与材质文字互相包含);
     * 命中不止一种或没有命中都不预填。
     */
    static MaterialOption legacyMatch(String legacyMaterial, List<MaterialOption> materials) {
        if (legacyMaterial == null || legacyMaterial.isBlank()) return null;
        String text = legacyMaterial.strip().toLowerCase(Locale.ROOT);
        MaterialOption found = null;
        for (MaterialOption option : materials) {
            String name = option.name() == null ? "" : option.name().strip().toLowerCase(Locale.ROOT);
            String code = option.code() == null ? "" : option.code().strip().toLowerCase(Locale.ROOT);
            boolean hit = (!name.isEmpty() && (name.equals(text) || name.contains(text) || text.contains(name)))
                    || (!code.isEmpty() && code.equals(text));
            if (!hit) continue;
            if (found != null) return null;
            found = option;
        }
        return found;
    }

    private static PreparationRow row(Map<String, Object> product, UUID bomItemId, UUID materialId,
                                      String materialCode, String materialName, UUID colorId, String source,
                                      BigDecimal unitWeightGrams, BigDecimal goodsGrams, String status,
                                      boolean alsoOrderMaterials, boolean hasOrderBom) {
        return new PreparationRow((UUID) product.get("id"), (String) product.get("code"), (String) product.get("name"),
                (String) product.get("spec"), (String) product.get("material"),
                ((Number) product.get("runs")).intValue(), bomItemId, materialId, materialCode, materialName, colorId,
                source, unitWeightGrams, goodsGrams, status, alsoOrderMaterials, hasOrderBom);
    }

    private static BigDecimal positiveOrNull(BigDecimal value) {
        return value == null || value.signum() <= 0 ? null : value;
    }

    // ================================================================ 保存

    /** 一次保存: 任何一行不合格整批不写 (要确认的一次问全)。 */
    @PreAuthorize("hasAuthority('goods:bom:create') and hasAuthority('goods:bom:edit')")
    @Transactional
    public PreparationBatchResult save(PreparationBatchRequest request) {
        tx.bind();
        GoodsPeriodicCommandLedger.requireKey(request.idempotencyKey());
        return commands.execute("PERIODIC_BOM_PREPARATION", request.idempotencyKey(), request,
                PreparationBatchResult.class, () -> saveRows(request));
    }

    /** 已有的期间边 (产品 × 料)。 */
    private record ExistingEdge(UUID id, UUID productId, UUID materialId, BigDecimal grams) {}

    private PreparationBatchResult saveRows(PreparationBatchRequest request) {
        Map<UUID, List<PreparationRowInput>> byProduct = new LinkedHashMap<>();
        for (PreparationRowInput row : request.rows()) {
            if (row == null || row.productGoodsId() == null || row.materialGoodsId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "每一行都要有产品和料");
            }
            if (row.unitWeightGrams() != null && row.unitWeightGrams().signum() <= 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "单个重量必须大于 0 克");
            }
            if (row.prefillSource() != null
                    && !WorkshopMaterialChoicePort.PREFILL_LEGACY_MATERIAL_TEXT.equals(row.prefillSource())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "预填来源不对, 请刷新页面");
            }
            byProduct.computeIfAbsent(row.productGoodsId(), key -> new ArrayList<>()).add(row);
        }
        // 锁序同 BOM 维护与发料方式切换 (先按 id 顺序锁全部产品, 再由 BOM 维护锁料), 批量里不会互相等成环。
        goodsRepo.lockBomParents(byProduct.keySet());
        Map<UUID, List<ExistingEdge>> existing = existingEdges(byProduct.keySet());
        Map<UUID, String> labels = labels(byProduct.keySet());
        requireConfirmations(byProduct, existing, labels);

        int created = 0;
        int updated = 0;
        List<String> warnings = new ArrayList<>();
        List<ProductChoice> productChoices = new ArrayList<>();
        for (Map.Entry<UUID, List<PreparationRowInput>> entry : byProduct.entrySet()) {
            UUID product = entry.getKey();
            List<PreparationRowInput> rows = entry.getValue();
            String label = labels.getOrDefault(product, "这个产品");
            long weighedRows = rows.stream().filter(row -> row.unitWeightGrams() != null).count();
            if (weighedRows > 0 && weighedRows < rows.size()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "「" + label + "」的几种料要么都填单个重量, 要么都先只选料");
            }
            Set<UUID> seen = new LinkedHashSet<>();
            for (PreparationRowInput row : rows) {
                if (!seen.add(row.materialGoodsId())) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + label + "」同一种料填了两行, 请合并");
                }
            }
            if (weighedRows == 0) {
                if (!existing.getOrDefault(product, List.of()).isEmpty()) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + label
                            + "」的 BOM 里已经填了单个重量, 开工按 BOM 用料; 请填单个重量, 不能只选料");
                }
                List<MaterialRef> refs = rows.stream().map(row -> new MaterialRef(row.materialGoodsId(), row.colorId()))
                        .toList();
                boolean allPrefilled = rows.stream().allMatch(row -> row.prefillSource() != null);
                productChoices.add(new ProductChoice(product, WorkshopMaterialChoicePort.KIND_MATERIAL, refs, false,
                        allPrefilled ? WorkshopMaterialChoicePort.PREFILL_LEGACY_MATERIAL_TEXT : null));
                continue;
            }
            for (PreparationRowInput row : rows) {
                ExistingEdge edge = target(row, existing.getOrDefault(product, List.of()), label);
                BomItemSaveRequest save = new BomItemSaveRequest();
                save.setComponentGoodsId(row.materialGoodsId());
                save.setUnitWeightGrams(row.unitWeightGrams());
                if (row.colorId() != null) save.setColorId(row.colorId());
                save.setConfirmUnusualWeight(row.confirmUnusualWeight());
                save.setConfirmSecondPeriodicMaterial(row.confirmSecondPeriodicMaterial());
                BomItemView view;
                if (edge == null) {
                    view = bom.create(product, save);
                    created++;
                } else {
                    // 只改料与单个重量: 备注照旧 (保存请求里备注为空会清掉原备注)。
                    save.setSummary(bomRepo.findById(edge.id()).map(GoodsBomItem::getSummary).orElse(null));
                    view = bom.update(product, edge.id(), save);
                    updated++;
                }
                if (view.getWarnings() != null) warnings.addAll(view.getWarnings());
            }
        }
        if (!productChoices.isEmpty()) {
            try {
                choices.choose(productChoices, request.workshopDepartmentId(),
                        GoodsPeriodicCommandLedger.derivedKey("prep-choice", request.idempotencyKey()));
            } catch (RuntimeException error) {
                throw GoodsPeriodicMaterialRules.translate(error);
            }
        }
        return new PreparationBatchResult(created, updated, productChoices.size(), List.copyOf(warnings));
    }

    /** 这一行改哪条已有期间边: 指定了 BOM 行就改它, 否则按 (产品, 料) 找; 找不到返回 null (新增)。 */
    private static ExistingEdge target(PreparationRowInput row, List<ExistingEdge> edges, String label) {
        if (row.bomItemId() != null) {
            return edges.stream().filter(edge -> edge.id().equals(row.bomItemId())).findFirst()
                    .orElseThrow(() -> new ApiException(ErrorCode.CONFLICT,
                            "「" + label + "」的 BOM 已被别人改过, 请刷新后重试"));
        }
        return edges.stream().filter(edge -> edge.materialId().equals(row.materialGoodsId())).findFirst()
                .orElse(null);
    }

    /**
     * 保存前把要人确认的事一次问全: 单个重量小于 0.1 克或大于 5000 克 (改了单重的行)、
     * 产品会同时有两种整批领料的料 (新增的料)。确认规则与 BOM 页签相同, 写入时 BOM 服务还会再核一遍。
     */
    private static void requireConfirmations(Map<UUID, List<PreparationRowInput>> byProduct,
                                             Map<UUID, List<ExistingEdge>> existing, Map<UUID, String> labels) {
        List<ApiError.FieldError> confirmations = new ArrayList<>();
        for (Map.Entry<UUID, List<PreparationRowInput>> entry : byProduct.entrySet()) {
            String label = labels.getOrDefault(entry.getKey(), "这个产品");
            List<ExistingEdge> edges = existing.getOrDefault(entry.getKey(), List.of());
            Set<UUID> materials = new LinkedHashSet<>();
            edges.forEach(edge -> materials.add(edge.materialId()));
            boolean secondAsked = false;
            for (PreparationRowInput row : entry.getValue()) {
                if (row.unitWeightGrams() == null) continue;
                ExistingEdge edge = row.bomItemId() != null
                        ? edges.stream().filter(e -> e.id().equals(row.bomItemId())).findFirst().orElse(null)
                        : edges.stream().filter(e -> e.materialId().equals(row.materialGoodsId())).findFirst()
                        .orElse(null);
                boolean weightChanged = edge == null || edge.grams() == null
                        || edge.grams().compareTo(row.unitWeightGrams()) != 0
                        || !edge.materialId().equals(row.materialGoodsId());
                if (weightChanged && GoodsPeriodicMaterialRules.unusual(row.unitWeightGrams())
                        && !Boolean.TRUE.equals(row.confirmUnusualWeight())) {
                    confirmations.add(new ApiError.FieldError(GoodsPeriodicMaterialRules.CONFIRM_UNUSUAL_WEIGHT,
                            GoodsPeriodicMaterialRules.unusualWeightMessage(label, row.unitWeightGrams())));
                }
                if (edge == null) {
                    boolean second = materials.stream().anyMatch(material -> !material.equals(row.materialGoodsId()));
                    materials.add(row.materialGoodsId());
                    if (second && !secondAsked && !Boolean.TRUE.equals(row.confirmSecondPeriodicMaterial())) {
                        confirmations.add(new ApiError.FieldError(GoodsPeriodicMaterialRules.CONFIRM_SECOND_MATERIAL,
                                GoodsPeriodicMaterialRules.secondMaterialMessage(label)));
                        secondAsked = true;
                    }
                }
            }
        }
        if (!confirmations.isEmpty()) throw GoodsPeriodicMaterialRules.confirmationRequired(confirmations);
    }

    private Map<UUID, List<ExistingEdge>> existingEdges(Set<UUID> products) {
        Map<UUID, List<ExistingEdge>> out = new HashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT bom.id, bom.goods_id, bom.component_goods_id, bom.qty, unit.name AS unit_name
                FROM goods_bom_items bom
                JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
                LEFT JOIN units unit ON unit.id = component.unit_id AND unit.is_deleted = FALSE
                WHERE bom.goods_id IN (:products) AND bom.is_deleted = FALSE
                ORDER BY bom.goods_id, bom.sort_order, bom.id
                """, Map.of("products", List.copyOf(products)))) {
            UUID product = (UUID) row.get("goods_id");
            out.computeIfAbsent(product, key -> new ArrayList<>()).add(new ExistingEdge((UUID) row.get("id"), product,
                    (UUID) row.get("component_goods_id"),
                    GoodsPeriodicMaterialRules.toGrams((BigDecimal) row.get("qty"),
                            GoodsPeriodicMaterialRules.gramsPerUnit((String) row.get("unit_name")))));
        }
        return out;
    }

    private Map<UUID, String> labels(Set<UUID> products) {
        Map<UUID, String> out = new HashMap<>();
        for (Map<String, Object> row : db.queryForList(
                "SELECT id, code, name FROM goods WHERE id IN (:products)",
                Map.of("products", List.copyOf(products)))) {
            String text = (Objects.toString(row.get("code"), "") + " " + Objects.toString(row.get("name"), "")).strip();
            out.put((UUID) row.get("id"), text.isEmpty() ? "这个产品" : text);
        }
        return out;
    }
}
