package com.uten.uten_imp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var clientUpdateBridge: ClientUpdateBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        clientUpdateBridge = ClientUpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        clientUpdateBridge?.close()
        clientUpdateBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
