package com.uten.imp.features.org.employee.reconcile;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.sql.Array;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * 员工资料核对计划四张表(V810/ADR-160)的唯一存取类: 计划、逐人行、修复建议项(证件号旧值/新值/候选值
 * 均为密文)与更正回执。只做手写参数化 SQL 的读写, 不做业务判定(建议生成、确认与逐人 changeIdentity
 * 更正由服务层编排, 本类不知道密钥)。数组列用 {@code java.sql.Array} 绑定, 读写都不拼接值。
 */
@Repository
public class ReconcilePlanStore {

    private static final String PLAN_COLUMNS = """
            id, source, origin, actor_user_id, actor_employee_id, counts::text AS counts_json, status,
            closed_reason, version, applying_until, created_at, expires_at, last_applied_at, purged_at
            """;
    private static final String APPLY_COLUMNS = """
            id, round_no, request_id, status, counts::text AS counts_json, result::text AS result_json,
            started_at, finished_at
            """;

    private final JdbcTemplate jdbc;

    public ReconcilePlanStore(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** 计划头: 状态与统计; counts/closed_reason/applying_until 等可空列由数据库约束成对出现。 */
    public record PlanRow(UUID id, String source, String origin, UUID actorUserId, UUID actorEmployeeId,
                          String countsJson, String status, String closedReason, int version,
                          OffsetDateTime applyingUntil, OffsetDateTime createdAt, OffsetDateTime expiresAt,
                          OffsetDateTime lastAppliedAt, OffsetDateTime purgedAt) {}

    /** 逐人行: 生成时的员工版本 + 结果(未执行为 null)。 */
    public record RowRec(int rowNo, UUID employeeId, int employeeVersion, String kind,
                         List<String> noticeCodes, String result) {}

    /** 修复建议项: old/new/candidates 为密文, 位置与理由码是非敏感元数据; outcome 三列为执行回写。 */
    public record ItemRec(int rowNo, int itemNo, String fieldCode, String writePath,
                          String oldValueEnc, String newValueEnc, String candidatesEnc,
                          List<Integer> diffPositions, List<Integer> suspectPositions,
                          String basisCode, String tier, BigDecimal probability, boolean preselected,
                          List<String> noteCodes, String appliedOrigin, String outcome, String outcomeCode,
                          String outcomeMessage, UUID applyId, OffsetDateTime appliedAt) {}

    /** 更正回执: 同请求幂等、同计划轮次唯一; result 不含 6 位以上连续数字(数据库约束)。 */
    public record ApplyRec(UUID id, int roundNo, String requestId, String status,
                           String countsJson, String resultJson, OffsetDateTime startedAt,
                           OffsetDateTime finishedAt) {}

    /**
     * 新建计划(调用方事务内); 过期时间由调用方按 ADR-160 的 24 小时上限给出。
     *
     * <p>落库用 {@code LEAST(?, now() + interval '24 hours')}：应用时钟只要比数据库快一点
     * (不同机部署、虚拟机时钟漂移都是常态)，应用侧算出的 expires_at 就会撞上 ck_erp_expiry
     * 的 24 小时上限，整次生成 422。以数据库时钟封顶后两边时钟谁快都成立，有效期最多 24 小时。</p>
     */
    public UUID insertPlan(String source, String origin, UUID actorUserId, UUID actorEmployeeId,
                           String countsJson, OffsetDateTime expiresAt) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employee_reconcile_plans(id, source, origin, actor_user_id, actor_employee_id,
                    counts, expires_at)
                VALUES (?, ?, ?, ?, ?, ?::jsonb, LEAST(?::timestamptz, now() + interval '24 hours'))
                """, id, source, origin, actorUserId, actorEmployeeId, countsJson, expiresAt);
        return id;
    }

    /** 计划的逐人行(row_no 从 1 起, 由调用方排号; notice_codes 为提示码, 非敏感)。 */
    public void insertRow(UUID planId, int rowNo, UUID employeeId, int employeeVersion, String kind,
                          List<String> noticeCodes) {
        jdbc.update("""
                INSERT INTO employee_reconcile_plan_rows(plan_id, row_no, employee_id, employee_version, kind, notice_codes)
                VALUES (?, ?, ?, ?, ?, ?)
                """, ps -> {
            ps.setObject(1, planId);
            ps.setInt(2, rowNo);
            ps.setObject(3, employeeId);
            ps.setInt(4, employeeVersion);
            ps.setString(5, kind);
            ps.setArray(6, ps.getConnection().createArrayOf("varchar", texts(noticeCodes)));
        });
    }

    /** 一条修复建议(值列均为密文或位置码; required_permissions 用数据库默认 {employee:pii:edit})。 */
    public void insertItem(UUID planId, int rowNo, int itemNo, String fieldCode, String writePath,
                           String oldValueEnc, String newValueEnc, String candidatesEnc,
                           List<Integer> diffPositions, List<Integer> suspectPositions, String basisCode,
                           String tier, BigDecimal probability, boolean preselected, List<String> noteCodes) {
        jdbc.update("""
                INSERT INTO employee_reconcile_plan_items(plan_id, row_no, item_no, field_code, write_path,
                    old_value_enc, new_value_enc, candidates_enc, diff_positions, suspect_positions,
                    basis_code, tier, probability, preselected, note_codes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, ps -> {
            ps.setObject(1, planId);
            ps.setInt(2, rowNo);
            ps.setInt(3, itemNo);
            ps.setString(4, fieldCode);
            ps.setString(5, writePath);
            ps.setString(6, oldValueEnc);
            ps.setString(7, newValueEnc);
            ps.setString(8, candidatesEnc);
            ps.setArray(9, ps.getConnection().createArrayOf("smallint", ints(diffPositions)));
            ps.setArray(10, ps.getConnection().createArrayOf("smallint", ints(suspectPositions)));
            ps.setString(11, basisCode);
            ps.setString(12, tier);
            ps.setBigDecimal(13, probability);
            ps.setBoolean(14, preselected);
            ps.setArray(15, ps.getConnection().createArrayOf("varchar", texts(noteCodes)));
        });
    }

