package com.uten.imp.features.master;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class FinancePartyReferenceLabelsAdapterTest {
  EntityManager em;Query query;FinancePartyReferenceLabelsAdapter labels;
  @BeforeEach void setup(){ em=mock(EntityManager.class);query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);labels=new FinancePartyReferenceLabelsAdapter(em); }
  @Test void boundedClientsSelectOnlyStoredLabelsAndRetainHiddenHistoricalIdentity(){
    UUID id=UUID.randomUUID();when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{id,"历史隐藏客户"}));
    assertThat(labels.clients(List.of(id,id))).containsExactlyEntriesOf(Map.of(id,"历史隐藏客户"));
    verify(em).createNativeQuery("SELECT id,name FROM clients WHERE id IN :ids");verify(query).setParameter("ids",List.of(id));
  }
  @Test void supplierUsesSameFiniteContractWithoutPiiOrMasterStatusGate(){
    UUID id=UUID.randomUUID(),other=UUID.randomUUID();when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{id,"旧供应商"},new Object[]{other,"unrequested"}));
    assertThat(labels.suppliers(List.of(id))).containsExactlyEntriesOf(Map.of(id,"旧供应商"));
    verify(em).createNativeQuery("SELECT id,name FROM suppliers WHERE id IN :ids");
  }
  @Test void absentLabelsStayUnknownAndEmptyInputDoesNotQuery(){
    assertThat(labels.clients(List.of())).isEmpty();verifyNoInteractions(em);
    UUID id=UUID.randomUUID();when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{id,null}));
    assertThat(labels.clients(List.of(id))).isEmpty();
  }
  @Test void overTwoHundredOrNullReferencesFailBeforeAnyRead(){
    assertThatThrownBy(()->labels.clients(Collections.nCopies(201,UUID.randomUUID()))).hasMessageContaining("200");
    assertThatThrownBy(()->labels.suppliers(Arrays.asList((UUID)null))).hasMessageContaining("200");verifyNoInteractions(em);
  }
}
