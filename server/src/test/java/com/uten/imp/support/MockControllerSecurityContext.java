package com.uten.imp.support;

import org.springframework.mock.web.MockServletContext;
import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;

/** Real request-scoped dependencies and method-security proxies without starting a server. */
public final class MockControllerSecurityContext {
    private MockControllerSecurityContext() { }

    public static AnnotationConfigWebApplicationContext open(Class<?>... configurations) {
        var context = new AnnotationConfigWebApplicationContext();
        context.setServletContext(new MockServletContext());
        context.register(configurations);
        context.refresh();
        return context;
    }
}
