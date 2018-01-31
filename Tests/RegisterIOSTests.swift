#if os(iOS)
import XCTest
@testable import PushNotifications

class RegisterTests: XCTestCase {

    let register = Register(token: "123", instanceId: "abc", bundleIdentifier: "com.pusher", metadata: Metadata(sdkVersion: "0.4.0", iosVersion: "11.2.0", macosVersion: nil))

    func testRegisterModel() {
        let register = self.register
        XCTAssertNotNil(register)
        XCTAssertEqual(register.token, "123")
        XCTAssertEqual(register.instanceId, "abc")
        XCTAssertEqual(register.bundleIdentifier, "com.pusher")
        XCTAssertEqual(register.metadata.sdkVersion, "0.4.0")
        XCTAssertEqual(register.metadata.iosVersion, "11.2.0")
        XCTAssertEqual(register.metadata.macosVersion, nil)
    }

    func testRegisterEncoded() {
        let registerEncoded = try! self.register.encode()
        XCTAssertNotNil(registerEncoded)
        let registerJSONExpected = "{\"metadata\":{\"sdkVersion\":\"0.4.0\",\"iosVersion\":\"11.2.0\"},\"instanceId\":\"abc\",\"token\":\"123\",\"bundleIdentifier\":\"com.pusher\"}"
        let registerJSON = String(data: registerEncoded, encoding: .utf8)!
        XCTAssertEqual(registerJSONExpected, registerJSON)
    }
}
#endif
