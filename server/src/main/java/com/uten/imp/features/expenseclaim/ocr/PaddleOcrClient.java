package com.uten.imp.features.expenseclaim.ocr;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.ExpenseOcrProperties;
import com.uten.imp.features.expenseclaim.dto.RecognizedInvoiceDto;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * 本地 PaddleOCR 侧车客户端（provider=paddle；ADR-094：不接外部付费 AI API）。
 *
 * <p>契约：POST {endpoint}/ocr/invoice（multipart file）→
 * {@code {"lines":[{"text":"..."}, ...]}}。侧车只做检测+识别输出文本行，
 * 字段抽取由 {@link InvoiceTextParser} 在本进程完成（规则可单测，不依赖外部模型）。
 * 侧车部署与运维见 deploy/simple/RUNBOOK.zh-CN.md §发票识别侧车。
 */
@Slf4j
@Component
@ConditionalOnProperty(name = "uten.expense-ocr.provider", havingValue = "paddle")
public class PaddleOcrClient implements InvoiceOcrClient {

    private final ExpenseOcrProperties props;
    private final RestClient http;
    private final ObjectMapper objectMapper = new ObjectMapper();

    public PaddleOcrClient(ExpenseOcrProperties props) {
        if (!props.isLocalEndpoint()) {
            throw new IllegalArgumentException("OCR endpoint must be a loopback HTTP address");
        }
        this.props = props;
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(5));
        factory.setReadTimeout(Duration.ofSeconds(props.getTimeoutSeconds()));
        this.http = RestClient.builder()
                .baseUrl(props.getEndpoint())
                .requestFactory(factory)
                .build();
    }

    @Override
    public Optional<RecognizedInvoiceDto> recognize(byte[] content, String contentType) {
        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        ByteArrayResource file = new ByteArrayResource(content) {
            @Override
            public String getFilename() {
                return "invoice.jpg";
            }
        };
        org.springframework.http.HttpHeaders headers = new org.springframework.http.HttpHeaders();
        headers.setContentType(MediaType.parseMediaType(contentType));
        body.add("file", new org.springframework.http.HttpEntity<>(file, headers));
        String raw = http.post()
                .uri("/ocr/invoice")
                .contentType(MediaType.MULTIPART_FORM_DATA)
                .body(body)
                .retrieve()
                .body(String.class);
        return Optional.ofNullable(parse(raw));
    }

    /** 响应解析（包内可见供单测）：lines[].text → 规则抽取。 */
    RecognizedInvoiceDto parse(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        try {
            JsonNode root = objectMapper.readTree(raw);
            JsonNode lines = root.path("lines");
            List<String> texts = new ArrayList<>();
            for (JsonNode line : lines) {
                String text = line.path("text").asText("");
                if (!text.isBlank()) {
                    texts.add(text);
                }
            }
            return InvoiceTextParser.parse(texts);
        } catch (Exception exception) {
            log.warn("PaddleOCR 侧车响应解析失败: {}", exception.getClass().getSimpleName());
            return null;
        }
    }
}
