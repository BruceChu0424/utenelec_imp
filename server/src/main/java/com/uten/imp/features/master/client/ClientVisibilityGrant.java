package com.uten.imp.features.master.client;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.IdClass;
import jakarta.persistence.Table;
import lombok.NoArgsConstructor;

import java.io.Serializable;
import java.util.Objects;
import java.util.UUID;

/**
 * Read-side mapping for the per-customer visibility table.
 *
 * <p>Writes stay in {@link ClientAccessService}; this mapping exists so customer
 * list/count/dictionary criteria can use a correlated EXISTS instead of loading
 * every shared customer UUID into the application and expanding a large IN list.</p>
 */
@Entity
@Table(name = "client_visibility_grants")
@IdClass(ClientVisibilityGrant.Key.class)
@NoArgsConstructor
public class ClientVisibilityGrant {

    @Id
    @Column(name = "client_id", nullable = false)
    private UUID clientId;

    @Id
    @Column(name = "grantee_employee_id", nullable = false)
    private UUID granteeEmployeeId;

    @Column(name = "active", nullable = false)
    private boolean active;

    /** Composite identity required by JPA; business writes never construct it. */
    public static final class Key implements Serializable {
        private UUID clientId;
        private UUID granteeEmployeeId;

        public Key() {
        }

        @Override
        public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Key key)) return false;
            return Objects.equals(clientId, key.clientId)
                    && Objects.equals(granteeEmployeeId, key.granteeEmployeeId);
        }

        @Override
        public int hashCode() {
            return Objects.hash(clientId, granteeEmployeeId);
        }
    }
}
