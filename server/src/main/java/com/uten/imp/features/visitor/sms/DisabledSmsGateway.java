package com.uten.imp.features.visitor.sms;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * Fail-closed SMS gateway used until a real provider is configured.
 *
 * <p>It never logs or returns an OTP and therefore cannot accidentally turn a production
 * deployment into the local-development authentication bypass.
 */
@Component
@ConditionalOnProperty(
        prefix = "uten.sms",
        name = "provider",
        havingValue = "disabled",
        matchIfMissing = true)
public class DisabledSmsGateway implements SmsGateway {

    @Override
    public SmsSendResult sendCode(String phone, String code) {
        return SmsSendResult.REJECTED;
    }
}
