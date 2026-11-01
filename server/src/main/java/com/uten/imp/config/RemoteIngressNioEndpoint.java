package com.uten.imp.config;

import org.apache.tomcat.util.net.NioChannel;
import org.apache.tomcat.util.net.NioEndpoint;
import org.apache.tomcat.util.net.SocketEvent;
import org.apache.tomcat.util.net.SocketWrapperBase;

/** Response backpressure must not inherit the remote connector's short request-read budget. */
final class RemoteIngressNioEndpoint extends NioEndpoint {
    private final long writeTimeoutMillis;

    RemoteIngressNioEndpoint(long writeTimeoutMillis) {
        this.writeTimeoutMillis = writeTimeoutMillis;
    }

    @Override
    public boolean processSocket(SocketWrapperBase<NioChannel> socket, SocketEvent event, boolean dispatch) {
        // Set before any processor (including a cached one) can write. Changing it after
        // super.setSocketOptions would race the poller registration performed by Tomcat.
        if (socket != null) socket.setWriteTimeout(writeTimeoutMillis);
        return super.processSocket(socket, event, dispatch);
    }
}
