package com.uten.imp.features.org.employee.reconcile.dto;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 员工资料核对（V810/ADR-160）的响应视图与执行结果，字段名/JSON 形状与客户端实现钉死：
 * {@code PlanView}/{@code RowView}/{@code ItemView}/{@code PlanSummary}/{@code ApplyResult}。
 *
 * <p>值列全部是服务端解密后的结果；无 {@code employee:pii:view} 的读取方拿到的是打码值
 * （证件号只保留后四位），位置数组与候选列表清空。任何字段都不在服务端日志里打印证件号。</p>
 */
public final class ReconcilePlanViews {

    /**
     * 修复依据码 → 中文说明。BASIS_* 常量见 {@code IdRepairAdvisor}；
     * 审计 {@code AuditEventInterpreter} 对 {@code employee_reconcile.apply} 的 fields 渲染
     * 保留同一份文案（逐字一致）。
     */
    private static final Map<String, String> BASIS_LABELS = Map.ofEntries(
            Map.entry("NORMALIZE", "去分隔符"),
            Map.entry("MAP_CHAR", "字符纠正"),
            Map.entry("UPGRADE15", "15位升18位"),
            Map.entry("BIRTH_ANCHOR", "生日对齐"),
            Map.entry("DEL_REPEAT", "删除重复数字"),
            Map.entry("SWAP", "相邻对调"),
            Map.entry("CHECK_SOLVED", "校验码推算"),
            Map.entry("INS_X", "补末位X"),
            Map.entry("ERASE_SOLVED", "擦除求解"),
            Map.entry("TYPE_HINT", "可能是其他证件"));

    /** 依据码 → 中文；{@code NONE}/未知返回 null（无依据可展示）。 */
    public static String basisLabel(String basisCode) {
        if (basisCode == null || basisCode.isBlank() || "NONE".equals(basisCode)) {
            return null;
        }
        return BASIS_LABELS.get(basisCode);
    }

    // ------------------------------------------------------------------
    // 计划视图
    // ------------------------------------------------------------------

    public record PlanView(
            UUID id,
            int version,
            String status,
            String closedReason,
            String source,
            String origin,
            String actorName,
            OffsetDateTime createdAt,
            OffsetDateTime expiresAt,
            boolean canApply,
            String readOnlyReason,
            Capabilities capabilities,
            Counts counts,
            List<RowView> rows) {
    }

    public record Capabilities(boolean viewPii, boolean piiEdit) {
    }

    /** rows/update/info/same 为生成时统计；applied/skipped/failed 随执行结果实时累计。 */
    public record Counts(
            int rows,
            int update,
            int updateItems,
            int info,
            int same,
            int applied,
            int skipped,
            int failed) {
    }

    public record RowView(
            int rowNo,
            String kind,
            EmployeeRef employee,
            String reason,
            ClaimView claim,
            List<NoticeView> notices,
            List<ItemView> items,
            ResultView result) {
    }

    public record EmployeeRef(
            UUID id,
            String code,
            String name,
            String deptName,
            String positionName,
            LocalDate hireDate) {
    }

    /** 「XXX 处理中」的软认领展示（实时查询，非计划快照）；byMe 为当前读取人。 */
    public record ClaimView(String byName, boolean byMe, OffsetDateTime leaseUntil) {
    }

    public record NoticeView(String code, String message) {
    }

    public record ItemView(
            int itemNo,
            String field,
            String label,
            String writePath,
            String oldValue,
            String newValue,
            List<Integer> diffPositions,
            BasisView basis,
            String tier,
            Double probability,
            boolean preselected,
            boolean permitted,
            String permissionLabel,
            List<CandidateView> candidates,
            List<Integer> suspectPositions,
            List<String> notes,
            OutcomeView outcome) {
    }

    public record BasisView(String code, String label) {
    }

    /** 候选修复值；也是 {@code candidates_enc} 密文解密后的 JSON 结构。 */
    public record CandidateView(String value, Double probability, List<Integer> diffPositions) {
    }

    /** 执行回写后的单项结果；未执行为 null。 */
    public record OutcomeView(String status, String code, String message) {
    }

    /** 执行回写后的单行结果；未执行为 null。 */
    public record ResultView(String status, String message) {
    }

    public record PlanSummary(
            UUID id,
            OffsetDateTime createdAt,
            String actorName,
            String status,
            String closedReason,
            Counts counts) {
    }

    // ------------------------------------------------------------------
    // 执行结果（同样作为 employee_reconcile_applies.result 的落库 JSON，幂等重放时原样反序列化）
    // ------------------------------------------------------------------

    public record ApplyResult(
            int planVersion,
            int round,
            ApplyCounts counts,
            List<ApplyRowResult> rows,
            String summary) {
    }

    public record ApplyCounts(int applied, int skipped, int failed) {
    }

    public record ApplyRowResult(int rowNo, String result, List<ApplyItemResult> items) {
    }

    public record ApplyItemResult(int itemNo, String status, String message) {
    }

    private ReconcilePlanViews() {
    }
}
