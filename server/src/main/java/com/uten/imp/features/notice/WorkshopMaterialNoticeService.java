package com.uten.imp.features.notice;

import com.uten.imp.application.port.WorkshopMaterialNoticePort;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 车间内料仓通知 (ADR-131 §5.8, 规格 §2.6; 实现 {@link WorkshopMaterialNoticePort})。
 *
 * <p>领料/退料待办发给预填叶仓的仓管 (持发料权限; 没有仓管时发给全体持码人), 发完、收完或作废时撤卡。
 * 自动结算被拦时按拦截种类通知该补的人 (未审报工: 该车间的报工审核人与这些草稿的制单人; 缺单重:
 * BOM 维护人; 有理论没进过料: 内料仓所在主仓的仓管与本车间的认料人), 同一期同一种类条数不变不重发;
 * 结算完成或撤销时全部撤卡。连续失败达到上限时通知设置负责人。
 *
 * <p>与业务同事务, 失败随业务回滚 (同 {@link HrNoticeService}): 加入调用方事务 (没有时自开一个, 例如
 * 后台结算在自己的新事务里调用), 异常原样抛出。
 */
@Slf4j
@Service
@Transactional
public class WorkshopMaterialNoticeService implements WorkshopMaterialNoticePort {

    public static final String EVENT_REQUISITION_PENDING = "WORKSHOP_MATERIAL_REQUISITION_PENDING";
    public static final String EVENT_RETURN_PENDING = "WORKSHOP_MATERIAL_RETURN_PENDING";
    public static final String EVENT_CLOSE_BLOCKED_REPORT = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_REPORT";
    public static final String EVENT_CLOSE_BLOCKED_WEIGHT = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_WEIGHT";
    public static final String EVENT_CLOSE_BLOCKED_STOCK = "WORKSHOP_MATERIAL_CLOSE_BLOCKED_STOCK";
    public static final String EVENT_CLOSE_FAILING = "WORKSHOP_MATERIAL_CLOSE_FAILING";

    static final String AGGREGATE_REQUISITION = "WORKSHOP_MATERIAL_REQUISITION";
    static final String AGGREGATE_PERIOD = "WORKSHOP_MATERIAL_PERIOD";

    private static final String NOTICE_READ = "notice:read";
    private static final String ISSUE = "workshop_material:issue";
    private static final String CHOOSE = "workshop_material:choose";
    private static final String SETUP = "workshop_material:setup";
    private static final String REPORT_APPROVE = "production_daily_report:approve";
    private static final String BOM_EDIT = "goods:bom:edit";
    private static final String TYPE_TASK = "task";
    private static final String ROUTE_WAREHOUSE = "/warehouse/tasks?group=workshopMaterial";
    private static final String ROUTE_BIN = "/workshop-material/bin?workshopId=";

    private final NoticeService noticeService;
    private final UserAccountRepository userRepo;
    private final PermissionResolver permissionResolver;
    private final NoticePermissionCandidateQuery permissionCandidates;
    private final WarehouseNoticeRouter warehouseRouter;
    private final NamedParameterJdbcTemplate db;

    public WorkshopMaterialNoticeService(NoticeService noticeService, UserAccountRepository userRepo,
                                         PermissionResolver permissionResolver,
                                         NoticePermissionCandidateQuery permissionCandidates,
                                         WarehouseNoticeRouter warehouseRouter, JdbcTemplate jdbc) {
        this.noticeService = noticeService;
        this.userRepo = userRepo;
        this.permissionResolver = permissionResolver;
        this.permissionCandidates = permissionCandidates;
        this.warehouseRouter = warehouseRouter;
        this.db = new NamedParameterJdbcTemplate(jdbc);
    }

    // ========================= 领料 / 退料 =========================

