package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 客户文件识别(ADR-134)读取主档的出口(实现在 features/master/learning)。
 *
 * <p>所有方法都按<b>当前安全上下文</b>的数据范围执行(AI 任务工作线程上是提交人恢复出的主体): 只返回调用人
 * 看得到的客户与货品。客户只返回启用中的; 货品只返回状态「使用」、未删除、非占位(auto_created)的。
 * 打分全部在销售侧用 int/double 完成, 本接口只负责按索引召回候选与提供证据, 不做任何金额舍入。
 */
public interface MasterIntakeLookupPort {

    /**
     * 按文件上的买方线索召回客户候选(可见 + 启用): 精确邮箱(clients.email 与联系方式 EMAIL)、非免费邮箱域名、
     * 电话后 8 位、外文名称精确、拉丁特征词包含、名称 word_similarity、国家/地区 place_id。
     * 每个候选带命中了哪些线索, 分数由调用方计算。
     */
    List<ClientCandidate> clientCandidates(ClientCandidateQuery q);

    /** 调用人可见的启用客户数(为 0 时识别结果提示「你名下还没有客户资料」)。 */
    int visibleActiveClientCount();

    /** 客户资料(补全对比用); 调用人看不到时返回 null。 */
    ClientProfile clientProfile(UUID clientId);

    /** 该客户最近 {@code months} 个月未作废订单里买过的货品: 货品 id → 订单数与最近日期。 */
    Map<UUID, ClientGoodsHistory> clientHistory(UUID clientId, int months);

    /** 篮子重合度: 这些客户各自买过(未作废订单)这些货品中的哪些。客户 id → 买过的货品 id。 */
    Map<UUID, Set<UUID>> historyContains(Collection<UUID> clientIds, Collection<UUID> goodsIds);

    /**
     * 按规范化型号精确召回货品(表达式与索引 idx_goods_model_norm 相同: NFKC、去全部空白、大写)。
     * 入参是已规范化的型号(含前缀变体)。
     */
    List<GoodsRow> goodsByModelNorm(Collection<String> modelNorms);

    /** 按货品编号精确召回(大小写不敏感)。 */
    List<GoodsRow> goodsByCode(Collection<String> codes);

    /**
     * 按中文名称召回候选(精确/包含, 走既有索引); 相似度由调用方按字二元组 Dice 计算。
     * {@code limit} 是整批返回的上限。
     */
    List<GoodsRow> goodsByNameCandidates(Collection<String> cnTexts, int limit);

    /** 按英文名称召回(精确与三元组相似, 走 idx_goods_name_en_trgm); {@code limit} 是整批上限。 */
    List<GoodsRow> goodsByNameEn(Collection<String> texts, int limit);

    /** 按 id 取货品(过滤规则同上, 看不到或已停用的不返回)。 */
    List<GoodsRow> goodsByIds(Collection<UUID> ids);

    /**
     * 取对照: {@code clientIdOrNull} 不为空时返回该客户的对照 + 全局对照, 为空时只返回全局对照;
     * {@code partNorms}/{@code descNorms} 是已按 normalizePart/normalizeDescription 规范化的叫法。
     * 只返回指向可见、使用中货品的对照。
     */
    List<AliasRow> aliases(UUID clientIdOrNull, Collection<String> partNorms, Collection<String> descNorms);

    /** 该客户最近 {@code days} 天内调用人可见的报价/订货单(未删除、未作废), 带明细(货品、颜色、数量), 查重复单据用。 */
    List<DuplicateDocRow> recentDocs(UUID clientId, int days);

    /**
     * 用文件信息新建客户(需要 {@code client:create})。先在<b>全部</b>客户里查重(精确邮箱、电话后 8 位、
     * 规范化外文名/全称): 命中调用人可见的客户抛 409 并带 existingClientId「这个客户已经存在」;
     * 命中调用人看不到的客户抛 409 且不带任何名称或 id「这个客户可能已由其他业务员负责, 请联系主管分配」
     * (均为 {@link com.uten.imp.common.web.ApiException})。否则建在系统「未分类」客户分类下, 负责人为当前员工,
     * 自动取号。
     */
    CreatedClient createClientFromDocument(NewClientRequest req);

