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

    /** 引导超管登录账号（默认管理员手机号）。 */
    private String adminLogin = "17665410007";

    /**
     * 引导超管一次性密码。仅在数据库尚无引导账号时必填；创建完成后应从生产密钥管理中删除。
     */
    private String adminPassword = "";
}
