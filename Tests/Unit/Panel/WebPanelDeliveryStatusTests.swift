import XCTest

@testable import WallpaperMachine

/// The panel has to keep three things apart for both audio and media: what the
/// user switched on, whether anything is actually being delivered, and whether
/// it can tell at all. Collapsing "available" into "cannot tell" is easy to do
/// by accident, because both are naturally spelled as an absent value, and the
/// result reads as a measurement the panel never made.
@MainActor
final class WebPanelDeliveryStatusTests: XCTestCase {
  private func payload(
    audioResponseEnabled: Bool = true,
    mediaIntegrationEnabled: Bool = true,
    delivery: WebWallpaperHost.DeliveryStatus?
  ) -> [String: Any] {
    WebPanelController.options(
      BridgeSnapshotFixtures.options(
        kind: .webpage,
        audioResponseEnabled: audioResponseEnabled,
        mediaIntegrationEnabled: mediaIntegrationEnabled),
      titles: ResolvedDisplayTitles(names: [:]),
      assets: [:],
      errors: [:],
      delivery: delivery)
  }

  func testNoRunningHostReportsNeitherDeliveringNorNotDelivering() {
    let row = payload(delivery: nil)
    XCTAssertNil(
      row["audioDelivering"],
      "with no host the panel has made no observation, so it must not publish one")
    XCTAssertNil(row["mediaAvailable"])
    XCTAssertNil(row["mediaUnavailableReason"])
  }

  func testAPageThatRegisteredAListenerIsReportedAsDelivering() {
    let row = payload(delivery: WebWallpaperHost.DeliveryStatus(
      audioSubscribedDisplayIDs: [1], mediaUnavailableReason: nil))
    XCTAssertEqual(row["audioDelivering"] as? Bool, true)
  }

  func testAnEnabledSettingWithNoSubscriberIsReportedAsNotDelivering() {
    let row = payload(delivery: WebWallpaperHost.DeliveryStatus(
      audioSubscribedDisplayIDs: [], mediaUnavailableReason: nil))
    XCTAssertEqual(
      row["audioDelivering"] as? Bool, false,
      "the user's setting is on, but nothing asked for data, and those are different claims")
    XCTAssertEqual(row["audioResponseEnabled"] as? Bool, true)
  }

  func testAnAvailableMediaSourceIsDistinguishableFromAnUnknownOne() {
    let available = payload(delivery: WebWallpaperHost.DeliveryStatus(mediaUnavailableReason: nil))
    let unknown = payload(delivery: nil)
    XCTAssertEqual(available["mediaAvailable"] as? Bool, true)
    XCTAssertNil(unknown["mediaAvailable"])
    XCTAssertNil(
      available["mediaUnavailableReason"],
      "there is no reason to give when nothing is wrong")
  }

  func testAnUnavailableMediaSourceCarriesItsReason() {
    let row = payload(delivery: WebWallpaperHost.DeliveryStatus(
      mediaUnavailableReason: "MediaRemote refused the request."))
    XCTAssertEqual(row["mediaAvailable"] as? Bool, false)
    XCTAssertEqual(row["mediaUnavailableReason"] as? String, "MediaRemote refused the request.")
  }

  func testDeliveryStatusNeverOverwritesTheUsersOwnSettings() {
    let row = payload(
      audioResponseEnabled: false, mediaIntegrationEnabled: false,
      delivery: WebWallpaperHost.DeliveryStatus(
        audioSubscribedDisplayIDs: [7], mediaUnavailableReason: nil))
    XCTAssertEqual(row["audioResponseEnabled"] as? Bool, false)
    XCTAssertEqual(row["mediaIntegrationEnabled"] as? Bool, false)
  }
}
