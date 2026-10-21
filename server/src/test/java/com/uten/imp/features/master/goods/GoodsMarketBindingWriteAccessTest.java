package com.uten.imp.features.master.goods;

import com.uten.imp.security.*;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsMarketBindingWriteAccessTest {
    final UUID id=UUID.randomUUID();
    GoodsService goods;GoodsRepository repository;EntityManager em;SecurityContextCurrentUser current;Goods row;
    GoodsMarketBindingWriteAccess access;
    @BeforeEach void setup(){
        goods=mock(GoodsService.class);repository=mock(GoodsRepository.class);em=mock(EntityManager.class);current=mock(SecurityContextCurrentUser.class);row=new Goods();
        when(repository.findById(id)).thenReturn(Optional.of(row));
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"market-test",Set.of("goods:view","goods:edit"),false,true,false);
        when(current.get()).thenReturn(Optional.of(actor));SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,"",actor.getAuthorities()));
        access=new GoodsMarketBindingWriteAccess(goods,repository,em,current);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    @Test void visibilityAloneDoesNotGrantManagement(){when(goods.canWrite(row)).thenReturn(false);assertThat(access.canManage(id)).isFalse();doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND)).when(goods).requireWritable(row);assertThatThrownBy(()->access.requireWritableAndLock(id)).isInstanceOf(com.uten.imp.common.web.ApiException.class);verifyNoInteractions(em);}
    @Test void writeScopeIsRecheckedOnTheLockedFreshMaster(){access.requireWritableAndLock(id);verify(em).refresh(row,LockModeType.PESSIMISTIC_WRITE);verify(goods,times(2)).requireVisible(row);verify(goods,times(2)).requireWritable(row);}
    @Test void aConcurrentDeletionAfterTheLockRejectsTheBinding(){doAnswer(call->{row.setDeleted(true);return null;}).when(em).refresh(row,LockModeType.PESSIMISTIC_WRITE);assertThatThrownBy(()->access.requireWritableAndLock(id)).hasMessage("货品不存在");}
    @Test void aReadOnlyActorCannotCallTheGuardDirectly(){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","",List.of(new org.springframework.security.core.authority.SimpleGrantedAuthority("goods:view"))));assertThatThrownBy(()->access.requireWritableAndLock(id)).hasMessageContaining("goods:edit");verifyNoInteractions(em);}
}
