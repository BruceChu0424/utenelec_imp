package com.uten.imp.common.platformcolumns;

import java.util.*;

/** Master-data annotations survive a business reset; all authorization remains delegated. */
public record RetainedPlatformColumnAdapter(PlatformColumnResourceAdapter delegate) implements PlatformColumnResourceAdapter {
    public String scope(){return delegate.scope();}public String label(){return delegate.label();}
    public void requireDefinitionAccess(boolean write){delegate.requireDefinitionAccess(write);}
    public boolean canWrite(){return delegate.canWrite();}public boolean canViewPrice(){return delegate.canViewPrice();}
    public boolean canCreate(){return delegate.canCreate();}public boolean supportsValues(){return delegate.supportsValues();}
    public boolean personalDefinitions(){return delegate.personalDefinitions();}public boolean preserveValuesOnReset(){return true;}
    public List<FactDefinition> facts(){return delegate.facts();}
    public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){return delegate.authorize(ids,write);}
    public void requireDocumentSaveAccess(boolean create){delegate.requireDocumentSaveAccess(create);}
    public Map<UUID,RecordAccess> authorizeCreated(Set<UUID> ids){return delegate.authorizeCreated(ids);}
    public Set<UUID> recordIdsForDocument(UUID id){return delegate.recordIdsForDocument(id);}
    public Map<UUID,UUID> parentDocuments(Set<UUID> ids){return delegate.parentDocuments(ids);}
}
