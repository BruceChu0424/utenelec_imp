package com.uten.imp.audit;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import org.hibernate.annotations.Immutable;
import org.hibernate.annotations.Subselect;
import org.hibernate.annotations.Synchronize;
import java.util.UUID;

/** Query-only identity names for audit predicates; never an account/permission or lifecycle authority. */
@Entity
@Immutable
@Subselect("""
        SELECT 'staff:'||account.id::text AS row_key, account.id AS actor_id,
               employee.full_name AS actor_name, NULL::text AS alternate_name
        FROM users account JOIN employees employee ON employee.id=account.employee_id
        UNION ALL
        SELECT 'visitor:'||visitor.id::text AS row_key, visitor.id AS actor_id,
               visitor.name AS actor_name, visitor.visitor_no AS alternate_name
        FROM visitor_accounts visitor
        """)
@Synchronize({"users", "employees", "visitor_accounts"})
public class AuditActorNameSearch {
    @Id @Column(name="row_key")
    private String rowKey;
    @Column(name="actor_id")
    private UUID actorId;
    @Column(name="actor_name")
    private String actorName;
    @Column(name="alternate_name")
    private String alternateName;

    protected AuditActorNameSearch() { }
}
