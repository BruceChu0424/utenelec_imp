package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;
import org.springframework.validation.annotation.Validated;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Pattern;
import java.net.URI;
import java.util.Set;

/**
 * 报销发票图片识别（OCR）配置。provider=disabled（默认）时识别端点返回明确的
 * 「未配置」业务错误，前端引导手工登记。
 *
 * <p>口径（ADR-094）：**不接入任何外部付费 AI API**——识别只走服务器本地部署的
 * 开源方案（调研结论：PaddleOCR，Apache-2.0，纯 CPU 可跑）。在服务器旁路部署
 * PaddleOCR HTTP 服务后，实现 {@code InvoiceOcrClient} 并把 provider 置为
 * paddle 即可接线，业务侧零改动。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.expense-ocr")
@Validated
public class ExpenseOcrProperties {

    /** disabled / paddle（本地开源识别服务；未部署即 disabled）。 */
    @Pattern(regexp = "disabled|paddle")
    private String provider = "disabled";

    /** 本地 PaddleOCR 侧车地址（同机部署，仅回环可达）。 */
    private String endpoint = "http://127.0.0.1:8501";

    /** 单张图片大小上限（MB）。 */
    @Min(1)
    @Max(8)
    private int maxImageMb = 8;

    /** 调用本地识别服务的超时（秒）。 */
    @Min(1)
    @Max(120)
    private int timeoutSeconds = 60;

    @AssertTrue(message = "发票识别仅允许同机回环 HTTP 服务，不允许外送票据信息")
    public boolean isLocalEndpoint() {
        try {
            URI uri = URI.create(endpoint);
            String host = uri.getHost();
            return "http".equals(uri.getScheme()) && host != null
                    && Set.of("127.0.0.1", "[::1]", "::1").contains(host)
                    && uri.getUserInfo() == null && uri.getQuery() == null && uri.getFragment() == null
                    && (uri.getPath().isEmpty() || "/".equals(uri.getPath()));
        } catch (RuntimeException invalid) {
            return false;
        }
    }
}
