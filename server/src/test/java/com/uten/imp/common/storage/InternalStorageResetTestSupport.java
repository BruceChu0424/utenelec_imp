package com.uten.imp.common.storage;
import com.uten.imp.config.props.StorageProperties;
/** Test-only portability: Linux verification selects the production directory-sync constructor explicitly. */
public final class InternalStorageResetTestSupport {
    private InternalStorageResetTestSupport(){}
    public static InternalStorageService open(StorageProperties properties) throws Exception {
        boolean real=Boolean.getBoolean("uten.test.internal.real-directory-sync");
        if(real && !System.getProperty("os.name").toLowerCase(java.util.Locale.ROOT).contains("linux"))
            throw new IllegalStateException("Real directory-sync test requires Linux");
        InternalStorageService store=real?new InternalStorageService(properties):new InternalStorageService(properties,directory->{});
        store.init();return store;
    }
}
