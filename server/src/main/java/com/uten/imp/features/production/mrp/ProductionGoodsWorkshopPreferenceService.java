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
 * Learns a future default workshop from unambiguous confirmed segments and
 * successful later assignment selections. This convenience read model never
 * replaces immutable execution history.
 */
@Service
@RequiredArgsConstructor
public class ProductionGoodsWorkshopPreferenceService {

    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public void learnSelection(
            UUID goodsId,
            UUID workshopId,
            UUID selectedBy) {
        if (goodsId == null || workshopId == null || selectedBy == null) {
            return;
        }
        upsert(goodsId, workshopId, selectedBy);
    }

    /**
     * Records at most one selection for each finished good in this planning
     * confirmation. A missing workshop or multiple workshops for one good is
     * deliberately ambiguous and therefore does not change the learned value.
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
                    .accept(segment.getWorkshopDepartmentId());
        }

        selections.forEach((goodsId, selection) -> {
            if (selection.isUnambiguous()) {
                upsert(goodsId, selection.workshopId, selectedBy);
            }
        });
    }

    /**
     * Returns valid learned defaults for planning UI prefill.
     *
     * <p>Only active goods and active direct children of {@code DEPT_PROD}
     * are returned. Stale preference rows are ignored instead of leaking an
     * invalid workshop into a new plan draft.</p>
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
                                SELECT preference.goods_id,
                                       preference.workshop_department_id,
                                       workshop.name
                                FROM production_goods_workshop_preferences preference
                                JOIN goods g
                                  ON g.id = preference.goods_id
                                 AND g.is_deleted = FALSE
                                JOIN departments workshop
                                  ON workshop.id = preference.workshop_department_id
                                 AND workshop.is_deleted = FALSE
                                JOIN departments production_department
                                  ON production_department.id = workshop.parent_id
                                 AND production_department.code = 'DEPT_PROD'
                                 AND production_department.is_deleted = FALSE
                                WHERE preference.goods_id IN (:goodsIds)
                                ORDER BY preference.goods_id
                                """)
                                .setParameter("goodsIds", goodsIds));
        return rows.stream()
                .map(row -> new GoodsWorkshopPreferenceView(
                        (UUID) row[0],
                        (UUID) row[1],
                        (String) row[2]))
                .toList();
    }

    private void upsert(UUID goodsId, UUID workshopId, UUID selectedBy) {
        em.createNativeQuery("""
                        INSERT INTO production_goods_workshop_preferences (
                            id, goods_id, workshop_department_id,
                            selection_count, last_selected_by,
                            last_selected_at, created_at, updated_at
                        )
                        SELECT gen_random_uuid(), g.id, d.id,
                               1, :selectedBy, now(), now(), now()
                        FROM goods g
                        JOIN departments d
                          ON d.id = :workshopId
                         AND d.is_deleted = FALSE
                        JOIN departments production_department
                          ON production_department.id = d.parent_id
                         AND production_department.code = 'DEPT_PROD'
                         AND production_department.is_deleted = FALSE
                        WHERE g.id = :goodsId
                          AND g.is_deleted = FALSE
                        ON CONFLICT (goods_id) DO UPDATE
                        SET workshop_department_id =
                                EXCLUDED.workshop_department_id,
                            selection_count =
                                production_goods_workshop_preferences
                                    .selection_count + 1,
                            last_selected_by = EXCLUDED.last_selected_by,
                            last_selected_at = EXCLUDED.last_selected_at,
                            updated_at = now()
                        """)
                .setParameter("goodsId", goodsId)
                .setParameter("workshopId", workshopId)
                .setParameter("selectedBy", selectedBy)
                .executeUpdate();
    }

    private static final class WorkshopSelection {
        private UUID workshopId;
        private boolean ambiguous;

        private void accept(UUID selectedWorkshopId) {
            if (selectedWorkshopId == null) {
                ambiguous = true;
            } else if (workshopId == null) {
                workshopId = selectedWorkshopId;
            } else if (!workshopId.equals(selectedWorkshopId)) {
                ambiguous = true;
            }
        }

        private boolean isUnambiguous() {
            return workshopId != null && !ambiguous;
        }
    }
}
