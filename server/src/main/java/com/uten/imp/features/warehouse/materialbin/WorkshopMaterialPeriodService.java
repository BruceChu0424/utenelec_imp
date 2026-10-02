package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Period;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialBinSupport.Settings;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialCommandLedger.Outcome;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 内料仓期间 (ADR-131 §5.7 第 1、5 条): 不设盘点周期, 期间 = 相邻两次盘点之间。
 *
 * <p>开始盘点在实物清点开始那一刻按: 当场写本期截止日、本期变"盘点中"、同时开出下一期; 之后的
 * 领入、退回、其它耗用记进下一期。撤回盘点只在下一期还没有任何进出和盘点单时, 删掉自动开出的下一期。
 * 两个命令都先对设置行加排他锁 (与发料的共享锁互斥), 再锁期间行。
 */
@Service
public class WorkshopMaterialPeriodService {

    private final NamedParameterJdbcTemplate db;
    private final WorkshopMaterialBinSupport bins;
    private final WorkshopMaterialCommandLedger commands;
    private final WorkshopMaterialScope scope;
    private final WorkshopMaterialCountService counts;
    private final WorkshopMaterialPeriodViews views;
    private final SecurityContextCurrentUser currentUser;

    public WorkshopMaterialPeriodService(NamedParameterJdbcTemplate db, WorkshopMaterialBinSupport bins,
                                         WorkshopMaterialCommandLedger commands, WorkshopMaterialScope scope,
                                         WorkshopMaterialCountService counts, WorkshopMaterialPeriodViews views,
                                         SecurityContextCurrentUser currentUser) {
        this.db = db;
        this.bins = bins;
        this.commands = commands;
        this.scope = scope;
        this.counts = counts;
        this.views = views;
        this.currentUser = currentUser;
    }

