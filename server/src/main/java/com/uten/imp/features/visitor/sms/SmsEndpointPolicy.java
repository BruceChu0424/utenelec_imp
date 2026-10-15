package com.uten.imp.features.visitor.sms;

import java.util.List;
import java.util.Locale;

/** Exact service hosts, not a wildcard that also accepts customer-owned OSS buckets.
 * Source: https://help.aliyun.com/en/sms/developer-reference/api-dysmsapi-2017-05-25-endpoint
 */
public final class SmsEndpointPolicy {
    private SmsEndpointPolicy() {}
    public static final List<String> ALLOWED = List.of(
            "dysmsapi.aliyuncs.com",
            "dysmsapi.ap-southeast-1.aliyuncs.com",
            "dysmsapi.ap-southeast-5.aliyuncs.com",
            "dysmsapi.eu-central-1.aliyuncs.com",
            "dysmsapi-xman.vpc-proxy.aliyuncs.com",
            "dysmsapi-xman-vpc.ap-southeast-5.aliyuncs.com",
            "dysmsapi-xman-vpc.eu-central-1.aliyuncs.com");
    public static String normalize(String value) {
        String text=SmsGatewayRuntime.blank(value);
        return text==null?null:text.toLowerCase(Locale.ROOT);
    }
    public static boolean allowed(String value) { return value!=null&&ALLOWED.contains(value); }
}
