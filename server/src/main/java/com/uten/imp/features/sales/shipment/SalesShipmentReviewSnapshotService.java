package com.uten.imp.features.sales.shipment;

import com.uten.imp.common.util.CanonicalFingerprint;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Stable business content excludes accounting-rate recognition and later warehouse progress. */
@Service
@RequiredArgsConstructor
@Transactional(propagation=Propagation.MANDATORY)
public class SalesShipmentReviewSnapshotService {
    private final EntityManager em;
    private final SecurityContextCurrentUser currentUser;
    public record Snapshot(String json,String hash) {}
    public Snapshot snapshot(UUID shipmentId) {
        String json=(String)em.createNativeQuery("SELECT fn_customer_shipment_commercial_snapshot(:id)").setParameter("id",shipmentId).getSingleResult();
        return new Snapshot(json,CanonicalFingerprint.sha256(List.of(json)));
    }
    public String previousDecision(UUID shipmentId,long currentRevision) {
        var rows=em.createNativeQuery("""
                SELECT commercial_snapshot::text FROM sales_shipment_finance_release_events
                WHERE shipment_id=:id AND review_revision<:revision AND event_type IN ('RELEASED','REJECTED')
                  AND commercial_snapshot IS NOT NULL ORDER BY occurred_at DESC,id DESC LIMIT 1
                """).setParameter("id",shipmentId).setParameter("revision",currentRevision).getResultList();
        return rows.isEmpty()?"":rows.getFirst().toString();
    }
    public void submit(SalesShipment document) {
        em.flush(); Snapshot snapshot=snapshot(document.getId());OffsetDateTime time=OffsetDateTime.now();
        em.createNativeQuery("""
                INSERT INTO sales_shipment_submission_events(id,shipment_id,review_revision,content_hash,commercial_snapshot,
                    actor_user_id,actor_employee_id,occurred_at)
                VALUES(gen_random_uuid(),:id,:revision,:hash,CAST(:snapshot AS jsonb),:actor,:employee,:time)
                """).setParameter("id",document.getId()).setParameter("revision",document.getReviewRevision())
                .setParameter("hash",snapshot.hash()).setParameter("snapshot",snapshot.json())
                .setParameter("actor",currentUser.requireId()).setParameter("employee",currentUser.requireEmployeeId())
                .setParameter("time",time).executeUpdate();
        document.setSalesConfirmedRevision(document.getReviewRevision());document.setSalesConfirmedAt(time);
        document.setSalesConfirmedBy(currentUser.requireEmployeeId());document.setFinanceRejected(false);document.setFinanceRejectionReason(null);
    }
}
