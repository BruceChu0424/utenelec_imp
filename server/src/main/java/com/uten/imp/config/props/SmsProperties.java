package com.uten.imp.config.props;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/** 访客短信验证码配置。开发期 provider=log（打印日志，不真实发送）。 */
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

    /** 验证码有效期（分钟）。 */
    private int codeTtlMinutes = 5;

    /** 同一手机号发送间隔（秒）。 */
    private int sendIntervalSeconds = 60;

    /** 同一手机号每日发送上限。 */
    private int dailyLimit = 10;
}