    @Override
    public void requisitionPending(UUID requisitionId) {
        List<Map<String, Object>> headers = db.queryForList("""
                SELECT requisition.kind, workshop.name AS workshop_name,
                       (SELECT count(*) FROM workshop_material_requisition_lines line
                        WHERE line.requisition_id = requisition.id) AS line_count
                FROM workshop_material_requisitions requisition
                JOIN departments workshop ON workshop.id = requisition.workshop_department_id
                WHERE requisition.id = :id
                """, Map.of("id", requisitionId));
        if (headers.isEmpty()) return;
        Map<String, Object> header = headers.getFirst();
        List<Map<String, Object>> lines = db.queryForList("""
                SELECT goods.name AS goods_name, line.requested_qty, line.suggested_leaf_warehouse_id
                FROM workshop_material_requisition_lines line
                JOIN goods ON goods.id = line.goods_id
                WHERE line.requisition_id = :id
                ORDER BY line.line_no
                """, Map.of("id", requisitionId));
        if (lines.isEmpty()) return;
        boolean issue = "ISSUE".equals(header.get("kind"));
        String workshop = text(header.get("workshop_name"), "车间");
        String firstName = text(lines.getFirst().get("goods_name"), "料");
        String firstQty = kilograms((BigDecimal) lines.getFirst().get("requested_qty"));
        int kinds = ((Number) header.get("line_count")).intValue();
        String more = kinds > 1 ? "等 " + kinds + " 种料" : "";
        String title = (issue ? "车间要领料: " : "车间要退料: ") + workshop;
        String content = issue
                ? workshop + "申请领「" + firstName + "」" + firstQty + " 公斤" + more + ", 请发到" + workshop + "内料仓。"
                : workshop + "要退回「" + firstName + "」" + firstQty + " 公斤" + more + ", 请点收。";
        Set<UUID> leaves = new LinkedHashSet<>();
        for (Map<String, Object> line : lines) {
            if (line.get("suggested_leaf_warehouse_id") instanceof UUID leaf) leaves.add(leaf);
        }
        // ADR-149 唯一分发规则: 预填叶仓的子仓负责人 ∩ 持发料权限的人; 没有则主管; 再没有才发全部持权限的人。
        Set<UUID> holders = usersWithNoticeAnd(Set.of(ISSUE));
        Set<UUID> recipients = new LinkedHashSet<>(warehouseRouter.recipients(holders, leaves));
        String event = issue ? EVENT_REQUISITION_PENDING : EVENT_RETURN_PENDING;
        for (UUID target : recipients) {
            publish(target, title, content, ROUTE_WAREHOUSE, event, requisitionId);
        }
    }

    @Override
    public void requisitionResolved(UUID requisitionId) {
        sameTransaction(() -> noticeService.resolveReviewNotices(AGGREGATE_REQUISITION, requisitionId, "COMPLETED"));
    }

    // ========================= 自动结算被拦 / 失败 =========================

    @Override
    public void closeBlocked(UUID periodId, List<Blocker> blockers) {
        Map<String, Object> period = period(periodId);
        if (period == null) return;
        Set<String> present = new LinkedHashSet<>();
        for (Blocker blocker : blockers == null ? List.<Blocker>of() : blockers) {
            String event = eventOf(blocker.kind());
            if (event == null || blocker.count() <= 0) continue;
            present.add(event);
            UUID aggregate = aggregate(periodId, suffixOf(event));
            String content = content(event, period, blocker);
            if (alreadySent(aggregate, content)) continue;
            // 条数变了: 旧卡撤掉再发新卡。
            sameTransaction(() -> noticeService.resolveReviewNotices(AGGREGATE_PERIOD, aggregate, "UPDATED"));
            for (UUID target : recipients(event, periodId, period)) {
                publish(target, title(event), content, ROUTE_BIN + period.get("workshop_department_id"), event,
                        aggregate);
            }
        }
        for (String event : List.of(EVENT_CLOSE_BLOCKED_REPORT, EVENT_CLOSE_BLOCKED_WEIGHT, EVENT_CLOSE_BLOCKED_STOCK)) {
            if (!present.contains(event)) {
                UUID aggregate = aggregate(periodId, suffixOf(event));
                sameTransaction(() -> noticeService.resolveReviewNotices(AGGREGATE_PERIOD, aggregate, "COMPLETED"));
            }
        }
    }

