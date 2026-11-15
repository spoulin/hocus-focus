import ApplicationServices
import Foundation

/// Undocumented functions from SkyLight and HIServices.
///
/// They are loaded at run time with dlopen/dlsym, never linked. If a future macOS
/// removes one of them, the symbol is nil and the app falls back to a normal raise
/// instead of failing to launch.
public enum Private {
    typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias SetFrontProcessWithOptions = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias GetWindowOwner = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> CGError
    typealias GetConnectionPSN = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> CGError
    typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

    private static func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    static let postEventRecordTo = load(skyLight, "SLPSPostEventRecordTo", as: PostEventRecordTo.self)
    static let setFrontProcessWithOptions = load(skyLight, "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptions.self)
    static let mainConnectionID = load(skyLight, "SLSMainConnectionID", as: MainConnectionID.self)
    static let getWindowOwner = load(skyLight, "SLSGetWindowOwner", as: GetWindowOwner.self)
    static let getConnectionPSN = load(skyLight, "SLSGetConnectionPSN", as: GetConnectionPSN.self)
    static let axGetWindow = load(appServices, "_AXUIElementGetWindow", as: AXGetWindow.self)

    /// True when every symbol needed for focus without raise was found.
    public static var focusWithoutRaiseAvailable: Bool {
        postEventRecordTo != nil && setFrontProcessWithOptions != nil
            && mainConnectionID != nil && getWindowOwner != nil && getConnectionPSN != nil
    }

    public static var report: [(String, Bool)] {
        [
            ("SLPSPostEventRecordTo", postEventRecordTo != nil),
            ("_SLPSSetFrontProcessWithOptions", setFrontProcessWithOptions != nil),
            ("SLSMainConnectionID", mainConnectionID != nil),
            ("SLSGetWindowOwner", getWindowOwner != nil),
            ("SLSGetConnectionPSN", getConnectionPSN != nil),
            ("_AXUIElementGetWindow", axGetWindow != nil),
        ]
    }

    /// The process serial number of the process that owns a window, found from the
    /// window itself. Replaces the deprecated GetProcessForPID.
    static func psn(ofWindow windowID: CGWindowID) -> ProcessSerialNumber? {
        guard let mainConnectionID, let getWindowOwner, let getConnectionPSN else { return nil }
        var ownerConnection: Int32 = 0
        guard getWindowOwner(mainConnectionID(), windowID, &ownerConnection) == .success else { return nil }
        var psn = ProcessSerialNumber()
        guard getConnectionPSN(ownerConnection, &psn) == .success else { return nil }
        return psn
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        return axGetWindow(element, &id) == .success && id != 0 ? id : nil
    }
}
