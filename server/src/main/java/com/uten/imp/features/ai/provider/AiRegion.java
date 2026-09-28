package com.uten.imp.features.ai.provider;

/** 服务商所在区域(决定数据是否出境与接口地址规则, ADR-133)。 */
public enum AiRegion {
    /** 境内服务商(已登记的中国大陆域名)。 */
    MAINLAND,
    /** 境外服务商: 默认禁用, 需服务端开关与数据出境确认。 */
    OVERSEAS,
    /** 本机或内网部署(Ollama/vLLM 等), 数据不出公司网络。 */
    LOCAL
}
