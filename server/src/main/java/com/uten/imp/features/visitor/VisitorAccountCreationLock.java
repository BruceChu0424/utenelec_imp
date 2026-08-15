package com.uten.imp.features.visitor;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Serializes first-account creation for one phone HMAC across application instances.
 *
 * <p>The lock is acquired before the authoritative phone-hash lookup and is released
 * automatically when the surrounding login transaction commits or rolls back.
 */
@Component
@RequiredArgsConstructor
public class VisitorAccountCreationLock {

    /** Independent fixed namespace; never derived from a JVM hash code. */
    static final long HASH_NAMESPACE = 0x5554454E5649534CL;

    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public void lock(String phoneHash) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(CAST(:phoneHash AS text), CAST(:namespace AS bigint))
                        )
                        """)
                .setParameter("phoneHash", phoneHash)
                .setParameter("namespace", HASH_NAMESPACE)
                .getSingleResult();
    }
}
