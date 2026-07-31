package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

import java.util.List;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.policy-intelligence")
public class PolicyIntelligenceProperties {

    /** 默认关闭；配置密钥并显式启用后才会发起外部请求。 */
    private boolean enabled;
    private String apiKey = "";
    private String baseUrl = "https://api.deepseek.com";
    private String model = "deepseek-v4-flash";
    private String refreshCron = "0 15 6 * * *";
    private int maxCandidates = 12;
    private List<String> indexUrls = List.of(
            "https://www.zs.gov.cn/zjj/zdlyxx/jdcctb/",
            "https://www.zs.gov.cn/xlz/zwdt/",
            "https://guangdong.chinatax.gov.cn/gdsw/ssfggds/");
}
