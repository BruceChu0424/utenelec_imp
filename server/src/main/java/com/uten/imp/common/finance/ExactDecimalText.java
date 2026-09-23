package com.uten.imp.common.finance;

import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.databind.SerializerProvider;
import com.fasterxml.jackson.databind.ser.std.StdSerializer;

import java.io.IOException;
import java.math.BigDecimal;

/**
 * 金额/数量按十进制原文输出为 JSON 字符串(ADR-112): 前端拿到的是 "123.45678901234567890",
 * 不经过 double, 也不会出现科学计数法。只挂在需要逐位展示的审核类 DTO 字段上。
 */
public final class ExactDecimalText extends StdSerializer<BigDecimal> {

    public ExactDecimalText() {
        super(BigDecimal.class);
    }

    @Override
    public void serialize(BigDecimal value, JsonGenerator generator, SerializerProvider provider) throws IOException {
        generator.writeString(value.toPlainString());
    }
}