    @Override
    public void closeResolved(UUID periodId) {
        for (String suffix : List.of("REPORT", "WEIGHT", "STOCK", "FAILING")) {
            UUID aggregate = aggregate(periodId, suffix);
            sameTransaction(() -> noticeService.resolveReviewNotices(AGGREGATE_PERIOD, aggregate, "COMPLETED"));
        }
    }

    @Override
    public void closeFailing(UUID periodId, String businessMessage) {
        Map<String, Object> period = period(periodId);
        if (period == null) return;
        String reason = businessMessage == null || businessMessage.isBlank() ? "系统没有给出原因" : businessMessage.strip();
        if (reason.length() > 200) reason = reason.substring(0, 200);
        String content = period.get("workshop_name") + "内料仓 " + range(period)
                + " 已经连续 3 次结算失败, 系统改为每天重试一次。原因: " + reason + "。请联系系统管理员处理。";
        UUID aggregate = aggregate(periodId, "FAILING");
        if (alreadySent(aggregate, content)) return;
        for (UUID target : usersWithNoticeAnd(Set.of(SETUP))) {
            publish(target, "车间内料仓结算连续失败", content, ROUTE_BIN + period.get("workshop_department_id"),
                    EVENT_CLOSE_FAILING, aggregate);
        }
    }

    // ========================= 收件人 =========================

    private Set<UUID> recipients(String event, UUID periodId, Map<String, Object> period) {
        UUID workshop = (UUID) period.get("workshop_department_id");
        Set<UUID> out = new LinkedHashSet<>();
        switch (event) {
            case EVENT_CLOSE_BLOCKED_REPORT -> {
                Set<UUID> approvers = usersWithNoticeAnd(Set.of(REPORT_APPROVE));
                Set<UUID> members = workshopMembers(workshop);
                for (UUID user : approvers) if (members.contains(user)) out.add(user);
                if (out.isEmpty()) out.addAll(approvers);
                // 审核人删不了别人的草稿: 另加这些草稿的制单人。
                for (UUID maker : draftMakers(periodId)) {
                    if (canReadNotices(maker)) out.add(maker);
                }
            }
            case EVENT_CLOSE_BLOCKED_WEIGHT -> out.addAll(usersWithNoticeAnd(Set.of(BOM_EDIT)));
            default -> {
                // ADR-149: 内料仓的「所在仓」= 该车间内料仓的来源仓(没设 = 未定仓, 交主管)。
                Set<UUID> issuers = usersWithNoticeAnd(Set.of(ISSUE));
                out.addAll(warehouseRouter.recipients(issuers, binSourceWarehouses(workshop)));
                Set<UUID> choosers = usersWithNoticeAnd(Set.of(CHOOSE));
                Set<UUID> members = workshopMembers(workshop);
                for (UUID user : choosers) if (members.contains(user)) out.add(user);
            }
        }
        return out;
    }

    private boolean canReadNotices(UUID userId) {
        return userRepo.findById(userId)
                .filter(user -> !user.isDeleted() && "active".equals(user.getStatus()) && user.getEmployeeId() != null)
                .map(user -> permissionResolver.grantedPermsOf(user).contains(NOTICE_READ))
                .orElse(false);
    }

    /** 活跃账号 × notice:read × 任一职能权限 (绑定员工档案的内部账号)。 */
    private Set<UUID> usersWithNoticeAnd(Set<String> anyPermission) {
        List<UserAccount> candidates = permissionCandidates == null
                ? userRepo.findAll()
                : permissionCandidates.possibleUsers(anyPermission).map(userRepo::findAllById).orElseGet(userRepo::findAll);
        Set<UUID> out = new LinkedHashSet<>();
        // 2026-10-09(ADR-063 追加修订): 任务卡池按「真实授出权限」解析，超管全量镜像不算任务归属。
        Set<String> adminGrantedPermissions = null;
        for (UserAccount user : candidates) {
            if (user == null || user.isDeleted() || !"active".equals(user.getStatus()) || user.getEmployeeId() == null) {
                continue;
            }
            Set<String> permissions;
            if (user.isSuperAdmin()) {
                if (adminGrantedPermissions == null) {
                    adminGrantedPermissions = permissionResolver.grantedPermsOf(user);
                }
                permissions = adminGrantedPermissions;
            } else {
                permissions = permissionResolver.grantedPermsOf(user);
            }
            if (!permissions.contains(NOTICE_READ)) continue;
            if (anyPermission.stream().anyMatch(permissions::contains)) out.add(user.getId());
        }
        return out;
    }