    // ------------------------------------------------------------------
    // 数据结构
    // ------------------------------------------------------------------

    /** 客户候选命中的线索。 */
    enum ClientSignal {
        /** 邮箱完全一致(clients.email 或联系方式 EMAIL)。 */
        EMAIL,
        /** 邮箱域名一致(调用方已排除免费邮箱域名)。 */
        EMAIL_DOMAIN,
        /** 外文名称规范化后完全一致。 */
        NAME_EN_EXACT,
        /** 拉丁特征词(>= 4 字符, 已去停用词)包含在客户名称/全称/外文名里。 */
        TOKEN,
        /** 电话/手机/传真后 8 位一致(含联系方式 PHONE/MOBILE)。 */
        PHONE,
        /** 名称 word_similarity 达到阈值, 见 {@link ClientCandidate#nameSimilarity()}。 */
        NAME_SIMILARITY,
        /** 国家/地区对应的 place_id 一致(只作候选召回)。 */
        PLACE
    }

    /**
     * 客户候选查询条件; 各集合由调用方规范化后传入, 空集合表示不按该线索召回。
     *
     * @param emails             小写邮箱
     * @param emailDomains       小写邮箱域名(已排除 gmail/163/qq 等免费邮箱)
     * @param phoneLast8         电话号码只留数字后的末 8 位
     * @param nameEnNorms        规范化外文名称(小写、合并空白、去首尾标点), 用于精确匹配
     * @param nameTexts          文件上的买方名称原文(做 word_similarity)
     * @param distinctiveTokens  大写拉丁特征词(>= 4 字符, 已去 ELECTRIC/TRADING/CO/LTD 等停用词)
     * @param placeIds           国家/地区映射出的 clients.place_id 值(如「约旦」)
     * @param minNameSimilarity  word_similarity 召回阈值(规格为 0.5)
     * @param limit              返回上限
     */
    record ClientCandidateQuery(Set<String> emails, Set<String> emailDomains, Set<String> phoneLast8,
                                Set<String> nameEnNorms, List<String> nameTexts, Set<String> distinctiveTokens,
                                Set<String> placeIds, double minNameSimilarity, int limit) {
        public ClientCandidateQuery {
            emails = emails == null ? Set.of() : Set.copyOf(emails);
            emailDomains = emailDomains == null ? Set.of() : Set.copyOf(emailDomains);
            phoneLast8 = phoneLast8 == null ? Set.of() : Set.copyOf(phoneLast8);
            nameEnNorms = nameEnNorms == null ? Set.of() : Set.copyOf(nameEnNorms);
            nameTexts = nameTexts == null ? List.of() : List.copyOf(nameTexts);
            distinctiveTokens = distinctiveTokens == null ? Set.of() : Set.copyOf(distinctiveTokens);
            placeIds = placeIds == null ? Set.of() : Set.copyOf(placeIds);
        }
    }

    /**
     * 客户候选(可见、启用)。
     *
     * @param clientId       客户 id
     * @param code           客户编号
     * @param name           客户简称
     * @param fullName       客户全称
     * @param nameEn         外文名称
     * @param placeId        国家/地区(clients.place_id)
     * @param signals        命中的线索
     * @param matchedTokens  命中的拉丁特征词
     * @param nameSimilarity 名称最佳 word_similarity(0-1; 未计算为 0)
     */
    record ClientCandidate(UUID clientId, String code, String name, String fullName, String nameEn, String placeId,
                           Set<ClientSignal> signals, Set<String> matchedTokens, double nameSimilarity) {
        public ClientCandidate {
            Objects.requireNonNull(clientId, "clientId");
            signals = signals == null ? Set.of() : Set.copyOf(signals);
            matchedTokens = matchedTokens == null ? Set.of() : Set.copyOf(matchedTokens);
        }
    }

