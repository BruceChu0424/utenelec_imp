package com.uten.imp.features.master.lifecycle;

import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MasterClientCoOwnerAccessTest {
    @Test
    void lifecyclePassesTheCustomerIdentitySoCoOwnershipCannotGrantOtherCustomers() {
        var policy=mock(ClientAccessPolicy.class);
        var scope=new ClientAccessPolicy.ClientScope(new OwnerVisibility.OwnerScope(false,Set.of()),Set.of(),false);
        when(policy.evaluate()).thenReturn(scope);
        UUID sharedClient=UUID.randomUUID(), otherClient=UUID.randomUUID(), primaryOwner=UUID.randomUUID();
        var ids=Set.of(sharedClient,otherClient);
        when(policy.writableCoOwnedClientIds(ids,scope)).thenReturn(Set.of(sharedClient));
        var access=new MasterObjectAccess(mock(OwnerVisibility.class),policy);
        var writable=access.writableObject(MasterEntityKind.CLIENT,ids);
        assertTrue(writable.test(sharedClient,primaryOwner));
        assertFalse(writable.test(otherClient,primaryOwner));
        verify(policy,times(1)).evaluate();
        verify(policy,times(1)).writableCoOwnedClientIds(ids,scope);
        verify(policy,never()).canWrite(any(UUID.class),any(UUID.class),any());
    }
}
