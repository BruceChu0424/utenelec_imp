package com.uten.imp.security;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.mock.web.MockServletContext;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.web.FilterChainProxy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.transport.HttpsRedirectFilter;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;
import org.springframework.web.servlet.config.annotation.EnableWebMvc;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class HttpsRequestAuthoritySecurityIntegrationTest {
    private AnnotationConfigWebApplicationContext context;
    private MockMvc mvc;

    @Configuration(proxyBeanMethods = false)
    @EnableWebSecurity
    @EnableWebMvc
    static class TestConfiguration {
        @Bean
        SecurityFilterChain security(HttpSecurity http) throws Exception {
            http.addFilterBefore(new HttpsRequestAuthorityFilter(), HttpsRedirectFilter.class);
            http.redirectToHttps(Customizer.withDefaults());
            http.authorizeHttpRequests(a -> a.requestMatchers("/probe").permitAll().anyRequest().authenticated());
            return http.build();
        }
        @Bean
        ProbeController probeController() { return new ProbeController(); }
    }

    @RestController
    static class ProbeController {
        @GetMapping("/probe")
        String probe() { return "UP"; }
    }

    @BeforeEach
    void startInProcessHttpSecurity() {
        context = new AnnotationConfigWebApplicationContext();
        context.setServletContext(new MockServletContext());
        context.register(TestConfiguration.class);
        context.refresh();
        mvc = MockMvcBuilders.webAppContextSetup(context).apply(springSecurity()).build();
    }

    @AfterEach
    void closeContext() { if (context != null) context.close(); }

    @Test
    void originalFrameworkFilterReproducesTheExactReportedFailure() {
        var request = new MockHttpServletRequest("GET", "/actuator/health/readiness");
        request.setServerName("[::ffff:127.0.0.1]");
        request.setServerPort(8080);
        var failure = assertThrows(org.springframework.web.util.InvalidUrlException.class,
                () -> new HttpsRedirectFilter().doFilter(request, new MockHttpServletResponse(), (req, res) -> fail()));
        assertEquals("Bad authority", failure.getMessage());
        assertTrue(java.util.Arrays.stream(failure.getStackTrace()).anyMatch(f ->
                f.getClassName().equals("org.springframework.web.util.RfcUriParser$State$5")));
    }

    @ParameterizedTest
    @CsvSource({
            "'[::ffff:127.0.0.1]','[::ffff:7f00:1]'",
            "'[2001:db8::192.0.2.1]','[2001:db8::c000:201]'",
            "'[::1]','[::1]'",
            "'[0:0:0:0:0:ffff:7f00:1]','[0:0:0:0:0:ffff:7f00:1]'",
            "'imp.utenelec','imp.utenelec'",
            "'192.168.1.13','192.168.1.13'"
    })
    void redirectsValidHttpWithoutChangingPathQueryOrPortMapping(String host, String expected) throws Exception {
        String query = "value=a%2Fb&empty=&plus=a+b";
        var baselineRequest = new MockHttpServletRequest("GET", "/probe");
        baselineRequest.setServerName(expected);
        baselineRequest.setServerPort(8080);
        baselineRequest.setQueryString(query);
        var baselineResponse = new MockHttpServletResponse();
        new HttpsRedirectFilter().doFilter(baselineRequest, baselineResponse, (req, res) -> fail());
        assertTrue(baselineResponse.getRedirectedUrl().startsWith("https://" + expected + ":8443/probe?"));
        // Preserve the framework's existing path/query encoding exactly; only the host changes.
        mvc.perform(get("/probe").with(request -> {
            request.setScheme("http"); request.setServerName(host); request.setServerPort(8080);
            request.setQueryString(query); return request;
        })).andExpect(status().isFound())
                .andExpect(header().string("Location", baselineResponse.getRedirectedUrl()));
    }

    @ParameterizedTest
    @ValueSource(strings = {"[zzzz::1]", "user@imp.utenelec", "imp.utenelec:443", "imp.utenelec\r\nX-Forged: true"})
    void rejectsMalformedEffectiveAuthorityWith400(String host) throws Exception {
        mvc.perform(get("/probe").with(request -> { request.setServerName(host); return request; }))
                .andExpect(status().isBadRequest()).andExpect(header().doesNotExist("Location"))
                .andExpect(content().string(""));
    }

    @Test
    void trustedProxyEffectiveHttpsAndExistingBusinessHttpsAreNotRedirected() throws Exception {
        for (String host : new String[]{"imp.utenelec", "justplayit.cn", "[::ffff:127.0.0.1]"}) {
            mvc.perform(get("/probe").secure(true).with(request -> {
                // The native trusted-proxy valve supplies these effective servlet fields.
                request.setScheme("https"); request.setServerName(host); request.setServerPort(443); return request;
            })).andExpect(status().isOk()).andExpect(content().string("UP"))
                    .andExpect(header().doesNotExist("Location"));
        }
    }

    @Test
    void untrustedForwardingHeadersCannotChangeTheAuthorityOrBypassHttps() throws Exception {
        mvc.perform(get("/probe").header("Forwarded", "host=evil.example;proto=https")
                .header("X-Forwarded-Host", "evil.example").header("X-Forwarded-Proto", "https")
                .with(request -> { request.setServerName("imp.utenelec"); return request; }))
                .andExpect(status().isFound()).andExpect(header().string("Location", "https://imp.utenelec/probe"));
    }

    @Test
    void actualNativeValveKeepsTrustedAndUntrustedProxySemantics() throws Exception {
        for (String peer : new String[]{"127.0.0.1", "203.0.113.20"}) {
            var coyote = new org.apache.coyote.Request();
            coyote.scheme().setString("http");
            coyote.serverName().setString("imp.utenelec");
            coyote.setServerPort(8080);
            coyote.remoteAddr().setString(peer);
            coyote.remoteHost().setString(peer);
            coyote.getMimeHeaders().addValue("X-Forwarded-Proto").setString("https");
            coyote.getMimeHeaders().addValue("X-Forwarded-Host").setString("justplayit.cn");
            coyote.getMimeHeaders().addValue("X-Forwarded-Port").setString("443");
            var request = new org.apache.catalina.connector.Request(new org.apache.catalina.connector.Connector(), coyote);
            request.setRemoteAddr(peer);
            var effective = new java.util.concurrent.atomic.AtomicReference<EffectiveAuthority>();
            var valve = new org.apache.catalina.valves.RemoteIpValve();
            valve.setInternalProxies("127\\..*|::1");
            valve.setHostHeader("X-Forwarded-Host");
            valve.setPortHeader("X-Forwarded-Port");
            valve.setNext(new org.apache.catalina.valves.ValveBase() {
                @Override
                public void invoke(org.apache.catalina.connector.Request req,
                                   org.apache.catalina.connector.Response res) {
                    effective.set(new EffectiveAuthority(req.getScheme(), req.getServerName(), req.getServerPort()));
                }
            });
            valve.invoke(request, new org.apache.catalina.connector.Response(new org.apache.coyote.Response()));
            EffectiveAuthority observed = effective.get();
            if (peer.equals("127.0.0.1")) {
                assertEquals(new EffectiveAuthority("https", "justplayit.cn", 443), observed);
                mvc.perform(get("/probe").with(mock -> {
                    mock.setScheme(observed.scheme()); mock.setServerName(observed.host());
                    mock.setServerPort(observed.port()); return mock;
                })).andExpect(status().isOk()).andExpect(header().doesNotExist("Location"));
            } else {
                assertEquals(new EffectiveAuthority("http", "imp.utenelec", 8080), observed);
                mvc.perform(get("/probe").with(mock -> {
                    mock.setScheme(observed.scheme()); mock.setServerName(observed.host());
                    mock.setServerPort(observed.port()); return mock;
                })).andExpect(status().isFound())
                        .andExpect(header().string("Location", "https://imp.utenelec:8443/probe"));
            }
        }
    }

    private record EffectiveAuthority(String scheme, String host, int port) {}

    @Test
    void authenticationStillAppliesAfterHttpsAndAuthorityNormalization() throws Exception {
        mvc.perform(get("/private").secure(true).with(request -> {
            request.setScheme("https"); request.setServerName("imp.utenelec"); request.setServerPort(443); return request;
        })).andExpect(status().isForbidden());
        var filters = context.getBean(FilterChainProxy.class).getFilters("/probe");
        int normalization = java.util.stream.IntStream.range(0, filters.size())
                .filter(i -> filters.get(i) instanceof HttpsRequestAuthorityFilter).findFirst().orElseThrow();
        int redirect = java.util.stream.IntStream.range(0, filters.size())
                .filter(i -> filters.get(i) instanceof HttpsRedirectFilter).findFirst().orElseThrow();
        assertTrue(normalization < redirect);
    }
}
