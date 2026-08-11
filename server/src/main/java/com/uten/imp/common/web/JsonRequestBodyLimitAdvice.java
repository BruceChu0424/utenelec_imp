package com.uten.imp.common.web;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.MethodParameter;
import org.springframework.http.HttpInputMessage;
import org.springframework.http.MediaType;
import org.springframework.http.converter.HttpMessageConverter;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.servlet.mvc.method.annotation.RequestBodyAdviceAdapter;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.lang.reflect.Type;
import java.util.Locale;

/**
 * Enforces a bounded body for JSON controller requests, including chunked
 * requests without a {@code Content-Length} header.
 *
 * <p>Multipart and binary request bodies are intentionally outside this
 * advice, so a future upload endpoint can use its own streaming size policy.
 */
@RestControllerAdvice
public class JsonRequestBodyLimitAdvice extends RequestBodyAdviceAdapter {

    private final int maxBytes;

    public JsonRequestBodyLimitAdvice(
            @Value("${uten.http.max-json-body-bytes:1048576}") int maxBytes) {
        if (maxBytes < 1 || maxBytes == Integer.MAX_VALUE) {
            throw new IllegalArgumentException(
                    "uten.http.max-json-body-bytes must be between 1 and 2147483646");
        }
        this.maxBytes = maxBytes;
    }

    @Override
    public boolean supports(
            MethodParameter methodParameter,
            Type targetType,
            Class<? extends HttpMessageConverter<?>> converterType) {
        return true;
    }

    @Override
    public HttpInputMessage beforeBodyRead(
            HttpInputMessage inputMessage,
            MethodParameter parameter,
            Type targetType,
            Class<? extends HttpMessageConverter<?>> converterType)
            throws IOException {
        if (!isJson(inputMessage.getHeaders().getContentType())) {
            return inputMessage;
        }

        long declaredLength = inputMessage.getHeaders().getContentLength();
        if (declaredLength > maxBytes) {
            throw new JsonBodyTooLargeException(maxBytes);
        }

        byte[] body = inputMessage.getBody().readNBytes(maxBytes + 1);
        if (body.length > maxBytes) {
            throw new JsonBodyTooLargeException(maxBytes);
        }
        return new BufferedHttpInputMessage(inputMessage, body);
    }

    private static boolean isJson(MediaType contentType) {
        if (contentType == null) {
            return false;
        }
        return MediaType.APPLICATION_JSON.includes(contentType)
                || contentType.getSubtype().toLowerCase(Locale.ROOT).endsWith("+json");
    }

    private record BufferedHttpInputMessage(
            HttpInputMessage original,
            byte[] body) implements HttpInputMessage {

        @Override
        public java.io.InputStream getBody() {
            return new ByteArrayInputStream(body);
        }

        @Override
        public org.springframework.http.HttpHeaders getHeaders() {
            return original.getHeaders();
        }
    }
}