    /** 行锁读取计划(更正前先锁, 防两轮并发)。 */
    public Optional<PlanRow> lockPlan(UUID id) {
        return jdbc.query("SELECT " + PLAN_COLUMNS + " FROM employee_reconcile_plans WHERE id = ? FOR UPDATE",
                this::plan, id).stream().findFirst();
    }

    public Optional<PlanRow> findPlan(UUID id) {
        return jdbc.query("SELECT " + PLAN_COLUMNS + " FROM employee_reconcile_plans WHERE id = ?",
                this::plan, id).stream().findFirst();
    }

    /** 计划的逐人行, row_no 升序。 */
    public List<RowRec> findRows(UUID planId) {
        return jdbc.query("""
                SELECT row_no, employee_id, employee_version, kind, notice_codes, result
                FROM employee_reconcile_plan_rows WHERE plan_id = ? ORDER BY row_no
                """, (rs, i) -> new RowRec(rs.getInt("row_no"), rs.getObject("employee_id", UUID.class),
                rs.getInt("employee_version"), rs.getString("kind"), strings(rs, "notice_codes"),
                rs.getString("result")), planId);
    }

    /** 计划的全部修复建议项, row_no、item_no 升序。 */
    public List<ItemRec> findItems(UUID planId) {
        return jdbc.query("""
                SELECT row_no, item_no, field_code, write_path, old_value_enc, new_value_enc, candidates_enc,
                       diff_positions, suspect_positions, basis_code, tier, probability, preselected, note_codes,
                       applied_origin, outcome, outcome_code, outcome_message, apply_id, applied_at
                FROM employee_reconcile_plan_items WHERE plan_id = ? ORDER BY row_no, item_no
                """, this::item, planId);
    }

    /** 计划列表(created_at 倒序, 页码 1 起)。 */
    public List<PlanRow> listPlans(int page, int size) {
        return jdbc.query("SELECT " + PLAN_COLUMNS + """
                FROM employee_reconcile_plans ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?
                """, this::plan, size, (long) (page - 1) * size);
    }

    public long countPlans() {
        Long count = jdbc.queryForObject("SELECT count(*) FROM employee_reconcile_plans", Long.class);
        return count == null ? 0 : count;
    }

    public Optional<ApplyRec> findApplyByRequestId(UUID planId, String requestId) {
        return jdbc.query("SELECT " + APPLY_COLUMNS + """
                FROM employee_reconcile_applies WHERE plan_id = ? AND request_id = ?
                """, this::apply, planId, requestId).stream().findFirst();
    }

