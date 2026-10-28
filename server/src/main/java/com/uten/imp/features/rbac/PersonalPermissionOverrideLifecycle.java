package com.uten.imp.features.rbac;

import jakarta.persistence.EntityManager;

import java.util.UUID;

/** Neutralizes a previous account lifecycle's overrides while retaining their CAS history. */
public final class PersonalPermissionOverrideLifecycle {

    private PersonalPermissionOverrideLifecycle() {}

    /** Remove only this recipient's current visibility grants; audit retains their before images. */
    public static int clearRecipientDataScopes(EntityManager entityManager, UUID userId) {
        return entityManager.createNativeQuery("DELETE FROM user_data_scopes WHERE user_id=:userId")
                .setParameter("userId", userId)
                .executeUpdate();
    }

    /** Caller must hold the employee/account lifecycle locks in its existing transaction. */
    public static int deactivateForEmployee(EntityManager entityManager, UUID employeeId) {
        entityManager.createNativeQuery("DELETE FROM user_permission_template_bindings WHERE user_id IN (SELECT id FROM users WHERE employee_id=:source)")
                .setParameter("source",employeeId).executeUpdate();
        entityManager.createNativeQuery("DELETE FROM permission_template_applies WHERE user_id IN (SELECT id FROM users WHERE employee_id=:source)")
                .setParameter("source",employeeId).executeUpdate();
        return entityManager.createNativeQuery("""
                        UPDATE user_permission_overrides permission_override
                        SET active=false, row_version=row_version+1
                        WHERE permission_override.active=true
                          AND permission_override.user_id IN (
                              SELECT id FROM users WHERE employee_id=:source)
                        """)
                .setParameter("source", employeeId)
                .executeUpdate();
    }
}
