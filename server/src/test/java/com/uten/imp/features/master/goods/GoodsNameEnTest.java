package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.Test;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class GoodsNameEnTest {

    @Test
    void normalizeCollapsesUnicodeWhitespaceAndKeepsTheCustomersCase() {
        assertThat(GoodsNameEn.normalize("  Double\u00A0 3 PIN\u3000Socket\u200B ")).isEqualTo("Double 3 PIN Socket");
        assertThat(GoodsNameEn.normalize(" \t ")).isNull();
        assertThat(GoodsNameEn.normalize(null)).isNull();
    }

    @Test
    void normalizeForWriteRejectsOverlongInsteadOfTruncating() {
        assertThat(GoodsNameEn.normalizeForWrite("x".repeat(255))).hasSize(255);
        assertThatThrownBy(() -> GoodsNameEn.normalizeForWrite("x".repeat(256)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void editRequiresTheDedicatedCodeOrFullGoodsEdit() {
        assertThat(GoodsNameEn.canEdit(user(Set.of("goods:name_en:edit"), false))).isTrue();
        assertThat(GoodsNameEn.canEdit(user(Set.of("goods:edit"), false))).isTrue();
        assertThat(GoodsNameEn.canEdit(user(Set.of("goods:view", "goods:price:view"), false))).isFalse();
        assertThat(GoodsNameEn.canEdit(user(Set.of(), true))).isTrue();
        assertThat(GoodsNameEn.canEdit(null)).isFalse();
        assertThat(GoodsNameEn.canEdit(AuthUser.visitor(UUID.randomUUID(), "v", "V1", Set.of("goods:edit"))))
                .isFalse();
    }

    @Test
    void saveRequestTracksWhetherTheNameEnKeyWasSent() throws Exception {
        ObjectMapper mapper = new ObjectMapper();
        GoodsSaveRequest absent = mapper.readValue("{\"name\":\"A\"}", GoodsSaveRequest.class);
        GoodsSaveRequest cleared = mapper.readValue("{\"name\":\"A\",\"nameEn\":null}", GoodsSaveRequest.class);
        GoodsSaveRequest set = mapper.readValue("{\"name\":\"A\",\"nameEn\":\"Socket\"}", GoodsSaveRequest.class);
        assertThat(absent.hasNameEn()).isFalse();
        assertThat(cleared.hasNameEn()).isTrue();
        assertThat(cleared.getNameEn()).isNull();
        assertThat(set.hasNameEn()).isTrue();
        assertThat(set.getNameEn()).isEqualTo("Socket");
        assertThat(mapper.writeValueAsString(set)).doesNotContain("nameEnPresent");
    }

    @Test
    void matchKeyIgnoresCaseAndPunctuation() {
        assertThat(GoodsNameEn.matchKey("Double 3 PIN Socket."))
                .isEqualTo(GoodsNameEn.matchKey(" double  3 pin socket"));
        assertThat(GoodsNameEn.matchKey("...")).isNull();
    }

    private static AuthUser user(Set<String> permissions, boolean superAdmin) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "u", permissions, false, true, superAdmin);
    }
}
