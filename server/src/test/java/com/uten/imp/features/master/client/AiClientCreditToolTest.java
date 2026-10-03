package com.uten.imp.features.master.client;

import com.uten.imp.application.port.ClientCreditFactsPort;
import com.uten.imp.common.finance.PartyOpenBalances;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientDetail;
import com.uten.imp.features.master.client.dto.ClientListItem;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ClientCreditReadAccess;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiClientCreditToolTest {
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final ClientService clients = mock(ClientService.class);
    private final ClientCreditFactsPort facts = mock(ClientCreditFactsPort.class);
    private final AiClientCreditTool tool = new AiClientCreditTool(access, current, clients, facts);
    private final UUID clientId = UUID.randomUUID(), currency = UUID.randomUUID();
    private ClientDetail detail;

    @BeforeEach void setUp() {
        when(access.hasDomain("SALES")).thenReturn(true);
        login(Set.of("ai:use", "client:view", "sales_order:view"));
        var candidate = mock(ClientListItem.class);
        when(candidate.getId()).thenReturn(clientId); when(candidate.getCode()).thenReturn("C001"); when(candidate.getName()).thenReturn("示例客户");
        when(clients.list(any(), eq(1), eq(11), eq("code"), eq("asc"))).thenReturn(new PageResponse<>(List.of(candidate), 1, 11, 1, 1));
        detail = mock(ClientDetail.class);
        when(detail.getId()).thenReturn(clientId); when(detail.getCode()).thenReturn("C001"); when(detail.getName()).thenReturn("示例客户");
        when(detail.getVersion()).thenReturn(1L); when(detail.getTday()).thenReturn(30); when(detail.getStatus()).thenReturn("使用");
        when(detail.getLegacyId()).thenReturn(null);
        when(detail.getDefaultCurrencyId()).thenReturn(currency); when(detail.getCredit()).thenReturn(new BigDecimal("100"));
        when(detail.getCreditFloor()).thenReturn(BigDecimal.ZERO); when(clients.detail(clientId)).thenReturn(detail);
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    private void login(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "sales", permissions, false, true, false);
        when(current.get()).thenReturn(Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    private void creditPermission() { login(Set.of("ai:use", "client:view", "sales_order:view", ClientCreditReadAccess.VIEW)); }
    private ClientCreditFactsPort.Snapshot snapshot(long overdue) {
        var amounts = new PartyOpenBalances.CurrencyAmounts(currency, new BigDecimal("150"), new BigDecimal("80"), new BigDecimal("80"));
        var balances = new PartyOpenBalances(Map.of(currency, new PartyOpenBalances.Currency(currency, "人民币", true)),
                Map.of(clientId, new PartyOpenBalances.Party(List.of(amounts), new BigDecimal("150"), new BigDecimal("20"), 1)));
        return new ClientCreditFactsPort.Snapshot(LocalDate.of(2026, 10, 3), balances, 2, 2, overdue, new BigDecimal("50"), 1,
                new BigDecimal("300"), LocalDate.of(2026, 9, 30));
    }
    @Test void ordinarySalesGetsAShortUnavailableReplyAndNeverReadsFinancialFacts() {
        when(detail.getCredit()).thenReturn(new BigDecimal("999999")); when(detail.getCreditFloor()).thenReturn(new BigDecimal("888888"));
        String reply = tool.execute(Map.of("clientKeyword", "C001")).get("reply").toString();
        assertThat(reply).contains("示例客户", "这项暂时不能查看").doesNotContain("999999", "888888", "权限", "范围", "来源");
        assertThat(reply.lines().count()).isLessThanOrEqualTo(2);
        verifyNoInteractions(facts);
    }
    @Test void narrowGrantShowsFactsButNeverOffsetsPrepaymentsOrInventsRating() {
        creditPermission(); when(facts.read(clientId)).thenReturn(snapshot(1));
        var response = tool.execute(Map.of("clientKeyword", "C001"));
        String reply = response.get("reply").toString(), detail = response.get("detailReply").toString();
        assertThat(reply).contains("欠款 150 人民币", "逾期 50 人民币", "预收 80 人民币", "已超额", "2026-10-03", "资料不全，暂时不能判断");
        assertThat(reply.lines().count()).isLessThanOrEqualTo(5);
        assertThat(reply).doesNotContain("待核历史余额", "累计收款");
        assertThat(detail).contains("待核历史余额：20 人民币", "累计收款：300 人民币", "最近结清：2026-09-30", "不能说明每次都按时付款");
        assertThat(reply + detail).doesNotContain("信用良好", "信用差", "净应收: 70", "来源:", "对话模型", "权限", "范围");
    }
    @Test void migratedCreditNeverBecomesAnApprovedLimit() {
        creditPermission(); when(detail.getLegacyId()).thenReturn(7); when(facts.read(clientId)).thenReturn(snapshot(0));
        var response = tool.execute(Map.of("clientKeyword", "C001"));
        assertThat(response.get("reply").toString()).contains("信用额度：尚未核实", "资料不全，暂时不能判断")
                .doesNotContain("信用额度：100", "已超额");
        assertThat(response.get("detailReply").toString()).contains("旧信用数字仅供参考");
    }
    @Test void ambiguousCustomerDoesNotChooseOneOrQueryFinance() {
        var one = mock(ClientListItem.class); when(one.getId()).thenReturn(clientId); when(one.getCode()).thenReturn("C001"); when(one.getName()).thenReturn("同名");
        var two = mock(ClientListItem.class); UUID other = UUID.randomUUID(); when(two.getId()).thenReturn(other); when(two.getCode()).thenReturn("C002"); when(two.getName()).thenReturn("同名");
        var otherDetail = mock(ClientDetail.class); when(otherDetail.getId()).thenReturn(other); when(otherDetail.getVersion()).thenReturn(1L); when(clients.detail(other)).thenReturn(otherDetail);
        when(clients.list(any(), eq(1), eq(11), eq("code"), eq("asc"))).thenReturn(new PageResponse<>(List.of(one, two), 1, 11, 2, 1));
        assertThat(tool.execute(Map.of("clientKeyword", "同名")).get("reply").toString()).contains("明确客户编号", "C001", "C002");
        verifyNoInteractions(facts);
    }
    @Test void financialRightsDoNotReplaceCustomerViewOrSalesDepartment() {
        login(Set.of("ai:use", "sales_order:view", ClientCreditReadAccess.VIEW));
        assertThatThrownBy(() -> tool.execute(Map.of("clientKeyword", "C001"))).isInstanceOf(ApiException.class);
        verify(clients, never()).list(any(), anyInt(), anyInt(), anyString(), anyString()); verifyNoInteractions(facts);
    }
    @Test void guessedClientUuidCannotReplaceTheScopedSearchContract() {
        assertThatThrownBy(() -> tool.execute(Map.of("clientId", clientId.toString()))).isInstanceOf(ApiException.class);
        verifyNoInteractions(facts);
    }
    @Test void historyRechecksScopeAndAllCandidateVersions() {
        Map<String, Object> response = tool.execute(Map.of("clientKeyword", "C001"));
        when(clients.detail(clientId)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));
        assertThatThrownBy(() -> tool.authorizeResultRead(evidence(response))).isInstanceOf(ApiException.class);
    }
    @Test void historyRejectsChangedFinancialFactsAndRevokedNarrowGrant() {
        creditPermission(); when(facts.read(clientId)).thenReturn(snapshot(1));
        Map<String, Object> response = tool.execute(Map.of("clientKeyword", "C001"));
        when(facts.read(clientId)).thenReturn(snapshot(0));
        assertThatThrownBy(() -> tool.authorizeResultRead(evidence(response))).isInstanceOf(ApiException.class);
        login(Set.of("ai:use", "client:view", "sales_order:view")); clearInvocations(facts);
        assertThatThrownBy(() -> tool.authorizeResultRead(evidence(response))).isInstanceOf(ApiException.class);
        verifyNoInteractions(facts);
    }
    @Test void unchangedFinancialHistoryIsReadableWithCurrentSourceChecks() {
        creditPermission(); when(facts.read(clientId)).thenReturn(snapshot(1));
        var response = tool.execute(Map.of("clientKeyword", "C001"));
        assertThatCode(() -> tool.authorizeResultRead(evidence(response))).doesNotThrowAnyException();
        verify(facts, times(2)).read(clientId);
    }
    @SuppressWarnings("unchecked") private static Map<String, Object> evidence(Map<String, Object> result) {
        return (Map<String, Object>) result.get("_toolEvidence");
    }
}