    /** 车间 (含下级班组) 的成员账号: 主部门、兼职部门或部门负责人。 */
    private Set<UUID> workshopMembers(UUID workshop) {
        if (workshop == null) return Set.of();
        return new LinkedHashSet<>(db.queryForList("""
                WITH RECURSIVE tree(id) AS (
                    SELECT CAST(:workshop AS uuid)
                    UNION
                    SELECT child.id FROM departments child JOIN tree parent ON child.parent_id = parent.id
                    WHERE NOT child.is_deleted
                )
                SELECT DISTINCT account.id
                FROM users account
                JOIN employees employee ON employee.id = account.employee_id AND NOT employee.is_deleted
                 AND employee.status IN ('active', 'probation', 'onLeave')
                WHERE NOT account.is_deleted AND account.status = 'active'
                  AND (employee.department_id IN (SELECT id FROM tree)
                       OR EXISTS (SELECT 1 FROM employee_secondary_departments secondary
                                  WHERE secondary.employee_id = employee.id
                                    AND secondary.department_id IN (SELECT id FROM tree))
                       OR EXISTS (SELECT 1 FROM departments managed
                                  WHERE managed.manager_id = employee.id AND managed.id IN (SELECT id FROM tree)))
                """, Map.of("workshop", workshop), UUID.class));
    }

    /** 拦住这一期的未审报工草稿的制单人账号。 */
    private List<UUID> draftMakers(UUID periodId) {
        return db.queryForList("""
                SELECT DISTINCT account.id
                FROM fn_workshop_material_close_blockers(:period) blocker
                JOIN production_daily_reports report ON report.id = blocker.report_id
                JOIN users account ON account.employee_id = report.maker_id AND NOT account.is_deleted
                 AND account.status = 'active'
                WHERE blocker.kind = 'DRAFT_REPORT'
                """, Map.of("period", periodId), UUID.class);
    }

    // ========================= 文案 =========================

    private static String eventOf(String kind) {
        if (BLOCKER_DRAFT_REPORT.equals(kind)) return EVENT_CLOSE_BLOCKED_REPORT;
        if (BLOCKER_MISSING_WEIGHT.equals(kind)) return EVENT_CLOSE_BLOCKED_WEIGHT;
        if (BLOCKER_THEORY_WITHOUT_STOCK.equals(kind)) return EVENT_CLOSE_BLOCKED_STOCK;
        return null; // 等上一期结算: 只在页面上显示, 不发通知
    }

    private static String suffixOf(String event) {
        return switch (event) {
            case EVENT_CLOSE_BLOCKED_REPORT -> "REPORT";
            case EVENT_CLOSE_BLOCKED_WEIGHT -> "WEIGHT";
            case EVENT_CLOSE_BLOCKED_STOCK -> "STOCK";
            default -> "FAILING";
        };
    }

    private static String title(String event) {
        return switch (event) {
            case EVENT_CLOSE_BLOCKED_REPORT -> "报工没审, 车间内料仓结不了账";
            case EVENT_CLOSE_BLOCKED_WEIGHT -> "请补产品的单个重量";
            default -> "有料没发进内料仓却已经在用";
        };
    }

