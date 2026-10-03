package com.uten.imp.features.master.client;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.application.port.ClientCreditFactsPort;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.features.master.client.dto.ClientQueryFilter;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.ClientCreditReadAccess;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** Returns server-computed evidence, not a model's impression or an invented credit rating. */
@Component
@RequiredArgsConstructor
public class AiClientCreditTool implements AiChatToolPort {
    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final ClientService clients;
    private final ClientCreditFactsPort facts;

    @Override public String name() { return "query_client_credit"; }
    @Override public String title() { return "查询客户信用依据"; }
    @Override public String description() { return "按客户名称或编号查询当前客户范围内、截至今日的信用依据。无信用汇总权限只说明可见基本条款和资料不足；有权限才读取正式应收、逾期与收款汇总事实。客户重名需明确编号，不凭印象给好坏评级。没有历史日期参数，也不列逐笔发票或回款明细；不能用当前汇总代替某个过去日期的数据。"; }
    @Override public String domain() { return "SALES"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("clientKeyword", Map.of("type", "string", "minLength", 1, "maxLength", 100)),
                "required", List.of("clientKeyword"));
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().contains("client:view") && (actor.getPermissions().contains("sales_order:view")
                || actor.getPermissions().contains("sales_quote:view"))).isPresent();
    }
    private void require() {
        access.requireDomain(domain());
        CurrentAuthorityGuard.requireAll("client:view");
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN, "这项暂时不能查看");
    }

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public Map<String, Object> execute(Map<String, Object> arguments) {
        require();
        if (arguments == null || !arguments.keySet().equals(Set.of("clientKeyword"))
                || !(arguments.get("clientKeyword") instanceof String raw) || raw.isBlank() || raw.length() > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请提供明确的客户名称或编号");
        }
        String keyword = raw.strip();
        var page = clients.list(new ClientQueryFilter(null, keyword, null, null, null, null, null, null,
                null, null, null, null, null, null, null, null, null, null, null, null, null, null,
                null, null, null, null, false, false), 1, 11, "code", "asc");
        List<ClientListItem> candidates = page.getItems();
        List<ClientListItem> exact = candidates.stream().filter(item -> keyword.equalsIgnoreCase(item.getCode())).toList();
        if (!exact.isEmpty()) candidates = exact;
        if (candidates.isEmpty()) return response("没找到这位客户，请核对名称或编号。", List.of(), null);
        if (candidates.size() != 1 || (exact.isEmpty() && page.getTotal() > 1)) {
            String brief = "找到多位客户，请明确客户编号：\n" + candidates.stream().limit(5)
                    .map(item -> item.getCode() + " · " + item.getName()).collect(Collectors.joining("\n"));
            String detail = "找到多位客户，请明确客户编号：\n" + candidates.stream().limit(10)
                    .map(item -> item.getCode() + " · " + item.getName()).collect(Collectors.joining("\n"));
            return withDetail(response(brief, candidates.stream().limit(10).map(item -> proof(clients.detail(item.getId()))).toList(), null), detail);
        }
        ClientDetail client = clients.detail(candidates.getFirst().getId());
        if (!current.get().filter(ClientCreditReadAccess::canRead).isPresent()) {
            return response(client.getName() + " (" + client.getCode() + ")\n这项暂时不能查看。", List.of(proof(client)), null);
        }
        var snapshot = facts.read(client.getId());
        String financial = financialText(client, snapshot);
        var text = display(client, snapshot);
        return withDetail(response(text.brief(), List.of(proof(client)), HashUtil.sha256(financial)), text.detail());
    }

    /** Display wording is independent from the evidence digest below. */
    private record Display(String brief, String detail) {}
    private static Display display(ClientDetail client, ClientCreditFactsPort.Snapshot snapshot) {
        BigDecimal limit = client.getLegacyId() == null && client.getCredit() != null && client.getCredit().signum() > 0 ? client.getCredit() : null;
        var balance = snapshot.balances().forDocument(client.getId(), client.getDefaultCurrencyId(), limit);
        String currency = value(balance.baseCurrencyName());
        StringBuilder brief = new StringBuilder(client.getName()).append(" (").append(client.getCode()).append(")，截至 ").append(snapshot.asOf())
                .append("\n欠款 ").append(amount(balance.openBookLocal())).append(" ").append(currency)
                .append("；逾期 ").append(amount(snapshot.overdueLocal())).append(" ").append(currency)
                .append(" (").append(snapshot.overdueRows()).append(" 笔)。")
                .append("\n信用额度：").append(limit == null ? "尚未核实。" : amount(limit) + " " + currency + (balance.overCredit() ? "，已超额。" : "。"));
        if (balance.currencyId() != null) brief.append("\n预收 ").append(amount(balance.creditOriginal())).append(" ")
                .append(value(balance.currencyName())).append("，未扣入欠款。")
                .append(balance.otherCurrencies().isEmpty() ? "" : " 另有其他币种。");
        else brief.append("\n欠款未扣预收。");
        boolean incomplete = limit == null || snapshot.formalRows() == 0 || snapshot.missingDueDateRows() > 0 || balance.unverifiedCount() > 0;
        brief.append("\n").append(incomplete ? "资料不全，暂时不能判断。"
                : snapshot.overdueRows() > 0 || balance.overCredit() ? "有逾期或超额，请先核对回款安排。"
                : "目前未见逾期或超额，还不能据此判断信用好坏。");
        StringBuilder detail = new StringBuilder(brief)
                .append("\n结算天数：").append(client.getTday() == null ? "未登记" : client.getTday() + " 天")
                .append("；结账方式：").append(value(client.getDefaultSettlementMethodName())).append("。")
                .append("\n累计收款：").append(amount(snapshot.receivedLocal())).append(" ").append(currency)
                .append("；最近结清：").append(snapshot.latestSettledDate() == null ? "未登记" : snapshot.latestSettledDate()).append("。")
                .append("\n未登记到期日：").append(snapshot.missingDueDateRows()).append(" 笔。")
                .append("\n待核历史余额：").append(amount(balance.unverifiedLocal())).append(" ").append(currency)
                .append(" (").append(balance.unverifiedCount()).append(" 笔)。")
                .append("\n铺底额：").append(amount(client.getCreditFloor())).append(" ").append(currency).append("。");
        if (client.getLegacyId() != null) detail.append("\n旧信用数字仅供参考，额度尚未核实。");
        if (balance.currencyId() != null) detail.append("\n").append(value(balance.currencyName())).append("欠款：").append(amount(balance.openOriginal())).append("。");
        for (var other : balance.otherCurrencies().stream().limit(10).toList()) detail.append("\n").append(value(other.currencyName()))
                .append("欠款：").append(amount(other.openOriginal())).append("；预收：").append(amount(other.creditOriginal())).append("。");
        detail.append("\n累计收款和结清日期不能说明每次都按时付款。");
        return new Display(brief.toString(), detail.toString());
    }

    private static String financialText(ClientDetail client, ClientCreditFactsPort.Snapshot snapshot) {
        // Matches the order-finance authority: migrated Credit and non-positive amounts are not approved limits.
        BigDecimal limit = client.getLegacyId() == null && client.getCredit() != null && client.getCredit().signum() > 0 ? client.getCredit() : null;
        var balance = snapshot.balances().forDocument(client.getId(), client.getDefaultCurrencyId(), limit);
        String currency = value(balance.baseCurrencyName());
        StringBuilder text = new StringBuilder("截至 ").append(snapshot.asOf()).append(" 的台账事实：")
                .append("\n正式应收账面余额: ").append(amount(balance.openBookLocal())).append(" ").append(currency).append(" (未扣预收)")
                .append("\n逾期正余额: ").append(amount(snapshot.overdueLocal())).append(" ").append(currency)
                .append("，共 ").append(snapshot.overdueRows()).append(" 笔；未登记到期日的未结应收 ").append(snapshot.missingDueDateRows()).append(" 笔")
                .append("\n正式应收台账已登记收款本币合计: ").append(amount(snapshot.receivedLocal())).append(" ").append(currency)
                .append("；最近已结清日期: ").append(snapshot.latestSettledDate() == null ? "未登记" : snapshot.latestSettledDate())
                .append("\n信用额度: ").append(limit == null ? "未设置可验证额度，不判断超信用" : amount(limit) + " " + currency)
                .append("；铺底额: ").append(amount(client.getCreditFloor())).append(" ").append(currency).append(" (不是信用评级)")
                .append("\n未核实历史/原币余额: ").append(amount(balance.unverifiedLocal())).append(" ").append(currency)
                .append("，共 ").append(balance.unverifiedCount()).append(" 笔，单列核对，不并作正常应收判断。");
        if (balance.currencyId() != null) text.append("\n").append(value(balance.currencyName())).append("原币应收: ")
                .append(amount(balance.openOriginal())).append("；可用预收: ").append(amount(balance.creditOriginal()));
        for (var other : balance.otherCurrencies().stream().limit(10).toList()) text.append("\n").append(value(other.currencyName()))
                .append("原币应收: ").append(amount(other.openOriginal())).append("；可用预收: ").append(amount(other.creditOriginal()));
        if (snapshot.formalRows() == 0) text.append("\n判断: 没有可验证的正式应收记录，资料不足，不能认定信用良好。");
        else if (snapshot.overdueRows() > 0 || balance.overCredit()) text.append("\n判断: ")
                .append(snapshot.overdueRows() > 0 ? "存在逾期应收；" : "")
                .append(balance.overCredit() ? "正式应收超过已登记信用额度；" : "")
                .append("应核对回款计划和资料完整性。这是台账风险提示，不是信用评级。");
        else text.append("\n判断: 当前可核实台账未显示逾期或已登记额度超限，但不代表信用良好。");
        if (snapshot.missingDueDateRows() > 0 || balance.unverifiedCount() > 0) text.append("仍有到期日或历史余额待核实，不能作完整信用结论。");
        text.append("收款累计与已结清日期不能证明每次均按时付款；预收与正式应收分列，不自动抵销。");
        return text.toString();
    }

    @Override
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public void authorizeResultRead(Map<String, Object> evidence) {
        require();
        if (evidence == null || !(evidence.get("clients") instanceof List<?> clientProofs) || clientProofs.size() > 10
                || !(evidence.get("financial") instanceof Boolean financial)) throw changed();
        ClientDetail selected = null;
        for (Object raw : clientProofs) {
            if (!(raw instanceof Map<?, ?> item) || !(item.get("id") instanceof String id) || !(item.get("version") instanceof Number version)) throw changed();
            ClientDetail client;
            try { client = clients.detail(UUID.fromString(id)); } catch (IllegalArgumentException malformed) { throw changed(); }
            if (client.getVersion() == null || client.getVersion() != version.longValue()) throw changed();
            selected = client;
        }
        if (financial) {
            if (!(evidence.get("financialDigest") instanceof String digest)) throw changed();
            if (clientProofs.size() != 1 || selected == null || !current.get().filter(ClientCreditReadAccess::canRead).isPresent()) throw changed();
            if (!digest.equals(HashUtil.sha256(financialText(selected, facts.read(selected.getId()))))) throw changed();
        }
    }
    private static Map<String, Object> proof(ClientDetail client) {
        if (client.getVersion() == null) throw changed();
        return Map.of("id", client.getId().toString(), "version", client.getVersion());
    }
    private static Map<String, Object> response(String text, List<Map<String, Object>> clients, String financialDigest) {
        Map<String, Object> evidence = new java.util.LinkedHashMap<>(); evidence.put("clients", clients); evidence.put("financial", financialDigest != null);
        if (financialDigest != null) evidence.put("financialDigest", financialDigest);
        return Map.of("reply", text, "_toolEvidence", evidence);
    }
    private static Map<String, Object> withDetail(Map<String, Object> response, String detail) {
        var result = new java.util.LinkedHashMap<>(response); result.put("detailReply", detail); return Map.copyOf(result);
    }
    private static String value(String value) { return value == null || value.isBlank() ? "未登记" : value; }
    private static String amount(BigDecimal value) { return value == null ? "未登记" : value.stripTrailingZeros().toPlainString(); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "客户资料有变化，请重新查询"); }
}
