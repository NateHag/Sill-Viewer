import Foundation
import CoreVideo
import CoreMedia

/// `--encoder-selftest` (see the CLI's main.swift; the app takes the flag too). Synthetic
/// 1512×949 420f frames at 60 Hz for 2.5 s per encoder.
package enum EncoderSelfTest {
    package static func run() {
        print("== launch probe (what SillHost does at startup)")
        print("   hardware encoder \(EncoderProbe.hardwareResponds() ? "responds" : "does not respond: the host would start on the software encoder")")
        for software in [false, true] {
            print("== \(software ? "software" : "hardware") HEVC")
            let done = DispatchSemaphore(value: 0)
            var out = 0, hung = false
            do {
                let enc = try HEVCEncoder(width: 1512, height: 949, fps: 60, bitrate: 8_000_000, prioritizeSpeed: false, software: software)
                enc.onEncoded = { _, _, _ in out += 1 }
                enc.onHung = { hung = true; done.signal() }
                var pool: CVPixelBufferPool?
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                              kCVPixelBufferWidthKey: 1512, kCVPixelBufferHeightKey: 949,
                                              kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
                guard let pool else { print("   no pixel buffer pool"); continue }
                let feeder = Thread {
                    for i in 0..<150 {
                        var pb: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                        if let pb {
                            CVPixelBufferLockBaseAddress(pb, [])
                            if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                                memset(base, Int32(16 + (i * 5) % 200), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * CVPixelBufferGetHeightOfPlane(pb, 0))
                            }
                            CVPixelBufferUnlockBaseAddress(pb, [])
                            enc.encode(pb, pts: CMTime(value: CMTimeValue(i), timescale: 60))
                        }
                        usleep(16_000)
                    }
                    done.signal()
                }
                feeder.start()
                _ = done.wait(timeout: .now() + 4)
                print("   \(out) frames encoded, watchdog fired: \(hung)")
                _ = enc   // keep alive until here
            } catch { print("   could not create: \(error)") }
        }
        Stats.shared.dump()
        exit(0)
    }
}