    /** 登记一轮更正(RUNNING), 同 (plan_id, request_id) 与 (plan_id, round_no) 由数据库唯一约束兜底。 */
    public ApplyRec insertApply(UUID planId, int roundNo, String requestId, UUID actorUserId) {
        return jdbc.queryForObject("""
                INSERT INTO employee_reconcile_applies(id, plan_id, round_no, request_id, actor_user_id)
                VALUES (?, ?, ?, ?, ?)
                RETURNING id, round_no, request_id, status, counts::text AS counts_json,
                          result::text AS result_json, started_at, finished_at
                """, this::apply, UUID.randomUUID(), planId, roundNo, requestId, actorUserId);
    }

    /** 一轮更正结束: FINISHED + 统计/结果, 计划回 OPEN、清 applying_until、记 last_applied_at、版本 +1。 */
    public void finishApply(UUID applyId, String countsJson, String resultJson) {
        jdbc.update("""
                UPDATE employee_reconcile_applies SET status = 'FINISHED', counts = ?::jsonb, result = ?::jsonb,
                                                       finished_at = now()
                WHERE id = ? AND status = 'RUNNING'
                """, countsJson, resultJson, applyId);
        jdbc.update("""
                UPDATE employee_reconcile_plans plan SET status = 'OPEN', applying_until = NULL,
                       last_applied_at = now(), version = version + 1
                WHERE plan.status = 'APPLYING'
                  AND plan.id = (SELECT apply.plan_id FROM employee_reconcile_applies apply WHERE apply.id = ?)
                """, applyId);
    }

    /** 一轮更正被中断(服务崩溃后的兜底标记; 计划回收由 {@link #reclaimStaleApplying} 做)。 */
    public void failApplyInterrupted(UUID applyId) {
        jdbc.update("""
                UPDATE employee_reconcile_applies SET status = 'INTERRUPTED', finished_at = now()
                WHERE id = ? AND status = 'RUNNING'
                """, applyId);
    }

    /**
     * 回写一条建议的执行结果。finalValueEnc 非空时(人事手工改值或改选候选)覆盖 new_value_enc,
     * 为空保持建议值密文; outcome/applied_at/apply_id 由数据库约束成对。
     */
    public void markItemOutcome(UUID planId, int rowNo, int itemNo, UUID applyId, String outcome,
                                String outcomeCode, String outcomeMessage, String appliedOrigin,
                                String finalValueEnc) {
        jdbc.update("""
                UPDATE employee_reconcile_plan_items SET outcome = ?, outcome_code = ?, outcome_message = ?,
                       applied_origin = ?, apply_id = ?, applied_at = now(),
                       new_value_enc = COALESCE(?, new_value_enc)
                WHERE plan_id = ? AND row_no = ? AND item_no = ?
                """, outcome, outcomeCode, outcomeMessage, appliedOrigin, applyId, finalValueEnc,
                planId, rowNo, itemNo);
    }

    /** 回写一行结果; newEmployeeVersion 非空时同步刷新行上的员工版本。 */
    public void markRowResult(UUID planId, int rowNo, String result, Integer newEmployeeVersion) {
        jdbc.update("""
                UPDATE employee_reconcile_plan_rows SET result = ?,
                       employee_version = COALESCE(?, employee_version)
                WHERE plan_id = ? AND row_no = ?
                """, result, newEmployeeVersion, planId, rowNo);
    }

    /** 关闭计划: CLOSED + 理由, 未执行项(outcome IS NULL)的旧值/新值/候选密文一并清掉, 记 purged_at。 */
    public void closePlan(UUID id, String reason) {
        jdbc.update("""
                UPDATE employee_reconcile_plans SET status = 'CLOSED', closed_reason = ?, purged_at = now()
                WHERE id = ? AND status <> 'CLOSED'
                """, reason, id);
        jdbc.update("""
                UPDATE employee_reconcile_plan_items SET old_value_enc = NULL, new_value_enc = NULL, candidates_enc = NULL
                WHERE plan_id = ? AND outcome IS NULL
                """, id);
    }

    /** 定时清理: 过期未关闭的计划按 closePlan 同一逻辑以 EXPIRED 关闭, 返回关闭的计划数。 */
    public int purgeExpired(OffsetDateTime now) {
        int expired = jdbc.update("""
                UPDATE employee_reconcile_plans SET status = 'CLOSED', closed_reason = 'EXPIRED', purged_at = now()
                WHERE status <> 'CLOSED' AND expires_at <= ?
                """, now);
        jdbc.update("""
                UPDATE employee_reconcile_plan_items item SET old_value_enc = NULL, new_value_enc = NULL, candidates_enc = NULL
                WHERE item.outcome IS NULL
                  AND EXISTS (SELECT 1 FROM employee_reconcile_plans plan
                              WHERE plan.id = item.plan_id AND plan.status = 'CLOSED' AND plan.closed_reason = 'EXPIRED')
                """);
        return expired;
    }

