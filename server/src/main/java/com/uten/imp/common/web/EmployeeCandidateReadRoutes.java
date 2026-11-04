package com.uten.imp.common.web;

/** Exact read bodies for large exclusion sets; adjacent candidate or handover commands stay writes. */
public final class EmployeeCandidateReadRoutes {
    private EmployeeCandidateReadRoutes() { }

    public static boolean matches(String method, String path) {
        return "POST".equals(method) && ("/api/master/clients/access-candidates/query".equals(path)
                || "/api/admin/data-handovers/candidates/query".equals(path));
    }
}
