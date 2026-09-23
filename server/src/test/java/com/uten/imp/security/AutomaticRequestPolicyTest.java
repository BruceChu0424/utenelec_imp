package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.mock.web.MockHttpServletRequest;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-110: 会话只由人为请求续期; 「是不是人不在场时发出的」只看客户端声明头, 与端点无关
 * (服务器状态、未读分来源计数、审核心跳这类不符合任何命名约定的常驻轮询同样不续期)。
 */
class AutomaticRequestPolicyTest {

    @ParameterizedTest(name = "header [{0}] -> automatic={1}")
    @CsvSource(value = {
            "1, true",
            "' 1 ', true",
            "0, false",
            "true, false",
            "'', false",
            "NULL, false"
    }, nullValues = "NULL")
    void onlyTheExplicitIdleMarkerCountsAsAutomatic(String header, boolean automatic) {
        assertEquals(automatic, AutomaticRequestPolicy.isAutomatic(header));
    }

    @Test
    void classificationIgnoresThePathAndMethodEntirely() {
        for (String path : new String[]{
                "/api/admin/server-status",
                "/api/notices/unread-count-by-source",
                "/api/notices/pending-review-status",
                "/api/production/material-analyses/abc",
                "/api/sales/orders/stats"}) {
            MockHttpServletRequest polled = new MockHttpServletRequest("GET", path);
            polled.addHeader(AutomaticRequestPolicy.HEADER, "1");
            assertTrue(AutomaticRequestPolicy.isAutomatic(polled), path);

            MockHttpServletRequest clicked = new MockHttpServletRequest("GET", path);
            assertFalse(AutomaticRequestPolicy.isAutomatic(clicked), path);
        }
        MockHttpServletRequest heartbeat = new MockHttpServletRequest("POST", "/api/task-claims/order/1/heartbeat");
        heartbeat.addHeader(AutomaticRequestPolicy.HEADER, "1");
        assertTrue(AutomaticRequestPolicy.isAutomatic(heartbeat));
    }
}
