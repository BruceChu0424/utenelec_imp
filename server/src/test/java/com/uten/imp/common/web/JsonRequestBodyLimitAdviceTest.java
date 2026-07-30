package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.mock.http.MockHttpInputMessage;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.nio.charset.StandardCharsets;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class JsonRequestBodyLimitAdviceTest {

    @Test
    void rejectsChunkedJsonAfterReadingPastLimit() {
        JsonRequestBodyLimitAdvice advice = new JsonRequestBodyLimitAdvice(8);
        MockHttpInputMessage input = input("123456789", MediaType.APPLICATION_JSON);

        assertThrows(
                JsonBodyTooLargeException.class,
                () -> advice.beforeBodyRead(
                        input,
                        null,
                        Object.class,
                        MappingJackson2HttpMessageConverter.class));
    }

    @Test
    void acceptsJsonAtLimitAndDoesNotTouchNonJsonBodies() throws Exception {
        JsonRequestBodyLimitAdvice advice = new JsonRequestBodyLimitAdvice(8);
        MockHttpInputMessage json = input("12345678", MediaType.APPLICATION_JSON);
        var buffered = advice.beforeBodyRead(
                json,
                null,
                Object.class,
                MappingJackson2HttpMessageConverter.class);
        assertArrayEquals(
                "12345678".getBytes(StandardCharsets.UTF_8),
                buffered.getBody().readAllBytes());

        MockHttpInputMessage binary =
                input("123456789", MediaType.APPLICATION_OCTET_STREAM);
        assertSame(
                binary,
                advice.beforeBodyRead(
                        binary,
                        null,
                        Object.class,
                        MappingJackson2HttpMessageConverter.class));
    }

    @Test
    void rejectsDeclaredLengthBeforeReadingBody() {
        JsonRequestBodyLimitAdvice advice = new JsonRequestBodyLimitAdvice(8);
        MockHttpInputMessage input = input("", MediaType.APPLICATION_JSON);
        input.getHeaders().setContentLength(9);

        assertThrows(
                JsonBodyTooLargeException.class,
                () -> advice.beforeBodyRead(
                        input,
                        null,
                        Object.class,
                        MappingJackson2HttpMessageConverter.class));
    }

    @Test
    void mvcReturnsStablePayloadTooLargeContract() throws Exception {
        MockMvc mvc = MockMvcBuilders.standaloneSetup(new BodyController())
                .setControllerAdvice(
                        new JsonRequestBodyLimitAdvice(16),
                        new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/body")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"value\":\"12345678901234567890\"}"))
                .andExpect(status().isPayloadTooLarge())
                .andExpect(jsonPath("$.code").value(ErrorCode.PAYLOAD_TOO_LARGE.name()));
    }

    private static MockHttpInputMessage input(String body, MediaType contentType) {
        MockHttpInputMessage input =
                new MockHttpInputMessage(body.getBytes(StandardCharsets.UTF_8));
        input.getHeaders().setContentType(contentType);
        return input;
    }

    @RestController
    private static final class BodyController {

        @PostMapping("/body")
        Map<String, Object> body(@RequestBody Map<String, Object> body) {
            return body;
        }
    }
}
