package com.uten.imp.testsupport;

import java.util.Set;
import org.springframework.security.core.Authentication;
import org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Synthetic business actors satisfy CSRF; real Bearer and transport-rejection tests use their own requests. */
public final class BusinessHttpRequests {
    private static final Set<String> WRITE_METHODS = Set.of("POST", "PUT", "PATCH", "DELETE");

    private BusinessHttpRequests() { }

    public static RequestPostProcessor authenticated(Authentication actor) {
        var authentication = SecurityMockMvcRequestPostProcessors.authentication(actor);
        return request -> {
            var authenticated = authentication.postProcessRequest(request);
            if (WRITE_METHODS.contains(authenticated.getMethod())) {
                return SecurityMockMvcRequestPostProcessors.csrf().asHeader().postProcessRequest(authenticated);
            }
            return authenticated;
        };
    }
}
