package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopBinService.OpenedBin;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchDisableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchEnableRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BatchResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.BinItem;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PendingChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PendingProduct;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SettingsView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SourceWarehouseOption;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.STATUS_NOT_OPEN;
import static com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.STATUS_OPEN;
import static com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.STATUS_OPEN_PERIODIC;

/**
 * 车间内料仓开通与整批领料 (ADR-147; 取代 ADR-131 §5.1 第 3 步的单车间开启)。
 *
 * <p>三态由服务端唯一给出: 未开通 -> 已开通(收车间直送) -> 已开通·整批领料。开通的唯一真源是开通记录
 * ({@link WorkshopBinService}); 整批领料是开通后的子能力({@code workshop_material_settings} 引用开通行)。
 *
 * <p>批量命令 (开通/开启整批领料/改来源仓; 撤销一步) 都是一个原子请求: 车间去重后按 UUID 排序逐个加锁,
 * 先把每个车间的问题全部查出来一次说清楚 (全成全败, 不写任何东西), 全部通过才写。单车间
 * {@code PUT /settings/{workshopId}} 是只有一个车间的批量, 走同一条代码路径。
 *
 * <p>开启整批领料: 写设置 -> 建第 1 期 -> 在产还没认料的产品一次认完 (按产品去重, 一个产品只认一次) ->
 * 本车间正在生产、状态已明确的段当场绑定 (起始日 = 启用日)。撤销只用来撤销设错的开启/开通。
 */
@Service
public class WorkshopMaterialSettingsService {

