// SPDX-License-Identifier: MIT
import XCTest
import LeokaniG2P

/// Load time and memory of a fresh instance (printed; read them from the test log on a device).
final class LoadTests: XCTestCase {
    func testColdLoad() throws {
        let before = Self.footprintMB()
        let t0 = Date()
        let g = try LeokaniG2P()
        let load = Date().timeIntervalSince(t0)
        let after = Self.footprintMB()
        let t1 = Date()
        let out = g.phonemize("Dr. Okafor lands at 7:45 AM, then Siobhan Quarrington drives to Llanfairpwll.")
        let first = Date().timeIntervalSince(t1)
        XCTAssertFalse(out.isEmpty)
        print(String(format: "LEOKANI-LOAD load %.3f s, first line %.3f s, footprint %.0f -> %.0f MB",
                     load, first, before, after))
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
