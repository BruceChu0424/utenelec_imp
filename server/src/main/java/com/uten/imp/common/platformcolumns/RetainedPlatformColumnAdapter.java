package com.uten.imp.common.platformcolumns;

import java.util.*;

/** Master-data annotations survive a business reset; all authorization remains delegated. */
public record RetainedPlatformColumnAdapter(PlatformColumnResourceAdapter delegate) implements PlatformColumnResourceAdapter {
    @Override public String scope(){return delegate.scope();}@Override public String label(){return delegate.label();}
    @Override public void requireDefinitionAccess(boolean write){delegate.requireDefinitionAccess(write);}
    @Override public boolean canWrite(){return delegate.canWrite();}@Override public boolean canViewPrice(){return delegate.canViewPrice();}
    @Override public boolean canCreate(){return delegate.canCreate();}@Override public boolean supportsValues(){return delegate.supportsValues();}
    @Override public boolean personalDefinitions(){return delegate.personalDefinitions();}@Override public boolean preserveValuesOnReset(){return true;}
    @Override public List<FactDefinition> facts(){return delegate.facts();}
    @Override public Map<UUID,RecordAccess> authorize(Set<UUID> ids,boolean write){return delegate.authorize(ids,write);}
    @Override public Map<UUID,RecordAccess> authorizeHistory(Set<UUID> ids){return delegate.authorizeHistory(ids);}
    @Override public void requireDocumentSaveAccess(boolean create){delegate.requireDocumentSaveAccess(create);}
    @Override public Map<UUID,RecordAccess> authorizeCreated(Set<UUID> ids){return delegate.authorizeCreated(ids);}
    @Override public Set<UUID> recordIdsForDocument(UUID id){return delegate.recordIdsForDocument(id);}
    @Override public void lockDocumentSave(UUID id,Object request){delegate.lockDocumentSave(id,request);}
    @Override public void requireDocumentFieldWrite(UUID id){delegate.requireDocumentFieldWrite(id);}
    @Override public Map<UUID,UUID> parentDocuments(Set<UUID> ids){return delegate.parentDocuments(ids);}
}