    /** 一次批量最多几个车间。 */
    static final int BATCH_LIMIT = 50;

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialPermissions permissions;
    private final WorkshopMaterialChoiceAdapter choices;
    private final WorkshopBinService openings;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialSettingsService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                           WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                           WorkshopMaterialPermissions permissions,
                                           WorkshopMaterialChoiceAdapter choices, WorkshopBinService openings,
                                           SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.commands = commands;
        this.scope = scope;
        this.permissions = permissions;
        this.choices = choices;
        this.openings = openings;
        this.currentUser = currentUser;
    }

    // ------------------------------------------------------------------ 读

    /** 生产部下每个车间一行 (没开通的也列出, 供开通); 内料仓总览是唯一的车间清单。 */
    @Transactional(readOnly = true)
    public List<SettingsView> list() {
        MapSqlParameterSource params = new MapSqlParameterSource();
        String inScope = scope.predicate("workshop.id", params);
        List<UUID> workshops = db.queryForList("""
                SELECT workshop.id FROM departments workshop
                JOIN departments production ON production.id = workshop.parent_id AND production.code = 'DEPT_PROD'
                 AND NOT production.is_deleted
                WHERE NOT workshop.is_deleted
                """ + " AND " + inScope + " ORDER BY workshop.code, workshop.name",
                params, UUID.class);
        return views(workshops);
    }

    @Transactional(readOnly = true)
    public SettingsView detail(UUID workshopId) {
        scope.requireWorkshop(workshopId);
        return views(List.of(workshopId)).getFirst();
    }

    /**
     * 发料来源仓滑窗的仓库层级 (只有元数据: 编号、名称、上级、状态、是不是不良品仓、能不能选)。
     * 开通设置与仓库发料都要选仓, 但不一定有仓库资料或库存查看权限, 所以单独给一份不含库存的层级。
     * 能选的只有启用中的良品子仓 ({@code fn_warehouse_is_good_stock_leaf}); 提交时服务端同一规则再校验。
     */
    @Transactional(readOnly = true)
    public List<SourceWarehouseOption> sourceWarehouses() {
        if (!permissions.has(WorkshopMaterialPermissions.SETUP) && !permissions.has(WorkshopMaterialPermissions.ISSUE)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "没有车间内料仓设置或发料权限");
        }
        List<SourceWarehouseOption> out = new ArrayList<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT warehouse.id, warehouse.code, warehouse.name, warehouse.parent_id, warehouse.status,
                       warehouse.is_defective, fn_warehouse_is_good_stock_leaf(warehouse.id) AS selectable,
                       fn_warehouse_is_defective_leaf(warehouse.id) AS selectable_defective
                FROM warehouses warehouse
                WHERE NOT warehouse.is_deleted AND warehouse.is_accountable AND NOT warehouse.is_line_side
                ORDER BY warehouse.parent_id NULLS FIRST, warehouse.code, warehouse.name, warehouse.id
                """, Map.of())) {
            out.add(new SourceWarehouseOption((UUID) row.get("id"), (String) row.get("code"),
                    (String) row.get("name"), (UUID) row.get("parent_id"), (String) row.get("status"),
                    Boolean.TRUE.equals(row.get("is_defective")), Boolean.TRUE.equals(row.get("selectable")),
                    Boolean.TRUE.equals(row.get("selectable_defective"))));
        }
        return out;
    }

    /**
     * 开启整批领料前, 这些车间正在生产、还没认料的产品 (按产品去重; 认料是产品级事实, 一个产品只认一次)。
     */
    @Transactional(readOnly = true)
    public PendingChoiceList inProgressPending(List<UUID> workshopIds) {
        List<UUID> ids = distinctIds(workshopIds);
        Map<UUID, String> names = new LinkedHashMap<>();
        for (UUID id : ids) names.put(id, requireWorkshopDepartment(id));
        Map<UUID, WorkshopMaterialChoicePort.PendingChoice> byProduct = new LinkedHashMap<>();
        Map<UUID, List<UUID>> workshopsByProduct = new LinkedHashMap<>();
        Map<UUID, List<UUID>> segmentsByProduct = new LinkedHashMap<>();
        for (UUID id : ids) {
            for (WorkshopMaterialChoicePort.PendingChoice pending : choices.inProgressPending(id)) {
                byProduct.putIfAbsent(pending.productGoodsId(), pending);
                workshopsByProduct.computeIfAbsent(pending.productGoodsId(), key -> new ArrayList<>()).add(id);
                segmentsByProduct.computeIfAbsent(pending.productGoodsId(), key -> new ArrayList<>())
                        .addAll(pending.segmentIds());
            }
        }
        List<PendingProduct> out = new ArrayList<>();
        for (Map.Entry<UUID, WorkshopMaterialChoicePort.PendingChoice> entry : byProduct.entrySet()) {
            WorkshopMaterialChoicePort.PendingChoice first = entry.getValue();
            List<UUID> workshops = workshopsByProduct.get(entry.getKey());
            List<UUID> segments = segmentsByProduct.get(entry.getKey());
            WorkshopMaterialChoicePort.PendingChoice merged = new WorkshopMaterialChoicePort.PendingChoice(
                    first.workshopDepartmentId(), first.workshopName(), first.productGoodsId(), first.productCode(),
                    first.productName(), segments, segments.size(), first.choiceRequired(),
                    first.prefill(), first.prefillSource(), first.options(), first.bomWeights(),
                    first.alsoOrderMaterialsAllowed());
            out.add(new PendingProduct(merged, List.copyOf(workshops),
                    workshops.stream().map(names::get).toList()));
        }
        return new PendingChoiceList(out);
    }

    // ------------------------------------------------------------------ 写

    /** 单车间命令: 与批量同一条代码路径。enabled 为假 = 撤销一步。 */
    @Transactional
    public SettingsView update(UUID workshopId, SettingsRequest request) {
        if (request == null || request.enabled() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择开通还是撤销");
        }
        BinItem item = new BinItem(workshopId, request.expectedStatus(), request.expectedVersion());
        BatchResult result = request.enabled()
                ? batchEnable(new BatchEnableRequest(List.of(item), request.sourceWarehouseId(),
                        request.clearSource(), request.periodic(), request.goLiveDate(),
                        request.inProgressChoices(), request.idempotencyKey()))
                : batchDisable(new BatchDisableRequest(List.of(item), request.idempotencyKey()));
        return result.settings().getFirst();
    }

    /**
     * 批量往前走一步: 未开通 -> 开通 (periodic 为真时同时开启整批领料); 已开通 -> 开启整批领料、改来源仓
     * 或恢复按货品所属仓库发料 (clearSource, 来源仓置空)。
     */
    @Transactional
    public BatchResult batchEnable(BatchEnableRequest request) {
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择要开通的车间");
        List<UUID> requested = requireItems(request.items());
        boolean periodic = Boolean.TRUE.equals(request.periodic());
        boolean clearSource = Boolean.TRUE.equals(request.clearSource());
        UUID source = request.sourceWarehouseId();
        if (clearSource && source != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "选了来源仓就不能同时「恢复按货品所属仓库」, 请二选一");
        }
        LocalDate goLive = request.goLiveDate();
        if (periodic && goLive == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择整批领料的启用日");
        List<WorkshopMaterialChoicePort.ProductChoice> productChoices = distinctChoices(request.inProgressChoices());
        return commands.execute("BIN_BATCH_ENABLE", request.idempotencyKey(), request, BatchResult.class, () -> {
            UUID actor = currentUser.requireId();
            Map<UUID, BinItem> items = itemsById(request.items());
            List<UUID> ordered = lockInOrder(requested);
            String sourceRefusal = openings.sourceRefusal(source);
            if (sourceRefusal != null) throw new ApiException(ErrorCode.VALIDATION_FAILED, sourceRefusal);

            // 1. 先全部校验, 收集每个车间的问题。
            Problems problems = new Problems();
            Map<UUID, State> states = new LinkedHashMap<>();
            Map<UUID, List<UUID>> pendingProducts = new LinkedHashMap<>();
            Set<UUID> chosen = new HashSet<>();
            for (WorkshopMaterialChoicePort.ProductChoice choice : productChoices) chosen.add(choice.productGoodsId());
            for (UUID id : ordered) {
                State state = state(id);
                states.put(id, state);
                if (!problems.checkVersion(state, items.get(id))) continue;
                switch (state.status()) {
                    case STATUS_NOT_OPEN -> {
                        String taken = openings.nameConflict(id);
                        if (taken != null) {
                            problems.rule(state, "已有名为「" + taken + "」的仓库, 内料仓建不出来, 请先到仓库资料给那个仓改名");
                        }
                    }
                    case STATUS_OPEN -> {
                        if (!periodic && !sourceChanges(state, source, clearSource)) {
                            problems.rule(state, "已经开通了内料仓, 没有要改的");
                        }
                    }
                    default -> {
                        if (periodic) problems.rule(state, "已经开启了整批领料");
                        else if (!sourceChanges(state, source, clearSource)) {
                            problems.rule(state, "已经开通了内料仓, 没有要改的");
                        }
                    }
                }
                if (!periodic || STATUS_OPEN_PERIODIC.equals(state.status())) continue;
                if (state.opened() != null && binHoldsPeriodicStock(state.opened().binWarehouseId())) {
                    problems.rule(state, "内料仓里已经有整批领料的料, 请先清空再开启");
                }
                if (closedAfterGoLive(state, goLive)) {
                    problems.rule(state, "启用日期必须晚于这个内料仓已结算的日期");
                }
                List<UUID> pending = pendingProducts(id);
                pendingProducts.put(id, pending);
                List<String> unchosen = productNames(pending.stream().filter(product -> !chosen.contains(product)).toList());
                if (!unchosen.isEmpty()) {
                    problems.rule(state, "这些正在生产的产品还没认料, 请在开启时一起选好: "
                            + String.join("、", unchosen.subList(0, Math.min(10, unchosen.size())))
                            + (unchosen.size() > 10 ? " 等 " + unchosen.size() + " 个" : ""));
                }
            }
            problems.throwIfAny("开通");

            // 2. 全部通过才写。
            Set<UUID> written = new HashSet<>();
            for (UUID id : ordered) {
                State state = states.get(id);
                OpenedBin opened = state.opened();
                if (opened == null) {
                    openings.open(id, source, actor);
                    opened = openings.openedForUpdate(id);
                } else if (sourceChanges(state, source, clearSource)) {
                    openings.changeSource(opened, clearSource ? null : source, actor);
                    opened = openings.openedForUpdate(id);
                }
                if (!periodic || STATUS_OPEN_PERIODIC.equals(state.status())) continue;
                if (state.opened() != null) openings.touch(opened, actor);
                enablePeriodic(id, state.settings(), opened.binWarehouseId(), goLive, actor);
                List<WorkshopMaterialChoicePort.ProductChoice> mine = new ArrayList<>();
                for (WorkshopMaterialChoicePort.ProductChoice choice : productChoices) {
                    if (!written.contains(choice.productGoodsId())
                            && pendingProducts.getOrDefault(id, List.of()).contains(choice.productGoodsId())) {
                        mine.add(choice);
                    }
                }
                if (!mine.isEmpty()) written.addAll(choices.chooseWithinCommand(mine, id));
                bindInProgress(id, opened.binWarehouseId(), goLive, actor);
            }
            // 没有车间在产的认料也照写 (挂在第一个开启整批领料的车间名下), 与原单车间开启一致。
            List<WorkshopMaterialChoicePort.ProductChoice> rest = productChoices.stream()
                    .filter(choice -> !written.contains(choice.productGoodsId())).toList();
            if (!rest.isEmpty() && periodic) {
                UUID first = ordered.stream().filter(id -> !STATUS_OPEN_PERIODIC.equals(states.get(id).status()))
                        .findFirst().orElse(null);
                if (first != null) choices.chooseWithinCommand(rest, first);
            }
            return new Outcome<>(null, new BatchResult(views(requested)));
        });
    }

    /** 批量撤销一步: 整批领料中 -> 已开通; 已开通 -> 未开通 (软删内料仓)。只撤销设错的。 */
    @Transactional
    public BatchResult batchDisable(BatchDisableRequest request) {
        if (request == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择要撤销的车间");
        List<UUID> requested = requireItems(request.items());
        return commands.execute("BIN_BATCH_DISABLE", request.idempotencyKey(), request, BatchResult.class, () -> {
            UUID actor = currentUser.requireId();
            Map<UUID, BinItem> items = itemsById(request.items());
            List<UUID> ordered = lockInOrder(requested);
            Problems problems = new Problems();
            Map<UUID, State> states = new LinkedHashMap<>();
            for (UUID id : ordered) {
                State state = state(id);
                states.put(id, state);
                if (!problems.checkVersion(state, items.get(id))) continue;
                List<String> blockers = switch (state.status()) {
                    case STATUS_NOT_OPEN -> List.of("还没开通内料仓");
                    case STATUS_OPEN_PERIODIC -> periodicUsage(state.opened().binWarehouseId());
                    default -> openings.revokeBlockers(state.opened().binWarehouseId());
                };
                if (!blockers.isEmpty()) {
                    problems.rule(state, (STATUS_OPEN_PERIODIC.equals(state.status()) ? "整批领料已经在用, 不能撤销: "
                            : STATUS_OPEN.equals(state.status()) ? "内料仓已经在用, 不能撤销开通: " : "")
                            + String.join("; ", blockers));
                }
            }
            problems.throwIfAny("撤销");
            for (UUID id : ordered) {
                State state = states.get(id);
                if (STATUS_OPEN_PERIODIC.equals(state.status())) {
                    disablePeriodic(id, state.opened().binWarehouseId(), actor);
                    openings.touch(state.opened(), actor);
                } else {
                    openings.revoke(state.opened(), actor);
                }
            }
            return new Outcome<>(null, new BatchResult(views(requested)));
        });
    }

    // ------------------------------------------------------------------ 状态与校验

    /** 一个车间加锁后的状态。 */
    private record State(UUID workshopId, String workshopName, String status, OpenedBin opened, Settings settings) {
        long version() {
            return opened == null ? 0 : opened.rowVersion();
        }
    }

    /** 已开通的车间这次要不要改来源仓: 选了另一个来源仓, 或要恢复按货品所属仓库而当前有来源仓。 */
    private static boolean sourceChanges(State state, UUID source, boolean clearSource) {
        UUID current = state.opened() == null ? null : state.opened().sourceWarehouseId();
        if (clearSource) return current != null;
        return source != null && !source.equals(current);
    }

    private State state(UUID workshopId) {
        String name = requireWorkshopDepartment(workshopId);
        OpenedBin opened = openings.openedForUpdate(workshopId);
        Settings settings = bins.settingsForUpdate(workshopId);
        return new State(workshopId, name, statusOf(opened != null, settings != null && settings.enabled()),
                opened, settings);
    }

    private static String statusOf(boolean opened, boolean periodic) {
        if (!opened) return STATUS_NOT_OPEN;
        return periodic ? STATUS_OPEN_PERIODIC : STATUS_OPEN;
    }

    /** 逐车间收集问题; 版本/状态不一致是冲突 (409), 其余是规则不满足 (422)。 */
    private static final class Problems {
        private final List<ApiError.FieldError> errors = new ArrayList<>();
        private boolean conflict;

        boolean checkVersion(State state, BinItem item) {
            if (item == null) return true;
            boolean statusChanged = item.expectedStatus() != null && !item.expectedStatus().equals(state.status());
            boolean versionChanged = item.expectedVersion() != null && item.expectedVersion() != state.version();
            if (!statusChanged && !versionChanged) return true;
            conflict = true;
            errors.add(new ApiError.FieldError(state.workshopId().toString(),
                    "「" + state.workshopName() + "」的内料仓设置已被别人改过, 请刷新后再试"));
            return false;
        }

        void rule(State state, String message) {
            errors.add(new ApiError.FieldError(state.workshopId().toString(),
                    "「" + state.workshopName() + "」" + message));
        }

        void throwIfAny(String verb) {
            if (errors.isEmpty()) return;
            String summary = errors.size() == 1 ? errors.getFirst().message()
                    : errors.size() + " 个车间不能" + verb + ", 这次一个都没办: "
                    + String.join("; ", errors.stream().map(ApiError.FieldError::message).toList());
            throw new ApiException(conflict ? ErrorCode.CONFLICT : ErrorCode.VALIDATION_FAILED, summary, errors);
        }
    }

    private static List<UUID> requireItems(List<BinItem> items) {
        if (items == null || items.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请至少选一个车间");
        }
        List<UUID> ids = new ArrayList<>();
        for (BinItem item : items) {
            if (item == null || item.workshopId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "所选车间不完整, 请刷新后重试");
            }
            ids.add(item.workshopId());
        }
        List<UUID> distinct = distinctIds(ids);
        if (distinct.size() != ids.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一个车间选了两次, 请刷新后重试");
        }
        if (distinct.size() > BATCH_LIMIT) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多办 " + BATCH_LIMIT + " 个车间");
        }
        return distinct;
    }

    private static Map<UUID, BinItem> itemsById(List<BinItem> items) {
        Map<UUID, BinItem> out = new LinkedHashMap<>();
        for (BinItem item : items) out.put(item.workshopId(), item);
        return out;
    }

    private static List<UUID> distinctIds(List<UUID> ids) {
        if (ids == null) return List.of();
        return List.copyOf(new LinkedHashSet<>(ids.stream().filter(java.util.Objects::nonNull).toList()));
    }

    private static List<WorkshopMaterialChoicePort.ProductChoice> distinctChoices(
            List<WorkshopMaterialChoicePort.ProductChoice> input) {
        if (input == null || input.isEmpty()) return List.of();
        Set<UUID> seen = new HashSet<>();
        for (WorkshopMaterialChoicePort.ProductChoice choice : input) {
            if (choice == null || choice.productGoodsId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "认料缺少产品");
            }
            if (!seen.add(choice.productGoodsId())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "同一个产品填了两次认料, 请合并");
            }
        }
        return List.copyOf(input);
    }

    /** 按车间 UUID 排序逐个取事务级建议锁 (多个批量命令交叉选车间时不会互相死锁)。 */
    private List<UUID> lockInOrder(List<UUID> workshopIds) {
        List<UUID> ordered = workshopIds.stream().sorted().toList();
        for (UUID id : ordered) {
            db.queryForObject("SELECT count(*) FROM (SELECT pg_advisory_xact_lock(hashtextextended(:key, 800))) locked",
                    Map.of("key", "WORKSHOP-BIN:" + id), Long.class);
        }
        return ordered;
    }

    private String requireWorkshopDepartment(UUID workshopId) {
        if (workshopId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择车间");
        List<String> names = db.queryForList("""
                SELECT workshop.name FROM departments workshop
                JOIN departments production ON production.id = workshop.parent_id AND production.code = 'DEPT_PROD'
                WHERE workshop.id = :id AND NOT workshop.is_deleted
                """, Map.of("id", workshopId), String.class);
        if (names.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "内料仓只能给生产部下的车间开通");
        }
        scope.requireWorkshop(workshopId);
        return names.getFirst();
    }

    private boolean binHoldsPeriodicStock(UUID bin) {
        Boolean held = db.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM stock_balances balance
                               JOIN goods material ON material.id = balance.goods_id AND material.issue_method = 'PERIODIC'
                               WHERE balance.warehouse_id = :bin AND balance.qty <> 0)
                """, Map.of("bin", bin), Boolean.class);
        return Boolean.TRUE.equals(held);
    }

    private boolean closedAfterGoLive(State state, LocalDate goLive) {
        if (state.opened() == null) return false;
        Boolean closed = db.queryForObject("""
                SELECT EXISTS (SELECT 1 FROM workshop_material_periods period
                               WHERE period.bin_warehouse_id = :bin AND period.status = 'CLOSED'
                                 AND period.end_date >= :goLive)
                """, new MapSqlParameterSource("bin", state.opened().binWarehouseId()).addValue("goLive", goLive),
                Boolean.class);
        return Boolean.TRUE.equals(closed);
    }

    private List<UUID> pendingProducts(UUID workshopId) {
        return db.queryForList("SELECT DISTINCT pending.product_goods_id FROM ("
                + WorkshopMaterialChoiceAdapter.IN_PROGRESS_NEED_CHOICE_SQL + ") pending",
                Map.of("workshop", workshopId), UUID.class);
    }

    private List<String> productNames(List<UUID> products) {
        if (products.isEmpty()) return List.of();
        return db.queryForList("SELECT COALESCE(name, code) FROM goods WHERE id IN (:ids) ORDER BY name, code",
                Map.of("ids", products), String.class);
    }

    /** 整批领料已经在用的原因 (有一条就不能撤销整批领料)。 */
    private List<String> periodicUsage(UUID bin) {
        Map<String, Object> row = db.queryForMap("""
                SELECT (SELECT count(*) FROM v_workshop_material_bin_ledger WHERE bin_warehouse_id = :bin) AS ledger,
                       (SELECT count(*) FROM production_execution_periodic_materials WHERE bin_warehouse_id = :bin) AS bound,
                       (SELECT count(*) FROM workshop_material_requisitions WHERE bin_warehouse_id = :bin
                                                                              AND status = 'PENDING') AS pending,
                       (SELECT count(*) FROM workshop_material_periods WHERE bin_warehouse_id = :bin
                                                                         AND (period_no > 1 OR status <> 'OPEN')) AS counted
                """, Map.of("bin", bin));
        List<String> out = new ArrayList<>();
        if (WorkshopMaterialBinSupport.number(row.get("ledger")).longValue() > 0) out.add("内料仓已经有发料、退回或盘点记录");
        if (WorkshopMaterialBinSupport.number(row.get("bound")).longValue() > 0) out.add("已经有生产任务接上了内料仓的料");
        if (WorkshopMaterialBinSupport.number(row.get("pending")).longValue() > 0) out.add("还有待处理的领料或退回单");
        if (WorkshopMaterialBinSupport.number(row.get("counted")).longValue() > 0) out.add("已经盘点或结算过");
        return out;
    }

    // ------------------------------------------------------------------ 整批领料

    private void enablePeriodic(UUID workshopId, Settings current, UUID bin, LocalDate goLive, UUID actor) {
        MapSqlParameterSource params = new MapSqlParameterSource("workshop", workshopId).addValue("bin", bin)
                .addValue("goLive", goLive).addValue("actor", actor);
        if (current == null) {
            db.update("""
                    INSERT INTO workshop_material_settings(
                        workshop_department_id, periodic_enabled, periodic_bin_warehouse_id, go_live_date,
                        enabled_by, enabled_at, created_by)
                    VALUES (:workshop, TRUE, :bin, :goLive, :actor, now(), :actor)
                    """, params);
        } else {
            db.update("""
                    UPDATE workshop_material_settings
                    SET periodic_enabled = TRUE, periodic_bin_warehouse_id = :bin, go_live_date = :goLive,
                        enabled_by = :actor, enabled_at = now(), disabled_by = NULL, disabled_at = NULL,
                        row_version = row_version + 1
                    WHERE workshop_department_id = :workshop
                    """, params);
        }
        db.update("""
                INSERT INTO workshop_material_periods(bin_warehouse_id, workshop_department_id, period_no, start_date,
                                                     created_by)
                VALUES (:bin, :workshop, 1, :goLive, :actor)
                """, params);
    }

    /**
     * 本车间正在生产、状态已明确的段当场绑定 (同开工时的绑定规则): 来源段有有效用料行的复制为继承行,
     * 否则按产品 BOM 期间边建 BOM 行, 否则按有效用料认料建认料行。起始日 = 启用日。
     */
    private void bindInProgress(UUID workshopId, UUID bin, LocalDate goLive, UUID actor) {
        List<UUID> segments = db.queryForList("""
                SELECT segment.id FROM production_execution_segments segment
                WHERE segment.workshop_department_id = :workshop AND segment.status = 'IN_PROGRESS'
                  AND NOT segment.is_deleted
                  AND NOT EXISTS (SELECT 1 FROM production_execution_periodic_materials material_row
                                  WHERE material_row.execution_segment_id = segment.id)
                  AND fn_segment_bin_material_state(segment.id) = 'KNOWN'
                ORDER BY segment.source_segment_id NULLS FIRST, segment.id
                """, Map.of("workshop", workshopId), UUID.class);
        for (UUID segment : segments) {
            MapSqlParameterSource params = new MapSqlParameterSource("segment", segment).addValue("bin", bin)
                    .addValue("from", goLive).addValue("actor", actor);
            int inherited = db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        source_row_id, effective_from, created_by)
                    SELECT :segment, :bin, source_row.material_goods_id, source_row.material_color_id,
                           source_row.unit_id, 'INHERITED', source_row.id, :from, :actor
                    FROM production_execution_segments segment
                    JOIN production_execution_periodic_materials source_row
                      ON source_row.execution_segment_id = COALESCE(segment.source_segment_id, (
                             SELECT proof.source_execution_segment_id FROM production_actual_output_supplement_proofs proof
                             WHERE proof.supplement_execution_segment_id = segment.id
                             ORDER BY proof.created_at, proof.id LIMIT 1))
                     AND source_row.effective_to IS NULL
                    WHERE segment.id = :segment
                    ORDER BY source_row.created_at, source_row.id
                    """, params);
            if (inherited > 0) continue;
            int fromBom = db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        bom_item_id, design_qty_snapshot, effective_from, created_by)
                    SELECT :segment, :bin, bom.component_goods_id, COALESCE(bom.color_id, component.color_id),
                           component.unit_id, 'BOM', bom.id, bom.qty, :from, :actor
                    FROM production_execution_segments segment
                    JOIN goods_bom_items bom ON bom.goods_id = segment.product_goods_id AND NOT bom.is_deleted
                    JOIN goods component ON component.id = bom.component_goods_id AND component.issue_method = 'PERIODIC'
                    WHERE segment.id = :segment
                    ORDER BY bom.sort_order, bom.id
                    """, params);
            if (fromBom > 0) continue;
            db.update("""
                    INSERT INTO production_execution_periodic_materials(
                        execution_segment_id, bin_warehouse_id, material_goods_id, material_color_id, unit_id, origin,
                        choice_id, effective_from, created_by)
                    SELECT :segment, :bin, choice.material_goods_id, choice.material_color_id, material.unit_id,
                           'CHOICE', choice.id, :from, :actor
                    FROM production_execution_segments segment
                    JOIN goods_periodic_material_choices choice
                      ON choice.product_goods_id = segment.product_goods_id AND choice.superseded_at IS NULL
                     AND choice.kind = 'MATERIAL'
                    JOIN goods material ON material.id = choice.material_goods_id
                    WHERE segment.id = :segment
                    ORDER BY choice.chosen_at, choice.id
                    """, params);
        }
    }

    /** 撤销整批领料 (只撤销设错的开启): 删掉那张空的第 1 期与草稿盘点, 设置置为停用。内料仓仍保持开通。 */
    private void disablePeriodic(UUID workshopId, UUID bin, UUID actor) {
        for (Period period : bins.periodsOf(bin)) {
            db.update("DELETE FROM workshop_material_counts WHERE period_id = :id AND status = 'DRAFT'",
                    Map.of("id", period.id()));
            db.update("DELETE FROM workshop_material_periods WHERE id = :id", Map.of("id", period.id()));
        }
        db.update("""
                UPDATE workshop_material_settings
                SET periodic_enabled = FALSE, disabled_by = :actor, disabled_at = now(), row_version = row_version + 1
                WHERE workshop_department_id = :workshop
                """, new MapSqlParameterSource("actor", actor).addValue("workshop", workshopId));
    }

    // ------------------------------------------------------------------ 视图

    private List<SettingsView> views(List<UUID> workshopIds) {
        if (workshopIds.isEmpty()) return List.of();
        Map<UUID, Map<String, Object>> rows = new LinkedHashMap<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT workshop.id, workshop.name, opened.bin_warehouse_id, opened.source_warehouse_id,
                       opened.row_version, opened.opened_at, bin.name AS bin_name, bin.code AS bin_code,
                       source.name AS source_name, COALESCE(settings.periodic_enabled, FALSE) AS periodic,
                       settings.go_live_date,
                       CASE WHEN opened.bin_warehouse_id IS NULL THEN NULL
                            ELSE fn_warehouse_main_id(opened.bin_warehouse_id) END AS main_id
                FROM departments workshop
                LEFT JOIN workshop_bins opened ON opened.workshop_department_id = workshop.id
                LEFT JOIN warehouses bin ON bin.id = opened.bin_warehouse_id
                LEFT JOIN warehouses source ON source.id = opened.source_warehouse_id
                LEFT JOIN workshop_material_settings settings ON settings.workshop_department_id = workshop.id
                WHERE workshop.id IN (:ids)
                """, Map.of("ids", workshopIds))) {
            rows.put((UUID) row.get("id"), row);
        }
        boolean canSetup = permissions.has(WorkshopMaterialPermissions.SETUP);
        List<SettingsView> out = new ArrayList<>();
        for (UUID workshopId : workshopIds) {
            Map<String, Object> row = rows.get(workshopId);
            if (row == null) throw new ApiException(ErrorCode.NOT_FOUND, "车间不存在");
            UUID bin = (UUID) row.get("bin_warehouse_id");
            boolean periodic = bin != null && Boolean.TRUE.equals(row.get("periodic"));
            String status = statusOf(bin != null, periodic);
            Period open = null;
            Period pending = null;
            if (periodic) {
                for (Period period : bins.periodsOf(bin)) {
                    if ("OPEN".equals(period.status())) open = period;
                    if (pending == null && ("COUNTING".equals(period.status()) || "COUNTED".equals(period.status()))) {
                        pending = period;
                    }
                }
            }
            List<String> blockers = switch (status) {
                case STATUS_OPEN_PERIODIC -> periodicUsage(bin);
                case STATUS_OPEN -> openings.revokeBlockers(bin);
                default -> List.of();
            };
            UUID main = (UUID) row.get("main_id");
            List<String> actions = new ArrayList<>();
            if (canSetup) {
                actions.add("SETUP");
                switch (status) {
                    case STATUS_NOT_OPEN -> {
                        actions.add("OPEN");
                        actions.add("ENABLE_PERIODIC");
                    }
                    case STATUS_OPEN -> {
                        actions.add("ENABLE_PERIODIC");
                        actions.add("CHANGE_SOURCE");
                    }
                    default -> actions.add("CHANGE_SOURCE");
                }
                if (!STATUS_NOT_OPEN.equals(status) && blockers.isEmpty()) actions.add("REVOKE");
            }
            out.add(new SettingsView(workshopId, (String) row.get("name"), status, bin != null, periodic, bin,
                    (String) row.get("bin_name"), (String) row.get("bin_code"),
                    (UUID) row.get("source_warehouse_id"), (String) row.get("source_name"),
                    main, bins.warehouseName(main),
                    periodic ? WorkshopMaterialBinSupport.date(row.get("go_live_date")) : null,
                    WorkshopMaterialBinSupport.number(row.get("row_version")).longValue(),
                    row.get("opened_at") == null ? null : WorkshopMaterialBinSupport.offset(row.get("opened_at")),
                    open == null ? null : open.ref(), pending == null ? null : pending.ref(),
                    List.copyOf(blockers), List.copyOf(actions)));
        }
        return out;
    }
}
