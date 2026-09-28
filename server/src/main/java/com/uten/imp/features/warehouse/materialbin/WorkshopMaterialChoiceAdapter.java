package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.MaterialInfo;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChoiceView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChooseRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialChangeRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodicRowView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SegmentMaterials;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 认料与换料 (ADR-131 §5.4、§5.5; 实现 {@link WorkshopMaterialChoicePort})。
 *
 * <p>认料是产品级事实: 产品没有期间边时, 车间在开工确认表里选它用内料仓里的哪种料 (可多种),
 * 或选"不用内料仓的料, 按工单领料"。同一产品改认料时原有效认料作废为"改认料"后写新行; 互斥、
 * 料必须是整批领料主料、BOM 接管等不变量由数据库守卫兜底, 这里先给出能照着改的话。
 * 换料是段级的: 已开工的工单从某天起改用别的料, 原用料行写截止日, 另起一行换料行。
 */
@Component
public class WorkshopMaterialChoiceAdapter implements WorkshopMaterialChoicePort {

    private static final Set<String> NOT_STARTED = Set.of("WAITING", "READY", "DISPATCHED");

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialChoiceAdapter(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                         WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                         SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.commands = commands;
        this.scope = scope;
        this.currentUser = currentUser;
    }

    // ------------------------------------------------------------------ 认料

    @Override
    @Transactional
    public void choose(List<ProductChoice> choices, UUID workshopDepartmentId, String idempotencyKey) {
        chooseAndList(new ChooseRequest(workshopDepartmentId, choices, idempotencyKey));
    }

    /** 写入认料 (一个原子请求) 并返回这些产品写入后的有效认料。 */
    @Transactional
    public ChoiceList chooseAndList(ChooseRequest request) {
        if (request.workshopDepartmentId() != null) scope.requireWorkshop(request.workshopDepartmentId());
        return commands.execute("CHOOSE", request.idempotencyKey(), request, ChoiceList.class, () -> {
            Set<UUID> products = chooseWithinCommand(request.choices(), request.workshopDepartmentId());
            return new Outcome<>(null, new ChoiceList(activeChoices(products)));
        });
    }

