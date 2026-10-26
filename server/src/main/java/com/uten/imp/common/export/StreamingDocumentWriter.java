package com.uten.imp.common.export;

import java.io.IOException;
import java.io.OutputStream;

/** A worker owns this writer and its private directory until publication or cancellation. */
public interface StreamingDocumentWriter extends DocumentPageSink.Consumer,AutoCloseable {
    default void onCheckpoint(Runnable checkpoint){}
    long primaryRowCount();
    long rowCount();
    void finish(OutputStream output)throws IOException;
    @Override void close()throws IOException;
}
