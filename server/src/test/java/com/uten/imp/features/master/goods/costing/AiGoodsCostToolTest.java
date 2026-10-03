package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AiGoodsCostToolTest {
    private final AiChatAccessPolicy access = mock(AiChatAccessPolicy.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final GoodsService goods = mock(GoodsService.class);
    private final GoodsCostSheetService costs = mock(GoodsCostSheetService.class);
    private final AiGoodsCostTool tool = new AiGoodsCostTool(access, current, goods, costs);
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    private void financePrincipal(Set<String> permissions) {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "finance", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
    }
    @Test void wrongDepartmentStopsBeforeAnyGoodsRead() {
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(access).requireDomain("FINANCE");
        assertThatThrownBy(() -> tool.execute(Map.of("goodsKeyword", "测试"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(goods, costs);
    }
    @Test void costPermissionIsRecheckedEvenAfterDomainCheck() {
        financePrincipal(Set.of("goods:view"));
        assertThatThrownBy(() -> tool.execute(Map.of("goodsKeyword", "测试"))).isInstanceOf(ApiException.class);
        verifyNoInteractions(goods, costs);
    }
    @Test void ambiguousSearchNeverChoosesAnArbitraryCost() {
        financePrincipal(Set.of("goods:view", "goods:cost:view"));
        var first = mock(GoodsListItem.class); when(first.getCode()).thenReturn("A1"); when(first.getName()).thenReturn("物料");
        var second = mock(GoodsListItem.class); when(second.getCode()).thenReturn("A2"); when(second.getName()).thenReturn("物料");
        when(first.getId()).thenReturn(UUID.randomUUID()); when(second.getId()).thenReturn(UUID.randomUUID());
        when(goods.list(any(), eq(1), eq(11), eq("code"), eq("asc")))
                .thenReturn(new PageResponse<>(List.of(first, second), 1, 11, 2, 1));
        assertThat(tool.execute(Map.of("goodsKeyword", "物料")).get("reply").toString()).contains("准确编码", "A1", "A2");
        verifyNoInteractions(costs);
    }
    @Test void unavailableCostRemainsUnknownNotZero() {
        financePrincipal(Set.of("goods:view", "goods:cost:view"));
        var first = mock(GoodsListItem.class); when(first.getCode()).thenReturn("A1"); when(first.getName()).thenReturn("物料");
        when(first.getId()).thenReturn(UUID.randomUUID());
        when(goods.list(any(), eq(1), eq(11), eq("code"), eq("asc")))
                .thenReturn(new PageResponse<>(List.of(first), 1, 11, 1, 1));
        when(costs.list(first.getId())).thenReturn(List.of());
        assertThat(tool.execute(Map.of("goodsKeyword", "A1")).get("reply").toString()).contains("未登记成本不能按 0");
    }
    @Test void oldCandidateReplyRechecksObjectScopeEvenWhenPermissionsAreUnchanged() {
        financePrincipal(Set.of("goods:view", "goods:cost:view"));
        UUID reassigned = UUID.randomUUID();
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(costs).requireGoodsScope(reassigned);
        assertThatThrownBy(() -> tool.authorizeResultRead(Map.of("goodsIds", List.of(reassigned.toString()), "sheets", List.of())))
                .isInstanceOf(ApiException.class);
        verify(costs).requireGoodsScope(reassigned);
    }
    @Test void changedSheetCannotValidateTheOriginalFinancialSnapshot() {
        financePrincipal(Set.of("goods:view", "goods:cost:view"));
        UUID goodsId = UUID.randomUUID(), sheetId = UUID.randomUUID();
        var changed = mock(GoodsCostContracts.Sheet.class); when(changed.version()).thenReturn(8L);
        when(costs.get(sheetId)).thenReturn(changed);
        assertThatThrownBy(() -> tool.authorizeResultRead(Map.of("goodsIds", List.of(goodsId.toString()),
                "sheets", List.of(Map.of("id", sheetId.toString(), "version", 7)))))
                .isInstanceOf(ApiException.class);
    }
    @Test void missingScopeEvidenceFailsClosed() {
        financePrincipal(Set.of("goods:view", "goods:cost:view"));
        assertThatThrownBy(() -> tool.authorizeResultRead(Map.of())).isInstanceOf(ApiException.class);
    }
}
