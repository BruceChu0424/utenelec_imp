package com.uten.imp.features.finance.gl;

import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 报表设置: 维护总账附表/经营损益表「报表行 → 科目/部门」绑定(ADR-112)。
 *
 * <p>绑定属于科目体系配置, 与编辑收付款类别同一权限点; 读取随钱流报表查看权限。
 * 人工行只能绑部门, 其余可配置行只能绑费用类的末级科目(取数只算科目本身的发生额, 绑目录会漏算
 * 下级; 停用的科目仍可绑定, 用于统计它的历史发生额); 同一部门(含上下级)不能同时算进直接人工和
 * 间接人工, 避免工资重复计入。
 */
@Service
@RequiredArgsConstructor
public class GlReportLineBindingService {

    private static final int MAX_TARGETS = 200;

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

    /** 报表行绑定一览。 */
    public record LineBinding(String lineKey, String label, String bindingKind, List<Target> targets) {
    }

    /** 绑定目标(科目或部门)。 */
    public record Target(UUID id, String code, String name) {
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<LineBinding> list() {
        Map<String, List<Target>> targets = new LinkedHashMap<>();
        for (Object[] row : NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT binding.line_key, COALESCE(style.id, department.id),
                       COALESCE(style.code, department.code), COALESCE(style.name, department.name)
                FROM finance_report_line_bindings binding
                LEFT JOIN payment_styles style ON style.id = binding.style_id
                LEFT JOIN departments department ON department.id = binding.department_id
                ORDER BY binding.line_key, COALESCE(style.path, department.path)
                """))) {
            targets.computeIfAbsent((String) row[0], ignored -> new ArrayList<>())
                    .add(new Target((UUID) row[1], (String) row[2], (String) row[3]));
        }
        return GlReportLine.configurableLines().stream()
                .map(line -> new LineBinding(line.key(), line.label(), line.bindingKind(),
                        List.copyOf(targets.getOrDefault(line.key(), List.of()))))
                .toList();
    }

    /** 整行替换绑定: 传空列表即清空(报表该行显示未配置)。 */
    @Transactional
    @PreAuthorize("hasAuthority('payment_style:edit')")
    public LineBinding replace(String lineKey, List<UUID> targetIds) {
        tx.bind();
        GlReportLine line = lineKey == null ? null : GlReportLine.configurable(lineKey.trim());
        if (line == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "报表行不存在或不可配置");
        }
        Set<UUID> ids = new LinkedHashSet<>(targetIds == null ? List.of() : targetIds);
        if (ids.contains(null) || ids.size() > MAX_TARGETS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "绑定目标不能为空且最多 " + MAX_TARGETS + " 个");
        }
        boolean department = "DEPARTMENT".equals(line.bindingKind());
        if (!department) {
            // 与类别层级维护同一把锁(V265 协议): 校验到写入之间科目不会被挂上下级。
            // 加锁顺序固定为「类别层级 → 报表设置」, 与默认补齐、老库导入一致, 不会互等。
            PaymentStyleHierarchyLock.lock(em);
        }
        lockBindings();
        if (!ids.isEmpty()) {
            long valid = ((Number) em.createNativeQuery(department ? """
                    SELECT count(*) FROM departments
                    WHERE id IN (:ids) AND COALESCE(is_deleted, FALSE) = FALSE
                    """ : """
                    SELECT count(*) FROM payment_styles style
                    WHERE style.id IN (:ids) AND style.category = 'EXPENSE'
                      AND COALESCE(style.is_deleted, FALSE) = FALSE
                      AND NOT EXISTS (
                          SELECT 1 FROM payment_styles child
                          WHERE child.parent_id = style.id AND COALESCE(child.is_deleted, FALSE) = FALSE)
                    """).setParameter("ids", ids).getSingleResult()).longValue();
            if (valid != ids.size()) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, department
                        ? "所选部门不存在或已删除" : "只能绑定费用类的末级科目");
            }
            if (department) requireNoLaborOverlap(line.key(), ids);
            else requireOneLinePerStyleInSheet(line.key(), ids);
        }
        em.createNativeQuery("DELETE FROM finance_report_line_bindings WHERE line_key = :key")
                .setParameter("key", line.key()).executeUpdate();
        UUID actor = currentUser.requireId();
        for (UUID id : ids) {
            em.createNativeQuery(department ? """
                    INSERT INTO finance_report_line_bindings(line_key, binding_kind, department_id, created_by)
                    VALUES (:key, 'DEPARTMENT', :id, :actor)
                    """ : """
                    INSERT INTO finance_report_line_bindings(line_key, binding_kind, style_id, created_by)
                    VALUES (:key, 'STYLE', :id, :actor)
                    """).setParameter("key", line.key()).setParameter("id", id)
                    .setParameter("actor", actor).executeUpdate();
        }
        return list().stream().filter(item -> item.lineKey().equals(line.key())).findFirst().orElseThrow();
    }

    /**
     * 按默认科目名单为还没有任何绑定的行补默认绑定(与老库导入后执行的是同一个库函数, 幂等):
     * 已有绑定的行不动, 只绑费用类末级科目; 人工与折旧行不猜。返回补齐后的全部行绑定。
     */
    @Transactional
    @PreAuthorize("hasAuthority('payment_style:edit')")
    public List<LineBinding> seedDefaults() {
        tx.bind();
        PaymentStyleHierarchyLock.lock(em);
        lockBindings();
        em.createNativeQuery("SELECT fn_finance_report_line_bindings_seed_defaults()").getSingleResult();
        return list();
    }

    /**
     * 报表设置整表一把锁(库函数 fn_finance_report_line_bindings_seed_defaults 用同一把):
     * 跨行校验(直接/间接人工部门不重叠、同表一个科目只归一行)读到的都是已提交的绑定,
     * 两个财务同时改两条相关的行不会各自通过校验后重复计数。
     */
    private void lockBindings() {
        em.createNativeQuery("SELECT pg_advisory_xact_lock(hashtextextended(:key,0))")
                .setParameter("key", "uten:finance-report-line-bindings")
                .getSingleResult();
    }

    /** 同一张表里一个科目只能归一行(科目行与折旧行之间也一样), 否则该表合计会把它算两次。 */
    private void requireOneLinePerStyleInSheet(String lineKey, Set<UUID> styleIds) {
        Set<String> siblings = GlReportLine.styleSiblings(lineKey);
        if (siblings.isEmpty()) return;
        List<Object[]> clashes = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                SELECT binding.line_key, style.name
                FROM finance_report_line_bindings binding
                JOIN payment_styles style ON style.id = binding.style_id
                WHERE binding.binding_kind = 'STYLE' AND binding.style_id IN (:ids)
                  AND binding.line_key IN (:siblings)
                ORDER BY binding.line_key, style.path
                LIMIT 1
                """).setParameter("ids", styleIds).setParameter("siblings", siblings));
        if (!clashes.isEmpty()) {
            GlReportLine other = GlReportLine.configurable((String) clashes.getFirst()[0]);
            throw new ApiException(ErrorCode.CONFLICT, "科目「" + clashes.getFirst()[1] + "」已归到同一张报表的「"
                    + (other == null ? clashes.getFirst()[0] : other.label())
                    + "」，同一张表里一个科目只能归一行，否则合计会重复计算");
        }
    }

    /** 直接人工与间接人工的部门(含上下级)不能重叠, 否则同一张工资单会算两次。 */
    private void requireNoLaborOverlap(String lineKey, Set<UUID> departmentIds) {
        String otherLine = GlReportLine.LABOR_DIRECT.key().equals(lineKey)
                ? GlReportLine.LABOR_INDIRECT.key() : GlReportLine.LABOR_DIRECT.key();
        long overlaps = ((Number) em.createNativeQuery("""
                SELECT count(*)
                FROM finance_report_line_bindings other
                JOIN departments other_department ON other_department.id = other.department_id
                JOIN departments chosen ON chosen.id IN (:ids)
                WHERE other.line_key = :otherLine
                  AND (left(chosen.path, length(other_department.path)) = other_department.path
                       OR left(other_department.path, length(chosen.path)) = chosen.path)
                """).setParameter("ids", departmentIds).setParameter("otherLine", otherLine)
                .getSingleResult()).longValue();
        if (overlaps > 0) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "所选部门(或其上下级)已算在另一条人工行里，同一部门的工资不能同时计入直接人工和间接人工");
        }
    }
}
