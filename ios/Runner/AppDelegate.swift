import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var clientUpdateChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/client_update",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "getSoftwareDownloadHost" {
        var system = utsname()
        let read = uname(&system) == 0
        let machineCapacity = MemoryLayout.size(ofValue: system.machine)
        let machine = read ? withUnsafePointer(to: &system.machine) { pointer in
          pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
        } : "unknown"
        #if targetEnvironment(simulator)
        let simulator = true
        let architecture = "unknown"
        #else
        let simulator = false
        // All devices supported by the current iOS deployment target are ARM64.
        let architecture = machine.hasPrefix("iPhone") || machine.hasPrefix("iPad") || machine.hasPrefix("iPod") ? "arm64" : "unknown"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        result([
          "platform": "ios", "architecture": architecture,
          "osVersion": UIDevice.current.systemVersion,
          "osLabel": "iOS \(UIDevice.current.systemVersion)",
          "osMajor": version.majorVersion, "osMinor": version.minorVersion,
          "osBuild": 0, "osPatch": version.patchVersion, "servicePackMajor": 0,
          "isServer": false, "isSimulator": simulator, "machine": machine,
        ])
        return
      }
      guard call.method == "getInstallContext" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let info = Bundle.main.infoDictionary ?? [:]
      let version = info["CFBundleShortVersionString"] as? String ?? ""
      let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
      let staging = FileManager.default.temporaryDirectory.appendingPathComponent("client-updates", isDirectory: true)
      try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      #if arch(arm64)
      let architecture = "arm64"
      #elseif arch(x86_64)
      let architecture = "x64"
      #else
      let architecture = "universal"
      #endif
      result([
        "platform": "ios",
        "architecture": architecture,
        "currentVersion": version,
        "currentBuild": build,
        "stagingDirectory": staging.path,
        "supportsInPlaceUpdate": false,
        "requiresSystemConfirmation": true,
      ])
    }
    clientUpdateChannel = channel
  }
}
