package com.uten.imp.config;

import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;

class ChinaLocaleDefaultsTest {

    @Test
    void requestsWithoutAcceptLanguageUseSimplifiedChinese() {
        WebMvcConfig config = new WebMvcConfig(null, null);

        assertEquals(
                Locale.SIMPLIFIED_CHINESE,
                config.localeResolver().resolveLocale(new MockHttpServletRequest()));
    }
}