    /**
     * 客户资料(补全对比用)。{@code editable} = 调用人持有 {@code client:edit} 且对该客户有写范围
     * (只读授权不算), 为 false 时识别面板不提供「补进客户资料」。
     *
     * @param contactEmails 联系方式里的邮箱(party_contact_methods EMAIL)
     * @param contactPhones 联系方式里的电话/手机(party_contact_methods PHONE/MOBILE)
     */
    record ClientProfile(UUID clientId, String code, String name, String fullName, String nameEn,
                         String linkman, String email, String phone, String mobile, String address,
                         String taxId, String website, String placeId, UUID defaultCurrencyId,
                         UUID defaultSettlementMethodId, UUID ownerEmployeeId, String status,
                         List<String> contactEmails, List<String> contactPhones, boolean editable) {
        public ClientProfile {
            Objects.requireNonNull(clientId, "clientId");
            contactEmails = contactEmails == null ? List.of() : List.copyOf(contactEmails);
            contactPhones = contactPhones == null ? List.of() : List.copyOf(contactPhones);
        }
    }

    /** 客户买过某货品的历史: 未作废订单数与最近订单日期。 */
    record ClientGoodsHistory(UUID goodsId, int orderCount, LocalDate lastOrderDate) {
    }

    /**
     * 货品候选行(可见、使用中、未删除、非占位)。{@code price} 是货品资料售价(本位币), 可能为空或 0;
     * 调用方按读者价格权限决定是否外露。
     *
     * @param nameEnSource 英文名称来源 {@code MANUAL}/{@code LEARNED}; 名称为空时为空
     * @param status       货品状态(召回只返回「使用」)
     */
    record GoodsRow(UUID id, String code, String name, String model, String series, String spec,
                    UUID colorId, String colorName, UUID unitId, String unitName,
                    String nameEn, String nameEnSource, BigDecimal price, String status) {
        public GoodsRow {
            Objects.requireNonNull(id, "id");
        }
    }

    /** 对照范围: 某客户专属, 或全局(client_id 为空)。 */
    enum AliasScope { CLIENT, GLOBAL }

    /** 对照种类: 客户型号/货号, 或客户品名/描述。 */
    enum AliasKind { PART_NO, DESCRIPTION }

    /**
     * 客户货品对照行(client_goods_aliases)。
     *
     * @param clientId      客户 id; 全局对照为空
     * @param text          最近一次确认的原文
     * @param norm          规范化叫法
     * @param context       规范化上下文「系列|主色」, 未知为空串
     * @param confirmCount  保存确认次数
     * @param explicitCount 用户明确选择/改成该货品的次数
     */
    record AliasRow(UUID id, AliasScope scope, UUID clientId, AliasKind kind, String text, String norm,
                    String context, UUID goodsId, int confirmCount, int explicitCount,
                    OffsetDateTime lastConfirmedAt) {
        public AliasRow {
            Objects.requireNonNull(id, "id");
            Objects.requireNonNull(scope, "scope");
            Objects.requireNonNull(kind, "kind");
            Objects.requireNonNull(goodsId, "goodsId");
            context = context == null ? "" : context;
        }
    }

    /**
     * 近期单据(查重复用)。
     *
     * @param docType    {@code quote} 或 {@code order}
     * @param contractNo 合同号(客户单号, 与文件上的单号比对)
     * @param lines      明细(货品、颜色、数量)
     */
    record DuplicateDocRow(String docType, UUID docId, String billNo, LocalDate billDate, String contractNo,
                           List<DuplicateDocLine> lines) {
        public DuplicateDocRow {
            Objects.requireNonNull(docType, "docType");
            Objects.requireNonNull(docId, "docId");
            lines = lines == null ? List.of() : List.copyOf(lines);
        }
    }

    /** 近期单据的一行明细。 */
    record DuplicateDocLine(UUID goodsId, UUID colorId, BigDecimal qty) {
    }

    /**
     * 用文件信息新建客户的请求(识别结果的 newClientProposal, 经用户确认后提交)。
     *
     * @param name    客户简称(买方名称截取, 不超过 64 字符)
     * @param placeId 国家/地区(clients.place_id)
     */
    record NewClientRequest(String name, String fullName, String nameEn, String linkman, String email,
                            String phone, String address, String taxId, String placeId) {
        public NewClientRequest {
            Objects.requireNonNull(name, "name");
        }
    }

    /** 新建成功的客户。 */
    record CreatedClient(UUID clientId, String code, String name) {
    }
}
