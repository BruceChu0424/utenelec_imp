package com.uten.imp.security;

/** Shared read policy for server operations and governed archive inspection. */
public final class ServerOperationsReadAccess {
    private ServerOperationsReadAccess() {}

    public static final String EXPRESSION = "!principal.visitor and !principal.mustChangePassword and "
            + "(principal.superAdmin or hasAnyAuthority('server_status:view','server:update','server:cleanup'))";
}
