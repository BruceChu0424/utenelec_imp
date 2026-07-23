package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.bootstrap")
public class BootstrapProperties {

    /** 引导超管登录账号。 */
    private String adminLogin = "admin";

    /** 引导超管一次性密码（必须经 .env/环境变量注入；缺省 fail-fast，不设弱默认）。 */
    private String adminPassword;
}
