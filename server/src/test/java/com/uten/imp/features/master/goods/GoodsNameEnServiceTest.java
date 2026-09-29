package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowableOfType;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** 货品英文名称三条写入路径(整单保存 / 单独修改 / 保存单据学习)的来源与保留规则。 */
class GoodsNameEnServiceTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categoryRepo = mock(MaterialCategoryRepository.class);
    private final CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
    private final MaterialCategory category = new MaterialCategory();
    private final GoodsService service = new GoodsService(
            goodsRepo, categoryRepo, mock(ColorRepository.class), mock(UnitRepository.class),
            mock(MouldRepository.class), mock(TxSessionVars.class), stubbedEm(), codes,
            mock(OwnerVisibility.class), currentUser, mock(GoodsCostMasker.class),
            mock(GoodsMasterRelationshipResolver.class));

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void fullSaveWritesManualSourceAndMissingKeyKeepsTheLearnedValue() {
        login(Set.of("goods:edit"), true);
        when(categoryRepo.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocate(any(), any(), any())).thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any()))
                .thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));

        GoodsSaveRequest create = baseRequest();
        create.setNameEn("  Double   Socket ");
        service.create(create);
        Goods created = captureSaved();
        assertThat(created.getNameEn()).isEqualTo("Double Socket");
        assertThat(created.getNameEnSource()).isEqualTo(GoodsNameEn.SOURCE_MANUAL);

        Goods learned = existingGoods("DOUBLE 3 PIN SOCKET", GoodsNameEn.SOURCE_LEARNED);
        service.update(learned.getId(), baseRequest());
        assertThat(learned.getNameEn()).as("老客户端不带 nameEn 键: 保留学习到的英文名").isEqualTo("DOUBLE 3 PIN SOCKET");
        assertThat(learned.getNameEnSource()).isEqualTo(GoodsNameEn.SOURCE_LEARNED);

        GoodsSaveRequest clear = baseRequest();
        clear.setNameEn("   ");
        service.update(learned.getId(), clear);
        assertThat(learned.getNameEn()).isNull();
        assertThat(learned.getNameEnSource()).isNull();
    }

    @Test
    void dedicatedEndpointWritesManualAndChecksTheVersion() {
        login(Set.of("goods:view", "goods:name_en:edit"), false);
        Goods goods = existingGoods("OLD NAME", GoodsNameEn.SOURCE_LEARNED);

        GoodsDetail detail = service.updateNameEn(goods.getId(), " New  Name ", goods.getVersion());

        assertThat(goods.getNameEn()).isEqualTo("New Name");
        assertThat(goods.getNameEnSource()).isEqualTo(GoodsNameEn.SOURCE_MANUAL);
        assertThat(detail.getNameEn()).isEqualTo("New Name");
        assertThat(detail.isCanEditNameEn()).isTrue();
        assertThat(detail.getVersion()).as("返回写入后的新版本号").isEqualTo(1L);

        ApiException stale = catchThrowableOfType(ApiException.class,
                () -> service.updateNameEn(goods.getId(), "Other", 0L));
        assertThat(stale.getCode()).isEqualTo(ErrorCode.CONFLICT);
    }

    @Test
    void detailCapabilityIsFalseWithoutEitherAuthority() {
        login(Set.of("goods:view"), false);
        Goods goods = existingGoods(null, null);

        assertThat(service.detail(goods.getId()).isCanEditNameEn()).isFalse();
    }

    @Test
    void learningNeedsTheAuthorityAndSkipsStubsAndUnchangedValues() {
        Goods goods = existingGoods("Manual Name", GoodsNameEn.SOURCE_MANUAL);

        login(Set.of("goods:view"), false);
        assertThat(service.learnNameEn(goods.getId(), "DOUBLE SOCKET")).isFalse();
        assertThat(goods.getNameEn()).isEqualTo("Manual Name");

        login(Set.of("goods:name_en:edit"), false);
        assertThat(service.learnNameEn(goods.getId(), "DOUBLE  SOCKET")).isTrue();
        assertThat(goods.getNameEn()).as("用户明确勾选, 覆盖人工值").isEqualTo("DOUBLE SOCKET");
        assertThat(goods.getNameEnSource()).isEqualTo(GoodsNameEn.SOURCE_LEARNED);
        assertThat(service.learnNameEn(goods.getId(), "DOUBLE SOCKET")).as("值相同不写").isFalse();

        Goods stub = existingGoods(null, null);
        stub.setAutoCreated(true);
        assertThat(service.learnNameEn(stub.getId(), "DOUBLE SOCKET")).isFalse();
        verify(goodsRepo, never()).save(stub);
    }

    // ------------------------------------------------------------------

    private GoodsSaveRequest baseRequest() {
        GoodsSaveRequest request = new GoodsSaveRequest();
        request.setCategoryId(category.getId());
        request.setName("Fixture goods");
        return request;
    }

    private Goods existingGoods(String nameEn, String source) {
        Goods goods = new Goods();
        goods.setCategory(category);
        goods.setName("Fixture goods");
        goods.setNameEn(nameEn);
        goods.setNameEnSource(source);
        goods.setStatus("使用");
        goods.setCode("HP1");
        goods.setCodeSequence(1L);
        when(goodsRepo.findById(goods.getId())).thenReturn(Optional.of(goods));
        when(goodsRepo.saveAndFlush(goods)).thenAnswer(invocation -> {
            goods.setVersion(goods.getVersion() + 1);
            return goods;
        });
        return goods;
    }

    private Goods captureSaved() {
        var saved = org.mockito.ArgumentCaptor.forClass(Goods.class);
        verify(goodsRepo).save(saved.capture());
        return saved.getValue();
    }

    private void login(Set<String> permissions, boolean superAdmin) {
        AuthUser user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "tester", permissions,
                false, true, superAdmin);
        when(currentUser.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, null, user.getAuthorities()));
    }

    private static EntityManager stubbedEm() {
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        when(em.createNativeQuery(anyString())).thenReturn(query);
        return em;
    }
}
