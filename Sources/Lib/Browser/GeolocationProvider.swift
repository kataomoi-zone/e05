import CoreLocation
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "Geolocation")

/// Supplies the positions a page's `navigator.geolocation` waits for.
///
/// On macOS, WebKit fetches positions only through a provider the
/// embedding app registers on each process pool; without one a page
/// whose request was granted gets neither a position nor an error and
/// runs into its own timeout. (iOS WebKit falls back to CoreLocation
/// by itself, macOS does not.) The registration is WebKit's C API,
/// which ships in the framework without a public header, so the
/// functions are looked up at run time: should a future WebKit drop
/// them, location stays unavailable instead of the app failing to
/// launch.
///
/// One `CLLocationManager` serves every pool. It runs while at least
/// one pool has a page watching, and its fixes go to all of them.
@MainActor
final class GeolocationProvider: NSObject, CLLocationManagerDelegate {
  static let shared = GeolocationProvider()

  private let locationManager = CLLocationManager()
  private let api = WebKitGeolocationAPI.load()
  /// Weak, so a pool that goes away doesn't linger and a new pool
  /// allocated at its address is not mistaken for a registered one.
  private let registeredPools = NSHashTable<AnyObject>.weakObjects()
  /// Retained while listed, so a fix arriving as a pool goes away
  /// can't reach a freed manager.
  private var updatingManagers: [OpaquePointer] = []

  private override init() {
    super.init()
    locationManager.delegate = self
    if api == nil {
      logger.error("WebKit geolocation provider API not found; pages get no location")
    }
  }

  /// Registers the provider on `webView`'s process pool, once per pool.
  /// Every fresh configuration brings a pool of its own, so this runs
  /// for each pane.
  /// Popups and opener-adopted panes share their opener's pool, so the
  /// web views a pane builds itself are the only ones to pass here.
  func attach(to webView: WKWebView) {
    guard let api else { return }
    // `WKProcessPool` is deprecated as a public API, but every
    // configuration still carries one and the provider lives on it.
    // Read through KVC so the deprecation doesn't warn on every build.
    guard let pool = webView.configuration.value(forKey: "processPool") as AnyObject?,
      !registeredPools.contains(pool),
      let manager = api.contextGetGeolocationManager(
        Unmanaged.passUnretained(pool).toOpaque())
    else { return }
    registeredPools.add(pool)
    var provider = ProviderV0(
      version: 0,
      clientInfo: nil,
      startUpdating: { manager, _ in
        guard let manager else { return }
        MainActor.assumeIsolated { GeolocationProvider.shared.startUpdating(manager) }
      },
      stopUpdating: { manager, _ in
        guard let manager else { return }
        MainActor.assumeIsolated { GeolocationProvider.shared.stopUpdating(manager) }
      })
    // WebKit copies the struct, so a stack value is enough.
    withUnsafePointer(to: &provider) { api.managerSetProvider(manager, UnsafeRawPointer($0)) }
  }

  private func startUpdating(_ manager: OpaquePointer) {
    logger.debug("start updating")
    guard let api, !updatingManagers.contains(manager) else { return }
    updatingManagers.append(api.retain(manager))
    switch locationManager.authorizationStatus {
    case .notDetermined:
      // Updating starts once the answer arrives: started now,
      // CoreLocation reports a denial while macOS is still asking.
      locationManager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      fail(Self.deniedMessage)
    default:
      // Restarted rather than left running: a pool joining would
      // otherwise wait for the next fix, which a Mac that isn't
      // moving may never produce. `CLLocationManager.location` is no
      // substitute, since it can be hours old.
      locationManager.stopUpdatingLocation()
      locationManager.startUpdatingLocation()
    }
  }

  private func stopUpdating(_ manager: OpaquePointer) {
    logger.debug("stop updating")
    guard let index = updatingManagers.firstIndex(of: manager) else { return }
    api?.release(updatingManagers.remove(at: index))
    if updatingManagers.isEmpty { locationManager.stopUpdatingLocation() }
  }

