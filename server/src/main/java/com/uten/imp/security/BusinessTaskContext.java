package com.uten.imp.security;

/** Distinguishes task responsibility from ordinary administrative browsing in shared caches/SQL. */
public final class BusinessTaskContext {
    private static final ThreadLocal<Boolean> ACTIVE = new ThreadLocal<>();
    private BusinessTaskContext() {}
    public static boolean active() { return Boolean.TRUE.equals(ACTIVE.get()); }

    public static Lease open() {
        boolean previous = active();
        ACTIVE.set(true);
        return new Lease(previous);
    }

    public static final class Lease implements AutoCloseable {
        private final boolean previous;
        private Lease(boolean previous) { this.previous = previous; }
        @Override public void close() {
            if (previous) ACTIVE.set(true);
            else ACTIVE.remove();
        }
    }
}
