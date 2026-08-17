#!/usr/bin/env python3
"""agentd の許可リスト（許可した動詞だけが通り、それ以外は 4xx で拒否される）を検証する。

simctl は PATH に置いたスタブ xcrun に差し替えるため、Simulator が無くても実行できる。
実行: python3 runner/test/test-agentd.py
"""
import importlib.util
import json
import os
import signal
import stat
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

RUNNER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

spec = importlib.util.spec_from_file_location("agentd", os.path.join(RUNNER_DIR, "agentd.py"))
agentd_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agentd_module)

USER_BUNDLE_ID = "com.example.sample"
SLOT_UDIDS = ["UDID-0", "UDID-1"]
ORIGINAL_STOP_SIGNALS = agentd_module.RECORD_STOP_SIGNALS

# 実 simctl の listapps と同じ OpenStep plist を返し、呼ばれた引数を argv ログへ残すスタブ
XCRUN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$XCRUN_ARGV_LOG"
if [ "${4:-}" = "recordVideo" ]; then
  # 実際の recordVideo は SIGINT を受けるまで動き続け、出力ファイルを書く
  [ "${XCRUN_RECORD_FAIL:-0}" = "1" ] && exit 1
  printf 'fake video' > "${!#}"
  # 起動直後の停止で SIGINT を取りこぼす実機の挙動を再現する
  [ "${XCRUN_RECORD_IGNORE_SIGINT:-0}" = "1" ] && trap '' INT || trap 'exit 0' INT
  while true; do sleep 0.1; done
