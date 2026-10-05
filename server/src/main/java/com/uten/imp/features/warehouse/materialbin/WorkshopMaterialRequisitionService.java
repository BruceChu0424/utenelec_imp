package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import com.uten.imp.application.port.WorkshopMaterialNoticePort;
import com.uten.imp.application.port.WorkshopMaterialSetupPort;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.common.finance.MoneyPolicy;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.features.stock.dto.WorkshopMaterialDocumentCommand;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Material;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.MaterialInfo;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CancelRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueDefaults;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.DirectIssueRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilLine;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.FulfilRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialSetup;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionCreate;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionDocumentView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionLineView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodRef;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.RequisitionView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.Supplement;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 车间内料仓的领料单与退回单 (ADR-131 §5.2、§5.3): 车间申请、仓库按申请发料或点收退回、
 * 仓库直接发料 (主路径)、作废, 以及上一期漏录的补录。
 *
 * <p>归期按期间, 不按日期: 普通进出记进本仓开着的那一期 (对设置行加共享锁, 与开始盘点互斥);
 * 补录记进请求指定的"盘点中"或"已盘点、还没结算"的那一期 (对设置行与该期加排他锁), 已盘点的
 * 同一事务按盘点过账规则自动更正, 提交后立即尝试结算。业务日期一律记真实日期。
 */
@Service
public class WorkshopMaterialRequisitionService {

    static final String KIND_ISSUE = "ISSUE";
    static final String KIND_RETURN = "RETURN";

    /** 一行申请 (已校验、已折成物料基本单位)。 */
    private record LineDraft(MaterialInfo material, UUID colorId, BigDecimal qty, BigDecimal bags, UUID leaf) {}

    /** 锁定后的单据表头。 */
    private record Header(UUID id, String requestNo, String kind, String origin, String status, UUID bin,
                          UUID workshop, UUID receiver, UUID requestedBy, long rowVersion) {}

    /** 单据的一行。 */
    private record Line(UUID id, UUID goodsId, UUID colorId, UUID unitId, UUID suggestedLeaf) {}

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialStockGateway gateway;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final WorkshopMaterialCountService counts;
    private final DocNumberService docNumbers;
    private final WorkshopMaterialNoticePort notices;
    private final SecurityContextCurrentUser currentUser;
    private final WorkshopMaterialSetupPort materialSetup;

