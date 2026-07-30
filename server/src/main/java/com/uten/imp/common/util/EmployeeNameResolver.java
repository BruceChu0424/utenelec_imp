package com.uten.imp.common.util;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.UUID;

/**
 * 员工姓名解析：制单员/审核员等业务人名 ID → 员工姓名。
 *
 * <p>制单员/审核员字段统一存 employees.id（建单/审核时由 SecurityContextCurrentUser.requireEmployeeId 写入）。
 * 兼容两类历史数据：
 * <ol>
 *   <li>V125 回填前写入的 users.id（账号 ID）→ 经 users.employee_id 解析其绑定员工姓名；</li>
 *   <li>老库迁移行：maker/approver 为 NULL，姓名走 maker_legacy_id / maker_name 等遗留列（报表层处理）。</li>
 * </ol>
 */
@Component
@RequiredArgsConstructor
public class EmployeeNameResolver {

    private final EntityManager em;

    /** 按 employees.id 直查；查不到再按 users.id 兼容解析。皆无返回 null。 */
    public String nameOf(UUID id) {
        if (id == null) return null;
        Object direct = em.createNativeQuery("SELECT full_name FROM employees WHERE id = :id")
                .setParameter("id", id)
                .getResultStream().findFirst().orElse(null);
        if (direct != null) return direct.toString();
        Object viaUser = em.createNativeQuery(
                        "SELECT e.full_name FROM users u JOIN employees e ON e.id = u.employee_id WHERE u.id = :id")
                .setParameter("id", id)
                .getResultStream().findFirst().orElse(null);
        return viaUser != null ? viaUser.toString() : null;
    }
}
