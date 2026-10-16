package com.uten.imp.features.visitor.sms;


/**
 * Fail-closed SMS gateway used until a real provider is configured.
 *
 * <p>It never logs or returns an OTP and therefore cannot accidentally turn a production
 * deployment into the local-development authentication bypass.
 */
public class DisabledSmsGateway implements SmsGateway {

    @Override
    public SmsSendResult sendCode(String phone, String code) {
        return SmsSendResult.REJECTED;
    }
}
