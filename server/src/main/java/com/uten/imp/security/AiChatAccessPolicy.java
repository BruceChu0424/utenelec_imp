package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** Chat additionally requires real department membership; a stray page permission cannot expand it. */
@Component
public class AiChatAccessPolicy {
    private static final Set<String> ALL = Set.of("SELF", "SALES", "PRODUCTION", "PURCHASE", "WAREHOUSE", "FINANCE", "ADMIN", "QUALITY", "SUBCONTRACT", "HR", "RD");
    private final SecurityContextCurrentUser current;
    private final JdbcTemplate jdbc;

    public AiChatAccessPolicy(SecurityContextCurrentUser current, JdbcTemplate jdbc) {
        this.current = current;
        this.jdbc = jdbc;
    }

    public AuthUser requireChat() {
        AuthUser actor = current.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (actor.isVisitor() || actor.getEmployeeId() == null || actor.isMustChangePassword()
                || !actor.isAccountNonLocked() || actor.getImpersonatedBy() != null
                || !(actor.isSuperAdmin() || actor.getPermissions().contains("ai:use"))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号不能使用 AI 对话");
        }
        return actor;
    }

    public boolean hasDomain(String domain) {
        try { return domains().contains(domain); }
        catch (ApiException denied) { return false; }
    }

    public void requireDomain(String domain) {
        if (!hasDomain(domain)) throw new ApiException(ErrorCode.FORBIDDEN, "这项暂时不能查看，请联系管理员。");
    }

    public Set<String> domains() {
        AuthUser actor = requireChat();
        if (actor.isSuperAdmin()) return ALL;
        Set<String> contextual = departmentDomains(actor);
        Set<String> domains = new LinkedHashSet<>(Set.of("SELF"));
        Set<String> permissions = actor.getPermissions();
        if (contextual.contains("SALES") && any(permissions, "sales_order:", "sales_quote:")) domains.add("SALES");
        if (contextual.contains("PRODUCTION") && any(permissions, "production_", "workshop_material:")) domains.add("PRODUCTION");
        if (contextual.contains("PURCHASE") && any(permissions, "purchase_")) domains.add("PURCHASE");
        if (contextual.contains("WAREHOUSE") && any(permissions, "stock_", "stock:", "warehouse:", "warehouse_", "inventory:")) domains.add("WAREHOUSE");
        if (contextual.contains("FINANCE") && any(permissions, "finance", "goods:cost:", "sales_quote_finance:")) domains.add("FINANCE");
        if (contextual.contains("QUALITY") && any(permissions, "production_quality_inspection:", "procurement_inspection:", "sales_return_quality:")) domains.add("QUALITY");
        if (contextual.contains("SUBCONTRACT") && any(permissions, "subcontract_")) domains.add("SUBCONTRACT");
        if (contextual.contains("HR") && any(permissions, "employee:", "department:", "attendance:", "leave:")) domains.add("HR");
        if (contextual.contains("RD") && permissions.contains("rd_task:view")) domains.add("RD");
        return Set.copyOf(domains);
    }

    /**
     * Classification context from the real primary/secondary departments, including their ancestors.
     * This is only a preference hint: it grants no access. Authorization must still use domains()
     * and the business feature's normal function, row and field guards. Super-admin status does not
     * imply membership in every department.
     */
    public Set<String> contextualDomains() {
        return departmentDomains(requireChat());
    }

    /** Real membership identity for invalidating classification hints, including super administrators. */
    public String contextualMembershipFingerprint() {
        return String.join("|", memberships(requireChat()).stream().sorted().toList());
    }

    private Set<String> departmentDomains(AuthUser actor) {
        Set<String> codes = Set.copyOf(memberships(actor).stream().map(value -> value.substring(value.indexOf(':') + 1)).toList());
        Set<String> domains = new LinkedHashSet<>();
        if (codes.contains("DEPT_SALES") || codes.contains("DEPT_RAIL")) domains.add("SALES");
        if (codes.contains("DEPT_PROD") || codes.contains("SUB_PLAN") || codes.contains("SUB_WL")) domains.add("PRODUCTION");
        if (codes.contains("SUB_PURCHASE")) domains.add("PURCHASE");
        if (codes.contains("SUB_WH")) domains.add("WAREHOUSE");
        if (codes.contains("DEPT_FIN")) domains.add("FINANCE");
        if (codes.contains("DEPT_QA")) domains.add("QUALITY");
        if (codes.contains("QA_OUT") || codes.contains("DEPT_SALES")) domains.add("SUBCONTRACT");
        if (codes.contains("DEPT_HR")) domains.add("HR");
        if (codes.contains("DEPT_ENG")) domains.add("RD");
        return Set.copyOf(domains);
    }

    /** Recomputed for history reads, including department moves which leave the functional grant unchanged. */
    public String membershipFingerprint() {
        AuthUser actor = requireChat();
        return actor.isSuperAdmin() ? "SUPER_ADMIN" : String.join("|", memberships(actor).stream().sorted().toList());
    }

    private List<String> memberships(AuthUser actor) {
        return jdbc.queryForList("""
                WITH RECURSIVE active_employee AS (
                    SELECT e.id,e.department_id FROM employees e JOIN users u ON u.employee_id=e.id
                    WHERE e.id=? AND u.id=? AND NOT e.is_deleted AND NOT u.is_deleted
                      AND e.status IN ('active','probation','onLeave') AND u.status='active'
                ), memberships(id) AS (
                    SELECT department_id FROM active_employee
                    UNION SELECT s.department_id FROM employee_secondary_departments s
                        JOIN active_employee e ON e.id=s.employee_id
                ), ancestry(id,parent_id,code) AS (
                    SELECT d.id,d.parent_id,d.code FROM departments d JOIN memberships m ON m.id=d.id
                    WHERE NOT d.is_deleted
                    UNION SELECT d.id,d.parent_id,d.code FROM departments d JOIN ancestry a ON a.parent_id=d.id
                    WHERE NOT d.is_deleted
                ) SELECT id::text || ':' || code FROM ancestry
                """, String.class, actor.getEmployeeId(), actor.getId());
    }

    private static boolean any(Set<String> permissions, String... prefixes) {
        return permissions.stream().anyMatch(value -> java.util.Arrays.stream(prefixes).anyMatch(value::startsWith));
    }
}
