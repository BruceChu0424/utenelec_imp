package com.uten.imp.features.production.mrp;

import com.uten.imp.features.production.fulfillment.ProductionExecutionSegment;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 货品「归属生产车间 + 归属车间负责人」的学习与预填（单一事实源 = 货品表两列，
 * V590 起原 production_goods_workshop_preferences 偏好表整体搬入并删除）。
 *
 * <p>从一个确认批次里无歧义的执行段学习未来默认车间；后续改派选择同样学习。
 * 这份便利读模型从不取代不可变的执行历史。</p>
 *
 * <p>2026-09-15 用户口径（V590）：货品资料表上的归属字段是唯一事实源——
 * 车间/负责人随最近一次排产确认或改派自动回写到 goods 行，预填与各处展示
 * （物料分析、货品资料）都读它。</p>
 */
@Service
@RequiredArgsConstructor
public class ProductionGoodsWorkshopPreferenceService {

    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public void learnSelection(
            UUID goodsId,
            UUID workshopId,
            UUID responsibleEmployeeId,
            UUID selectedBy) {
        if (goodsId == null || workshopId == null || selectedBy == null) {
            return;
        }
        apply(goodsId, workshopId, responsibleEmployeeId);
    }

    /**
     * Records at most one selection for each finished good in this planning
     * confirmation. A missing workshop or multiple workshops for one good is
     * deliberately ambiguous and therefore does not change the learned value.
     *
     * <p>2026-09-06 起同时学习负责人：仅在车间无歧义且本次负责人一致（非空）
     * 时更新；未填负责人不视为歧义、也不清掉旧记忆。</p>
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void learnFromConfirmedSegments(
            List<ProductionExecutionSegment> segments,
            UUID selectedBy) {
        if (segments == null || segments.isEmpty() || selectedBy == null) {
            return;
        }

        Map<UUID, WorkshopSelection> selections = new LinkedHashMap<>();
        for (ProductionExecutionSegment segment : segments) {
            if (segment == null || segment.getProductGoodsId() == null) {
                continue;
            }
            selections.computeIfAbsent(
                            segment.getProductGoodsId(),
                            ignored -> new WorkshopSelection())
                    .accept(
                            segment.getWorkshopDepartmentId(),
                            segment.getResponsibleEmployeeId());
        }

        selections.forEach((goodsId, selection) -> {
            if (selection.isUnambiguous()) {
                apply(goodsId, selection.workshopId, selection.learnedWorker());
            }
        });
    }

    /**
     * Returns valid learned defaults for planning UI prefill.
     *
     * <p>Only active goods and active direct children of {@code DEPT_PROD}
     * are returned. Stale attributions are ignored instead of leaking an
     * invalid workshop into a new plan draft. The learned responsible worker
     * is returned only while the employee is still current (not deleted /
     * not resigned).</p>
     */
    @Transactional(readOnly = true)
    public List<GoodsWorkshopPreferenceView> findValidByGoodsIds(
            Set<UUID> goodsIds) {
        if (goodsIds == null || goodsIds.isEmpty()) {
            return List.of();
        }
        List<Object[]> rows =
                com.uten.imp.common.util.NativeQueryResults.objectArrayRows(
                        em.createNativeQuery("""
                                SELECT g.id,
                                       g.owning_workshop_department_id,
                                       workshop.name,
                                       g.owning_responsible_employee_id,
                                       employee.full_name
                                FROM goods g
                                JOIN departments workshop
                                  ON workshop.id = g.owning_workshop_department_id
                                 AND workshop.is_deleted = FALSE
                                JOIN departments production_department
                                  ON production_department.id = workshop.parent_id
                                 AND production_department.code = 'DEPT_PROD'
                                 AND production_department.is_deleted = FALSE
                                LEFT JOIN employees employee
                                  ON employee.id = g.owning_responsible_employee_id
                                 AND employee.is_deleted = FALSE
                                 AND employee.status = 'active'
                                WHERE g.is_deleted = FALSE
                                  AND g.id IN (:goodsIds)
                                ORDER BY g.id
                                """)
                                .setParameter("goodsIds", goodsIds));
        return rows.stream()
                .map(row -> new GoodsWorkshopPreferenceView(
                        (UUID) row[0],
                        (UUID) row[1],
                        (String) row[2],
                        (UUID) row[3],
                        (String) row[4]))
                .toList();
    }

    /** 最近一次学习直接回写货品表两列（值没变不写，避免无谓审计行）。 */
    private void apply(UUID goodsId, UUID workshopId, UUID responsibleEmployeeId) {
        em.createNativeQuery("""
                        UPDATE goods g
                        SET owning_workshop_department_id = :workshopId,
                            owning_responsible_employee_id = CASE
                                -- 车间换了：负责人整体跟随本次选择（未选则为空）。
                                WHEN g.owning_workshop_department_id
                                        IS DISTINCT FROM :workshopId
                                    THEN :workerId
                                -- 车间没换：本次没选负责人时保留旧记忆。
                                WHEN :workerId IS NOT NULL
                                    THEN :workerId
                                ELSE g.owning_responsible_employee_id
                            END
                        WHERE g.id = :goodsId
                          AND g.is_deleted = FALSE
                          AND EXISTS (
                              SELECT 1
                              FROM departments d
                              WHERE d.id = :workshopId
                                AND d.is_deleted = FALSE
                                AND EXISTS (
                                    SELECT 1
                                    FROM departments pd
                                    WHERE pd.id = d.parent_id
                                      AND pd.code = 'DEPT_PROD'
                                      AND pd.is_deleted = FALSE))
                          AND (g.owning_workshop_department_id IS DISTINCT FROM :workshopId
                               OR g.owning_responsible_employee_id
                                      IS DISTINCT FROM COALESCE(:workerId,
                                          g.owning_responsible_employee_id))
                        """)
                .setParameter("goodsId", goodsId)
                .setParameter("workshopId", workshopId)
                .setParameter("workerId", responsibleEmployeeId)
                .executeUpdate();
    }

    private static final class WorkshopSelection {
        private UUID workshopId;
        private boolean ambiguous;
        private UUID workerId;
        private boolean workerAmbiguous;

        private void accept(UUID selectedWorkshopId, UUID selectedWorkerId) {
            if (selectedWorkshopId == null) {
                ambiguous = true;
            } else if (workshopId == null) {
                workshopId = selectedWorkshopId;
            } else if (!workshopId.equals(selectedWorkshopId)) {
                ambiguous = true;
            }
            // 未填负责人：不算歧义，也不学习（保留旧记忆）。
            if (selectedWorkerId == null) {
                return;
            }
            if (workerId == null) {
                workerId = selectedWorkerId;
            } else if (!workerId.equals(selectedWorkerId)) {
                workerAmbiguous = true;
            }
        }

        private boolean isUnambiguous() {
            return workshopId != null && !ambiguous;
        }

        /** 本次确认一致的负责人；未选或冲突（多段不同人）返回 null 不更新。 */
        private UUID learnedWorker() {
            return workerAmbiguous ? null : workerId;
        }
    }
}
