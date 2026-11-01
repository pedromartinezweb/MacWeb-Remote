import AppKit
import ScreenCaptureKit
import CoreImage
import IOKit.pwr_mgt

final class FrameStore {
    private let lock = NSLock()
    private var frame = Data()
    private var revision: UInt64 = 0
    private var timestamp = Date.distantPast
    func update(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        frame = data; revision &+= 1; timestamp = Date()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        frame = Data(); timestamp = .distantPast
    }
    func read() -> (Data, UInt64, Date) {
        lock.lock(); defer { lock.unlock() }
        return (frame, revision, timestamp)
    }
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "local.macweb.capture", qos: .userInteractive)
    private var stream: SCStream?
    var isRunning: Bool { stream != nil }
    private var quality: Float = 0.65
    private var assertion: IOPMAssertionID = 0
    private(set) var selectedID: CGDirectDisplayID = 0
    private(set) var error: String?
    private(set) var displays: [SCDisplay] = []

    func refreshDisplays() async throws {
        displays = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false).displays
    }
    func start(displayID: CGDirectDisplayID, quality: Float = 0.65) async throws {
        try await refreshDisplays()
        guard let display = displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected display is no longer available."])
        }
        if let old = stream { try await old.stopCapture() }
        stream = nil
        selectedID = 0
        frames.clear()
        self.quality = quality
        let configuration = SCStreamConfiguration()
        let scale = min(1.0, 1600.0 / Double(display.width))
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.capturesAudio = false
        let next = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await next.startCapture()
        stream = next
        selectedID = displayID
        error = nil
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Remote desktop server active" as CFString, &assertion)
        }
    }
    func stop() async {
        if let old = stream { try? await old.stopCapture() }
        stream = nil
        selectedID = 0
        frames.clear()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.selectedID = 0
            self.frames.clear()
            self.error = error.localizedDescription
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = buffer.imageBuffer else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixels)
            guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]) else { return }
            frames.update(data)
        }
    }
}
