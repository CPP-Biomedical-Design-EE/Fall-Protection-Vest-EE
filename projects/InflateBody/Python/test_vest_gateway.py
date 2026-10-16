"""Tests for the local Python-to-Flutter status gateway."""

import json
import urllib.request
import unittest

from vest_gateway import GatewayState, start_http_server


class VestGatewayTests(unittest.TestCase):
    def test_status_endpoint_and_candidate_acknowledgement(self):
        state = GatewayState()
        state.update(connected=True, fall_candidate=True, notice="test candidate")
        server = start_http_server(state, "127.0.0.1", 0)
        try:
            host, port = server.server_address
            with urllib.request.urlopen(f"http://{host}:{port}/api/status") as response:
                status = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")
            self.assertTrue(status["connected"])
            self.assertTrue(status["fall_candidate"])

            request = urllib.request.Request(
                f"http://{host}:{port}/api/candidate/ack", data=b"{}", method="POST"
            )
            with urllib.request.urlopen(request) as response:
                acknowledged = json.loads(response.read().decode("utf-8"))
            self.assertFalse(acknowledged["fall_candidate"])
            self.assertEqual(state.candidate_acknowledgements(), 1)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
