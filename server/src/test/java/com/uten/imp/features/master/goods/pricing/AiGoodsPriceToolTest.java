package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.features.ai.chat.AiChatToolRegistry;
import org.springframework.jdbc.core.JdbcTemplate;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiGoodsPriceToolTest {
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final GoodsService goods = mock(GoodsService.class);
    private final GoodsPriceAnalysisService prices = mock(GoodsPriceAnalysisService.class);
    private final AiGoodsPriceTool tool = new AiGoodsPriceTool(access, current, goods, prices);
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    private void actor(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "finance", permissions, false, true, false);
        when(current.get()).thenReturn(java.util.Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @Test void theSameSourcePermissionsOpenTheFormalAnalysisAndRegisteredAiToolWithoutFinanceMembership() {
        var jdbc = mock(JdbcTemplate.class);
        var policy = new AiChatAccessPolicy(current, jdbc);
        var realTool = new AiGoodsPriceTool(policy, current, goods, prices);
        var registry = new AiChatToolRegistry(List.of(realTool), policy);
        var sourceAccess = new GoodsPriceAccess(current, mock(OwnerVisibility.class));
        for (Kind kind : List.of(Kind.PURCHASE, Kind.SUBCONTRACT, Kind.SALES)) {
            String source = kind.name().toLowerCase(java.util.Locale.ROOT) + "_order";
            actor(Set.of("ai:use", "goods:view", "goods:price_analysis:view", source + ":view", source + ":price:view"));
            assertThatCode(() -> sourceAccess.require(kind)).doesNotThrowAnyException();
            assertThat(sourceAccess.available(kind)).isTrue();
            assertThat(realTool.available()).isTrue();
            assertThat(registry.available(realTool.name())).contains(realTool);
        }
        verifyNoInteractions(jdbc, goods, prices);
    }
    @Test void openingThePriceAnalysisDomainDoesNotGrantSourcePricesOrBroaderFinancePermissions() {
        var policy = new AiChatAccessPolicy(current, mock(JdbcTemplate.class));
        var realTool = new AiGoodsPriceTool(policy, current, goods, prices);
        var sourceAccess = new GoodsPriceAccess(current, mock(OwnerVisibility.class));
        actor(Set.of("ai:use", "goods:view", "goods:price_analysis:view", "purchase_order:view"));
        assertThat(realTool.available()).isTrue();
        assertThat(sourceAccess.available(Kind.PURCHASE)).isFalse();
        assertThatThrownBy(() -> sourceAccess.require(Kind.PURCHASE)).isInstanceOf(ApiException.class);
        assertThat(current.get().orElseThrow().getPermissions())
                .doesNotContain("purchase_order:price:view", "finance:view:all", "goods:cost:view");
        actor(Set.of("ai:use", "goods:view", "purchase_order:view", "purchase_order:price:view"));
        assertThat(realTool.available()).isFalse();
        assertThat(new AiChatToolRegistry(List.of(realTool), policy).available()).isEmpty();
        verifyNoInteractions(goods, prices);
    }
    @Test void priceAnalysisPermissionIsRequiredBeforeLookingUpAnyGoods() {
        actor(Set.of("goods:view", "goods:cost:view"));
        assertThatThrownBy(() -> tool.execute(Map.of("goodsKeyword", "A1", "kind", "PURCHASE"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(goods, prices);
    }
    @Test void privatePriceFactsNeverLeaveTheApplication() {
        assertThat(tool.modelFacts(Map.of("reply", "供应商A价格12.80", "secret", "cost"))).isEmpty();
    }
    @Test void invalidOrArbitraryArgumentsAreRejectedBeforeQueries() {
        actor(Set.of("goods:view", "goods:price_analysis:view"));
        for (var args : List.<Map<String,Object>>of(
                Map.of("goodsKeyword", "A1", "kind", "PURCHASE", "sql", "select prices"),
                Map.of("goodsKeyword", "A1", "kind", "PURCHASE", "days", 1.5),
                Map.of("goodsKeyword", "A1", "kind", "PURCHASE", "days", 367),
                Map.of("goodsKeyword", "A1", "kind", "PURCHASE", "quantity", "NaN"))) {
            assertThatThrownBy(() -> tool.execute(args)).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(goods, prices);
    }
    @Test void ambiguousNameCannotChooseAnArbitraryGoodsPrice() {
        actor(Set.of("goods:view", "goods:price_analysis:view"));
        var a = mock(GoodsListItem.class); var b = mock(GoodsListItem.class);
        when(a.getId()).thenReturn(UUID.randomUUID()); when(b.getId()).thenReturn(UUID.randomUUID());
        when(a.getCode()).thenReturn("A1"); when(b.getCode()).thenReturn("A2");
        when(a.getName()).thenReturn("物料"); when(b.getName()).thenReturn("物料");
        when(goods.list(any(), eq(1), eq(11), eq("code"), eq("asc")))
                .thenReturn(new PageResponse<>(List.of(a,b), 1, 11, 2, 1));
        assertThat(tool.execute(Map.of("goodsKeyword", "物料", "kind", "PURCHASE")).get("reply").toString()).contains("准确编码", "A1", "A2");
        verifyNoInteractions(prices);
    }
    @Test void storedAnswerRechecksObjectScopeAndExactPriceEvidence() {
        actor(Set.of("goods:view", "goods:price_analysis:view"));
        UUID id = UUID.randomUUID();
        var evidence = Map.<String,Object>of("goodsIds", List.of(id.toString()), "goodsId", id.toString(),
                "kind", "PURCHASE", "days", 180, "evidenceToken", "original-token");
        tool.authorizeResultRead(evidence);
        verify(goods).detail(id);
        verify(prices).requireCurrentEvidence(argThat(query -> query.goodsId().equals(id) && query.kind() == Kind.PURCHASE), eq("original-token"));
    }
    @Test void storedAnswerWithAnotherGoodsIdIsRejected() {
        actor(Set.of("goods:view", "goods:price_analysis:view"));
        assertThatThrownBy(() -> tool.authorizeResultRead(Map.of("goodsIds", List.of(UUID.randomUUID().toString()),
                "goodsId", UUID.randomUUID().toString(), "kind", "PURCHASE", "evidenceToken", "x"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(prices);
    }
    @Test void aSingleOldRecordIsNeverPresentedAsATodaysRecommendation() {
        actor(Set.of("goods:view", "goods:price_analysis:view"));
        UUID id = UUID.randomUUID(); var item = mock(GoodsListItem.class);
        when(item.getId()).thenReturn(id); when(item.getCode()).thenReturn("A1"); when(item.getName()).thenReturn("材料");
        when(goods.list(any(), eq(1), eq(11), eq("code"), eq("asc")))
                .thenReturn(new PageResponse<>(List.of(item), 1, 11, 1, 1));
        var result = mock(Analysis.class);
        when(result.goodsCode()).thenReturn("A1"); when(result.goodsName()).thenReturn("材料");
        when(result.status()).thenReturn("STALE"); when(result.referencePrice()).thenReturn("10");
        when(result.weightedAveragePrice()).thenReturn("10"); when(result.independentOrderCount()).thenReturn(1);
        when(result.explanation()).thenReturn("按可比历史计算"); when(result.evidenceToken()).thenReturn("evidence");
        when(prices.analysis(any())).thenReturn(result);
        String reply = tool.execute(Map.of("goodsKeyword", "A1", "kind", "PURCHASE")).get("reply").toString();
        assertThat(reply).contains("暂不能给出可靠", "历史可比加权均价").doesNotContain("今日参考：");
    }
}
