package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/** 引导超管账号配置（uten.bootstrap.*）：数据库尚无超管时用于一次性初始化。 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.bootstrap")
public class BootstrapProperties {

    /** Root-managed bootstrap login identifier. Source provides no account default. */
    private String adminLogin = "";

    /**
     * 引导超管一次性密码。仅在数据库尚无引导账号时必填；创建完成后应从生产密钥管理中删除。
     */
    private String adminPassword = "";
}
