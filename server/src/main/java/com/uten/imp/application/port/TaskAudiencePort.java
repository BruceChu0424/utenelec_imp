package com.uten.imp.application.port;

/**
 * Runs a business-task read with actually granted authority and responsibility scope.
 * Administrative capability is deliberately not a subscription to every business task.
 */
public interface TaskAudiencePort {
    /** Same actual-grant derivation as read(), without entering/reusing a request-local read window. */
    default com.uten.imp.security.AuthUser freshTaskSubject(com.uten.imp.security.AuthUser sessionSubject) {
        throw new UnsupportedOperationException("Fresh task identity is required");
    }
    /** Task projections cannot accept the generic callbacks used by business commands. */
    @FunctionalInterface
    interface ReadQuery<T> {
        T read();
    }

    <T> T read(ReadQuery<T> work);

    /**
     * Runs a display-layer aggregate (workbench badges) as ordinary browsing under the
     * caller's own session principal: task rewriting and its warehouse task scope stay
     * suspended, so the numbers follow the same visibility as the pages they point to.
     */
    <T> T browsingRead(ReadQuery<T> work);
}
