package com.uten.imp.features.visitor;

import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Serializes SMS issuance for one normalized phone number across application instances.
 *
 * <p>The caller passes an HMAC-derived key rather than raw PII. PostgreSQL releases the
 * transaction advisory lock automatically on commit or rollback.
 */
@Component
@RequiredArgsConstructor
public class VisitorSmsSendLock {

    /** Independent fixed namespace; never derived from a JVM hash code. */
    static final long HASH_NAMESPACE = 0x5554454E534D534CL;

    private final EntityManager em;

    @Transactional(propagation = Propagation.MANDATORY)
    public void lock(String phoneKey) {
        em.createNativeQuery("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(CAST(:phoneKey AS text), CAST(:namespace AS bigint))
                        )
                        """)
                .setParameter("phoneKey", phoneKey)
                .setParameter("namespace", HASH_NAMESPACE)
                .getSingleResult();
    }
}
