package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Material;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.MaterialInfo;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ContainerSlot;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CorrectCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountDetail;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MachineCard;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialSlot;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ZeroRestRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ZeroRestResult;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * 车间内料仓盘点 (ADR-131 §5.7): 逐行保存 (两人可同时录, 行级版本)、"其余记 0"、提交、更正,
 * 以及已盘点后补录的自动更正。
 *
 * <p>提交时建或更新期间用量行 (实际 = 期初 + 领入 - 退回 - 其它耗用 - 期末), 当场按净额过账:
 * 实际大于 0 记 21 型耗用出库, 小于 0 记 22 型盘盈入库。更正与补录都走同一个过账调整规则
 * ({@link #adjust}): 任何时候净 21 型 = max(实际, 0)、净 22 型 = max(-实际, 0), 冲回只原路冲。
 */
@Service
public class WorkshopMaterialCountService {

    private static final Pattern LINE_KEY = Pattern.compile("^[A-Za-z0-9._:-]{1,80}$");
    private static final Set<String> LINE_KINDS = Set.of("FULL_BAGS", "CONTAINER", "WEIGHED");
    private static final Set<String> WEIGH_NOTES = Set.of("OPEN_BAG", "MIXED", "LOOSE");
    private static final Set<String> FILL_LEVELS = Set.of("FULL", "HALF", "EMPTY", "WEIGHED");

    /** 盘点单表头。 */
    record Count(UUID id, UUID periodId, int version, String status, String correctionReason, long rowVersion) {}

    /** 期间用量行 (过账调整用)。 */
    private record PeriodLine(UUID id, UUID goodsId, UUID colorId, UUID unitId, BigDecimal actual) {}

    /** 一条尚未冲完的过账。 */
    private record OpenPosting(UUID id, BigDecimal remaining) {}

    /** 一行盘点保存时的版本冲突: 带回最新那一行。 */
    public static final class LineConflict extends ApiException {
        private final transient CountLineView latest;

        LineConflict(CountLineView latest) {
            super(ErrorCode.CONFLICT, "这一行刚被别人改过, 已显示最新的数, 请核对后再保存");
            this.latest = latest;
        }

        public CountLineView latest() {
            return latest;
        }
    }

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialStockGateway gateway;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final WorkshopMaterialPeriodViews periodViews;
    private final ObjectProvider<WorkshopMaterialCloseRequester> closeRequests;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialCountService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                        WorkshopMaterialStockGateway gateway, WorkshopMaterialCommandLedger commands,
                                        WorkshopMaterialScope scope, WorkshopMaterialPermissions permissions,
                                        WorkshopMaterialPeriodViews periodViews,
                                        ObjectProvider<WorkshopMaterialCloseRequester> closeRequests,
                                        SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.gateway = gateway;
        this.commands = commands;
        this.scope = scope;
        this.permissions = permissions;
        this.periodViews = periodViews;
        this.closeRequests = closeRequests;
        this.currentUser = currentUser;
    }

    // ------------------------------------------------------------------ 查看

    @Transactional(readOnly = true)
    public CountDetail detail(UUID countId) {
        Count count = count(countId, false);
        Period period = bins.period(count.periodId());
        scope.requireWorkshop(period.workshopDepartmentId());
        return detailOf(count, period);
    }

    // ------------------------------------------------------------------ 逐行保存

    /** 保存一行 (新行或改行); 行版本不符时带回最新那一行。 */
    @Transactional
    public CountLineView saveLine(UUID countId, String clientLineKey, CountLineInput input) {
        String key = requireLineKey(clientLineKey);
        if (input == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "盘点行内容为空");
        Count count = count(countId, false);
        Period period = bins.period(count.periodId());
        scope.requireWorkshop(period.workshopDepartmentId());
        requireDraft(count);
        LineValues values = validate(period, input);
        MapSqlParameterSource params = values.params()
                .addValue("count", countId).addValue("key", key).addValue("actor", currentUser.requireId());
        CountLineView existing = line(countId, key);
        if (existing == null) {
            if (input.expectedVersion() != null) throw new ApiException(ErrorCode.CONFLICT, "这一行已被别人删掉, 请刷新");
            if (values.containerId() != null && containerTaken(countId, values.containerId(), key)) {
                throw new ApiException(ErrorCode.CONFLICT, "这个容器已经录过了, 请在原来那一行上改");
            }
            List<UUID> inserted = db.queryForList("""
                    INSERT INTO workshop_material_count_lines(
                        count_id, client_line_key, line_kind, weigh_note, goods_id, color_id, unit_id, bag_count,
                        bag_net_qty, weighed_qty, machine_id, container_id, capacity_qty_snapshot, fill_level,
                        entered_by)
                    VALUES (:count, :key, :kind, :note, CAST(:goods AS uuid), CAST(:color AS uuid), CAST(:unit AS uuid),
                            :bagCount, :bagNet, :weighed, CAST(:machine AS uuid), CAST(:container AS uuid), :capacity,
                            :fill, :actor)
                    ON CONFLICT (count_id, client_line_key) DO NOTHING
                    RETURNING id
                    """, params, UUID.class);
            if (inserted.isEmpty()) throw new LineConflict(line(countId, key));
        } else {
            if (input.expectedVersion() == null || input.expectedVersion() != existing.rowVersion()) {
                throw new LineConflict(existing);
            }
            if (values.containerId() != null && containerTaken(countId, values.containerId(), key)) {
                throw new ApiException(ErrorCode.CONFLICT, "这个容器已经录过了, 请在原来那一行上改");
            }
            params.addValue("expected", input.expectedVersion());
            int updated = db.update("""
                    UPDATE workshop_material_count_lines
                    SET line_kind = :kind, weigh_note = :note, goods_id = CAST(:goods AS uuid),
                        color_id = CAST(:color AS uuid), unit_id = CAST(:unit AS uuid), bag_count = :bagCount,
                        bag_net_qty = :bagNet, weighed_qty = :weighed, machine_id = CAST(:machine AS uuid),
                        container_id = CAST(:container AS uuid), capacity_qty_snapshot = :capacity,
                        fill_level = :fill, entered_by = :actor, entered_at = now(), row_version = row_version + 1
                    WHERE count_id = :count AND client_line_key = :key AND row_version = :expected
                    """, params);
            if (updated != 1) throw new LineConflict(line(countId, key));
        }
        return line(countId, key);
    }

    @Transactional
    public void deleteLine(UUID countId, String clientLineKey, Long expectedVersion) {
        String key = requireLineKey(clientLineKey);
        Count count = count(countId, false);
        Period period = bins.period(count.periodId());
        scope.requireWorkshop(period.workshopDepartmentId());
        requireDraft(count);
        CountLineView existing = line(countId, key);
        if (existing == null) return;
        if (expectedVersion == null || expectedVersion != existing.rowVersion()) throw new LineConflict(existing);
        int deleted = db.update("""
                DELETE FROM workshop_material_count_lines
                WHERE count_id = :count AND client_line_key = :key AND row_version = :expected
                """, new MapSqlParameterSource("count", countId).addValue("key", key)
                .addValue("expected", expectedVersion));
        if (deleted != 1) throw new LineConflict(line(countId, key));
    }

    /** "其余料都用完了, 记 0": 有账或本期有进出、但还没录的料各记一行 0。 */
    @Transactional
    public ZeroRestResult zeroRest(UUID countId, ZeroRestRequest request) {
        return commands.execute("COUNT_ZERO_REST", request.idempotencyKey(), List.of(countId, request),
                ZeroRestResult.class, () -> {
                    Count count = count(countId, true);
                    Period period = bins.period(count.periodId());
                    scope.requireWorkshop(period.workshopDepartmentId());
                    requireDraft(count);
                    List<CountLineView> added = new ArrayList<>();
                    Set<Material> counted = countedMaterials(countId);
                    for (Map<String, Object> row : neededMaterials(period.id())) {
                        Material material = new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id"));
                        if (counted.contains(material)) continue;
                        MaterialInfo info = bins.material(material.goodsId());
                        String key = "Z-" + material.goodsId()
                                + (material.colorId() == null ? "" : ":" + material.colorId());
                        db.update("""
                                INSERT INTO workshop_material_count_lines(
                                    count_id, client_line_key, line_kind, goods_id, color_id, unit_id, weighed_qty,
                                    entered_by)
                                VALUES (:count, :key, 'WEIGHED', :goods, CAST(:color AS uuid), :unit, 0, :actor)
                                ON CONFLICT (count_id, client_line_key) DO NOTHING
                                """, new MapSqlParameterSource("count", countId).addValue("key", key)
                                .addValue("goods", material.goodsId())
                                .addValue("color", material.colorId() == null ? null : material.colorId().toString())
                                .addValue("unit", info.unitId()).addValue("actor", currentUser.requireId()));
                        CountLineView view = line(countId, key);
                        if (view != null) added.add(view);
                    }
                    return new Outcome<>(countId, new ZeroRestResult(added));
                });
    }

    // ------------------------------------------------------------------ 提交与更正

    /**
     * 提交盘点 (第一版或更正版): 核对覆盖 → 建或更新期间用量行 → 按过账调整规则过 21/22 型 →
     * 期间改为已盘点、排队结算, 提交后立即尝试结算。
     */
    @Transactional
    public PeriodView submit(UUID countId, VersionRequest request) {
        return commands.execute("COUNT_SUBMIT", request.idempotencyKey(), List.of(countId, request),
                PeriodView.class, () -> {
                    Count draft = count(countId, false);
                    Period loose = bins.period(draft.periodId());
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    Settings settings = bins.enabledSettingsForUpdate(loose.workshopDepartmentId());
                    Period period = bins.periodForUpdate(loose.id());
                    Count count = count(countId, true);
                    requireDraft(count);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), count.rowVersion(), "盘点单");
                    boolean correction = count.version() > 1;
                    if (!correction && !"COUNTING".equals(period.status())
                            || correction && !"COUNTED".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期的状态已经变了, 请刷新后再提交");
                    }
                    if (!WorkshopMaterialBinSupport.same(settings.binWarehouseId(), period.binWarehouseId())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期不属于本车间在用的内料仓");
                    }
                    Period previous = bins.periodByNo(period.binWarehouseId(), period.no() - 1);
                    if (previous != null && !Set.of("COUNTED", "CLOSED").contains(previous.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "上一期还没有提交盘点, 请先提交上一期");
                    }
                    requireCoverage(period, countId);

                    Map<Material, BigDecimal> closing = closingByMaterial(countId);
                    Set<Material> universe = new LinkedHashSet<>(closing.keySet());
                    for (Map<String, Object> row : neededMaterials(period.id())) {
                        universe.add(new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id")));
                    }
                    gateway.lockInventory(universe);

                    UUID actor = currentUser.requireId();
                    if (correction) {
                        db.update("""
                                UPDATE workshop_material_counts SET status = 'SUPERSEDED', row_version = row_version + 1
                                WHERE period_id = :period AND status = 'SUBMITTED'
                                """, Map.of("period", period.id()));
                    }
                    db.update("""
                            UPDATE workshop_material_counts
                            SET status = 'SUBMITTED', submitted_by = :actor, submitted_at = now(),
                                row_version = row_version + 1
                            WHERE id = :id
                            """, new MapSqlParameterSource("actor", actor).addValue("id", countId));
                    List<UUID> lines = new ArrayList<>();
                    for (Material material : universe) {
                        lines.add(upsertPeriodLine(period, material,
                                closing.getOrDefault(material, BigDecimal.ZERO)));
                    }
                    String reason = correction ? "CORRECTION" : "SUBMIT";
                    for (UUID line : lines) {
                        adjust(line, countId, reason, period);
                    }
                    db.update("""
                            UPDATE workshop_material_periods
                            SET status = 'COUNTED',
                                close_state = CASE WHEN close_state = 'HELD' THEN 'HELD' ELSE 'QUEUED' END,
                                close_blockers = CASE WHEN close_state = 'HELD' THEN close_blockers ELSE '[]'::jsonb END,
                                row_version = row_version + 1
                            WHERE id = :id
                            """, Map.of("id", period.id()));
                    requestClose(period.id(), actor);
                    return new Outcome<>(period.id(), periodViews.view(period.id()));
                });
    }

    /** 更正盘点: 只在已盘点 (含撤销结算后) 且下一期还没提交盘点时; 出新版本, 预置上一版全部行。 */
    @Transactional
    public CountDetail correct(UUID periodId, CorrectCountRequest request) {
        String reason = request.reason() == null ? "" : request.reason().strip();
        if (reason.length() < 2 || reason.length() > 500) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明更正原因 (2 到 500 个字)");
        }
        return commands.execute("COUNT_CORRECT", request.idempotencyKey(), List.of(periodId, request),
                CountDetail.class, () -> {
                    Period loose = bins.period(periodId);
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    bins.enabledSettingsForUpdate(loose.workshopDepartmentId());
                    Period period = bins.periodForUpdate(periodId);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), period.rowVersion(), "这一期");
                    if (!"COUNTED".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "只有已盘点、还没结算的那一期才能更正盘点");
                    }
                    Period next = bins.periodByNo(period.binWarehouseId(), period.no() + 1);
                    if (next != null && !Set.of("OPEN", "COUNTING").contains(next.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "下一期已经提交盘点, 这一期不能再更正");
                    }
                    Integer drafts = db.queryForObject("""
                            SELECT count(*) FROM workshop_material_counts WHERE period_id = :period AND status = 'DRAFT'
                            """, Map.of("period", periodId), Integer.class);
                    if (drafts != null && drafts > 0) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期已经有一张更正中的盘点单, 请继续录那一张");
                    }
                    UUID previousCount = submittedCountId(periodId);
                    Integer latest = db.queryForObject(
                            "SELECT max(version) FROM workshop_material_counts WHERE period_id = :period",
                            Map.of("period", periodId), Integer.class);
                    int version = (latest == null ? 0 : latest) + 1;
                    UUID countId = UUID.randomUUID();
                    UUID actor = currentUser.requireId();
                    db.update("""
                            INSERT INTO workshop_material_counts(id, period_id, version, correction_reason, created_by)
                            VALUES (:id, :period, :version, :reason, :actor)
                            """, new MapSqlParameterSource("id", countId).addValue("period", periodId)
                            .addValue("version", version).addValue("reason", reason).addValue("actor", actor));
                    db.update("""
                            INSERT INTO workshop_material_count_lines(
                                count_id, client_line_key, line_kind, weigh_note, goods_id, color_id, unit_id,
                                bag_count, bag_net_qty, weighed_qty, machine_id, container_id, capacity_qty_snapshot,
                                fill_level, entered_by)
                            SELECT :count, client_line_key, line_kind, weigh_note, goods_id, color_id, unit_id,
                                   bag_count, bag_net_qty, weighed_qty, machine_id, container_id,
                                   capacity_qty_snapshot, fill_level, :actor
                            FROM workshop_material_count_lines WHERE count_id = :previous
                            """, new MapSqlParameterSource("count", countId).addValue("actor", actor)
                            .addValue("previous", previousCount));
                    return new Outcome<>(countId, detailOf(count(countId, false), bins.period(periodId)));
                });
    }

    // ------------------------------------------------------------------ 补录 (由领料单服务在同一事务调用)

    /** 补录进已盘点那一期的料必须在那一期的盘点里盘到过 (期末不知道, 不能默认 0)。 */
    void requireCountedMaterials(Period period, Collection<Material> materials) {
        for (Material material : materials) {
            Integer found = db.queryForObject("""
                    SELECT count(*) FROM workshop_material_period_lines
                    WHERE period_id = :period AND goods_id = :goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                    """, params(period.id(), material), Integer.class);
            if (found == null || found == 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + bins.material(material.goodsId()).label()
                        + "」在这一期的盘点里没有盘到, 请先更正盘点补上实盘数");
            }
        }
    }

    /**
     * 已盘点后补录: 期间用量行的领入加上补录量 (期末实盘不变, 实际用量随之增加), 按过账调整规则追加过账,
     * 提交后立即尝试结算。调用方已锁设置行、该期与库存维度。
     */
    void applySupplement(Period period, Collection<Material> materials) {
        UUID countId = submittedCountId(period.id());
        for (Material material : materials) {
            MapSqlParameterSource params = params(period.id(), material);
            List<UUID> line = db.queryForList("""
                    SELECT id FROM workshop_material_period_lines
                    WHERE period_id = :period AND goods_id = :goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                    FOR UPDATE
                    """, params, UUID.class);
            if (line.isEmpty()) continue;
            db.update("""
                    UPDATE workshop_material_period_lines
                    SET transfer_in_qty = COALESCE((
                            SELECT sum(ledger.signed_qty) FROM v_workshop_material_bin_ledger ledger
                            WHERE ledger.period_id = :period AND ledger.source_kind = 'ISSUE'
                              AND ledger.goods_id = :goods AND ledger.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)), 0),
                        row_version = row_version + 1
                    WHERE id = :line
                    """, params.addValue("line", line.getFirst()));
            adjust(line.getFirst(), countId, "SUPPLEMENT", period);
        }
        db.update("""
                UPDATE workshop_material_periods
                SET close_state = CASE WHEN close_state = 'HELD' THEN 'HELD' ELSE 'QUEUED' END,
                    close_blockers = CASE WHEN close_state = 'HELD' THEN close_blockers ELSE '[]'::jsonb END,
                    row_version = row_version + 1
                WHERE id = :id
                """, Map.of("id", period.id()));
        requestClose(period.id(), currentUser.requireId());
    }

    // ------------------------------------------------------------------ 期间用量行与过账

    /** 建或更新一种料的期间用量行; 期初取上一期期末, 进出取本期流水, 期末取实盘合计。 */
    private UUID upsertPeriodLine(Period period, Material material, BigDecimal closing) {
        MapSqlParameterSource params = params(period.id(), material)
                .addValue("bin", period.binWarehouseId()).addValue("previousNo", period.no() - 1)
                .addValue("closing", MoneyPolicy.quantity(closing));
        Map<String, Object> figures = db.queryForMap("""
                SELECT fn_workshop_material_period_opening(:period,:goods,CAST(:color AS uuid)) AS opening,
                       COALESCE(sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'ISSUE'), 0) AS transfer_in,
                       COALESCE(-sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'RETURN'), 0) AS returned,
                       COALESCE(-sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'OTHER_ISSUE'), 0) AS other,
                       COALESCE(sum(ledger.signed_qty) FILTER (WHERE ledger.source_kind = 'ADJUSTMENT'), 0) AS adjustment
                FROM v_workshop_material_bin_ledger ledger
                WHERE ledger.period_id = :period AND ledger.goods_id = :goods
                  AND ledger.color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                """, params);
        params.addValue("opening", figures.get("opening")).addValue("transferIn", figures.get("transfer_in"))
                .addValue("returned", figures.get("returned")).addValue("other", figures.get("other"))
                .addValue("adjustment", figures.get("adjustment"));
        List<UUID> existing = db.queryForList("""
                SELECT id FROM workshop_material_period_lines
                WHERE period_id = :period AND goods_id = :goods AND color_id IS NOT DISTINCT FROM CAST(:color AS uuid)
                FOR UPDATE
                """, params, UUID.class);
        if (!existing.isEmpty()) {
            UUID id = existing.getFirst();
            db.update("""
                    UPDATE workshop_material_period_lines
                    SET opening_qty = :opening, transfer_in_qty = :transferIn, return_qty = :returned,
                        other_issue_qty = :other, adjustment_qty = :adjustment, closing_qty = :closing, row_version = row_version + 1
                    WHERE id = :line
                    """, params.addValue("line", id));
            return id;
        }
        MaterialInfo info = bins.material(material.goodsId());
        if (!info.periodic() || info.costBasis() == null) {
            throw new ApiException(ErrorCode.CONFLICT, "「" + info.label() + "」已经不是整批领料的料, 不能盘点");
        }
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO workshop_material_period_lines(
                    id, period_id, goods_id, color_id, unit_id, cost_basis, opening_qty, transfer_in_qty, return_qty,
                    other_issue_qty, adjustment_qty, closing_qty)
                VALUES (:line, :period, :goods, CAST(:color AS uuid), :unit, :basis, :opening, :transferIn, :returned,
                        :other, :adjustment, :closing)
                """, params.addValue("line", id).addValue("unit", info.unitId()).addValue("basis", info.costBasis()));
        return id;
    }

    /**
     * 过账调整规则 (唯一一处; 提交、更正、已盘点补录共用)。设实际用量 A、现有净 21 型 C、净 22 型 G:
     * A >= 0 时先把未冲完的 22 型全部原路冲回, 再把 21 型调到正好 A (多了追加, 少了按倒序原路冲回);
     * A < 0 时先把未冲完的 21 型全部原路冲回, 再把 22 型调到正好 -A。
     */
    private void adjust(UUID lineId, UUID countId, String reason, Period period) {
        Map<String, Object> row = db.queryForMap("""
                SELECT id, goods_id, color_id, unit_id, actual_qty FROM workshop_material_period_lines WHERE id = :id
                """, Map.of("id", lineId));
        PeriodLine line = new PeriodLine((UUID) row.get("id"), (UUID) row.get("goods_id"), (UUID) row.get("color_id"),
                (UUID) row.get("unit_id"), WorkshopMaterialBinSupport.zero(row.get("actual_qty")));
        List<OpenPosting> consumes = open(lineId, "CONSUME", "CONSUME_REVERSE");
        List<OpenPosting> gains = open(lineId, "GAIN", "GAIN_REVERSE");
        BigDecimal consumed = total(consumes);
        BigDecimal gained = total(gains);
        BigDecimal actual = line.actual();
        if (actual.signum() >= 0) {
            for (OpenPosting gain : gains) {
                post(line, countId, "GAIN_REVERSE", gain.id(), gain.remaining(), reason, period);
            }
            if (actual.compareTo(consumed) > 0) {
                post(line, countId, "CONSUME", null, actual.subtract(consumed), reason, period);
            } else if (actual.compareTo(consumed) < 0) {
                reverse(line, countId, "CONSUME_REVERSE", consumes, consumed.subtract(actual), reason, period);
            }
        } else {
            BigDecimal gain = actual.negate();
            for (OpenPosting consume : consumes) {
                post(line, countId, "CONSUME_REVERSE", consume.id(), consume.remaining(), reason, period);
            }
            if (gain.compareTo(gained) > 0) {
                post(line, countId, "GAIN", null, gain.subtract(gained), reason, period);
            } else if (gain.compareTo(gained) < 0) {
                reverse(line, countId, "GAIN_REVERSE", gains, gained.subtract(gain), reason, period);
            }
        }
    }

    /** 按倒序 (最近的先冲) 原路冲回共 amount。 */
    private void reverse(PeriodLine line, UUID countId, String kind, List<OpenPosting> postings, BigDecimal amount,
                         String reason, Period period) {
        BigDecimal need = amount;
        for (OpenPosting posting : postings) {
            if (need.signum() <= 0) break;
            BigDecimal take = posting.remaining().min(need);
            post(line, countId, kind, posting.id(), take, reason, period);
            need = need.subtract(take);
        }
    }

    private void post(PeriodLine line, UUID countId, String kind, UUID reverses, BigDecimal qty, String reason,
                      Period period) {
        if (qty.signum() <= 0) return;
        gateway.countPosting(line.id(), countId, period.binWarehouseId(), line.goodsId(), line.colorId(),
                line.unitId(), kind, reverses, MoneyPolicy.quantity(qty), period.endDate(), reason);
    }

    /** 某类过账里还没冲完的, 最近的在前。 */
    private List<OpenPosting> open(UUID lineId, String kind, String reverseKind) {
        List<OpenPosting> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT posting.id, posting.qty - COALESCE((
                           SELECT sum(reversal.qty) FROM workshop_material_count_postings reversal
                           WHERE reversal.reverses_posting_id = posting.id AND reversal.kind = :reverseKind), 0) AS remaining
                FROM workshop_material_count_postings posting
                WHERE posting.period_line_id = :line AND posting.kind = :kind
                ORDER BY posting.created_at DESC, posting.id DESC
                """, new MapSqlParameterSource("line", lineId).addValue("kind", kind)
                .addValue("reverseKind", reverseKind))) {
            BigDecimal remaining = WorkshopMaterialBinSupport.zero(row.get("remaining"));
            if (remaining.signum() > 0) out.add(new OpenPosting((UUID) row.get("id"), remaining));
        }
        return out;
    }

    private static BigDecimal total(List<OpenPosting> postings) {
        return postings.stream().map(OpenPosting::remaining).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    // ------------------------------------------------------------------ 覆盖核对

    /** 提交时断言: 本车间启用机台的每个启用容器都有一行; 有账或本期有进出的每种料至少一行。 */
    private void requireCoverage(Period period, UUID countId) {
        List<String> containers = db.queryForList("""
                SELECT machine.name || ' ' || container.name
                FROM workshop_machines machine
                JOIN workshop_machine_containers container ON container.machine_id = machine.id
                WHERE machine.workshop_department_id = :workshop AND machine.enabled AND NOT machine.is_deleted
                  AND container.enabled AND NOT container.is_deleted
                  AND NOT EXISTS (SELECT 1 FROM workshop_material_count_lines line
                                  WHERE line.count_id = :count AND line.container_id = container.id)
                ORDER BY machine.sort_order, machine.code, container.sort_order, container.name
                """, new MapSqlParameterSource("workshop", period.workshopDepartmentId()).addValue("count", countId),
                String.class);
        Set<Material> counted = countedMaterials(countId);
        List<String> materials = new ArrayList<>();
        for (Map<String, Object> row : neededMaterials(period.id())) {
            Material material = new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id"));
            if (!counted.contains(material)) materials.add(bins.material(material.goodsId()).label());
        }
        if (containers.isEmpty() && materials.isEmpty()) return;
        StringBuilder message = new StringBuilder("还没盘完: ");
        if (!containers.isEmpty()) {
            message.append(containers.size()).append(" 个容器没录 (").append(sample(containers)).append(")");
        }
        if (!materials.isEmpty()) {
            if (!containers.isEmpty()) message.append("; ");
            message.append(materials.size()).append(" 种料没盘 (").append(sample(materials))
                    .append("), 没有了请点\"其余料都用完了, 记 0\"");
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, message.toString());
    }

    private static String sample(List<String> names) {
        List<String> head = names.subList(0, Math.min(5, names.size()));
        return String.join("、", head) + (names.size() > 5 ? " 等" : "");
    }

    /**
     * 这一期必须盘到的料: 截至本期盘点过账之前账面不为 0, 或本期有发料、退回、其它耗用, 或已有期间用量行。
     * book_qty 为截至本期盘点过账之前的账面。
     */
    private List<Map<String, Object>> neededMaterials(UUID periodId) {
        return db.queryForList("""
                WITH target AS (
                    SELECT period.id, period.bin_warehouse_id, period.period_no
                    FROM workshop_material_periods period WHERE period.id = :period
                ), book AS (
                    SELECT ledger.goods_id, ledger.color_id, sum(ledger.signed_qty) AS qty
                    FROM target
                    JOIN workshop_material_periods ledger_period
                      ON ledger_period.bin_warehouse_id = target.bin_warehouse_id
                     AND ledger_period.period_no <= target.period_no
                    JOIN v_workshop_material_bin_ledger ledger ON ledger.period_id = ledger_period.id
                    WHERE ledger_period.period_no < target.period_no
                       OR ledger.source_kind IN ('ISSUE', 'RETURN', 'OTHER_ISSUE')
                    GROUP BY ledger.goods_id, ledger.color_id
                ), wanted AS (
                    SELECT book.goods_id, book.color_id FROM book WHERE book.qty <> 0
                    UNION
                    SELECT ledger.goods_id, ledger.color_id FROM v_workshop_material_bin_ledger ledger
                    WHERE ledger.period_id = :period AND ledger.source_kind IN ('ISSUE', 'RETURN', 'OTHER_ISSUE')
                    UNION
                    SELECT line.goods_id, line.color_id FROM workshop_material_period_lines line
                    WHERE line.period_id = :period
                )
                SELECT wanted.goods_id, wanted.color_id, COALESCE(book.qty, 0) AS book_qty
                FROM wanted
                LEFT JOIN book ON book.goods_id = wanted.goods_id AND book.color_id IS NOT DISTINCT FROM wanted.color_id
                ORDER BY wanted.goods_id, wanted.color_id
                """, Map.of("period", periodId));
    }

    private Set<Material> countedMaterials(UUID countId) {
        Set<Material> out = new LinkedHashSet<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT DISTINCT goods_id, color_id FROM workshop_material_count_lines
                WHERE count_id = :count AND goods_id IS NOT NULL
                """, Map.of("count", countId))) {
            out.add(new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id")));
        }
        return out;
    }

    private Map<Material, BigDecimal> closingByMaterial(UUID countId) {
        Map<Material, BigDecimal> out = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT goods_id, color_id, COALESCE(sum(qty_base), 0) AS qty FROM workshop_material_count_lines
                WHERE count_id = :count AND goods_id IS NOT NULL
                GROUP BY goods_id, color_id ORDER BY goods_id, color_id
                """, Map.of("count", countId))) {
            out.put(new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id")),
                    WorkshopMaterialBinSupport.zero(row.get("qty")));
        }
        return out;
    }

    // ------------------------------------------------------------------ 盘点单读写

    /** 期间开始盘点时建第一版盘点单 (由期间服务在同一事务调用)。 */
    UUID createFirstCount(UUID periodId) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO workshop_material_counts(id, period_id, version, created_by) VALUES (:id, :period, 1, :actor)
                """, new MapSqlParameterSource("id", id).addValue("period", periodId)
                .addValue("actor", currentUser.requireId()));
        return id;
    }

    /** 撤回盘点: 删掉还是草稿的盘点单与它的行。 */
    void deleteDrafts(UUID periodId) {
        db.update("""
                DELETE FROM workshop_material_count_lines
                WHERE count_id IN (SELECT id FROM workshop_material_counts WHERE period_id = :period AND status = 'DRAFT')
                """, Map.of("period", periodId));
        db.update(
                "DELETE FROM workshop_material_counts WHERE period_id = :period AND status = 'DRAFT'",
                Map.of("period", periodId));
    }

    CountDetail detailOf(UUID countId) {
        Count count = count(countId, false);
        return detailOf(count, bins.period(count.periodId()));
    }

    private Count count(UUID countId, boolean forUpdate) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT id, period_id, version, status, correction_reason, row_version
                FROM workshop_material_counts WHERE id = :id""" + (forUpdate ? " FOR UPDATE" : ""),
                Map.of("id", countId));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "盘点单不存在");
        Map<String, Object> row = rows.getFirst();
        return new Count((UUID) row.get("id"), (UUID) row.get("period_id"),
                WorkshopMaterialBinSupport.number(row.get("version")).intValue(), (String) row.get("status"),
                (String) row.get("correction_reason"), WorkshopMaterialBinSupport.number(row.get("row_version")).longValue());
    }

    private UUID submittedCountId(UUID periodId) {
        List<UUID> rows = db.queryForList("""
                SELECT id FROM workshop_material_counts WHERE period_id = :period AND status = 'SUBMITTED'
                """, Map.of("period", periodId), UUID.class);
        if (rows.isEmpty()) throw new ApiException(ErrorCode.CONFLICT, "这一期还没有提交的盘点单");
        return rows.getFirst();
    }

    private static void requireDraft(Count count) {
        if (!"DRAFT".equals(count.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "这张盘点单已经提交, 不能再改; 要改请点\"更正盘点\"");
        }
    }

    private CountDetail detailOf(Count count, Period period) {
        Settings settings = bins.settingsByBin(period.binWarehouseId());
        List<CountLineView> lines = lines(count.id());
        Map<UUID, CountLineView> byContainer = new LinkedHashMap<>();
        Map<Material, Integer> perMaterial = new LinkedHashMap<>();
        for (CountLineView line : lines) {
            if (line.containerId() != null) byContainer.put(line.containerId(), line);
            if (line.goodsId() != null) perMaterial.merge(new Material(line.goodsId(), line.colorId()), 1, Integer::sum);
        }
        Map<UUID, MachineCard> cards = new LinkedHashMap<>();
        Map<UUID, List<ContainerSlot>> slots = new LinkedHashMap<>();
        int missingContainers = 0;
        for (Map<String, Object> row : db.queryForList("""
                SELECT machine.id AS machine_id, machine.code, machine.name AS machine_name,
                       container.id AS container_id, container.name AS container_name, container.capacity_qty
                FROM workshop_machines machine
                JOIN workshop_machine_containers container ON container.machine_id = machine.id
                WHERE machine.workshop_department_id = :workshop AND machine.enabled AND NOT machine.is_deleted
                  AND container.enabled AND NOT container.is_deleted
                ORDER BY machine.sort_order, machine.code, container.sort_order, container.name
                """, Map.of("workshop", period.workshopDepartmentId()))) {
            UUID machine = (UUID) row.get("machine_id");
            UUID container = (UUID) row.get("container_id");
            CountLineView line = byContainer.get(container);
            if (line == null) missingContainers++;
            slots.computeIfAbsent(machine, key -> new ArrayList<>()).add(new ContainerSlot(container,
                    (String) row.get("container_name"), WorkshopMaterialBinSupport.decimal(row.get("capacity_qty")),
                    line == null ? "C-" + container : line.clientLineKey(), line));
            cards.putIfAbsent(machine, new MachineCard(machine, (String) row.get("code"),
                    (String) row.get("machine_name"), null, null, null));
        }
        Map<UUID, Material> lastInUse = lastMaterialPerMachine(count, period);
        List<MachineCard> machines = new ArrayList<>();
        for (MachineCard card : cards.values()) {
            Material last = lastInUse.get(card.machineId());
            machines.add(new MachineCard(card.machineId(), card.code(), card.name(),
                    last == null ? null : last.goodsId(), last == null ? null : last.colorId(),
                    slots.get(card.machineId())));
        }
        List<MaterialSlot> materials = new ArrayList<>();
        int missingMaterials = 0;
        for (Map<String, Object> row : neededMaterials(period.id())) {
            Material material = new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id"));
            MaterialInfo info = bins.material(material.goodsId());
            int lineCount = perMaterial.getOrDefault(material, 0);
            if (lineCount == 0) missingMaterials++;
            materials.add(new MaterialSlot(material.goodsId(), info.code(), info.name(), material.colorId(),
                    colorName(material.colorId()), info.unitName(), WorkshopMaterialBinSupport.zero(row.get("book_qty")),
                    info.bulkPackageQty(), "B-" + material.goodsId()
                    + (material.colorId() == null ? "" : ":" + material.colorId()), lineCount));
        }
        List<String> actions = new ArrayList<>();
        if ("DRAFT".equals(count.status()) && permissions.has(WorkshopMaterialPermissions.COUNT)) {
            actions.add("EDIT_COUNT");
        }
        if ("DRAFT".equals(count.status()) && permissions.has(WorkshopMaterialPermissions.COUNT_REVIEW)) {
            actions.add("SUBMIT_COUNT");
        }
        return new CountDetail(count.id(), period.id(), period.no(), period.startDate(), period.endDate(),
                period.status(), period.binWarehouseId(), bins.warehouseName(period.binWarehouseId()),
                period.workshopDepartmentId(), settings == null ? null : settings.workshopName(), count.version(),
                count.status(), count.correctionReason(), count.rowVersion(), lines, machines, materials,
                missingContainers, missingMaterials, actions);
    }

    /**
     * 每台机上一次盘点时容器里在用的料 (本仓更早的、或这一期被更正前的已提交盘点单; 同一台机取最近一次录的那一行)。
     * 页面用它预选「在用料」, 员工照样可以改。
     */
    private Map<UUID, Material> lastMaterialPerMachine(Count count, Period period) {
        Map<UUID, Material> out = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT DISTINCT ON (line.machine_id) line.machine_id, line.goods_id, line.color_id
                FROM workshop_material_count_lines line
                JOIN workshop_material_counts counted ON counted.id = line.count_id
                JOIN workshop_material_periods counted_period ON counted_period.id = counted.period_id
                WHERE counted_period.bin_warehouse_id = :bin
                  AND counted_period.period_no <= :periodNo
                  AND counted.id <> :count
                  AND counted.status IN ('SUBMITTED', 'SUPERSEDED')
                  AND line.line_kind = 'CONTAINER' AND line.machine_id IS NOT NULL AND line.goods_id IS NOT NULL
                ORDER BY line.machine_id, counted_period.period_no DESC, counted.version DESC,
                         line.entered_at DESC, line.id
                """, new MapSqlParameterSource("bin", period.binWarehouseId()).addValue("periodNo", period.no())
                .addValue("count", count.id()))) {
            out.put((UUID) row.get("machine_id"), new Material((UUID) row.get("goods_id"), (UUID) row.get("color_id")));
        }
        return out;
    }

    private String colorName(UUID colorId) {
        if (colorId == null) return null;
        List<String> names = db.queryForList("SELECT name FROM colors WHERE id = :id", Map.of("id", colorId),
                String.class);
        return names.isEmpty() ? null : names.getFirst();
    }

    private List<CountLineView> lines(UUID countId) {
        return lineViews("line.count_id = :count", new MapSqlParameterSource("count", countId));
    }

    private CountLineView line(UUID countId, String key) {
        List<CountLineView> rows = lineViews("line.count_id = :count AND line.client_line_key = :key",
                new MapSqlParameterSource("count", countId).addValue("key", key));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    private List<CountLineView> lineViews(String where, MapSqlParameterSource params) {
        List<CountLineView> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT line.id, line.client_line_key, line.line_kind, line.weigh_note, line.goods_id,
                       goods.code AS goods_code, goods.name AS goods_name, line.color_id, color.name AS color_name,
                       line.bag_count, line.bag_net_qty, line.weighed_qty, line.machine_id,
                       machine.name AS machine_name, line.container_id, container.name AS container_name,
                       line.capacity_qty_snapshot, line.fill_level, line.qty_base, enterer.full_name AS entered_by_name,
                       line.entered_at, line.row_version
                FROM workshop_material_count_lines line
                LEFT JOIN goods ON goods.id = line.goods_id
                LEFT JOIN colors color ON color.id = line.color_id
                LEFT JOIN workshop_machines machine ON machine.id = line.machine_id
                LEFT JOIN workshop_machine_containers container ON container.id = line.container_id
                LEFT JOIN users entered_user ON entered_user.id = line.entered_by
                LEFT JOIN employees enterer ON enterer.id = entered_user.employee_id
                """ + " WHERE " + where + " ORDER BY line.entered_at, line.client_line_key", params)) {
            out.add(new CountLineView((UUID) row.get("id"), (String) row.get("client_line_key"),
                    (String) row.get("line_kind"), (String) row.get("weigh_note"), (UUID) row.get("goods_id"),
                    (String) row.get("goods_code"), (String) row.get("goods_name"), (UUID) row.get("color_id"),
                    (String) row.get("color_name"), WorkshopMaterialBinSupport.decimal(row.get("bag_count")),
                    WorkshopMaterialBinSupport.decimal(row.get("bag_net_qty")),
                    WorkshopMaterialBinSupport.decimal(row.get("weighed_qty")), (UUID) row.get("machine_id"),
                    (String) row.get("machine_name"), (UUID) row.get("container_id"),
                    (String) row.get("container_name"), WorkshopMaterialBinSupport.decimal(row.get("capacity_qty_snapshot")),
                    (String) row.get("fill_level"), WorkshopMaterialBinSupport.decimal(row.get("qty_base")),
                    (String) row.get("entered_by_name"), WorkshopMaterialBinSupport.offset(row.get("entered_at")),
                    WorkshopMaterialBinSupport.number(row.get("row_version")).longValue()));
        }
        return out;
    }

    private boolean containerTaken(UUID countId, UUID containerId, String key) {
        Integer taken = db.queryForObject("""
                SELECT count(*) FROM workshop_material_count_lines
                WHERE count_id = :count AND container_id = :container AND line_kind = 'CONTAINER'
                  AND client_line_key <> :key
                """, new MapSqlParameterSource("count", countId).addValue("container", containerId)
                .addValue("key", key), Integer.class);
        return taken != null && taken > 0;
    }

    // ------------------------------------------------------------------ 行校验

    private record LineValues(MapSqlParameterSource params, UUID containerId) {}

    private LineValues validate(Period period, CountLineInput input) {
        String kind = input.lineKind();
        if (kind == null || !LINE_KINDS.contains(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择整袋、机台容器还是过秤");
        }
        if (!"WEIGHED".equals(kind) && input.weighNote() != null && !input.weighNote().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "只有过秤的行才分开口袋、搅好未上机、散料");
        }
        UUID goods = input.goodsId();
        UUID unit = null;
        if (goods != null) {
            unit = bins.periodicMaterial(goods).unitId();
            bins.requireColor(input.colorId());
        }
        String note = null;
        BigDecimal bagCount = null, bagNet = null, weighed = null, capacity = null;
        UUID machine = null, container = null;
        String fill = null;
        switch (kind) {
            case "FULL_BAGS" -> {
                if (goods == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "整袋行请选择料");
                bagCount = nonNegative(input.bagCount(), "袋数");
                bagNet = positive(input.bagNetQty(), "每袋净重");
            }
            case "WEIGHED" -> {
                if (goods == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "过秤行请选择料");
                weighed = nonNegative(input.weighedQty(), "过秤公斤数");
                if (input.weighNote() != null && !input.weighNote().isBlank()) {
                    if (!WEIGH_NOTES.contains(input.weighNote())) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "过秤行的分组不对");
                    }
                    note = input.weighNote();
                }
            }
            default -> {
                fill = input.fillLevel();
                if (fill == null || !FILL_LEVELS.contains(fill)) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择满、半、空或直接填公斤");
                }
                if (input.machineId() == null || input.containerId() == null) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择机台和容器");
                }
                List<Map<String, Object>> rows = db.queryForList("""
                        SELECT container.capacity_qty FROM workshop_machine_containers container
                        JOIN workshop_machines machine ON machine.id = container.machine_id
                        WHERE container.id = :container AND machine.id = :machine AND NOT container.is_deleted
                          AND NOT machine.is_deleted AND machine.workshop_department_id = :workshop
                        """, new MapSqlParameterSource("container", input.containerId())
                        .addValue("machine", input.machineId()).addValue("workshop", period.workshopDepartmentId()));
                if (rows.isEmpty()) throw new ApiException(ErrorCode.VALIDATION_FAILED, "这个容器不在本车间的机台上");
                capacity = WorkshopMaterialBinSupport.decimal(rows.getFirst().get("capacity_qty"));
                machine = input.machineId();
                container = input.containerId();
                if (goods == null && !"EMPTY".equals(fill)) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "容器里有料时请选择是哪种料");
                }
                if ("WEIGHED".equals(fill)) weighed = nonNegative(input.weighedQty(), "容器里的公斤数");
            }
        }
        MapSqlParameterSource params = new MapSqlParameterSource()
                .addValue("kind", kind).addValue("note", note)
                .addValue("goods", goods == null ? null : goods.toString())
                .addValue("color", goods == null || input.colorId() == null ? null : input.colorId().toString())
                .addValue("unit", unit == null ? null : unit.toString())
                .addValue("bagCount", bagCount).addValue("bagNet", bagNet).addValue("weighed", weighed)
                .addValue("machine", machine == null ? null : machine.toString())
                .addValue("container", container == null ? null : container.toString())
                .addValue("capacity", capacity).addValue("fill", fill);
        return new LineValues(params, container);
    }

    private static BigDecimal nonNegative(BigDecimal value, String what) {
        if (value == null || value.signum() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, what + "不能为空或小于 0");
        }
        return scale(value, what);
    }

    private static BigDecimal positive(BigDecimal value, String what) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, what + "必须大于 0");
        }
        return scale(value, what);
    }

    private static BigDecimal scale(BigDecimal value, String what) {
        if (value.stripTrailingZeros().scale() > MoneyPolicy.QUANTITY_SCALE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, what + "最多保留 4 位小数");
        }
        return MoneyPolicy.quantity(value);
    }

    private static String requireLineKey(String key) {
        if (key == null || !LINE_KEY.matcher(key).matches()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "盘点行编号不对, 请刷新页面");
        }
        return key;
    }

    private static MapSqlParameterSource params(UUID periodId, Material material) {
        return new MapSqlParameterSource("period", periodId).addValue("goods", material.goodsId())
                .addValue("color", material.colorId() == null ? null : material.colorId().toString());
    }

    private void requestClose(UUID periodId, UUID actor) {
        WorkshopMaterialCloseRequester requester = closeRequests.getIfAvailable();
        if (requester != null) requester.requestAfterCommit(periodId, actor);
    }
}
