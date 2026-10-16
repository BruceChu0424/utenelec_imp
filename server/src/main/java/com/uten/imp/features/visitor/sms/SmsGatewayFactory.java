package com.uten.imp.features.visitor.sms;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.SmsProperties;
import org.springframework.stereotype.Component;

/** Construction never sends a message; every Aliyun sender owns an immutable client/configuration. */
@Component
public class SmsGatewayFactory {
    private final ObjectMapper mapper;
    public SmsGatewayFactory(ObjectMapper mapper) { this.mapper=mapper; }
    public SmsGateway create(SmsGatewayRuntime.Snapshot snapshot) {
        return switch(snapshot.effectiveProvider()) {
            case "LOG" -> new LogSmsGateway();
            case "ALIYUN" -> {
                String endpoint=SmsEndpointPolicy.normalize(snapshot.endpoint());
                if(!SmsEndpointPolicy.allowed(endpoint))throw new IllegalArgumentException("SMS endpoint is not an allowed provider service");
                var properties=new SmsProperties();
                properties.setAccessKeyId(snapshot.accessKeyId());properties.setAccessKeySecret(snapshot.accessKeySecret());
                properties.setSignName(snapshot.signName());properties.setTemplateCode(snapshot.templateCode());properties.setEndpoint(endpoint);
                yield new AliyunSmsGateway(properties,mapper);
            }
            default -> new DisabledSmsGateway();
        };
    }
}
