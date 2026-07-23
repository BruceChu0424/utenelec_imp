package com.uten.imp.features.visitor.sms;

/** 短信网关抽象。开发期用 LogSmsGateway，生产用阿里云实现。 */
public interface SmsGateway {

    /** 发送验证码短信。返回是否发送成功（log 永远返回 true）。 */
    boolean sendCode(String phone, String code);
}
