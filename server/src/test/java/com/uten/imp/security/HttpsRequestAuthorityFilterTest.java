package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;

class HttpsRequestAuthorityFilterTest {
    @ParameterizedTest
    @CsvSource({
            "'[::ffff:127.0.0.1]','[::ffff:7f00:1]'",
            "'[2001:db8::192.0.2.1]','[2001:db8::c000:201]'",
            "'[::0.0.0.0]','[::0:0]'",
            "'[::255.255.255.255]','[::ffff:ffff]'",
            "'[::1]','[::1]'",
            "'[0:0:0:0:0:ffff:7f00:1]','[0:0:0:0:0:ffff:7f00:1]'",
            "'::1','[::1]'",
            "'imp.utenelec','imp.utenelec'",
            "'192.168.1.13','192.168.1.13'"
    })
    void canonicalizesOnlyNumericEmbeddedIpv4(String host, String expected) {
        assertEquals(expected, HttpsRequestAuthorityFilter.canonicalHost(host, 8080));
    }

    @ParameterizedTest
    @ValueSource(strings = {"[zzzz::1]", "[::ffff:999.0.0.1]", "[::ffff:01.0.0.1]",
            "user@imp.utenelec", "imp.utenelec:443", "imp.utenelec/path", "imp.utenelec?x=1",
            "imp.utenelec#x", "imp.utenelec\\evil", "imp.utenelec\r\nX-Test: injected", "[fe80::1%25eth0]", "[::1", ""})
    void invalidAuthoritiesReturn400BeforeAnyDownstreamFilter(String host) throws Exception {
        var request = new MockHttpServletRequest("GET", "/api/example");
        request.setServerName(host);
        var response = new MockHttpServletResponse();
        var invoked = new AtomicBoolean();
        new HttpsRequestAuthorityFilter().doFilter(request, response, (req, res) -> invoked.set(true));
        assertEquals(400, response.getStatus());
        assertFalse(invoked.get());
        assertEquals("", response.getContentAsString());
        assertNull(response.getErrorMessage());
    }

    @Test
    void rejectsMissingHostAndOutOfRangePorts() {
        assertThrows(IllegalArgumentException.class, () -> HttpsRequestAuthorityFilter.canonicalHost(null, 80));
        for (int port : new int[]{-1, 0, 65536}) {
            assertThrows(IllegalArgumentException.class, () -> HttpsRequestAuthorityFilter.canonicalHost("imp.utenelec", port));
        }
    }
}