    public WorkshopMaterialRequisitionService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                              WorkshopMaterialStockGateway gateway,
                                              WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                              WorkshopMaterialPermissions permissions,
                                              WorkshopMaterialCountService counts, DocNumberService docNumbers,
                                              WorkshopMaterialNoticePort notices,
                                              SecurityContextCurrentUser currentUser,
                                              WorkshopMaterialSetupPort materialSetup) {
        this.db = db;
        this.bins = bins;
        this.gateway = gateway;
        this.commands = commands;
        this.scope = scope;
        this.permissions = permissions;
        this.counts = counts;
        this.docNumbers = docNumbers;
        this.notices = notices;
        this.currentUser = currentUser;
        this.materialSetup = materialSetup;
    }

    // ------------------------------------------------------------------ 车间申请

    /** 车间申请领料或退回: 只生成申请, 通知预填叶仓的仓管。 */
    @Transactional
    public RequisitionView create(RequisitionCreate request) {
        String kind = requireKind(request.kind());
        UUID workshop = requireWorkshop(request.workshopDepartmentId());
        List<LineDraft> drafts = drafts(kind, request.lines());
        String remark = remark(request.remark());
        return commands.execute("REQUISITION_CREATE", request.idempotencyKey(), request, RequisitionView.class, () -> {
            Settings settings = bins.enabledSettingsForShare(workshop);
            UUID id = insertHeader(kind, "WORKSHOP_REQUEST", settings, null, remark);
            insertLines(id, workshop, drafts);
            notices.requisitionPending(id);
            return new Outcome<>(id, view(id));
        });
    }

    /** 仓库按申请发料 (领料单) 或点收退回 (退回单); 办完即结单。 */
    @Transactional
    public RequisitionView fulfil(UUID requisitionId, FulfilRequest request) {
        // 未带首次设置时保持旧 JSON 指纹形状, 已办理的旧客户端重放仍能返回原回执。
        Object fingerprint = request.materialSetup() == null || request.materialSetup().isEmpty()
                ? new LegacyFulfilRequest(request.expectedVersion(), request.lines(), request.supplement(), request.idempotencyKey())
                : request;
        return commands.execute("REQUISITION_FULFIL", request.idempotencyKey(), List.of(requisitionId, fingerprint),
                RequisitionView.class, () -> {
                    Header header = lockHeader(requisitionId);
                    scope.requireWorkshop(header.workshop());
                    requirePending(header);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), header.rowVersion(), "这张单据");
                    Settings settings = request.supplement() == null
                            ? bins.enabledSettingsForShare(header.workshop())
                            : bins.enabledSettingsForUpdate(header.workshop());
                    requireSameBin(settings, header);
                    execute(header, settings, request.lines(), request.supplement(), () -> prepareFulfilMaterials(header, request));
                    notices.requisitionResolved(header.id());
                    return new Outcome<>(header.id(), view(header.id()));
                });
    }

    private record LegacyFulfilRequest(Long expectedVersion, List<FulfilLine> lines, Supplement supplement,
                                      String idempotencyKey) {}

    /** 首次用途确认复用主档命令, 先持有本次全部库存锁再进入主档锁; 后续失败一并回滚。 */
    private void prepareFulfilMaterials(Header header, FulfilRequest request) {
        if (request.lines() == null || request.lines().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少办理一行");
        }
        Map<UUID, Line> available = lines(header.id());
        Map<UUID, Line> selected = new LinkedHashMap<>();
        for (FulfilLine line : request.lines()) {
            if (line == null || !available.containsKey(line.lineId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "办理的明细不属于这张单据, 请刷新后重试");
            }
            requirePositive(line.qty(), "数量");
            selected.put(line.lineId(), available.get(line.lineId()));
        }
        Map<UUID, MaterialInfo> materials = new LinkedHashMap<>();
        for (Line line : selected.values()) {
            MaterialInfo info = materials.computeIfAbsent(line.goodsId(), bins::material);
            requireLineUnit(line, info.unitId());
            if (info.deleted()) throw new ApiException(ErrorCode.CONFLICT, "申请的材料已删除, 请撤回后重新申请");
            if (!info.periodic()) requestMaterial(info.goodsId());
        }
        List<MaterialSetup> setups = request.materialSetup() == null ? List.of() : request.materialSetup();
        if (!setups.isEmpty() && (!KIND_ISSUE.equals(header.kind()) || !"WORKSHOP_REQUEST".equals(header.origin()))) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "只有车间领料申请首次发料时可以确认材料用途");
        }
        Set<UUID> configured = new LinkedHashSet<>();
        for (MaterialSetup setup : setups) {
            if (setup == null || setup.goodsId() == null || setup.expectedVersion() == null || setup.expectedVersion() < 0
                    || !Set.of("OWN", "SHARED", "EXPENSE").contains(Objects.toString(setup.periodicCostBasis(), ""))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请完整确认首次发料材料的用途和当前版本");
            }
            MaterialInfo info = materials.get(setup.goodsId());
            if (info == null || info.periodic() || !configured.add(setup.goodsId())) {
                throw new ApiException(ErrorCode.CONFLICT, "只能确认本次实际发料中尚未设置用途的材料, 请刷新后重新核对");
            }
        }
        for (MaterialInfo info : materials.values()) {
            if (!info.periodic() && !configured.contains(info.goodsId())) {
                throw new ApiException(ErrorCode.CONFLICT, "「" + info.label() + "」首次发料需确认用途，请在本页核对材料用途和影响后再发料");
            }
        }
        if (!setups.isEmpty()) {
            materialSetup.setup(setups.stream().map(item -> new WorkshopMaterialSetupPort.Setup(item.goodsId(),
                    item.expectedVersion(), item.periodicCostBasis())).toList(), request.idempotencyKey());
        }
        // 库存锁已经齐备。直接取得库存内核稍后需要的 goods UPDATE 锁, 避免不同颜色的共享锁互相升级。
        Map<UUID, Map<String, Object>> current = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT id, unit_id, issue_method, is_deleted, status FROM goods
                WHERE id IN (:ids) ORDER BY id FOR UPDATE
                """, Map.of("ids", materials.keySet()))) current.put((UUID) row.get("id"), row);
        for (Line line : selected.values()) {
            Map<String, Object> row = current.get(line.goodsId());
            if (row == null || Boolean.TRUE.equals(row.get("is_deleted")) || !"PERIODIC".equals(row.get("issue_method"))) {
                throw new ApiException(ErrorCode.CONFLICT, "材料用途已变化，请刷新后重新确认首次发料用途");
            }
            requireLineUnit(line, (UUID) row.get("unit_id"));
        }
        if (KIND_ISSUE.equals(header.kind())) {
            Map<UUID, Map<String, Object>> units = new LinkedHashMap<>();
            for (Map<String, Object> row : db.queryForList("""
                    SELECT unit.id, unit.status, unit.is_deleted, profile.measurement_dimension
                    FROM units unit JOIN unit_measurement_profiles profile ON profile.unit_id = unit.id
                    WHERE unit.id IN (:ids) ORDER BY unit.id FOR SHARE OF unit, profile
                    """, Map.of("ids", current.values().stream().map(row -> (UUID) row.get("unit_id")).distinct().toList()))) {
                units.put((UUID) row.get("id"), row);
            }
            for (Map<String, Object> material : current.values()) {
                Map<String, Object> unit = units.get((UUID) material.get("unit_id"));
                if (!"使用".equals(material.get("status")) || unit == null || Boolean.TRUE.equals(unit.get("is_deleted"))
                        || !"使用".equals(unit.get("status")) || !"MASS".equals(unit.get("measurement_dimension"))) {
                    throw new ApiException(ErrorCode.CONFLICT, "材料或重量单位已停用或发生变化，请刷新后重新核对发料");
                }
            }
        }
    }

    private static void requireLineUnit(Line line, UUID currentUnit) {
        if (!Objects.equals(line.unitId(), currentUnit)) {
            throw new ApiException(ErrorCode.CONFLICT, "申请后材料的基本单位已变化，不能沿用原数量，请撤回后重新申请");
        }
    }

    /**
     * 仓库直接发料 (主路径): 同一事务建"已完成"领料单、按叶仓逐张建并审核调拨单、写调拨关联。
     * 库存不足或版本冲突整笔回滚。
     */
    @Transactional
    public RequisitionView directIssue(DirectIssueRequest request) {
        UUID workshop = requireWorkshop(request.workshopDepartmentId());
        UUID receiver = request.receiverEmployeeId();
        if (receiver == null || bins.employeeName(receiver) == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择领料人");
        }
        if (request.lines() == null || request.lines().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少发一种料");
        }
        List<LineDraft> inputs = new ArrayList<>();
        for (DirectIssueLine line : request.lines()) {
            if (line == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "发料明细不完整");
            MaterialInfo material = bins.periodicMaterial(line.goodsId());
            bins.requireColor(line.colorId());
            BigDecimal qty = kilograms(material, line.qty(), line.bags());
            UUID leaf = line.leafWarehouseId() != null ? line.leafWarehouseId()
                    : bins.defaultSource(workshop, material.goodsId(), line.colorId());
            if (leaf == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + material.label() + "」请选择出库仓库");
            }
            inputs.add(new LineDraft(material, line.colorId(), qty, positive(line.bags()), leaf));
        }
        return commands.execute("DIRECT_ISSUE", request.idempotencyKey(), request, RequisitionView.class, () -> {
            Settings settings = request.supplement() == null
                    ? bins.enabledSettingsForShare(workshop) : bins.enabledSettingsForUpdate(workshop);
            // 一种料一行申请; 同一种料从两个叶仓发时, 在同一行下挂两条调拨关联。
            Map<Material, LineDraft> merged = new LinkedHashMap<>();
            for (LineDraft input : inputs) {
                merged.merge(new Material(input.material().goodsId(), input.colorId()), input, (left, right) ->
                        new LineDraft(left.material(), left.colorId(), left.qty().add(right.qty()),
                                sum(left.bags(), right.bags()), left.leaf()));
            }
            UUID id = insertHeader(KIND_ISSUE, "WAREHOUSE_DIRECT", settings, receiver, null);
            Header header = lockHeader(id);
            // INSERT 明细的 FK/单位身份锁也引用 goods, 因而直接发料须在建明细前先声明库存范围。
            if (request.supplement() != null && request.supplement().periodId() != null) {
                bins.periodForUpdate(request.supplement().periodId());
            }
            gateway.lockInventory(merged.keySet());
            db.queryForList("SELECT id FROM goods WHERE id IN (:ids) ORDER BY id FOR UPDATE",
                    Map.of("ids", merged.keySet().stream().map(Material::goodsId).distinct().toList()));
            Map<Material, UUID> lineIds = insertLines(id, workshop, List.copyOf(merged.values()));
            List<FulfilLine> fulfil = new ArrayList<>();
            for (LineDraft input : inputs) {
                fulfil.add(new FulfilLine(lineIds.get(new Material(input.material().goodsId(), input.colorId())),
                        input.leaf(), input.qty()));
            }
            execute(header, settings, fulfil, request.supplement());
            return new Outcome<>(id, view(id));
        });
    }

    /** 作废还没办的申请 (车间撤回或仓库拒办)。 */
    @Transactional
    public RequisitionView cancel(UUID requisitionId, CancelRequest request) {
        String reason = request.reason() == null ? "" : request.reason().strip();
        if (reason.length() < 2 || reason.length() > 200) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明作废原因 (2 到 200 个字)");
        }
        return commands.execute("REQUISITION_CANCEL", request.idempotencyKey(), List.of(requisitionId, request),
                RequisitionView.class, () -> {
                    Header header = lockHeader(requisitionId);
                    scope.requireWorkshop(header.workshop());
                    requirePending(header);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), header.rowVersion(), "这张单据");
                    if (!permissions.has(WorkshopMaterialPermissions.ISSUE)
                            && !permissions.has(WorkshopMaterialPermissions.REQUEST)) {
                        throw new ApiException(ErrorCode.FORBIDDEN, "没有作废这张单据的权限");
                    }
                    db.update("""
                            UPDATE workshop_material_requisitions
                            SET status = 'CANCELLED', cancelled_by = :actor, cancelled_at = now(),
                                cancel_reason = :reason, row_version = row_version + 1
                            WHERE id = :id
                            """, new MapSqlParameterSource("actor", currentUser.requireId())
                            .addValue("reason", reason).addValue("id", header.id()));
                    notices.requisitionResolved(header.id());
                    return new Outcome<>(header.id(), view(header.id()));
                });
    }

    // ------------------------------------------------------------------ 查询

    @Transactional(readOnly = true)
    public RequisitionView detail(UUID requisitionId) {
        RequisitionView view = view(requisitionId);
        scope.requireWorkshop(view.workshopDepartmentId());
        return view;
    }

    @Transactional(readOnly = true)
    public PageResponse<RequisitionView> list(String status, String kind, UUID workshopId,
                                              WarehouseTaskScopePort.WarehouseTaskScope warehouseScope,
                                              int page, int size) {
        MapSqlParameterSource params = new MapSqlParameterSource();
        StringBuilder where = new StringBuilder(scope.predicate("requisition.workshop_department_id", params));
        if (status != null && !status.isBlank()) {
            if (!Set.of("PENDING", "DONE", "CANCELLED").contains(status)) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "单据状态不对");
            }
            where.append(" AND requisition.status = :status");
            params.addValue("status", status);
        }
        if (kind != null && !kind.isBlank()) {
            where.append(" AND requisition.kind = :kind");
            params.addValue("kind", requireKind(kind));
        }
        if (workshopId != null) {
            where.append(" AND requisition.workshop_department_id = :workshop");
            params.addValue("workshop", workshopId);
        }
        String warehouseFilter = scope.requisitionWarehouseFilter(warehouseScope, params);
        if (!warehouseFilter.isEmpty()) where.append(" AND ").append(warehouseFilter);
        var pageable = Pageables.of(page, size);
        Long total = db.queryForObject("SELECT count(*) FROM workshop_material_requisitions requisition WHERE "
                + where, params, Long.class);
        params.addValue("limit", pageable.getPageSize()).addValue("offset", pageable.getOffset());
        List<UUID> ids = db.queryForList("SELECT requisition.id FROM workshop_material_requisitions requisition WHERE "
                + where + " ORDER BY requisition.requested_at DESC, requisition.id LIMIT :limit OFFSET :offset",
                params, UUID.class);
        long count = total == null ? 0 : total;
        int pages = (int) ((count + pageable.getPageSize() - 1) / pageable.getPageSize());
        return new PageResponse<>(views(ids), pageable.getPageNumber() + 1, pageable.getPageSize(), count, pages);
    }

    /** 直接发料的领料人默认该车间上一次的领料人。 */
    @Transactional(readOnly = true)
    public DirectIssueDefaults defaults(UUID workshopId) {
        UUID workshop = requireWorkshop(workshopId);
        List<UUID> last = db.queryForList("""
                SELECT receiver_employee_id FROM workshop_material_requisitions
                WHERE workshop_department_id = :workshop AND origin = 'WAREHOUSE_DIRECT' AND status = 'DONE'
                  AND receiver_employee_id IS NOT NULL
                ORDER BY done_at DESC, id DESC LIMIT 1
                """, Map.of("workshop", workshop), UUID.class);
        UUID receiver = last.isEmpty() ? null : last.getFirst();
        return new DirectIssueDefaults(workshop, receiver, bins.employeeName(receiver));
    }

    // ------------------------------------------------------------------ 办理

    /** 按叶仓逐张建调拨单并审核; 补录进已盘点的那一期时同事务自动更正。 */
    private void execute(Header header, Settings settings, List<FulfilLine> requested, Supplement supplement) {
        execute(header, settings, requested, supplement, () -> {});
    }

    private void execute(Header header, Settings settings, List<FulfilLine> requested, Supplement supplement,
                         Runnable beforeTransfer) {
        if (requested == null || requested.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少办理一行");
        }
        Map<UUID, Line> lines = lines(header.id());
        LocalDate today = BusinessTime.today();
        Period period;
        String supplementReason = null;
        if (supplement == null) {
            if (settings.goLiveDate() != null && today.isBefore(settings.goLiveDate())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "整批领料从 " + settings.goLiveDate() + " 起启用, 这之前不能进出车间内料仓");
            }
            period = bins.openPeriod(settings.binWarehouseId());
        } else {
            if (!KIND_ISSUE.equals(header.kind())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "只有发料可以补录到上一期");
            }
            supplementReason = supplement.reason() == null ? "" : supplement.reason().strip();
            if (supplementReason.length() < 2 || supplementReason.length() > 500) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请写明补录原因 (2 到 500 个字)");
            }
            if (supplement.periodId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择补到哪一期");
            }
            period = bins.periodForUpdate(supplement.periodId());
            if (!WorkshopMaterialBinSupport.same(period.binWarehouseId(), settings.binWarehouseId())
                    || !Set.of("COUNTING", "COUNTED").contains(period.status())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        "漏录的料只能补到正在盘点或已盘点、还没结算的那一期");
            }
        }
        // 按叶仓分组, 同一叶仓同一行合并成一行调拨明细。
        Map<UUID, Map<UUID, BigDecimal>> byLeaf = new LinkedHashMap<>();
        Set<Material> materials = new LinkedHashSet<>();
        for (FulfilLine fulfil : requested) {
            if (fulfil == null || fulfil.lineId() == null || !lines.containsKey(fulfil.lineId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "办理的明细不属于这张单据, 请刷新后重试");
            }
            Line line = lines.get(fulfil.lineId());
            BigDecimal qty = requirePositive(fulfil.qty(), "数量");
            UUID leaf = fulfil.leafWarehouseId() != null ? fulfil.leafWarehouseId() : line.suggestedLeaf();
            if (leaf == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        KIND_ISSUE.equals(header.kind()) ? "请选择出库仓库" : "请选择收料仓库");
            }
            if (WorkshopMaterialBinSupport.same(leaf, settings.binWarehouseId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "出库或收料仓库不能是车间内料仓本身");
            }
            byLeaf.computeIfAbsent(leaf, key -> new LinkedHashMap<>()).merge(line.id(), qty, BigDecimal::add);
            materials.add(new Material(line.goodsId(), line.colorId()));
        }
        if (supplement != null && "COUNTED".equals(period.status())) {
            counts.requireCountedMaterials(period, materials);
        }
        gateway.lockInventory(materials);
        beforeTransfer.run();
        UUID receiver = header.receiver() != null ? header.receiver() : employeeOf(header.requestedBy());
        WorkshopMaterialDocumentCommand.Kind kind = KIND_ISSUE.equals(header.kind())
                ? WorkshopMaterialDocumentCommand.Kind.ISSUE : WorkshopMaterialDocumentCommand.Kind.RETURN;
        for (Map.Entry<UUID, Map<UUID, BigDecimal>> group : byLeaf.entrySet()) {
            List<WorkshopMaterialStockGateway.TransferLine> transfer = new ArrayList<>();
            for (Map.Entry<UUID, BigDecimal> entry : group.getValue().entrySet()) {
                Line line = lines.get(entry.getKey());
                transfer.add(new WorkshopMaterialStockGateway.TransferLine(line.id(), line.goodsId(), line.colorId(),
                        line.unitId(), entry.getValue()));
            }
            gateway.transfer(new WorkshopMaterialStockGateway.TransferCommand(kind, settings.binWarehouseId(),
                    group.getKey(), header.id(), header.workshop(), receiver, header.requestNo(), transfer,
                    period.id(), today, supplement != null, supplementReason));
        }
        db.update("""
                UPDATE workshop_material_requisitions
                SET status = 'DONE', done_by = :actor, done_at = now(), row_version = row_version + 1
                WHERE id = :id
                """, new MapSqlParameterSource("actor", currentUser.requireId()).addValue("id", header.id()));
        if (supplement != null && "COUNTED".equals(period.status())) {
            counts.applySupplement(period, materials);
        }
    }

    // ------------------------------------------------------------------ 写入

    private UUID insertHeader(String kind, String origin, Settings settings, UUID receiver, String remark) {
        UUID id = UUID.randomUUID();
        String number = docNumbers.nextNumber(KIND_ISSUE.equals(kind)
                ? DocNumberPrefix.WORKSHOP_MATERIAL_ISSUE : DocNumberPrefix.WORKSHOP_MATERIAL_RETURN);
        db.update("""
                INSERT INTO workshop_material_requisitions(
                    id, request_no, kind, origin, bin_warehouse_id, workshop_department_id, receiver_employee_id,
                    requested_by, remark)
                VALUES (:id, :number, :kind, :origin, :bin, :workshop, CAST(:receiver AS uuid), :actor, :remark)
                """, new MapSqlParameterSource()
                .addValue("id", id)
                .addValue("number", number)
                .addValue("kind", kind)
                .addValue("origin", origin)
                .addValue("bin", settings.binWarehouseId())
                .addValue("workshop", settings.workshopDepartmentId())
                .addValue("receiver", receiver == null ? null : receiver.toString())
                .addValue("actor", currentUser.requireId())
                .addValue("remark", remark));
        return id;
    }

    /** 申请行的建议出库仓: 人选了就用人选的, 否则取默认出库仓 (与内料仓页、申请候选同一个函数)。 */
    private Map<Material, UUID> insertLines(UUID requisitionId, UUID workshop, List<LineDraft> drafts) {
        Map<Material, UUID> ids = new LinkedHashMap<>();
        int lineNo = 1;
        for (LineDraft draft : drafts) {
            UUID id = UUID.randomUUID();
            UUID suggested = draft.leaf() != null ? draft.leaf()
                    : bins.defaultSource(workshop, draft.material().goodsId(), draft.colorId());
            int number = lineNo++;
            db.update("""
                    INSERT INTO workshop_material_requisition_lines(
                        id, requisition_id, line_no, goods_id, color_id, unit_id, requested_qty, requested_bags,
                        suggested_leaf_warehouse_id)
                    VALUES (:id, :requisition, :lineNo, :goods, CAST(:color AS uuid), :unit, :qty, :bags,
                            CAST(:leaf AS uuid))
                    """, new MapSqlParameterSource()
                    .addValue("id", id)
                    .addValue("requisition", requisitionId)
                    .addValue("lineNo", number)
                    .addValue("goods", draft.material().goodsId())
                    .addValue("color", draft.colorId() == null ? null : draft.colorId().toString())
                    .addValue("unit", draft.material().unitId())
                    .addValue("qty", draft.qty())
                    .addValue("bags", draft.bags())
                    .addValue("leaf", suggested == null ? null : suggested.toString()));
            ids.put(new Material(draft.material().goodsId(), draft.colorId()), id);
        }
        return ids;
    }

    // ------------------------------------------------------------------ 读取

    private Header lockHeader(UUID id) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT id, request_no, kind, origin, status, bin_warehouse_id, workshop_department_id,
                       receiver_employee_id, requested_by, row_version
                FROM workshop_material_requisitions WHERE id = :id FOR UPDATE
                """, Map.of("id", id));
        if (rows.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "领料单或退回单不存在");
        Map<String, Object> row = rows.getFirst();
        return new Header((UUID) row.get("id"), (String) row.get("request_no"), (String) row.get("kind"),
                (String) row.get("origin"), (String) row.get("status"), (UUID) row.get("bin_warehouse_id"),
                (UUID) row.get("workshop_department_id"), (UUID) row.get("receiver_employee_id"),
                (UUID) row.get("requested_by"), WorkshopMaterialBinSupport.number(row.get("row_version")).longValue());
    }

    private Map<UUID, Line> lines(UUID requisitionId) {
        Map<UUID, Line> out = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT id, goods_id, color_id, unit_id, suggested_leaf_warehouse_id
                FROM workshop_material_requisition_lines WHERE requisition_id = :id ORDER BY line_no
                """, Map.of("id", requisitionId))) {
            out.put((UUID) row.get("id"), new Line((UUID) row.get("id"), (UUID) row.get("goods_id"),
                    (UUID) row.get("color_id"), (UUID) row.get("unit_id"),
                    (UUID) row.get("suggested_leaf_warehouse_id")));
        }
        return out;
    }

    private UUID employeeOf(UUID userId) {
        List<UUID> rows = db.queryForList("SELECT employee_id FROM users WHERE id = :id",
                Map.of("id", userId), UUID.class);
        return rows.isEmpty() ? null : rows.getFirst();
    }

    RequisitionView view(UUID id) {
        List<RequisitionView> views = views(List.of(id));
        if (views.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "领料单或退回单不存在");
        return views.getFirst();
    }

    private List<RequisitionView> views(List<UUID> ids) {
        if (ids.isEmpty()) return List.of();
        MapSqlParameterSource params = new MapSqlParameterSource("ids", ids);
        Map<UUID, List<RequisitionLineView>> lineViews = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT line.requisition_id, line.id, line.line_no, line.goods_id, goods.code AS goods_code,
                       goods.name AS goods_name, line.color_id, color.name AS color_name, line.unit_id,
                       unit.name AS unit_name, line.requested_qty, line.requested_bags, goods.bulk_package_qty,
                       line.suggested_leaf_warehouse_id, leaf.name AS leaf_name, line.fulfilled_qty, goods.issue_method
                FROM workshop_material_requisition_lines line
                JOIN goods ON goods.id = line.goods_id
                LEFT JOIN colors color ON color.id = line.color_id
                LEFT JOIN units unit ON unit.id = line.unit_id
                LEFT JOIN warehouses leaf ON leaf.id = line.suggested_leaf_warehouse_id
                WHERE line.requisition_id IN (:ids)
                ORDER BY line.requisition_id, line.line_no
                """, params)) {
            lineViews.computeIfAbsent((UUID) row.get("requisition_id"), key -> new ArrayList<>())
                    .add(new RequisitionLineView((UUID) row.get("id"),
                            WorkshopMaterialBinSupport.number(row.get("line_no")).intValue(),
                            (UUID) row.get("goods_id"), (String) row.get("goods_code"), (String) row.get("goods_name"),
                            (UUID) row.get("color_id"), (String) row.get("color_name"), (UUID) row.get("unit_id"),
                            (String) row.get("unit_name"), WorkshopMaterialBinSupport.decimal(row.get("requested_qty")),
                            WorkshopMaterialBinSupport.decimal(row.get("requested_bags")),
                            WorkshopMaterialBinSupport.decimal(row.get("bulk_package_qty")),
                            (UUID) row.get("suggested_leaf_warehouse_id"), (String) row.get("leaf_name"),
                            WorkshopMaterialBinSupport.decimal(row.get("fulfilled_qty")), (String) row.get("issue_method")));
        }
        Map<UUID, List<RequisitionDocumentView>> documents = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT line.requisition_id, document.id AS document_id, document.bill_no, posting.leaf_warehouse_id,
                       leaf.name AS leaf_name, posting.period_id, period.period_no,
                       bool_or(posting.is_supplement) AS supplement, sum(posting.qty) AS qty
                FROM workshop_material_requisition_postings posting
                JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
                JOIN stock_document_items item ON item.id = posting.stock_document_item_id
                JOIN stock_documents document ON document.id = item.doc_id
                JOIN warehouses leaf ON leaf.id = posting.leaf_warehouse_id
                JOIN workshop_material_periods period ON period.id = posting.period_id
                WHERE line.requisition_id IN (:ids)
                GROUP BY line.requisition_id, document.id, document.bill_no, posting.leaf_warehouse_id, leaf.name,
                         posting.period_id, period.period_no
                ORDER BY line.requisition_id, document.bill_no
                """, params)) {
            documents.computeIfAbsent((UUID) row.get("requisition_id"), key -> new ArrayList<>())
                    .add(new RequisitionDocumentView((UUID) row.get("document_id"), (String) row.get("bill_no"),
                            (UUID) row.get("leaf_warehouse_id"), (String) row.get("leaf_name"),
                            (UUID) row.get("period_id"), WorkshopMaterialBinSupport.number(row.get("period_no")).intValue(),
                            Boolean.TRUE.equals(row.get("supplement")),
                            WorkshopMaterialBinSupport.decimal(row.get("qty"))));
        }
        // 料记进了哪一期: 一次发完 (或收完) 只归一期; 取过账里期号最大的那一期。
        Map<UUID, PeriodRef> periodOf = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT DISTINCT ON (line.requisition_id) line.requisition_id, period.id, period.period_no,
                       period.start_date, period.end_date, period.status, period.close_state
                FROM workshop_material_requisition_postings posting
                JOIN workshop_material_requisition_lines line ON line.id = posting.line_id
                JOIN workshop_material_periods period ON period.id = posting.period_id
                WHERE line.requisition_id IN (:ids)
                ORDER BY line.requisition_id, period.period_no DESC
                """, params)) {
            periodOf.put((UUID) row.get("requisition_id"), new PeriodRef((UUID) row.get("id"),
                    WorkshopMaterialBinSupport.number(row.get("period_no")).intValue(),
                    WorkshopMaterialBinSupport.date(row.get("start_date")),
                    WorkshopMaterialBinSupport.date(row.get("end_date")), (String) row.get("status"),
                    (String) row.get("close_state")));
        }
        boolean canIssue = permissions.has(WorkshopMaterialPermissions.ISSUE);
        boolean canRequest = permissions.has(WorkshopMaterialPermissions.REQUEST);
        Map<UUID, RequisitionView> byId = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT requisition.id, requisition.request_no, requisition.kind, requisition.origin, requisition.status,
                       requisition.workshop_department_id, workshop.name AS workshop_name,
                       requisition.bin_warehouse_id, bin.name AS bin_name, requisition.receiver_employee_id,
                       receiver.full_name AS receiver_name, requester.full_name AS requested_by_name,
                       requisition.requested_at, finisher.full_name AS done_by_name, requisition.done_at,
                       requisition.cancel_reason, requisition.remark, requisition.row_version
                FROM workshop_material_requisitions requisition
                JOIN departments workshop ON workshop.id = requisition.workshop_department_id
                JOIN warehouses bin ON bin.id = requisition.bin_warehouse_id
                LEFT JOIN employees receiver ON receiver.id = requisition.receiver_employee_id
                LEFT JOIN users requested_user ON requested_user.id = requisition.requested_by
                LEFT JOIN employees requester ON requester.id = requested_user.employee_id
                LEFT JOIN users done_user ON done_user.id = requisition.done_by
                LEFT JOIN employees finisher ON finisher.id = done_user.employee_id
                WHERE requisition.id IN (:ids)
                """, params)) {
            UUID id = (UUID) row.get("id");
            String status = (String) row.get("status");
            List<String> actions = new ArrayList<>();
            if ("PENDING".equals(status)) {
                if (canIssue) actions.add("FULFIL");
                if (canIssue || canRequest) actions.add("CANCEL");
            }
            byId.put(id, new RequisitionView(id, (String) row.get("request_no"), (String) row.get("kind"),
                    (String) row.get("origin"), status, (UUID) row.get("workshop_department_id"),
                    (String) row.get("workshop_name"), (UUID) row.get("bin_warehouse_id"), (String) row.get("bin_name"),
                    (UUID) row.get("receiver_employee_id"), (String) row.get("receiver_name"),
                    (String) row.get("requested_by_name"), WorkshopMaterialBinSupport.offset(row.get("requested_at")),
                    (String) row.get("done_by_name"), WorkshopMaterialBinSupport.offset(row.get("done_at")),
                    (String) row.get("cancel_reason"), (String) row.get("remark"),
                    WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(),
                    lineViews.getOrDefault(id, List.of()), documents.getOrDefault(id, List.of()),
                    periodOf.get(id), actions));
        }
        List<RequisitionView> out = new ArrayList<>();
        for (UUID id : ids) {
            RequisitionView view = byId.get(id);
            if (view != null) out.add(view);
        }
        return out;
    }

    // ------------------------------------------------------------------ 校验

    private List<LineDraft> drafts(String kind, List<RequisitionLineInput> lines) {
        if (lines == null || lines.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少填一种料");
        }
        Map<Material, LineDraft> drafts = new LinkedHashMap<>();
        for (RequisitionLineInput line : lines) {
            if (line == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "申请明细不完整");
            MaterialInfo material = KIND_ISSUE.equals(kind) ? requestMaterial(line.goodsId()) : bins.periodicMaterial(line.goodsId());
            bins.requireColor(line.colorId());
            BigDecimal qty = kilograms(material, line.qty(), line.bags());
            if (drafts.putIfAbsent(new Material(material.goodsId(), line.colorId()),
                    new LineDraft(material, line.colorId(), qty, positive(line.bags()), null)) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                        "「" + material.label() + "」填了两行, 请合并成一行");
            }
        }
        return List.copyOf(drafts.values());
    }

    private MaterialInfo requestMaterial(UUID goodsId) {
        if (goodsId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择原料");
        MaterialInfo material = bins.material(goodsId);
        boolean valid = Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM goods JOIN units unit ON unit.id = goods.unit_id
                    JOIN unit_measurement_profiles profile ON profile.unit_id = unit.id
                    WHERE goods.id = :goods AND NOT goods.is_deleted AND goods.status = '使用'
                      AND NOT unit.is_deleted AND unit.status = '使用' AND profile.measurement_dimension = 'MASS')
                """, Map.of("goods", goodsId), Boolean.class));
        if (!valid) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择使用中的重量单位原料");
        return material;
    }

    /** 基本单位数量优先; 只填袋数时按每袋净重折算。 */
    private static BigDecimal kilograms(MaterialInfo material, BigDecimal qty, BigDecimal bags) {
        if (qty != null) return requirePositive(qty, "「" + material.label() + "」的数量");
        if (bags != null && bags.signum() > 0 && material.bulkPackageQty() != null) {
            return requirePositive(MoneyPolicy.quantity(bags.multiply(material.bulkPackageQty())),
                    "「" + material.label() + "」的数量");
        }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "「" + material.label() + "」请填数量 (" + material.unitName() + ")");
    }

    private static BigDecimal requirePositive(BigDecimal value, String what) {
        if (value == null || value.signum() <= 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, what + "必须大于 0");
        }
        if (value.stripTrailingZeros().scale() > MoneyPolicy.QUANTITY_SCALE) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, what + "最多保留 4 位小数");
        }
        return MoneyPolicy.quantity(value);
    }

    private static BigDecimal positive(BigDecimal value) {
        return value == null || value.signum() <= 0 ? null : MoneyPolicy.quantity(value);
    }

    private static BigDecimal sum(BigDecimal left, BigDecimal right) {
        if (left == null) return right;
        if (right == null) return left;
        return left.add(right);
    }

    private static String requireKind(String kind) {
        if (!KIND_ISSUE.equals(kind) && !KIND_RETURN.equals(kind)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择领料还是退回");
        }
        return kind;
    }

    private UUID requireWorkshop(UUID workshop) {
        if (workshop == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        scope.requireWorkshop(workshop);
        return workshop;
    }

    private static String remark(String remark) {
        if (remark == null || remark.isBlank()) return null;
        String value = remark.strip();
        if (value.length() > 500) throw new ApiException(ErrorCode.VALIDATION_FAILED, "备注最多 500 个字");
        return value;
    }

    private static void requirePending(Header header) {
        if (!"PENDING".equals(header.status())) {
            throw new ApiException(ErrorCode.CONFLICT, "这张单据已经办完或作废了, 请刷新");
        }
    }

    private static void requireSameBin(Settings settings, Header header) {
        if (!WorkshopMaterialBinSupport.same(settings.binWarehouseId(), header.bin())) {
            throw new ApiException(ErrorCode.CONFLICT, "这张单据的内料仓已经不是本车间在用的内料仓");
        }
    }
}
