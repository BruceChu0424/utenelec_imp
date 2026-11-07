package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;

/** Receipt-order allocation for explicitly ordered alternatives on the same material node. */
@Service
@RequiredArgsConstructor
public class PreplanReceiptPriorityService {
    private final EntityManager em;
    private final ObjectMapper mapper;

    @Transactional(propagation = Propagation.MANDATORY)
    public void recordPriority(UUID actionId, Map<UUID, BigDecimal> quantityByMaterial) {
        var rows = mapper.createArrayNode();
        quantityByMaterial.forEach((materialId, quantity) -> {
            if (quantity.signum() > 0) {
                var row = rows.addObject();
                row.put("material_id", materialId.toString());
                row.put("qty", quantity);
            }
        });
        if (rows.isEmpty()) return;

        int changed = em.createNativeQuery("""
                INSERT INTO preplan_receipt_priority_allocations(allocation_id, priority_qty)
                SELECT allocation.id, source.qty
                FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS source(material_id uuid, qty numeric)
                JOIN preplan_supply_action_allocations allocation
                  ON allocation.action_id=:actionId AND allocation.analysis_material_id=source.material_id
                """).setParameter("actionId", actionId).setParameter("rows", rows.toString()).executeUpdate();
        if (changed != rows.size()) {
            throw new ApiException(ErrorCode.CONFLICT, "优先补货的物料来源已变化，请刷新后重试");
        }
    }

    static BigDecimal withinHeadroom(Map<UUID, BigDecimal> remaining, UUID material, BigDecimal proposed) {
        BigDecimal headroom = remaining.get(material);
        return headroom == null ? proposed : proposed.min(headroom);
    }

    static void useHeadroom(Map<UUID, BigDecimal> remaining, UUID material, BigDecimal quantity) {
        remaining.computeIfPresent(material, (id, headroom) -> headroom.subtract(quantity));
    }
}
