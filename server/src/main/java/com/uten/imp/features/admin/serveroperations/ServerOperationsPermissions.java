package com.uten.imp.features.admin.serveroperations;

/** Shared server-operation capability expressions. Source configuration stays super-admin-only. */
public final class ServerOperationsPermissions {
    private ServerOperationsPermissions() {}

    public static final String UPDATE = "server:update";
    public static final String CLEANUP = "server:cleanup";
    public static final String READ_EXPRESSION = "!principal.visitor and !principal.mustChangePassword and "
            + "(principal.superAdmin or hasAnyAuthority('server_status:view','server:update','server:cleanup'))";
    public static final String UPDATE_EXPRESSION = "!principal.visitor and !principal.mustChangePassword and "
            + "principal.impersonatedBy == null and (principal.superAdmin or hasAuthority('server:update'))";
    public static final String CLEANUP_EXPRESSION = "!principal.visitor and !principal.mustChangePassword and "
            + "principal.impersonatedBy == null and (principal.superAdmin or hasAuthority('server:cleanup'))";
    public static final String SOURCE_EXPRESSION = "!principal.visitor and !principal.mustChangePassword and "
            + "principal.impersonatedBy == null and principal.superAdmin and hasAuthority('authorization:manage')";
}