    /**
     * 回收卡死的更正轮: APPLYING 超过 applying_until 的计划回 OPEN(版本 +1, 让在看的页面重读),
     * 其 RUNNING 回执置 INTERRUPTED; 返回回收的计划数。
     */
    public int reclaimStaleApplying(OffsetDateTime now) {
        List<UUID> stale = jdbc.query("""
                SELECT id FROM employee_reconcile_plans WHERE status = 'APPLYING' AND applying_until < ?
                """, (rs, i) -> rs.getObject("id", UUID.class), now);
        if (stale.isEmpty()) {
            return 0;
        }
        jdbc.update("""
                UPDATE employee_reconcile_plans SET status = 'OPEN', applying_until = NULL, version = version + 1
                WHERE status = 'APPLYING' AND id = ANY (?)
                """, ps -> ps.setArray(1, ps.getConnection().createArrayOf("uuid", stale.toArray(UUID[]::new))));
        jdbc.update("""
                UPDATE employee_reconcile_applies SET status = 'INTERRUPTED', finished_at = now()
                WHERE status = 'RUNNING' AND plan_id = ANY (?)
                """, ps -> ps.setArray(1, ps.getConnection().createArrayOf("uuid", stale.toArray(UUID[]::new))));
        return stale.size();
    }

    private PlanRow plan(ResultSet rs, int index) throws SQLException {
        return new PlanRow(rs.getObject("id", UUID.class), rs.getString("source"), rs.getString("origin"),
                rs.getObject("actor_user_id", UUID.class), rs.getObject("actor_employee_id", UUID.class),
                rs.getString("counts_json"), rs.getString("status"), rs.getString("closed_reason"),
                rs.getInt("version"), rs.getObject("applying_until", OffsetDateTime.class),
                rs.getObject("created_at", OffsetDateTime.class), rs.getObject("expires_at", OffsetDateTime.class),
                rs.getObject("last_applied_at", OffsetDateTime.class), rs.getObject("purged_at", OffsetDateTime.class));
    }

    private ItemRec item(ResultSet rs, int index) throws SQLException {
        return new ItemRec(rs.getInt("row_no"), rs.getInt("item_no"), rs.getString("field_code"),
                rs.getString("write_path"), rs.getString("old_value_enc"), rs.getString("new_value_enc"),
                rs.getString("candidates_enc"), intList(rs, "diff_positions"), intList(rs, "suspect_positions"),
                rs.getString("basis_code"), rs.getString("tier"), rs.getBigDecimal("probability"),
                rs.getBoolean("preselected"), strings(rs, "note_codes"), rs.getString("applied_origin"),
                rs.getString("outcome"), rs.getString("outcome_code"), rs.getString("outcome_message"),
                rs.getObject("apply_id", UUID.class), rs.getObject("applied_at", OffsetDateTime.class));
    }

    private ApplyRec apply(ResultSet rs, int index) throws SQLException {
        return new ApplyRec(rs.getObject("id", UUID.class), rs.getInt("round_no"), rs.getString("request_id"),
                rs.getString("status"), rs.getString("counts_json"), rs.getString("result_json"),
                rs.getObject("started_at", OffsetDateTime.class), rs.getObject("finished_at", OffsetDateTime.class));
    }

    private static String[] texts(List<String> values) {
        return values == null ? new String[0] : values.stream().filter(Objects::nonNull).toArray(String[]::new);
    }

    private static Integer[] ints(List<Integer> values) {
        return values == null ? new Integer[0] : values.stream().filter(Objects::nonNull).toArray(Integer[]::new);
    }

    private static List<String> strings(ResultSet rs, String column) throws SQLException {
        Array array = rs.getArray(column);
        if (array == null) {
            return List.of();
        }
        try {
            Object[] elements = (Object[]) array.getArray();
            return java.util.Arrays.stream(elements).filter(Objects::nonNull).map(Object::toString).toList();
        } finally {
            array.free();
        }
    }

    private static List<Integer> intList(ResultSet rs, String column) throws SQLException {
        Array array = rs.getArray(column);
        if (array == null) {
            return List.of();
        }
        try {
            Object[] elements = (Object[]) array.getArray();
            return java.util.Arrays.stream(elements).filter(Objects::nonNull)
                    .map(element -> ((Number) element).intValue()).toList();
        } finally {
            array.free();
        }
    }
}