    private static String content(String event, Map<String, Object> period, Blocker blocker) {
        String bin = period.get("workshop_name") + "内料仓";
        String range = range(period);
        String samples = blocker.samples().isEmpty() ? "" : String.join("、", blocker.samples().subList(0,
                Math.min(5, blocker.samples().size()))) + (blocker.samples().size() > 5 ? " 等" : "");
        return switch (event) {
            case EVENT_CLOSE_BLOCKED_REPORT -> bin + " " + range + " 已经盘点, 还有 " + blocker.count() + " 张报工没审核"
                    + (samples.isEmpty() ? "" : ": " + samples)
                    + "。请审核; 填错不要的草稿请制单人删掉。处理完系统会自动结算。";
            case EVENT_CLOSE_BLOCKED_WEIGHT -> bin + " " + range + " 有 " + blocker.count()
                    + " 个产品有产量, 但 BOM 里没填单个重量" + (samples.isEmpty() ? "" : ": " + samples)
                    + "。补好后系统会自动结算。";
            default -> bin + " " + range + ": " + (samples.isEmpty() ? "有 " + blocker.count() + " 种料" : "「"
                    + String.join("」「", blocker.samples().subList(0, Math.min(5, blocker.samples().size()))) + "」")
                    + "有产品报工用到, 但这一期没有发料记录。如果是发了料没录, 请仓库在\"直接发料\"里勾选"
                    + "\"这批料是上一期漏录的\", 补录到 " + range + " 这一期; 如果是认错了料, 请车间改认料或换料。"
                    + "处理完系统会自动结算。";
        };
    }

    private static String range(Map<String, Object> period) {
        Object start = period.get("start_date");
        Object end = period.get("end_date");
        return date(start) + " 至 " + (end == null ? "今天" : date(end));
    }

    private static String date(Object value) {
        if (value instanceof java.sql.Date sql) return sql.toLocalDate().toString();
        if (value instanceof LocalDate local) return local.toString();
        return String.valueOf(value);
    }

    private static String kilograms(BigDecimal qty) {
        return qty == null ? "0" : qty.stripTrailingZeros().toPlainString();
    }

    private static String text(Object value, String fallback) {
        return value == null || value.toString().isBlank() ? fallback : value.toString();
    }

    // ========================= 公共 =========================

    private List<UUID> binSourceWarehouses(UUID workshopId) {
        if (workshopId == null) return List.of();
        return db.queryForList("""
                SELECT source_warehouse_id FROM workshop_bins
                WHERE workshop_department_id = :workshop AND source_warehouse_id IS NOT NULL
                """, Map.of("workshop", workshopId), UUID.class);
    }

    private Map<String, Object> period(UUID periodId) {
        List<Map<String, Object>> rows = db.queryForList("""
                SELECT period.id, period.bin_warehouse_id, period.workshop_department_id, period.start_date,
                       period.end_date, workshop.name AS workshop_name
                FROM workshop_material_periods period
                JOIN departments workshop ON workshop.id = period.workshop_department_id
                WHERE period.id = :id
                """, Map.of("id", periodId));
        return rows.isEmpty() ? null : rows.getFirst();
    }

    static UUID aggregate(UUID periodId, String suffix) {
        return UUID.nameUUIDFromBytes((periodId + ":" + suffix).getBytes(StandardCharsets.UTF_8));
    }

    /** 同一聚合已有内容相同、未办结的通知: 不重发。 */
    private boolean alreadySent(UUID aggregate, String content) {
        Integer existing = db.queryForObject("""
                SELECT count(*) FROM notices
                WHERE aggregate_kind = :kind AND aggregate_id = :aggregate AND resolved_at IS NULL AND content = :content
                """, new MapSqlParameterSource("kind", AGGREGATE_PERIOD).addValue("aggregate", aggregate)
                .addValue("content", content), Integer.class);
        return existing != null && existing > 0;
    }

    private void publish(UUID target, String title, String content, String route, String event, UUID aggregate) {
        sameTransaction(() -> noticeService.publishForUser(target, title, content, TYPE_TASK, "车间内料仓", route,
                event, "important", aggregate));
    }

    private void sameTransaction(Runnable action) {
        try {
            action.run();
        } catch (RuntimeException error) {
            log.warn("车间内料仓通知写入失败, 随业务事务一起回滚: {}", error.getMessage());
            throw error;
        }
    }
}
