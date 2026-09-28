package com.uten.imp.features.ai.provider;

/** 让模型输出 JSON 的方式: 不声明 / JSON 对象模式 / 按 JSON Schema 严格输出。 */
public enum AiJsonMode {
    NONE,
    JSON_OBJECT,
    JSON_SCHEMA
}