fi
if [ "$2" = "listapps" ]; then
  cat <<'PLIST'
{
    "com.example.sample" = {
        ApplicationType = User;
        CFBundleIdentifier = "com.example.sample";
    };
    "com.apple.Maps" = {
        ApplicationType = System;
        CFBundleIdentifier = "com.apple.Maps";
    };
    "com.facebook.WebDriverAgentRunner.xctrunner" = {
        ApplicationType = User;
        CFBundleIdentifier = "com.facebook.WebDriverAgentRunner.xctrunner";
    };
}
PLIST
fi
exit 0
"""


class AgentdTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        bin_dir = os.path.join(cls.tmp.name, "bin")
        os.makedirs(bin_dir)
        stub = os.path.join(bin_dir, "xcrun")
        with open(stub, "w", encoding="utf-8") as f:
            f.write(XCRUN_STUB)
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        cls.argv_log = os.path.join(cls.tmp.name, "xcrun-argv.log")
        os.environ["XCRUN_ARGV_LOG"] = cls.argv_log
        os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]

        cls.work_dir = os.path.join(cls.tmp.name, "work")
        cls.server = agentd_module.build_server(SLOT_UDIDS, cls.work_dir, 0)
        cls.base_url = f"http://127.0.0.1:{cls.server.server_address[1]}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.tmp.cleanup()

    def setUp(self):
        open(self.argv_log, "w", encoding="utf-8").close()

    def post(self, path, body):
        request = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.loads(error.read().decode("utf-8"))

    def simctl_calls(self):
        with open(self.argv_log, encoding="utf-8") as f:
            return [line.strip() for line in f if line.strip() and "listapps" not in line]

    # --- 許可した動詞が通ること ----------------------------------------
    def test_status_lists_allowed_verbs(self):
        with urllib.request.urlopen(self.base_url + "/status", timeout=10) as response:
            body = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertEqual(body["slots"], len(SLOT_UDIDS))
        self.assertEqual(
            body["verbs"], sorted(["relaunch", "push", "record/start", "record/stop", "privacy", "status_bar"])
        )

    def test_relaunch_terminates_then_launches_with_args(self):
        status, body = self.post("/v1/relaunch", {"slot": 1, "args": ["-UITEST", "1"]})
        self.assertEqual(status, 200, body)
        self.assertEqual(
            self.simctl_calls(),
            [
                f"simctl terminate {SLOT_UDIDS[1]} {USER_BUNDLE_ID}",
                f"simctl launch {SLOT_UDIDS[1]} {USER_BUNDLE_ID} -UITEST 1",
            ],
        )

    def test_push_writes_payload_file_and_removes_it(self):
        status, body = self.post("/v1/push", {"payload": {"aps": {"alert": "hello"}}})
        self.assertEqual(status, 200, body)
        call = self.simctl_calls()[0]
        self.assertTrue(call.startswith(f"simctl push {SLOT_UDIDS[0]} {USER_BUNDLE_ID} "), call)
        payload_path = call.split(" ")[-1]
        self.assertFalse(os.path.exists(payload_path))

    def test_privacy_grants_listed_service(self):
        status, body = self.post("/v1/privacy", {"action": "grant", "service": "photos"})
        self.assertEqual(status, 200, body)
        self.assertEqual(
            self.simctl_calls(), [f"simctl privacy {SLOT_UDIDS[0]} grant photos {USER_BUNDLE_ID}"]
        )

    def test_status_bar_override_and_clear(self):
        status, body = self.post("/v1/status_bar", {"time": "09:41", "batteryLevel": 100})
        self.assertEqual(status, 200, body)
        self.assertEqual(
            self.simctl_calls(),
            [f"simctl status_bar {SLOT_UDIDS[0]} override --time 09:41 --batteryLevel 100"],
        )
        status, body = self.post("/v1/status_bar", {"action": "clear"})
        self.assertEqual(status, 200, body)

    def test_record_start_then_stop(self):
        status, body = self.post("/v1/record/start", {})
        self.assertEqual(status, 200, body)
        recording_id = body["recordingId"]
        status, body = self.post("/v1/record/stop", {"recordingId": recording_id})
        self.assertEqual(status, 200, body)
        self.assertGreater(body["bytes"], 0)

    def test_record_start_replaces_running_recording_on_same_slot(self):
        # recordingId を受け取れなかったクライアントの録画を残さない
        _, first = self.post("/v1/record/start", {"slot": 0})
        _, second = self.post("/v1/record/start", {"slot": 0})
        self.assertNotEqual(first["recordingId"], second["recordingId"])
        status, _ = self.post("/v1/record/stop", {"recordingId": first["recordingId"]})
        self.assertEqual(status, 400)
        status, _ = self.post("/v1/record/stop", {"recordingId": second["recordingId"]})
        self.assertEqual(status, 200)

    def test_record_stop_escalates_when_sigint_is_ignored(self):
        os.environ["XCRUN_RECORD_IGNORE_SIGINT"] = "1"
        agentd_module.RECORD_STOP_SIGNALS = (
            (signal.SIGINT, 1), (signal.SIGINT, 1), (signal.SIGTERM, 2), (signal.SIGKILL, 2),
        )
        try:
            _, started = self.post("/v1/record/start", {})
            started_at = time.monotonic()
            status, body = self.post("/v1/record/stop", {"recordingId": started["recordingId"]})
        finally:
            agentd_module.RECORD_STOP_SIGNALS = ORIGINAL_STOP_SIGNALS
            del os.environ["XCRUN_RECORD_IGNORE_SIGINT"]
        # 応答を返さずクライアントをぶら下げたままにしない
        self.assertLess(time.monotonic() - started_at, 10)
        # SIGINT で止まらなかった録画は、ファイルが残っていても成功として返さない
        self.assertEqual(status, 500, body)

    def test_record_start_failure_is_not_reported_as_success(self):
        os.environ["XCRUN_RECORD_FAIL"] = "1"
        try:
            status, body = self.post("/v1/record/start", {})
        finally:
            del os.environ["XCRUN_RECORD_FAIL"]
        self.assertEqual(status, 500, body)

    # --- 許可外・不正入力が 4xx で拒否されること ------------------------
    def test_unknown_verb_is_rejected(self):
        for path in ("/v1/spawn", "/v1/openurl", "/v1/keychain", "/v1/addmedia"):
            status, _ = self.post(path, {})
            self.assertEqual(status, 404, path)
        self.assertEqual(self.simctl_calls(), [])

    def test_udid_in_body_is_rejected(self):
        status, _ = self.post("/v1/relaunch", {"udid": "ATTACKER-UDID"})
        self.assertEqual(status, 400)
        self.assertEqual(self.simctl_calls(), [])

    def test_out_of_range_slot_is_rejected(self):
        for slot in (-1, len(SLOT_UDIDS), "0", True):
            status, _ = self.post("/v1/relaunch", {"slot": slot})
            self.assertEqual(status, 400, slot)
        self.assertEqual(self.simctl_calls(), [])

    def test_bundle_id_outside_session_is_rejected(self):
        status, _ = self.post("/v1/relaunch", {"bundleId": "com.apple.Maps"})
        self.assertEqual(status, 403)
        self.assertEqual(self.simctl_calls(), [])

    def test_xctest_runner_is_not_operable(self):
        # WDA / maestro のドライバを terminate できるとセッション自体を殺せてしまう
        status, _ = self.post("/v1/relaunch", {"bundleId": "com.facebook.WebDriverAgentRunner.xctrunner"})
        self.assertEqual(status, 403)
        self.assertEqual(self.simctl_calls(), [])

    def test_invalid_launch_args_are_rejected(self):
        for args in (
            ["; rm -rf /"],
            ["--path /etc/passwd"],
            ["$(whoami)"],
            ["a" * (agentd_module.MAX_LAUNCH_ARG_LENGTH + 1)],
            ["ok"] * (agentd_module.MAX_LAUNCH_ARGS + 1),
            "not-a-list",
            [1],
        ):
            status, _ = self.post("/v1/relaunch", {"args": args})
            self.assertEqual(status, 400, args)
        self.assertEqual(self.simctl_calls(), [])

    def test_unknown_keys_are_rejected(self):
        status, _ = self.post("/v1/relaunch", {"env": {"DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib"}})
        self.assertEqual(status, 400)
        self.assertEqual(self.simctl_calls(), [])

    def test_invalid_push_payload_is_rejected(self):
        for payload in (
            "not-an-object",
            {},
            {"aps": "not-an-object"},
            {"aps": {}, "Simulator Target Bundle": "com.apple.Maps"},
            {"aps": {"a": {"b": {"c": {"d": {"e": {"f": {"g": 1}}}}}}}},
        ):
            status, _ = self.post("/v1/push", {"payload": payload})
            self.assertEqual(status, 400, payload)
        self.assertEqual(self.simctl_calls(), [])

    def test_invalid_privacy_and_status_bar_values_are_rejected(self):
        cases = [
            ("/v1/privacy", {"action": "grant", "service": "keychain"}),
            ("/v1/privacy", {"action": "spawn", "service": "photos"}),
            ("/v1/status_bar", {"time": "not-a-time"}),
            ("/v1/status_bar", {"time": "24:00"}),
            ("/v1/status_bar", {"time": "12:60"}),
            ("/v1/status_bar", {"time": "99:99"}),
            ("/v1/status_bar", {"wifiBars": 99}),
            ("/v1/status_bar", {"action": "override"}),
        ]
        for path, body in cases:
            status, _ = self.post(path, body)
            self.assertEqual(status, 400, (path, body))
        self.assertEqual(self.simctl_calls(), [])

    def test_oversized_and_malformed_bodies_are_rejected(self):
        request = urllib.request.Request(
            self.base_url + "/v1/push",
            data=b"x" * (agentd_module.MAX_BODY_BYTES + 1),
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        with caught.exception:
            self.assertEqual(caught.exception.code, 413)

        request = urllib.request.Request(self.base_url + "/v1/push", data=b"{not json", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        with caught.exception:
            self.assertEqual(caught.exception.code, 400)

    def test_get_on_unknown_path_is_rejected(self):
        request = urllib.request.Request(self.base_url + "/v1/relaunch", method="GET")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request, timeout=10)
        with caught.exception:
            self.assertEqual(caught.exception.code, 404)

    # --- 監査ログ -------------------------------------------------------
    def test_calls_are_recorded_in_audit_log(self):
        self.post("/v1/privacy", {"action": "grant", "service": "photos"})
        with open(os.path.join(self.work_dir, "agentd-audit.log"), encoding="utf-8") as f:
            entries = [json.loads(line) for line in f if line.strip()]
        self.assertTrue(any(entry.get("verb") == "privacy" and entry.get("status") == 200 for entry in entries))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