    /**
     * 在调用方命令里写认料 (开启车间整批领料时一并认完在产产品; 不另记命令账本)。返回涉及的产品。
     */
    Set<UUID> chooseWithinCommand(List<ProductChoice> choices, UUID workshopDepartmentId) {
        if (choices == null || choices.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少给一个产品认料");
        }
        Map<UUID, ProductChoice> byProduct = new LinkedHashMap<>();
        for (ProductChoice choice : choices) {
            if (choice == null || choice.productGoodsId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "认料缺少产品");
            }
            if (byProduct.putIfAbsent(choice.productGoodsId(), choice) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一个产品填了两次认料, 请合并");
            }
        }
        UUID actor = currentUser.requireId();
        for (ProductChoice choice : byProduct.values()) {
            write(choice, workshopDepartmentId, actor);
        }
        return byProduct.keySet();
    }

    private void write(ProductChoice choice, UUID workshop, UUID actor) {
        MaterialInfo product = bins.material(choice.productGoodsId());
        if (product.deleted()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "产品不存在或已删除");
        String kind = choice.kind();
        if (!KIND_MATERIAL.equals(kind) && !KIND_NONE.equals(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + product.label() + "」请选择用料");
        }
        if (choice.prefillSource() != null && !PREFILL_LEGACY_MATERIAL_TEXT.equals(choice.prefillSource())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "认料的预填来源不对, 请刷新页面");
        }
        Set<MaterialRef> materials = new LinkedHashSet<>(choice.materials());
        if (KIND_MATERIAL.equals(kind)) {
            if (materials.isEmpty()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + product.label() + "」请选择用内料仓里的哪种料");
            }
            for (MaterialRef material : materials) {
                MaterialInfo info = bins.material(material.goodsId());
                if (!info.periodic() || !"OWN".equals(info.costBasis()) || info.deleted()) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED,
                            "「" + info.label() + "」不是整批领料的主料, 不能认作产品用料");
                }
                bins.requireColor(material.colorId());
            }
            if (Boolean.TRUE.equals(flag("fn_goods_has_periodic_bom", product.goodsId()))) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "「" + product.label() + "」的 BOM 里已经填了塑料单个重量, 开工时按 BOM 用料, 不需要认料");
            }
            if (choice.alsoOrderMaterials() && Boolean.TRUE.equals(flag("fn_goods_has_bom", product.goodsId()))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "「" + product.label() + "」有 BOM, 按 BOM 领料, 不需要勾\"还要按工单领别的料\"");
            }
        } else if (!materials.isEmpty() || choice.alsoOrderMaterials()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "「" + product.label() + "」选了不用内料仓的料, 就不要再选料");
        }
        if (sameAsActive(product.goodsId(), kind, materials, choice.alsoOrderMaterials())) return;
        WorkshopMaterialGuards.guarded(() -> db.update("""
                UPDATE goods_periodic_material_choices
                SET superseded_at = now(), superseded_by = :actor, superseded_reason = 'CHANGED'
                WHERE product_goods_id = :product AND superseded_at IS NULL
                """, new MapSqlParameterSource("actor", actor).addValue("product", product.goodsId())));
        List<MaterialRef> rows = KIND_NONE.equals(kind) ? java.util.Collections.singletonList(null)
                : List.copyOf(materials);
        for (MaterialRef material : rows) {
            WorkshopMaterialGuards.guarded(() -> db.update("""
                    INSERT INTO goods_periodic_material_choices(
                        product_goods_id, kind, material_goods_id, material_color_id, also_order_materials,
                        prefill_source, chosen_by, chosen_workshop_department_id)
                    VALUES (:product, :kind, CAST(:material AS uuid), CAST(:color AS uuid), :alsoOrder, :prefill,
                            :actor, CAST(:workshop AS uuid))
                    """, new MapSqlParameterSource()
                    .addValue("product", product.goodsId())
                    .addValue("kind", kind)
                    .addValue("material", material == null ? null : material.goodsId().toString())
                    .addValue("color", material == null || material.colorId() == null ? null
                            : material.colorId().toString())
                    .addValue("alsoOrder", KIND_MATERIAL.equals(kind) && choice.alsoOrderMaterials())
                    .addValue("prefill", choice.prefillSource())
                    .addValue("actor", actor)
                    .addValue("workshop", workshop == null ? null : workshop.toString())));
        }
    }

    private boolean sameAsActive(UUID product, String kind, Set<MaterialRef> materials, boolean alsoOrder) {
        List<Map<String, Object>> active = db.queryForList("""
                SELECT kind, material_goods_id, material_color_id, also_order_materials
                FROM goods_periodic_material_choices WHERE product_goods_id = :product AND superseded_at IS NULL
                """, Map.of("product", product));
        if (active.isEmpty()) return false;
        Set<MaterialRef> current = new LinkedHashSet<>();
        for (Map<String, Object> row : active) {
            if (!kind.equals(row.get("kind"))) return false;
            if (KIND_MATERIAL.equals(kind)) {
                if (alsoOrder != Boolean.TRUE.equals(row.get("also_order_materials"))) return false;
                current.add(new MaterialRef((UUID) row.get("material_goods_id"), (UUID) row.get("material_color_id")));
            }
        }
        return KIND_NONE.equals(kind) || current.equals(materials);
    }

    @Override
    @Transactional
    public void supersedeForMaterial(UUID materialGoodsId, String reason) {
        if (materialGoodsId == null) return;
        if (!SUPERSEDE_ISSUE_METHOD_SWITCH.equals(reason)) {
            throw new IllegalArgumentException("unsupported supersede reason");
        }
        UUID actor = currentUser.id().orElse(null);
        WorkshopMaterialGuards.guarded(() -> db.update("""
                UPDATE goods_periodic_material_choices
                SET superseded_at = now(), superseded_by = CAST(:actor AS uuid), superseded_reason = :reason
                WHERE material_goods_id = :material AND superseded_at IS NULL
                """, new MapSqlParameterSource("actor", actor == null ? null : actor.toString())
                .addValue("reason", reason).addValue("material", materialGoodsId)));
    }

    /** 这些产品当前有效的认料。 */
    List<ChoiceView> activeChoices(Collection<UUID> products) {
        if (products.isEmpty()) return List.of();
        List<ChoiceView> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT choice.id, choice.product_goods_id, product.name AS product_name, choice.kind,
                       choice.material_goods_id, material.name AS material_name, choice.material_color_id,
                       choice.also_order_materials, choice.prefill_source, choice.chosen_at
                FROM goods_periodic_material_choices choice
                JOIN goods product ON product.id = choice.product_goods_id
                LEFT JOIN goods material ON material.id = choice.material_goods_id
                WHERE choice.product_goods_id IN (:products) AND choice.superseded_at IS NULL
                ORDER BY product.code, material.code, choice.id
                """, Map.of("products", List.copyOf(products)))) {
            out.add(new ChoiceView((UUID) row.get("id"), (UUID) row.get("product_goods_id"),
                    (String) row.get("product_name"), (String) row.get("kind"), (UUID) row.get("material_goods_id"),
                    (String) row.get("material_name"), (UUID) row.get("material_color_id"),
                    Boolean.TRUE.equals(row.get("also_order_materials")), (String) row.get("prefill_source"),
                    WorkshopMaterialBinSupport.offset(row.get("chosen_at"))));
        }
        return out;
    }

    // ------------------------------------------------------------------ 开工确认表

    @Override
    @Transactional(readOnly = true)
    public List<PendingChoice> pending(Collection<UUID> segmentIds) {
        if (segmentIds == null || segmentIds.isEmpty()) return List.of();
        MapSqlParameterSource params = new MapSqlParameterSource("ids", List.copyOf(new LinkedHashSet<>(segmentIds)));
        String inScope = scope.predicate("segment.workshop_department_id", params);
        Map<String, List<Map<String, Object>>> groups = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT segment.id, segment.product_goods_id, segment.workshop_department_id, segment.status,
                       segment.start_route, fn_segment_bin_material_state(segment.id) AS state
                FROM production_execution_segments segment
                WHERE segment.id IN (:ids) AND NOT segment.is_deleted
                """ + " AND " + inScope
                + " ORDER BY segment.workshop_department_id, segment.product_goods_id, segment.id", params)) {
            String state = (String) row.get("state");
            boolean needChoice = STATE_NEED_CHOICE.equals(state);
            boolean needRoute = row.get("start_route") == null && !STATE_NEED_BIN.equals(state);
            if (!NOT_STARTED.contains((String) row.get("status")) || !(needChoice || needRoute)) continue;
            groups.computeIfAbsent(row.get("workshop_department_id") + "|" + row.get("product_goods_id"),
                    key -> new ArrayList<>()).add(row);
        }
        List<PendingChoice> out = new ArrayList<>();
        for (List<Map<String, Object>> rows : groups.values()) {
            UUID workshop = (UUID) rows.getFirst().get("workshop_department_id");
            UUID product = (UUID) rows.getFirst().get("product_goods_id");
            List<UUID> segments = rows.stream().map(row -> (UUID) row.get("id")).toList();
            boolean choiceRequired = rows.stream().anyMatch(row -> STATE_NEED_CHOICE.equals(row.get("state")));
            out.add(pendingRow(workshop, product, segments, choiceRequired));
        }
        return out;
    }

    /** 开启整批领料前在产、还没认料的产品 (开启对话框一次认完)。 */
    List<PendingChoice> inProgressPending(UUID workshopDepartmentId) {
        Map<UUID, List<UUID>> byProduct = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList(IN_PROGRESS_NEED_CHOICE_SQL,
                Map.of("workshop", workshopDepartmentId))) {
            byProduct.computeIfAbsent((UUID) row.get("product_goods_id"), key -> new ArrayList<>())
                    .add((UUID) row.get("id"));
        }
        List<PendingChoice> out = new ArrayList<>();
        for (Map.Entry<UUID, List<UUID>> entry : byProduct.entrySet()) {
            out.add(pendingRow(workshopDepartmentId, entry.getKey(), entry.getValue(), true));
        }
        return out;
    }

    /**
     * 本车间正在生产、按开启后的口径会是"待认料"的段: 没有期间料行、没有未核清的整批领料按单需求、
     * 产品没有期间边、来源段没有有效期间料行、产品没有任何有效认料。
     */
    static final String IN_PROGRESS_NEED_CHOICE_SQL = """
            SELECT segment.id, segment.product_goods_id
            FROM production_execution_segments segment
            WHERE segment.workshop_department_id = :workshop AND segment.status = 'IN_PROGRESS'
              AND NOT segment.is_deleted
              AND NOT EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                              WHERE material_row.execution_segment_id = segment.id)
              AND NOT EXISTS (SELECT 1 FROM production_material_demands demand
                              JOIN goods material ON material.id = demand.goods_id AND material.issue_method = 'PERIODIC'
                              WHERE demand.execution_segment_id = segment.id
                                AND fn_material_demand_uncleared(demand.id))
              AND NOT fn_goods_has_periodic_bom(segment.product_goods_id)
              AND NOT EXISTS (
                  SELECT 1 FROM production_execution_periodic_materials source_row
                  WHERE source_row.effective_to IS NULL
                    AND source_row.execution_segment_id = COALESCE(segment.source_segment_id, (
                        SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
                        WHERE proof.supplement_execution_segment_id = segment.id
                        ORDER BY proof.created_at, proof.id LIMIT 1)))
              AND NOT EXISTS (SELECT 1 FROM goods_periodic_material_choices choice
                              WHERE choice.product_goods_id = segment.product_goods_id AND choice.superseded_at IS NULL)
            ORDER BY segment.product_goods_id, segment.id
            """;

    private static final String STATE_NEED_CHOICE = "NEED_CHOICE";
    private static final String STATE_NEED_BIN = "NEED_BIN";

    private PendingChoice pendingRow(UUID workshop, UUID product, List<UUID> segments, boolean choiceRequired) {
        MaterialInfo info = bins.material(product);
        Settings settings = workshop == null ? null : bins.settings(workshop);
        List<MaterialOption> options = options(settings);
        List<MaterialRef> prefill = new ArrayList<>();
        String prefillSource = null;
        for (Map<String, Object> row : db.queryForList("""
                SELECT material_goods_id, material_color_id FROM goods_periodic_material_choices
                WHERE product_goods_id = :product AND superseded_at IS NULL AND kind = 'MATERIAL'
                ORDER BY chosen_at, id
                """, Map.of("product", product))) {
            prefill.add(new MaterialRef((UUID) row.get("material_goods_id"), (UUID) row.get("material_color_id")));
        }
        if (prefill.isEmpty()) {
            for (Map<String, Object> row : db.queryForList("""
                    SELECT choice.material_goods_id, choice.material_color_id
                    FROM goods_periodic_material_choices choice
                    JOIN goods material ON material.id = choice.material_goods_id
                     AND material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN'
                     AND NOT material.is_deleted
                    WHERE choice.product_goods_id = :product AND choice.kind = 'MATERIAL'
                      AND choice.chosen_at = (SELECT max(previous.chosen_at) FROM goods_periodic_material_choices previous
                                              WHERE previous.product_goods_id = :product AND previous.kind = 'MATERIAL')
                    ORDER BY choice.id
                    """, Map.of("product", product))) {
                prefill.add(new MaterialRef((UUID) row.get("material_goods_id"), (UUID) row.get("material_color_id")));
            }
        }
        if (prefill.isEmpty()) {
            List<UUID> legacy = db.queryForList("""
                    WITH text AS (
                        SELECT lower(btrim(product.material)) AS value FROM goods product
                        WHERE product.id = :product AND length(btrim(COALESCE(product.material, ''))) > 0
                    )
                    SELECT material.id FROM goods material CROSS JOIN text
                    WHERE material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN'
                      AND NOT material.is_deleted
                      AND (lower(btrim(material.name)) = text.value OR lower(btrim(material.code)) = text.value
                           OR position(text.value IN lower(material.name)) > 0
                           OR position(lower(btrim(material.name)) IN text.value) > 0)
                    LIMIT 2
                    """, Map.of("product", product), UUID.class);
            if (legacy.size() == 1) {
                prefill.add(new MaterialRef(legacy.getFirst(), null));
                prefillSource = PREFILL_LEGACY_MATERIAL_TEXT;
            }
        }
        List<BomWeight> weights = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT bom.component_goods_id, COALESCE(bom.color_id, component.color_id) AS color_id, bom.qty,
                       unit.name AS unit_name
                FROM goods_bom_items bom
                JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
                LEFT JOIN units unit ON unit.id = component.unit_id
                WHERE bom.goods_id = :product AND NOT bom.is_deleted
                ORDER BY bom.sort_order, bom.id
                """, Map.of("product", product))) {
            weights.add(new BomWeight((UUID) row.get("component_goods_id"), (UUID) row.get("color_id"),
                    grams(WorkshopMaterialBinSupport.decimal(row.get("qty")), (String) row.get("unit_name"))));
        }
        boolean alsoOrderAllowed = !Boolean.TRUE.equals(flag("fn_goods_has_bom", product));
        return new PendingChoice(workshop, settings == null ? null : settings.workshopName(), product, info.code(),
                info.name(), segments, segments.size(), choiceRequired, prefill, prefillSource, options, weights,
                alsoOrderAllowed);
    }

    /** 本车间内料仓收的主料: 进过这个内料仓的排在前面, 其余整批领料主料随后。 */
    private List<MaterialOption> options(Settings settings) {
        MapSqlParameterSource params = new MapSqlParameterSource("bin",
                settings == null || settings.binWarehouseId() == null ? null : settings.binWarehouseId().toString());
        List<MaterialOption> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT material.id, material.color_id, material.code, material.name, color.name AS color_name,
                       EXISTS (SELECT 1 FROM v_workshop_material_bin_ledger ledger
                               WHERE ledger.bin_warehouse_id = CAST(:bin AS uuid) AND ledger.goods_id = material.id) AS used
                FROM goods material
                LEFT JOIN colors color ON color.id = material.color_id
                WHERE material.issue_method = 'PERIODIC' AND material.periodic_cost_basis = 'OWN'
                  AND NOT material.is_deleted
                ORDER BY used DESC, material.code, material.id
                LIMIT 300
                """, params)) {
            out.add(new MaterialOption((UUID) row.get("id"), (UUID) row.get("color_id"), (String) row.get("code"),
                    (String) row.get("name"), (String) row.get("color_name")));
        }
        return out;
    }

    /** BOM 单个重量换算成克: 基本单位是千克/公斤时乘 1000, 其它质量单位原样。 */
    static BigDecimal grams(BigDecimal qty, String unitName) {
        if (qty == null) return null;
        String unit = unitName == null ? "" : unitName.strip().toLowerCase(java.util.Locale.ROOT);
        if (Set.of("千克", "公斤", "kg", "kgs").contains(unit)) return qty.multiply(BigDecimal.valueOf(1000));
        return qty;
    }

    // ------------------------------------------------------------------ 换料 (段级)

    /** 这张工单从某天起改用别的料 (或加一种料); 原用料行写截止日, 已结算的期间不变。 */
    @Transactional
    public SegmentMaterials changeMaterial(UUID segmentId, MaterialChangeRequest request) {
        return commands.execute("MATERIAL_CHANGE", request.idempotencyKey(), List.of(segmentId, request),
                SegmentMaterials.class, () -> {
                    List<Map<String, Object>> segments = db.queryForList("""
                            SELECT id, status, lock_version, product_goods_id, workshop_department_id
                            FROM production_execution_segments WHERE id = :id AND NOT is_deleted FOR UPDATE
                            """, Map.of("id", segmentId));
                    if (segments.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "工单不存在");
                    Map<String, Object> segment = segments.getFirst();
                    UUID workshop = (UUID) segment.get("workshop_department_id");
                    scope.requireWorkshop(workshop);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(),
                            WorkshopMaterialBinSupport.number(segment.get("lock_version")).longValue(), "这张工单");
                    if (!"IN_PROGRESS".equals(segment.get("status"))) {
                        throw new ApiException(ErrorCode.CONFLICT, "只有生产中的工单才能改用别的料");
                    }
                    Settings settings = bins.enabledSettingsForShare(workshop);
                    UUID bin = settings.binWarehouseId();
                    Integer rows = db.queryForObject("""
                            SELECT count(*) FROM production_execution_periodic_materials
                            WHERE execution_segment_id = :segment AND bin_warehouse_id = :bin
                            """, Map.of("segment", segmentId, "bin", bin), Integer.class);
                    if (rows == null || rows == 0) {
                        throw new ApiException(ErrorCode.CONFLICT, "这张工单没有从车间内料仓用料, 不用换料");
                    }
                    if (request.toMaterialGoodsId() == null) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择改用哪种料");
                    }
                    MaterialInfo material = bins.material(request.toMaterialGoodsId());
                    if (!material.periodic() || !"OWN".equals(material.costBasis()) || material.deleted()) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED,
                                "「" + material.label() + "」不是整批领料的主料, 不能换成它");
                    }
                    bins.requireColor(request.toMaterialColorId());
                    LocalDate from = request.effectiveFrom();
                    LocalDate closedThrough = db.queryForObject("SELECT fn_workshop_material_closed_through(:bin)",
                            Map.of("bin", bin), LocalDate.class);
                    if (from == null || closedThrough != null && !from.isAfter(closedThrough)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "改用新料的日期要晚于内料仓已结算的截止日"
                                + (closedThrough == null ? "" : " " + closedThrough));
                    }
                    if (from.isAfter(BusinessTime.today())) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "改用新料的日期不能晚于今天");
                    }
                    String basis = request.weightBasis() == null || request.weightBasis().isBlank()
                            ? (request.fromRowId() == null ? "OWN_BOM" : "FROM_REPLACED") : request.weightBasis();
                    if (!Set.of("FROM_REPLACED", "OWN_BOM").contains(basis)
                            || "FROM_REPLACED".equals(basis) && request.fromRowId() == null) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "加一种料时只能按新料自己的 BOM 单个重量");
                    }
                    String reason = request.reason() == null || request.reason().isBlank() ? null : request.reason().strip();
                    if (reason != null && (reason.length() < 2 || reason.length() > 500)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "换料原因写 2 到 500 个字");
                    }
                    if (request.fromRowId() != null) {
                        List<Map<String, Object>> fromRows = db.queryForList("""
                                SELECT material_goods_id, material_color_id, effective_from
                                FROM production_execution_periodic_materials
                                WHERE id = :row AND execution_segment_id = :segment AND effective_to IS NULL
                                FOR UPDATE
                                """, Map.of("row", request.fromRowId(), "segment", segmentId));
                        if (fromRows.isEmpty()) {
                            throw new ApiException(ErrorCode.CONFLICT, "要换掉的那种料已经不在这张工单上用了, 请刷新");
                        }
                        Map<String, Object> fromRow = fromRows.getFirst();
                        if (from.isBefore(WorkshopMaterialBinSupport.date(fromRow.get("effective_from")))) {
                            throw new ApiException(ErrorCode.VALIDATION_FAILED, "改用新料的日期不能早于原来那种料开始用的日期");
                        }
                        if (Objects.equals(fromRow.get("material_goods_id"), material.goodsId())
                                && Objects.equals(fromRow.get("material_color_id"), request.toMaterialColorId())) {
                            throw new ApiException(ErrorCode.VALIDATION_FAILED, "新料和原来的料一样, 不用换");
                        }
                    }
                    UUID changeId = UUID.randomUUID();
                    UUID actor = currentUser.requireId();
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            INSERT INTO production_execution_material_changes(
                                id, execution_segment_id, from_row_id, to_material_goods_id, to_material_color_id,
                                effective_from, weight_basis, reason, created_by)
                            VALUES (:id, :segment, CAST(:fromRow AS uuid), :material, CAST(:color AS uuid), :from,
                                    :basis, :reason, :actor)
                            """, new MapSqlParameterSource("id", changeId).addValue("segment", segmentId)
                            .addValue("fromRow", request.fromRowId() == null ? null : request.fromRowId().toString())
                            .addValue("material", material.goodsId())
                            .addValue("color", request.toMaterialColorId() == null ? null
                                    : request.toMaterialColorId().toString())
                            .addValue("from", from).addValue("basis", basis).addValue("reason", reason)
                            .addValue("actor", actor)));
                    if (request.fromRowId() != null) {
                        WorkshopMaterialGuards.guarded(() -> db.update("""
                                UPDATE production_execution_periodic_materials SET effective_to = :to WHERE id = :row
                                """, new MapSqlParameterSource("to", from.minusDays(1))
                                .addValue("row", request.fromRowId())));
                    }
                    BigDecimal snapshot = "OWN_BOM".equals(basis) ? db.queryForObject(
                            "SELECT fn_workshop_material_edge_weight(:product, :material, CAST(:color AS uuid))",
                            new MapSqlParameterSource("product", segment.get("product_goods_id"))
                                    .addValue("material", material.goodsId())
                                    .addValue("color", request.toMaterialColorId() == null ? null
                                            : request.toMaterialColorId().toString()), BigDecimal.class) : null;
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            INSERT INTO production_execution_periodic_materials(
                                execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id,
                                origin, change_id, design_qty_snapshot, effective_from, created_by)
                            VALUES (:segment, :bin, :material, CAST(:color AS uuid), :unit, 'CHANGE', :change,
                                    :snapshot, :from, :actor)
                            """, new MapSqlParameterSource("segment", segmentId).addValue("bin", bin)
                            .addValue("material", material.goodsId())
                            .addValue("color", request.toMaterialColorId() == null ? null
                                    : request.toMaterialColorId().toString())
                            .addValue("unit", material.unitId()).addValue("change", changeId)
                            .addValue("snapshot", snapshot).addValue("from", from).addValue("actor", actor)));
                    // 换料结果进命令账本 (同号重放原样返回), 不带可换料清单; 页面要清单时重新读底稿。
                    return new Outcome<>(changeId, segmentMaterials(segmentId, bin, settings, false));
                });
    }

    /**
     * 换料对话框的底稿: 这张工单现在用的料 (含已换下的)、可换的料、最早可以从哪天起改、段的最新版本。
     * 车间成员只能看本车间的工单 (对象范围); 读不改。
     */
    @Transactional(readOnly = true)
    public SegmentMaterials segmentMaterials(UUID segmentId) {
        if (segmentId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择工单");
        List<Map<String, Object>> segments = db.queryForList("""
                SELECT workshop_department_id FROM production_execution_segments WHERE id = :id AND NOT is_deleted
                """, Map.of("id", segmentId));
        if (segments.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "工单不存在");
        UUID workshop = (UUID) segments.getFirst().get("workshop_department_id");
        if (workshop == null) {
            throw new ApiException(ErrorCode.CONFLICT, "这张工单还没有分到车间, 没有从车间内料仓用的料");
        }
        scope.requireWorkshop(workshop);
        Settings settings = bins.settings(workshop);
        List<UUID> rowBins = db.queryForList("""
                SELECT bin_warehouse_id FROM production_execution_periodic_materials
                WHERE execution_segment_id = :segment
                ORDER BY effective_from DESC, created_at DESC, id
                LIMIT 1
                """, Map.of("segment", segmentId), UUID.class);
        UUID bin = !rowBins.isEmpty() ? rowBins.getFirst() : settings == null ? null : settings.binWarehouseId();
        return segmentMaterials(segmentId, bin, settings, true);
    }

    SegmentMaterials segmentMaterials(UUID segmentId, UUID bin, Settings settings, boolean withOptions) {
        List<PeriodicRowView> rows = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT material_row.id, material_row.material_goods_id, material.code, material.name,
                       material_row.material_color_id, color.name AS color_name, material_row.origin,
                       material_row.effective_from, material_row.effective_to, material_row.design_qty_snapshot,
                       (fn_workshop_material_unit_weight(material_row.id)).unit_weight AS unit_weight,
                       unit.name AS unit_name
                FROM production_execution_periodic_materials material_row
                JOIN goods material ON material.id = material_row.material_goods_id
                LEFT JOIN colors color ON color.id = material_row.material_color_id
                LEFT JOIN units unit ON unit.id = material_row.unit_id
                WHERE material_row.execution_segment_id = :segment
                ORDER BY material_row.effective_from, material_row.created_at, material_row.id
                """, Map.of("segment", segmentId))) {
            rows.add(new PeriodicRowView((UUID) row.get("id"), (UUID) row.get("material_goods_id"),
                    (String) row.get("code"), (String) row.get("name"), (UUID) row.get("material_color_id"),
                    (String) row.get("color_name"), (String) row.get("origin"),
                    WorkshopMaterialBinSupport.date(row.get("effective_from")),
                    WorkshopMaterialBinSupport.date(row.get("effective_to")),
                    WorkshopMaterialBinSupport.decimal(row.get("design_qty_snapshot")),
                    gramsOrNull(WorkshopMaterialBinSupport.decimal(row.get("unit_weight")),
                            (String) row.get("unit_name"))));
        }
        long lockVersion = WorkshopMaterialBinSupport.number(db.queryForObject(
                "SELECT lock_version FROM production_execution_segments WHERE id = :id",
                Map.of("id", segmentId), Long.class)).longValue();
        LocalDate earliest = null;
        if (bin != null) {
            LocalDate closedThrough = db.queryForObject("SELECT fn_workshop_material_closed_through(:bin)",
                    Map.of("bin", bin), LocalDate.class);
            earliest = closedThrough == null ? null : closedThrough.plusDays(1);
        }
        return new SegmentMaterials(segmentId, bin, lockVersion, earliest, rows,
                withOptions ? options(settings) : List.of());
    }

    /** 单个重量换算成克; 只认千克、克两类质量单位 (按单位名), 其它单位给空, 不猜。 */
    static BigDecimal gramsOrNull(BigDecimal qty, String unitName) {
        if (qty == null || unitName == null) return null;
        String unit = unitName.strip().toLowerCase(java.util.Locale.ROOT);
        if (Set.of("千克", "公斤", "kg", "kgs").contains(unit)) {
            return qty.multiply(BigDecimal.valueOf(1000));
        }
        if (Set.of("克", "g", "公克").contains(unit)) return qty;
        return null;
    }

    private Boolean flag(String function, UUID goods) {
        // function 只取本类里写死的两个函数名, 不是请求输入。
        if (!Set.of("fn_goods_has_bom", "fn_goods_has_periodic_bom").contains(function)) {
            throw new IllegalArgumentException("unsupported function");
        }
        return db.queryForObject("SELECT " + function + "(:goods)", Map.of("goods", goods), Boolean.class);
    }
}
