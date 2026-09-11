package com.uten.imp.features.production;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 「本人属于该执行段的车间」唯一口径（2026-09-11 抽出，原先只在生产日报守卫里内联）。
 *
 * <p>成员判定 = 段的负责人本人 ∪ 车间子树内的主职 ∪ 车间子树内的兼职 ∪ 车间子树部门的负责人，
 * 且员工在职（active/probation/onLeave）未删除。车间子树用递归 CTE 展开，父车间的人
 * 对子车间的段同样成立。
 *
 * <p>为什么需要它：V543 把 {@code production_plan:view:all} 从生产部默认包里删掉后，
 * 车间账号不再能「读取生产计划归属」，而执行段的写侧（开工/报工/确认用料）此前一律走
 * {@code DocumentAccessPolicy.requireScopedOperationWritable(计划制单人)}——于是车间负责人
 * 连自己车间的工单都开不了工（FullChainEndToEndTest 的
 * materialAnalysis_plannedWorkshopAssignmentStartsDirectlyAndRequiresStartBeforeReporting 坐实）。
 * 车间任务的读侧（我的车间任务列表）本就按车间归属收敛，写侧必须同口径：
 * 属于本车间 + 持动作权限即可操作，不再要求能读计划制单人。
 */
@Component
@RequiredArgsConstructor
public class ProductionWorkshopMembership {

    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;

    /**
     * @param workshopDepartmentId 执行段所属车间（为空表示未派工，一律不成立）
     * @param responsibleEmployeeId 执行段负责人（可空）
     * @param employeeId 当前操作人员工档案 id（可空）
     */
    @Transactional(readOnly = true)
    public boolean isWorkshopMember(
            UUID workshopDepartmentId, UUID responsibleEmployeeId, UUID employeeId) {
        // 超级管理员不隶属任何车间，却必须能替任何车间办理（开工/报工/确认用料）——
        // 否则「我的车间任务」对超管是一张点不动的表（2026-09-11 用户反馈）。
        // 超管标记每请求从库复读（见 AuthUser/JwtAuthFilter 的 av/ae 复核），
        // 不是 token 里可伪造的字段，所以这里放行是安全的。
        if (isSuperAdmin()) return true;
        if (employeeId == null) return false;
        if (employeeId.equals(responsibleEmployeeId)) return true;
        if (workshopDepartmentId == null) return false;
        Boolean eligible = (Boolean) em.createNativeQuery("""
                        WITH RECURSIVE workshop_tree(id) AS (
                            SELECT CAST(:workshopId AS uuid)
                            UNION ALL
                            SELECT child.id
                            FROM departments child
                            JOIN workshop_tree parent
                              ON child.parent_id = parent.id
                            WHERE child.is_deleted = FALSE
                        )
                        SELECT EXISTS (
                            SELECT 1
                            FROM employees employee
                            WHERE employee.id = CAST(:employeeId AS uuid)
                              AND employee.is_deleted = FALSE
                              AND employee.status IN (
                                  'active','probation','onLeave')
                              AND (
                                  employee.department_id IN (
                                      SELECT id FROM workshop_tree)
                                  OR EXISTS (
                                      SELECT 1
                                      FROM employee_secondary_departments secondary
                                      WHERE secondary.employee_id = employee.id
                                        AND secondary.department_id IN (
                                            SELECT id FROM workshop_tree))
                                  OR EXISTS (
                                      SELECT 1
                                      FROM departments managed
                                      WHERE managed.id IN (
                                          SELECT id FROM workshop_tree)
                                        AND managed.manager_id = employee.id
                                        AND managed.is_deleted = FALSE)
                              )
                        )
                        """)
                .setParameter("workshopId", workshopDepartmentId)
                .setParameter("employeeId", employeeId)
                .getSingleResult();
        return Boolean.TRUE.equals(eligible);
    }

    /** 超管标记取自安全上下文（JwtAuthFilter 已逐请求与库中 users.is_super_admin 复核）。 */
    private boolean isSuperAdmin() {
        return currentUser.get().map(AuthUser::isSuperAdmin).orElse(false);
    }
}
