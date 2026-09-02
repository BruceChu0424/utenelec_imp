package com.uten.imp.features.org.hrtask;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

import java.sql.Date;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * HR 任务中心：从员工档案动态计算人事提醒（转正 / 生日 / 入职周年 / 新入职）。
 *
 * 设计：
 * - 无任务表、不落库——每次请求按「今天」重算，结果天然随日期滚动；
 * - 转正视窗默认 3 个月（{@link #PROBATION_MONTHS}）：预计转正日 = hire_date + 3 个月；
 *   已登记 confirmed_at 的员工不再出现在转正提醒里；
 * - 逾期转正只跟踪近 {@link #CONFIRM_TRACK_MONTHS} 个月入职的员工；更早入职且未登记转正
 *   日期的老员工聚合为 unconfirmedLegacyCount（数据补录提示），避免刷出上百条噪音；
 * - 2 月 29 日生日在非闰年按 2 月 28 日庆祝（{@link #nextOccurrence}）；
 * - 员工规模（数百人级）一次查询内存计算即可，无需分页/物化视图。
 */
@Service
@RequiredArgsConstructor
public class HrTaskService {

    static final int PROBATION_MONTHS = 3;
    static final int UPCOMING_DAYS = 30;
    static final int NEW_HIRE_DAYS = 30;
    static final int CONFIRM_TRACK_MONTHS = 12;

    private static final String SELECT = """
            SELECT e.id, e.code, e.full_name,
                   d.name AS dept_name, p.name AS position_name,
                   e.hire_date, e.confirmed_at, e.birth_date
            FROM employees e
            JOIN departments d ON d.id = e.department_id
            LEFT JOIN positions p ON p.id = e.position_id
            WHERE e.is_deleted = false
              AND e.status IN ('active', 'probation')
            """;

    private final JdbcTemplate jdbc;
    private final HrTaskClaimService claimService;
    private final com.uten.imp.security.SecurityContextCurrentUser currentUser;

    /**
     * 按「今天」内存重算人事提醒（转正/生日/周年/新入职），无任务表、不落库。
     * 仅需 employee:view 即可调用，但生日派生信息属 PII：无 employee:pii:view 时生日列表清空且不计入徽标；
     * 本年已发布庆典祝福的生日/周年仍保留在列表（标记 blessed）但不计徽标。
     */
    public HrTaskSummary summary() {
        LocalDate today = LocalDate.now();
        List<Row> rows = jdbc.query(SELECT, (rs, i) -> new Row(
                rs.getObject("id", UUID.class),
                rs.getString("code"),
                rs.getString("full_name"),
                rs.getString("dept_name"),
                rs.getString("position_name"),
                toLocalDate(rs.getDate("hire_date")),
                toLocalDate(rs.getDate("confirmed_at")),
                toLocalDate(rs.getDate("birth_date"))));

        List<HrTaskSummary.Item> confirmToday = new ArrayList<>();
        List<HrTaskSummary.Item> confirmUpcoming = new ArrayList<>();
        List<HrTaskSummary.Item> confirmOverdue = new ArrayList<>();
        long unconfirmedLegacy = 0;
        List<HrTaskSummary.Item> birthdayToday = new ArrayList<>();
        List<HrTaskSummary.Item> birthdayUpcoming = new ArrayList<>();
        List<HrTaskSummary.Item> anniversaryToday = new ArrayList<>();
        List<HrTaskSummary.Item> newHires = new ArrayList<>();

        for (Row r : rows) {
            // ---- 转正：预计转正日 = 入职 + 3 个月；已登记转正日期者不再提醒 ----
            if (r.hireDate() != null && r.confirmedAt() == null) {
                LocalDate expected = r.hireDate().plusMonths(PROBATION_MONTHS);
                long daysLeft = ChronoUnit.DAYS.between(today, expected);
                boolean tracked = !r.hireDate().isBefore(today.minusMonths(CONFIRM_TRACK_MONTHS));
                if (daysLeft == 0) {
                    confirmToday.add(r.item(expected, 0, "预计今日转正，请及时办理"));
                } else if (daysLeft > 0 && daysLeft <= UPCOMING_DAYS) {
                    confirmUpcoming.add(r.item(expected, (int) daysLeft, null));
                } else if (daysLeft < 0 && tracked) {
                    confirmOverdue.add(r.item(expected, (int) -daysLeft, "已过预计转正日，待办理或核实"));
                } else if (daysLeft < 0) {
                    unconfirmedLegacy++;
                }
            }

            // ---- 生日（2/29 非闰年按 2/28） ----
            if (r.birthDate() != null) {
                LocalDate next = nextOccurrence(r.birthDate(), today);
                long daysLeft = ChronoUnit.DAYS.between(today, next);
                if (daysLeft == 0) {
                    birthdayToday.add(r.item(next, today.getYear() - r.birthDate().getYear(), "今日生日"));
                } else if (daysLeft <= UPCOMING_DAYS) {
                    birthdayUpcoming.add(r.item(next, (int) daysLeft, null));
                }
            }

            // ---- 入职周年 ----
            if (r.hireDate() != null && r.hireDate().getYear() < today.getYear()) {
                LocalDate anniv = nextOccurrence(r.hireDate(), today);
                if (anniv.equals(today)) {
                    int years = today.getYear() - r.hireDate().getYear();
                    anniversaryToday.add(r.item(r.hireDate(), years, "入职满 " + years + " 年"));
                }
            }

            // ---- 新入职（近 30 天） ----
            if (r.hireDate() != null) {
                long since = ChronoUnit.DAYS.between(r.hireDate(), today);
                if (since >= 0 && since <= NEW_HIRE_DAYS) {
                    newHires.add(r.item(r.hireDate(), (int) since, since == 0 ? "今日入职" : null));
                }
            }
        }

        // PII 边界：生日派生信息（姓名 + 出生月日 + 年龄）属 PII，仅 employee:pii:view 可见（与
        // EmployeeQueryService.detail 无该权限清空 birthDate 的边界一致）。本接口仅需 employee:view，
        // 故对无 PII 权限者清空生日列表且不计入徽标，避免仅 employee:view 即批量暴露生日。
        boolean canSeePii = currentUser.get()
                .map(u -> u.isSuperAdmin()
                        || u.getPermissions().contains(com.uten.imp.security.DataAccessPolicy.PII_VIEW))
                .orElse(false);
        if (!canSeePii) {
            birthdayToday = new ArrayList<>();
            birthdayUpcoming = new ArrayList<>();
        }

        // 本类型本年已出现在任何庆典卡（聚合或单人）的员工（V454 起按主角表口径，
        // 与 CelebrationScheduler / 一键祝福去重一致）：已祝福的生日/周年不再计入徽标
        // （HR 发布祝福后角标即减），但列表仍保留并标记 blessed。
        Set<UUID> blessedBirthday = new HashSet<>();
        Set<UUID> blessedAnniversary = new HashSet<>();
        if (!birthdayToday.isEmpty() || !anniversaryToday.isEmpty()) {
            List<Map<String, Object>> celeb = jdbc.queryForList("""
                    SELECT n.type, s.employee_id AS sid
                    FROM notices n
                    JOIN notice_celebration_subjects s ON s.notice_id = n.id
                    WHERE n.type IN ('birthday','anniversary')
                      AND s.employee_id IS NOT NULL
                      AND n.published_at >= make_date(?::int, 1, 1)
                    """, today.getYear());
            for (Map<String, Object> r : celeb) {
                UUID sid = (UUID) r.get("sid");
                if ("birthday".equals(r.get("type"))) {
                    blessedBirthday.add(sid);
                } else {
                    blessedAnniversary.add(sid);
                }
            }
        }
        birthdayToday = markBlessed(birthdayToday, blessedBirthday);
        anniversaryToday = markBlessed(anniversaryToday, blessedAnniversary);

        Comparator<HrTaskSummary.Item> byDays = Comparator.comparingInt(HrTaskSummary.Item::days);
        confirmUpcoming.sort(byDays);
        confirmOverdue.sort(byDays);
        birthdayUpcoming.sort(byDays);
        newHires.sort(Comparator.comparing(HrTaskSummary.Item::date).reversed());

        // ---- 软认领装配（ADR-021：任务不隐藏，显示「XXX 处理中」） ----
        Map<String, HrTaskClaim> claims = claimService.activeClaimsByTaskKey();
        if (!claims.isEmpty()) {
            UUID me = currentUser.employeeId().orElse(null);
            Map<UUID, String> names = new HashMap<>();
            confirmToday = attachClaims(confirmToday, "confirm", claims, names, me);
            confirmUpcoming = attachClaims(confirmUpcoming, "confirm", claims, names, me);
            confirmOverdue = attachClaims(confirmOverdue, "confirm", claims, names, me);
            birthdayToday = attachClaims(birthdayToday, "birthday", claims, names, me);
            birthdayUpcoming = attachClaims(birthdayUpcoming, "birthday", claims, names, me);
            anniversaryToday = attachClaims(anniversaryToday, "anniversary", claims, names, me);
            newHires = attachClaims(newHires, "newhire", claims, names, me);
        }

        long badge = confirmToday.size() + confirmOverdue.size()
                + birthdayToday.stream().filter(it -> !it.blessed()).count()
                + anniversaryToday.stream().filter(it -> !it.blessed()).count();

        return new HrTaskSummary(
                today, PROBATION_MONTHS,
                confirmToday, confirmUpcoming, confirmOverdue, unconfirmedLegacy,
                birthdayToday, birthdayUpcoming, anniversaryToday, newHires,
                badge);
    }

    public long badgeCount() {
        return summary().badgeCount();
    }

    /** 把本类型本年已祝福的员工对应条目标记 blessed（无命中则原样返回，避免无谓重建）。 */
    private List<HrTaskSummary.Item> markBlessed(List<HrTaskSummary.Item> items, Set<UUID> blessed) {
        if (blessed.isEmpty()) {
            return items;
        }
        return items.stream()
                .map(it -> blessed.contains(it.employeeId()) ? it.withBlessed(true) : it)
                .toList();
    }

    /** 给某个区块的条目贴上有效认领信息；认领人姓名按批缓存，避免逐条查库。 */
    private List<HrTaskSummary.Item> attachClaims(
            List<HrTaskSummary.Item> items, String taskType,
            Map<String, HrTaskClaim> claims, Map<UUID, String> names, UUID me) {
        return items.stream().map(it -> {
            HrTaskClaim claim = claims.get(taskType + ":" + it.employeeId());
            if (claim == null) return it;
            String name = names.computeIfAbsent(
                    claim.getClaimedBy(), claimService::claimantName);
            return it.withClaim(name, claim.getClaimedBy().equals(me), claim.getLeaseUntil());
        }).toList();
    }

    /** 月-日在目标年的落点；2/29 在非闰年落到 2/28；今年已过则取明年。 */
    private static LocalDate nextOccurrence(LocalDate source, LocalDate today) {
        LocalDate thisYear = safeDate(today.getYear(), source.getMonthValue(), source.getDayOfMonth());
        return thisYear.isBefore(today)
                ? safeDate(today.getYear() + 1, source.getMonthValue(), source.getDayOfMonth())
                : thisYear;
    }

    private static LocalDate safeDate(int year, int month, int day) {
        try {
            return LocalDate.of(year, month, day);
        } catch (Exception e) {
            // 2/29 → 非闰年 2/28
            return LocalDate.of(year, month, day - 1);
        }
    }

    private static LocalDate toLocalDate(Date date) {
        return date == null ? null : date.toLocalDate();
    }

    private record Row(UUID id, String code, String name, String deptName, String positionName,
                       LocalDate hireDate, LocalDate confirmedAt, LocalDate birthDate) {
        HrTaskSummary.Item item(LocalDate date, int days, String note) {
            return new HrTaskSummary.Item(id, code, name, deptName, positionName, date, days, note,
                    null, false, null, false);
        }
    }
}
