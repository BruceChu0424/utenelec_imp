package com.uten.imp.features.ai.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.AiCompletionPort.AiCallException;
import com.uten.imp.application.port.AiCompletionPort.AiErrorCategory;

/** Reject explicit business failures even when a gateway incorrectly uses HTTP 200. Never unwrap arbitrary data. */
final class AiProtocolEnvelope {
    private AiProtocolEnvelope() {}

    static void requireSuccess(JsonNode root, int httpStatus, boolean hasProtocolPayload) {
        boolean declaredFailure = root.path("success").isBoolean() && !root.path("success").asBoolean();
        boolean errorObject = root.has("error") && !root.path("error").isNull();
        JsonNode code = root.path("code");
        boolean failureCode = code.isIntegralNumber() && code.bigIntegerValue().compareTo(java.math.BigInteger.valueOf(400)) >= 0;
        if (code.isTextual() && code.asText().matches("[0-9]{3,9}") && Long.parseLong(code.asText()) >= 400) failureCode = true;
        if (declaredFailure || (!hasProtocolPayload && (errorObject || failureCode))) {
            // msg/error/message may echo request text, credentials or proxy internals. None is displayed.
            throw new AiCallException(AiErrorCategory.BAD_REQUEST,
                    "AI 服务返回了失败结果，请核对接口协议、接口地址和模型设置", httpStatus);
        }
    }
}