    @Transactional(readOnly = true)
    public PeriodList list(UUID binWarehouseId) {
        if (binWarehouseId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择内料仓");
        Settings settings = bins.settingsByBin(binWarehouseId);
        if (settings == null) throw new ApiException(ErrorCode.NOT_FOUND, "这个仓库不是车间内料仓");
        scope.requireWorkshop(settings.workshopDepartmentId());
        return new PeriodList(views.ofBin(binWarehouseId));
    }

    /** 一期的详情 (盘点页只拿到期间, 靠它找当前盘点单); 车间成员只能看本车间的。 */
    @Transactional(readOnly = true)
    public PeriodView detail(UUID periodId) {
        if (periodId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择期间");
        Period period = bins.period(periodId);
        scope.requireWorkshop(period.workshopDepartmentId());
        PeriodView view = views.view(periodId);
        if (view == null) throw new ApiException(ErrorCode.NOT_FOUND, "这一期不存在");
        return view;
    }

    /** 开始盘点: 截止日默认今天, 可选更早 (例如交班时盘点选昨天), 不能早于本期开始日、不能晚于今天。 */
    @Transactional
    public StartCountResult startCount(UUID periodId, StartCountRequest request) {
        return commands.execute("COUNT_START", request.idempotencyKey(), List.of(periodId, request),
                StartCountResult.class, () -> {
                    Period loose = bins.period(periodId);
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    Settings settings = bins.enabledSettingsForUpdate(loose.workshopDepartmentId());
                    Period period = bins.periodForUpdate(periodId);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), period.rowVersion(), "这一期");
                    if (!"OPEN".equals(period.status())
                            || !WorkshopMaterialBinSupport.same(period.binWarehouseId(), settings.binWarehouseId())) {
                        throw new ApiException(ErrorCode.CONFLICT, "这一期已经开始盘点了, 请刷新");
                    }
                    Period previous = bins.periodByNo(period.binWarehouseId(), period.no() - 1);
                    if (previous != null && !"COUNTED".equals(previous.status()) && !"CLOSED".equals(previous.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "上一期的盘点还没提交, 请先提交上一期的盘点");
                    }
                    LocalDate today = BusinessTime.today();
                    LocalDate cutoff = request.cutoffDate() == null ? today : request.cutoffDate();
                    if (cutoff.isBefore(period.startDate())) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED,
                                "截止日不能早于这一期的开始日 " + period.startDate());
                    }
                    if (cutoff.isAfter(today)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, "截止日不能晚于今天");
                    }
                    UUID actor = currentUser.requireId();
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            UPDATE workshop_material_periods
                            SET status = 'COUNTING', end_date = :cutoff, counting_started_by = :actor,
                                counting_started_at = now(), row_version = row_version + 1
                            WHERE id = :id
                            """, new MapSqlParameterSource("cutoff", cutoff).addValue("actor", actor)
                            .addValue("id", periodId)));
                    UUID next = UUID.randomUUID();
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            INSERT INTO workshop_material_periods(
                                id, bin_warehouse_id, workshop_department_id, period_no, start_date, created_by)
                            VALUES (:id, :bin, :workshop, :no, :start, :actor)
                            """, new MapSqlParameterSource("id", next).addValue("bin", period.binWarehouseId())
                            .addValue("workshop", period.workshopDepartmentId()).addValue("no", period.no() + 1)
                            .addValue("start", cutoff.plusDays(1)).addValue("actor", actor)));
                    UUID count = counts.createFirstCount(periodId);
                    return new Outcome<>(periodId, new StartCountResult(views.view(periodId), views.view(next),
                            counts.detailOf(count)));
                });
    }

    /**
     * 审批库存盘点前恢复误启动的空周期盘点。必须没有任何实盘录入、后继期间事实；
     * 沿正式撤回命令留审计，与审批过账同事务，后续失败会恢复原来的期间与草稿。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    @PreAuthorize("hasAuthority('stock:count:warehouse_review')")
    public Period openForApprovedStockCount(UUID workshopId, UUID binId, UUID approvalEventId) {
        scope.requireWorkshop(workshopId);
        // 从一开始取排他锁，不能先 SHARE 再升级；发料、开始盘点与其它审批都按同一设置锁串行。
        Settings settings = bins.enabledSettingsForUpdate(workshopId);
        if (!binId.equals(settings.binWarehouseId())) {
            throw new ApiException(ErrorCode.CONFLICT, "车间内料仓已变化，请重新核对盘点申请");
        }
        Period open = bins.openPeriod(binId);
        boolean blockedByCutoff = BusinessTime.today().isBefore(open.startDate());
        Period previous = bins.periodByNo(binId, open.no() - 1);
        if (previous == null || !"COUNTING".equals(previous.status())) {
            if (!blockedByCutoff) return open;
            throw new ApiException(ErrorCode.CONFLICT,
                    "本期从 " + open.startDate() + " 开始，请到车间内料仓查看上一期盘点状态后再审核");
        }
        previous = bins.periodForUpdate(previous.id());
        bins.periodForUpdate(open.id());
        List<Map<String, Object>> drafts = db.queryForList("""
                SELECT id,status FROM workshop_material_counts WHERE period_id=:period ORDER BY id FOR UPDATE
                """, Map.of("period", previous.id()));
        // 锁盘点单父行也锁住新增录入行的 FK，避免检查零行后有人并发录入再被撤回。
        Integer entered = db.queryForObject("""
                SELECT count(*) FROM workshop_material_count_lines line
                JOIN workshop_material_counts counted ON counted.id=line.count_id WHERE counted.period_id=:period
                """, Map.of("period", previous.id()), Integer.class);
        if (drafts.size() != 1 || !"DRAFT".equals(drafts.getFirst().get("status"))
                || entered == null || entered > 0) {
            if (!blockedByCutoff) return open;
            throw new ApiException(ErrorCode.CONFLICT, "第 " + previous.no() + " 期已有盘点录入，不能自动退出。"
                    + "请到车间内料仓的周期盘点继续审核，或确认撤回本次盘点后，再审核这张库存盘点申请");
        }
        if (hasSuccessorFacts(open)) {
            if (!blockedByCutoff) return open;
            throw new ApiException(ErrorCode.CONFLICT, "第 " + previous.no() + " 期开始盘点后，下一期已有收发料、报工或盘点记录，不能自动退出。"
                    + "请先到车间内料仓完成第 " + previous.no() + " 期盘点，再按当前库存重新提交盘点申请");
        }
        withdrawCount(previous.id(), new VersionRequest(previous.rowVersion(), "COUNT-APPROVAL-RECOVER:" + approvalEventId));
        return bins.openPeriod(binId);
    }

    private boolean hasSuccessorFacts(Period next) {
        return Boolean.TRUE.equals(db.queryForObject("""
                SELECT EXISTS(SELECT 1 FROM v_workshop_material_bin_ledger WHERE period_id=:next)
                    OR EXISTS(SELECT 1 FROM workshop_material_counts WHERE period_id=:next)
                    OR EXISTS(SELECT 1 FROM workshop_material_period_lines WHERE period_id=:next)
                    OR EXISTS(SELECT 1 FROM workshop_material_period_closes WHERE period_id=:next)
                    OR EXISTS(SELECT 1 FROM workshop_material_periods WHERE bin_warehouse_id=:bin AND period_no>:no)
                    OR EXISTS(SELECT 1 FROM production_daily_reports report
                        JOIN production_daily_report_items item ON item.report_id=report.id AND NOT item.is_deleted
                        JOIN production_execution_periodic_materials material ON material.execution_segment_id=item.execution_segment_id
                        WHERE material.bin_warehouse_id=:bin AND NOT report.is_deleted AND report.bill_date>=:start)
                    OR EXISTS(SELECT 1 FROM production_execution_periodic_materials
                        WHERE bin_warehouse_id=:bin AND effective_from>=:start)
                """, new MapSqlParameterSource("next",next.id()).addValue("bin",next.binWarehouseId())
                .addValue("no",next.no()).addValue("start",next.startDate()), Boolean.class));
    }

    /** 撤回盘点: 只在"盘点中"且下一期没有任何进出与盘点单时; 删掉下一期, 本期回到"开着"。 */
    @Transactional
    public PeriodView withdrawCount(UUID periodId, VersionRequest request) {
        return commands.execute("COUNT_WITHDRAW", request.idempotencyKey(), List.of(periodId, request),
                PeriodView.class, () -> {
                    Period loose = bins.period(periodId);
                    scope.requireWorkshop(loose.workshopDepartmentId());
                    bins.enabledSettingsForUpdate(loose.workshopDepartmentId());
                    Period period = bins.periodForUpdate(periodId);
                    WorkshopMaterialBinSupport.requireVersion(request.expectedVersion(), period.rowVersion(), "这一期");
                    if (!"COUNTING".equals(period.status())) {
                        throw new ApiException(ErrorCode.CONFLICT, "只有正在盘点的那一期才能撤回盘点");
                    }
                    Period next = bins.periodByNo(period.binWarehouseId(), period.no() + 1);
                    if (next != null) {
                        bins.periodForUpdate(next.id());
                        if (!"OPEN".equals(next.status()) || hasSuccessorFacts(next)) {
                            throw new ApiException(ErrorCode.CONFLICT,
                                    "盘点开始后下一期已有收发料、报工或盘点记录，不能再撤回盘点");
                        }
                        WorkshopMaterialGuards.guarded(() -> db.update(
                                "DELETE FROM workshop_material_periods WHERE id = :id", Map.of("id", next.id())));
                    }
                    counts.deleteDrafts(periodId);
                    WorkshopMaterialGuards.guarded(() -> db.update("""
                            UPDATE workshop_material_periods
                            SET status = 'OPEN', end_date = NULL, counting_started_by = NULL, counting_started_at = NULL,
                                row_version = row_version + 1
                            WHERE id = :id
                            """, Map.of("id", periodId)));
                    return new Outcome<>(periodId, views.view(periodId));
                });
    }
}
