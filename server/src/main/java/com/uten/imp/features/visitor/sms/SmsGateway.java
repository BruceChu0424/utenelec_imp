package com.uten.imp.features.visitor.sms;

/** 短信网关抽象。开发期用 LogSmsGateway，生产用阿里云实现。 */
public interface SmsGateway {

    /** 提交验证码短信；必须区分供应商明确拒绝与网络结果不确定。 */
    SmsSendResult sendCode(String phone, String code);

    /** One immutable selection for issuance, delivery and optional development response. */
    default Prepared prepare() { return new Prepared(this, false); }

    record Prepared(SmsGateway gateway, boolean developmentCodeAllowed) {
        public SmsSendResult sendCode(String phone, String code) { return gateway.sendCode(phone, code); }
        @Override public String toString() { return "PreparedSms[developmentCodeAllowed=" + developmentCodeAllowed + "]"; }
    }
}
