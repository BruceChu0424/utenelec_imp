package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.deser.DeserializationProblemHandler;
import com.fasterxml.jackson.databind.exc.MismatchedInputException;
import com.fasterxml.jackson.databind.module.SimpleModule;
import org.springframework.stereotype.Component;

import java.io.IOException;

/**
 * 全局 Jackson 模块: 对标记了 {@link ServerDerivedAmounts} 的请求 DTO, 请求体带金额字段时直接失败
 * (Spring 转成 400), 不让客户端算的金额有机会被当成事实。其余 DTO 的未知字段仍按全局口径忽略。
 */
@Component
public class ServerDerivedAmountsModule extends SimpleModule {

    public ServerDerivedAmountsModule() {
        super("server-derived-amounts");
    }

    @Override
    public void setupModule(SetupContext context) {
        super.setupModule(context);
        context.addDeserializationProblemHandler(new RejectClientAmounts());
    }

    static final class RejectClientAmounts extends DeserializationProblemHandler {
        @Override
        public boolean handleUnknownProperty(DeserializationContext ctxt, JsonParser parser,
                JsonDeserializer<?> deserializer, Object beanOrClass, String propertyName) throws IOException {
            Class<?> type = beanOrClass instanceof Class<?> declared ? declared
                    : beanOrClass == null ? null : beanOrClass.getClass();
            if (type != null && ServerDerivedAmounts.class.isAssignableFrom(type)
                    && ServerDerivedAmounts.CLIENT_FORBIDDEN_FIELDS.contains(propertyName)) {
                throw MismatchedInputException.from(parser, type,
                        "金额由系统按数量、单价和汇率计算，请求里不能带金额字段: " + propertyName);
            }
            return false;
        }
    }
}
