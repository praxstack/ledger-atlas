import Foundation
import Testing

@testable import LedgerAtlasMacUI

@Test func loopbackPortalAllowsOnlyTokenedReadOnlyStatusRequests() throws {
  let projection = LedgerPortalProjection(state: .ready, accountCount: 2, transactionCount: 4)
  let body = try JSONEncoder().encode(projection)
  let token = "test-token"
  let ok = LedgerLoopbackPortal.response(
    request: "GET /status?token=test-token HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    token: token, projectionData: body)
  #expect(ok.status == 200)
  #expect(ok.body == body)
  #expect(
    LedgerLoopbackPortal.response(
      request: "GET /status?token=wrong HTTP/1.1\r\n\r\n", token: token, projectionData: body
    ).status == 401)
  #expect(
    LedgerLoopbackPortal.response(
      request: "POST /status?token=test-token HTTP/1.1\r\n\r\n", token: token, projectionData: body
    ).status == 405)
  #expect(
    LedgerLoopbackPortal.response(
      request: "GET /mutate?token=test-token HTTP/1.1\r\n\r\n", token: token, projectionData: body
    ).status == 404)
}

@MainActor
@Test func loopbackPortalServesAReadOnlyStatusAndStops() async throws {
  let portal = LedgerLoopbackPortal(idleTimeout: 30)
  let projection = LedgerPortalProjection(state: .ready, accountCount: 1, transactionCount: 2)
  let url = try await portal.start(projection: projection)
  defer { portal.stop() }
  let (data, response) = try await URLSession.shared.data(from: url)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(try JSONDecoder().decode(LedgerPortalProjection.self, from: data) == projection)
  portal.stop()
  #expect(portal.url == nil)
}
