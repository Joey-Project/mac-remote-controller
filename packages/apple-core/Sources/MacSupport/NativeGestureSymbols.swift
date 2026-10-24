#if os(macOS)
    import CoreGraphics
    import Darwin
    import Foundation

    /// Loads only fixed system libraries. Missing private symbols disable the action.
    final class SystemGestureLibrary {
        private let handle: UnsafeMutableRawPointer

        init?(_ path: String) {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
            self.handle = handle
        }

        deinit { dlclose(handle) }

        func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
    }

    final class NativeDockNotification {
        private typealias Send = @convention(c) (CFString, Int32) -> Void
        private let library: SystemGestureLibrary
        private let sendNotification: Send

        init?() {
            guard
                let library = SystemGestureLibrary(
                    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"),
                let send = library.symbol("CoreDockSendNotification", as: Send.self)
            else { return nil }
            self.library = library
            self.sendNotification = send
        }

        func send(_ name: String) { sendNotification(name as CFString, 0) }
    }

    /// The HID payload is required by macOS 27. No virtual device or driver is created.
    /// C ABI follows Apple's HIDEvent wrapper; no CGEvent memory offsets are accessed.
    final class NativeHIDEventBridge {
        private typealias Create =
            @convention(c) (CFAllocator?, UInt32, UInt64, UInt32) -> Unmanaged<CFTypeRef>?
        private typealias SetInteger = @convention(c) (CFTypeRef, UInt32, CFIndex) -> Void
        private typealias SetDouble = @convention(c) (CFTypeRef, UInt32, Double) -> Void
        private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
        private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void

        private let iokit: SystemGestureLibrary
        private let skyLight: SystemGestureLibrary
        private let create: Create
        private let setInteger: SetInteger
        private let setDouble: SetDouble
        private let append: Append
        private let attach: Attach

        init?() {
            guard
                let iokit = SystemGestureLibrary(
                    "/System/Library/Frameworks/IOKit.framework/IOKit"),
                let skyLight = SystemGestureLibrary(
                    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"),
                let create = iokit.symbol("IOHIDEventCreate", as: Create.self),
                let setInteger = iokit.symbol("IOHIDEventSetIntegerValue", as: SetInteger.self),
                let setDouble = iokit.symbol("IOHIDEventSetDoubleValue", as: SetDouble.self),
                let append = iokit.symbol("IOHIDEventAppendEvent", as: Append.self),
                let attach = skyLight.symbol("SLEventSetIOHIDEvent", as: Attach.self)
            else { return nil }
            self.iokit = iokit
            self.skyLight = skyLight
            self.create = create
            self.setInteger = setInteger
            self.setDouble = setDouble
            self.append = append
            self.attach = attach
        }

        func attach(to event: CGEvent, frame: DockSwipeFrame) -> Bool {
            guard let hid = create(nil, 23, 0, frame.phase << 24)?.takeRetainedValue() else {
                return false
            }
            // IOHIDEventFieldBase(type) is type << 16. DockPrimary flavor is 3.
            let dockBase: UInt32 = 23 << 16
            setInteger(hid, dockBase | 1, 1)
            setInteger(hid, dockBase | 5, 3)
            setDouble(hid, dockBase | 2, frame.progress)
            if frame.phase == 4 {
                guard let velocity = create(nil, 9, 0, 0)?.takeRetainedValue() else { return false }
                setDouble(velocity, 9 << 16, frame.velocity)
                setDouble(velocity, (9 << 16) | 1, 0)
                setDouble(velocity, (9 << 16) | 2, 0)
                append(hid, velocity, 0)
            }
            attach(event, hid)
            return true
        }
    }
#endif
