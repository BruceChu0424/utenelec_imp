import Cocoa
import FlutterMacOS
import QuartzCore

class MainFlutterWindow: NSWindow {
  private var clientUpdateChannel: FlutterMethodChannel?
  private var desktopWindowChannel: FlutterMethodChannel?
  private enum DesktopMode: String { case login, main }
  private var requestedMode = DesktopMode.login
  private var appliedMode: DesktopMode?
  private var mainFrame: NSRect?
  private var mainUnzoomedFrame: NSRect?
  private var restoreMainZoom = false
  private var mainWasZoomedBeforeFullScreen = false
  private var mainCollectionBehavior: NSWindow.CollectionBehavior = []
  private var restoreMainFullScreen = false
  private var fullScreenTransition = false
  private var exitingFullScreenForLogin = false
  private var leftMouseDown: NSEvent?
  private var windowObservers: [NSObjectProtocol] = []
  private var lastPublishedMaximized: Bool?
  private static let loginCornerRadius: CGFloat = 16
  private struct WindowAppearance {
    let isOpaque: Bool
    let backgroundColor: NSColor?
  }
  private struct ContentLayerAppearance {
    let wantsLayer: Bool
    let cornerRadius: CGFloat
    let masksToBounds: Bool
    let maskedCorners: CACornerMask
  }
  private var normalWindowAppearance: WindowAppearance?
  private weak var roundedContentView: NSView?
  private var normalContentLayerAppearance: ContentLayerAppearance?