  private func deliver(_ location: CLLocation, to managers: [OpaquePointer]) {
    // A negative accuracy marks the coordinate itself as invalid.
    guard let api, location.horizontalAccuracy >= 0 else { return }
    let floor = location.floor.map { Double($0.level) }
    guard
      let position = api.positionCreate(
        location.timestamp.timeIntervalSince1970,
        location.coordinate.latitude,
        location.coordinate.longitude,
        location.horizontalAccuracy,
        location.verticalAccuracy > 0, location.altitude,
        location.verticalAccuracy > 0, location.verticalAccuracy,
        location.course >= 0, location.course,
        location.speed >= 0, location.speed,
        floor != nil, floor ?? 0)
    else { return }
    defer { api.release(position) }
    for manager in managers { api.managerDidChangePosition(manager, position) }
  }

  private func fail(_ message: String) {
    guard let api, !updatingManagers.isEmpty else { return }
    logger.error("no position: \(message, privacy: .public)")
    guard let string = api.stringCreateWithCFString(message as CFString) else { return }
    defer { api.release(string) }
    for manager in updatingManagers {
      api.managerDidFailToDeterminePosition(manager, string)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    guard let location = locations.last else { return }
    MainActor.assumeIsolated { deliver(location, to: updatingManagers) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // `locationUnknown` only means no fix yet; CoreLocation keeps
    // trying, and the page's own timeout covers it if none comes.
    // `denied` is answered from the authorization change instead,
    // since it also arrives while the macOS prompt is still up.
    if let code = (error as? CLError)?.code, code == .locationUnknown || code == .denied {
      return
    }
    let message = error.localizedDescription
    MainActor.assumeIsolated { fail(message) }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    MainActor.assumeIsolated {
      logger.debug("authorization status \(status.rawValue, privacy: .public)")
      switch status {
      case .notDetermined:
        break
      case .denied, .restricted:
        fail(Self.deniedMessage)
      default:
        if !updatingManagers.isEmpty { locationManager.startUpdatingLocation() }
      }
    }
  }

  private static let deniedMessage = "Location access for e05 is turned off in System Settings"
}

/// `WKGeolocationProviderV0` from WebKit's `WKGeolocationManager.h`.
/// Swift's stable ABI lays a struct out in declaration order with
/// natural alignment, which is what makes it match the C one.
struct ProviderV0 {
  var version: Int32
  var clientInfo: UnsafeRawPointer?
  var startUpdating: @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
  var stopUpdating: @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
}

/// The WebKit C functions the provider calls, resolved from the loaded
/// framework.
struct WebKitGeolocationAPI {
  typealias Ref = OpaquePointer

  let contextGetGeolocationManager: @convention(c) (UnsafeRawPointer) -> Ref?
  let managerSetProvider: @convention(c) (Ref, UnsafeRawPointer) -> Void
  let managerDidChangePosition: @convention(c) (Ref, Ref) -> Void
  let managerDidFailToDeterminePosition: @convention(c) (Ref, Ref) -> Void
  let positionCreate:
    @convention(c) (
      Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double,
      Bool, Double
    ) -> Ref?
  let stringCreateWithCFString: @convention(c) (CFString) -> Ref?
  let retain: @convention(c) (Ref) -> Ref
  let release: @convention(c) (Ref) -> Void

  static func load() -> WebKitGeolocationAPI? {
    struct Missing: Error {}
    // Each function type is inferred from the init parameter it fills.
    func symbol<T>(_ name: String) throws -> T {
      // RTLD_DEFAULT: WebKit is already linked into the process.
      guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
        logger.error("missing WebKit symbol \(name, privacy: .public)")
        throw Missing()
      }
      return unsafeBitCast(pointer, to: T.self)
    }
    return try? WebKitGeolocationAPI(
      contextGetGeolocationManager: symbol("WKContextGetGeolocationManager"),
      managerSetProvider: symbol("WKGeolocationManagerSetProvider"),
      managerDidChangePosition: symbol("WKGeolocationManagerProviderDidChangePosition"),
      managerDidFailToDeterminePosition: symbol(
        "WKGeolocationManagerProviderDidFailToDeterminePositionWithErrorMessage"),
      positionCreate: symbol("WKGeolocationPositionCreate_c"),
      stringCreateWithCFString: symbol("WKStringCreateWithCFString"),
      retain: symbol("WKRetain"),
      release: symbol("WKRelease"))
  }
}
