package com.uten.imp.features.sales.intake;

import java.math.BigDecimal;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 识别流程的销售侧数据: 读币种、学习到的版式、同一文件是否已被用过, 以及保存后写入学习到的版式。
 * 实现是 {@link SalesIntakeStore}(每个方法一个短事务); 单元测试用内存假实现。
 */
interface IntakeReferenceData {

    /** 启用中的币种(很小的表, 一次读完)。 */
    List<CurrencyRow> currencies();

    /** 按指纹找学习到的版式: 指定客户的 + 全局的({@code clientIdOrNull} 为空只找全局)。 */
    List<LearnedLayout> layouts(Collection<String> fingerprints, UUID clientIdOrNull);

    /** 同一文件(SHA-256)以前识别后被保存进了哪些单据: 单据 id → 单据类型(quote/order)。 */
    Map<UUID, String> docsUsingSameFile(String sha256, UUID excludeJobId);

    /**
     * 保存后学习版式: 客户专属一行 + 全局一行, 已有则确认次数加 1 并刷新列角色(独立事务, 单据提交之后调用)。
     *
     * @param columnRoles     列字母 → 角色名(只接受合法字母与已知角色)
     * @param headerRowOffset 表头占用的额外行数(单行表头为 0)
     */
    void upsertLayout(String fingerprint, UUID clientId, String headerTexts, Map<String, String> columnRoles,
                      int headerRowOffset);

    /** 币种。 */
    record CurrencyRow(UUID id, String code, String name, BigDecimal exchangeRate, boolean base) {
    }

    /** 学习到的版式。 */
    record LearnedLayout(String fingerprint, UUID clientId, Map<String, String> columnRoles, int headerRowOffset,
                         int confirmCount) {
    }

    /** 常见币种写法(ISO → 名称里可能出现的字样), 用于把文件币种对到币种资料。 */
    Map<String, Set<String>> CURRENCY_ALIASES = Map.of(
            "USD", Set.of("USD", "US$", "美元", "美金"),
            "CNY", Set.of("CNY", "RMB", "人民币"),
            "EUR", Set.of("EUR", "欧元"),
            "HKD", Set.of("HKD", "HK$", "港币", "港元"),
            "GBP", Set.of("GBP", "英镑"),
            "JPY", Set.of("JPY", "日元"));

    /** ISO 代码的中文名(提示文字用)。 */
    Map<String, String> CURRENCY_LABELS = Map.of("USD", "美元", "CNY", "人民币", "EUR", "欧元", "HKD", "港币",
            "GBP", "英镑", "JPY", "日元");
}