  // Borderless windows otherwise cannot receive keyboard focus on macOS.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    mainCollectionBehavior = collectionBehavior.union(.fullScreenPrimary)
    title = "UTEN"
    // Configure the login frame before creating/showing the Flutter surface.
    // Authentication changes only this window's presentation, not its engine.
    applyMode(.login)
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    // applyMode initially saw the nib's content view. Clip the actual Flutter
    // root after replacement, before it can display its opaque Metal content.
    updateWindowShape()
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/client_update",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
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
        "platform": "macos",
        "architecture": architecture,
        "currentVersion": version,
        "currentBuild": build,
        "stagingDirectory": staging.path,
        "supportsInPlaceUpdate": false,
        "requiresSystemConfirmation": true,
      ])
    }
    clientUpdateChannel = channel

    installDesktopWindowChannel(flutterViewController)
    observeFullScreenTransitions()

    super.awakeFromNib()
  }

  override func sendEvent(_ event: NSEvent) {
    // Method-channel messages arrive after sendEvent has returned; currentEvent
    // alone is not a reliable way to recover the original mouse-down event.
    if event.type == .leftMouseDown { leftMouseDown = event }
    if event.type == .leftMouseUp { leftMouseDown = nil }
    super.sendEvent(event)
  }

  override func performClose(_ sender: Any?) {
    if styleMask.contains(.titled) {
      super.performClose(sender)
    } else if delegate?.windowShouldClose?(self) != false {
      // AppKit's normal performClose requires a native titlebar close button.
      // Honor the delegate while supporting the login button and Command+W.
      close()
    }
  }

  override func zoom(_ sender: Any?) {
    if appliedMode == .main && !isZoomed &&
       !fullScreenTransition && !styleMask.contains(.fullScreen) {
      // Keep the ordinary frame independently of AppKit's internal zoom frame,
      // which can be replaced when the same window becomes the compact login.
      mainUnzoomedFrame = frame
    }
    super.zoom(sender)
    publishWindowState()
  }

  private func installDesktopWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "com.uten.imp/desktop_window",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "WINDOW_UNAVAILABLE", message: "The window is closing.", details: nil))
        return
      }
      switch call.method {
      case "setMode":
        guard let value = call.arguments as? String, let mode = DesktopMode(rawValue: value) else {
          result(FlutterError(code: "INVALID_MODE", message: "Expected login or main.", details: nil))
          return
        }
        self.requestMode(mode)
        result(nil)
      case "beginDrag":
        if self.appliedMode != nil,
           NSEvent.pressedMouseButtons & 1 != 0,
           let event = self.leftMouseDown,
           event.windowNumber == self.windowNumber {
          self.performDrag(with: event)
        }
        result(nil)
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "toggleMaximize":
        if self.appliedMode == .main && !self.fullScreenTransition {
          if self.styleMask.contains(.fullScreen) {
            self.toggleFullScreen(nil)
          } else {
            self.zoom(nil)
          }
        }
        result(nil)
      case "getWindowState":
        result(self.windowState)
      case "close":
        result(nil)
        // Do not tear down Flutter/the channel while it is handling this call.
        DispatchQueue.main.async { [weak self] in self?.performClose(nil) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    desktopWindowChannel = channel
    publishWindowState(force: true)
  }

  private var windowState: [String: Bool] {
    ["maximized": appliedMode == .main && (isZoomed || styleMask.contains(.fullScreen))]
  }

  private func publishWindowState(force: Bool = false) {
    let state = windowState
    let maximized = state["maximized"] ?? false
    guard force || lastPublishedMaximized != maximized else { return }
    lastPublishedMaximized = maximized
    desktopWindowChannel?.invokeMethod("windowStateChanged", arguments: state)
  }

  private func requestMode(_ mode: DesktopMode) {
    requestedMode = mode
    if mode == appliedMode && !exitingFullScreenForLogin { return }
    if mode == .login && appliedMode == .main {
      if styleMask.contains(.fullScreen) || fullScreenTransition {
        restoreMainZoom = mainWasZoomedBeforeFullScreen
        restoreMainFullScreen = true
        exitingFullScreenForLogin = true
        if !fullScreenTransition { toggleFullScreen(nil) }
        return
      }
      restoreMainZoom = isZoomed
      mainFrame = isZoomed ? (mainUnzoomedFrame ?? frame) : frame
    }
    if fullScreenTransition { return }
    applyMode(mode)
  }

  private func applyMode(_ mode: DesktopMode) {
    guard appliedMode != mode else { return }
    if mode == .login && normalWindowAppearance == nil {
      normalWindowAppearance = WindowAppearance(isOpaque: isOpaque, backgroundColor: backgroundColor)
    }
    appliedMode = mode
    leftMouseDown = nil
    let visibleFrame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    contentMinSize = .zero
    contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    if mode == .login {
      // Closable/miniaturizable retain native menu semantics without a titlebar.
      styleMask = [.borderless, .closable, .miniaturizable]
      collectionBehavior = [.fullScreenNone]
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      isMovableByWindowBackground = false
      hasShadow = true
      let size = NSSize(width: min(800, visibleFrame.width), height: min(540, visibleFrame.height))
      let origin = NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
      setFrame(NSRect(origin: origin, size: size), display: true)
    } else {
      // Retain AppKit resizing, zoom and full-screen semantics while Flutter
      // draws the same transparent control strip used by the login window.
      styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      collectionBehavior = mainCollectionBehavior
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      isMovableByWindowBackground = false
      hasShadow = true
      hideNativeTitlebar()
      let target: NSRect
      if let rememberedFrame = mainFrame {
        target = constrainToVisibleScreen(rememberedFrame, fallback: visibleFrame)
      } else {
        let requested = frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let size = NSSize(width: min(requested.width, visibleFrame.width), height: min(requested.height, visibleFrame.height))
        target = NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
      }
      setFrame(target, display: true)
      let availableContent = contentRect(forFrameRect: target).size
      contentMinSize = NSSize(width: min(960, availableContent.width), height: min(640, availableContent.height))
      if restoreMainZoom {
        restoreMainZoom = false
        if !isZoomed { zoom(nil) }
      }
    }
    updateWindowShape()
    if isVisible && NSApp.isActive { makeKey() }
    if mode == .main { restoreFullScreenIfNeeded() }
    publishWindowState()
  }

  private func hideNativeTitlebar() {
    guard appliedMode == .main else { return }
    let closeButton = standardWindowButton(.closeButton)
    // A transparent native titlebar can still receive pointer events over the
    // full-size Flutter content. Hide its own container as well as the buttons;
    // never hide the content view or its root frame when AppKit changes layout.
    if let titlebar = closeButton?.superview?.superview,
       let content = contentView, titlebar !== content,
       !content.isDescendant(of: titlebar) {
      titlebar.isHidden = true
    }
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
  }

  private func updateWindowShape() {
    guard let mode = appliedMode else { return }
    if mode == .login {
      // A Flutter-only rounded rectangle would leave an opaque native window
      // behind it. Clear the window itself, then clip the root layer so every
      // Flutter/Metal sublayer is inside the same four 16-point corners.
      isOpaque = false
      backgroundColor = .clear
      if let view = contentView {
        if roundedContentView !== view {
          restoreContentLayerAppearance()
          normalContentLayerAppearance = ContentLayerAppearance(
            wantsLayer: view.wantsLayer,
            cornerRadius: view.layer?.cornerRadius ?? 0,
            masksToBounds: view.layer?.masksToBounds ?? false,
            maskedCorners: view.layer?.maskedCorners ?? [
              .layerMinXMinYCorner, .layerMaxXMinYCorner,
              .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ]
          )
          roundedContentView = view
        }
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.cornerRadius = Self.loginCornerRadius
        view.layer?.maskedCorners = [
          .layerMinXMinYCorner, .layerMaxXMinYCorner,
          .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
        ]
        view.layer?.masksToBounds = true
        CATransaction.commit()
      }
    } else {
      restoreContentLayerAppearance()
      if let appearance = normalWindowAppearance {
        backgroundColor = appearance.backgroundColor
        isOpaque = appearance.isOpaque
        normalWindowAppearance = nil
      }
      hideNativeTitlebar()
    }
    // AppKit recomputes the native shadow after size/backing-scale changes.
    invalidateShadow()
  }

  private func restoreContentLayerAppearance() {
    if let view = roundedContentView, let appearance = normalContentLayerAppearance {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      view.layer?.cornerRadius = appearance.cornerRadius
      view.layer?.maskedCorners = appearance.maskedCorners
      view.layer?.masksToBounds = appearance.masksToBounds
      CATransaction.commit()
      view.wantsLayer = appearance.wantsLayer
    }
    roundedContentView = nil
    normalContentLayerAppearance = nil
  }

  private func restoreFullScreenIfNeeded() {
    guard restoreMainFullScreen else { return }
    restoreMainFullScreen = false
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.requestedMode == .main,
            self.appliedMode == .main, !self.fullScreenTransition,
            !self.styleMask.contains(.fullScreen) else { return }
      self.toggleFullScreen(nil)
    }
  }

  private func constrainToVisibleScreen(_ remembered: NSRect, fallback: NSRect) -> NSRect {
    // A monitor may have disappeared while the login window was open.
    let matchingScreen = NSScreen.screens.max { first, second in
      let a = first.visibleFrame.intersection(remembered)
      let b = second.visibleFrame.intersection(remembered)
      return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }
    let candidate = matchingScreen?.visibleFrame ?? fallback
    let bounds = candidate.intersects(remembered) ? candidate : fallback
    let size = NSSize(width: min(remembered.width, bounds.width), height: min(remembered.height, bounds.height))
    return NSRect(
      x: min(max(remembered.minX, bounds.minX), bounds.maxX - size.width),
      y: min(max(remembered.minY, bounds.minY), bounds.maxY - size.height),
      width: size.width, height: size.height
    )
  }

  private func observeFullScreenTransitions() {
    let center = NotificationCenter.default
    for name in [NSWindow.didResizeNotification, NSWindow.didChangeBackingPropertiesNotification,
                 NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification,
                 NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      windowObservers.append(center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
        self?.updateWindowShape()
        self?.publishWindowState()
      })
    }
    windowObservers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.mainWasZoomedBeforeFullScreen = self.isZoomed
      self.mainFrame = self.isZoomed ? (self.mainUnzoomedFrame ?? self.frame) : self.frame
      self.fullScreenTransition = true
    })
    windowObservers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.fullScreenTransition = false
      if self.requestedMode == .login {
        self.requestMode(.login)
      } else {
        // The login request may have been cancelled during full-screen entry.
        self.exitingFullScreenForLogin = false
        self.restoreMainFullScreen = false
      }
      self.hideNativeTitlebar()
      self.publishWindowState()
    })
    windowObservers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      self?.fullScreenTransition = true
    })
    windowObservers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.fullScreenTransition = false
      self.hideNativeTitlebar()
      self.publishWindowState()
      guard self.exitingFullScreenForLogin else { return }
      self.exitingFullScreenForLogin = false
      // Do not save the full-screen frame as the ordinary main-window bounds.
      if self.requestedMode == .login {
        self.applyMode(.login)
      } else {
        // A rapid logout/login can cancel the compact-window transition.
        self.restoreMainFullScreen = true
        self.restoreFullScreenIfNeeded()
      }
    })
  }

  deinit {
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    desktopWindowChannel?.setMethodCallHandler(nil)
    clientUpdateChannel?.setMethodCallHandler(nil)
  }
}
