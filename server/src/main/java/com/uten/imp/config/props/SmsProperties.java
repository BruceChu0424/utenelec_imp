package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 访客短信网关的部署回退配置；页面覆盖后由运行时配置选择网关。开发期 provider=log 不真实发送。验证码有效期、发送间隔、
 * 每日上限属于运行时策略, 只登记在系统设置 (SystemSettingKey.SMS_*)。
 */
@Getter
@Setter
@Component
@ConfigurationProperties(prefix = "uten.sms")
public class SmsProperties {

    /** 短信网关：log（开发期）/ aliyun（阿里云，生产）。 */
    private String provider = "disabled";

    /** Only a local development profile may return the code in an API response. */
    private boolean exposeCode = false;

    /** 阿里云 AccessKey Id。 */
    private String accessKeyId = "";

    /** 阿里云 AccessKey Secret。 */
    private String accessKeySecret = "";

    /** 短信签名。 */
    private String signName = "";

    /** 验证码模板 CODE（模板含 ${code} 占位）。 */
    private String templateCode = "";

    /** 阿里云国内短信服务地址。 */
    private String endpoint = "dysmsapi.aliyuncs.com";
}
