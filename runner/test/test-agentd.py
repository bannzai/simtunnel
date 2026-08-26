#!/usr/bin/env python3
"""agentd の許可リスト（許可した動詞だけが通り、それ以外は 4xx で拒否される）を検証する。

simctl は PATH に置いたスタブ xcrun に差し替えるため、Simulator が無くても実行できる。
実行: python3 runner/test/test-agentd.py
"""
import http.client
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
ORIGINAL_READY_TIMEOUT_SECONDS = agentd_module.RECORD_READY_TIMEOUT_SECONDS
ORIGINAL_MAX_FINISHED_RECORDINGS = agentd_module.MAX_FINISHED_RECORDINGS

# 実 simctl の listapps と同じ OpenStep plist を返し、呼ばれた引数を argv ログへ残すスタブ
XCRUN_STUB = r"""#!/bin/bash
printf '%s\n' "$*" >> "$XCRUN_ARGV_LOG"
if [ "${4:-}" = "recordVideo" ]; then
  # 実際の recordVideo は SIGINT を受けるまで動き続け、出力ファイルを書く
  [ "${XCRUN_RECORD_FAIL:-0}" = "1" ] && exit 1
  # 実際の simctl は録画開始時に "Recording started" を出し、出力ファイルは終了時に書く
  [ "${XCRUN_RECORD_NEVER_READY:-0}" != "1" ] && echo "Recording started"
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
        # 停止しないまま終わったテストの録画スタブが残らないよう回収する
        cls.server.agentd.stop_all_recordings()
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

    def test_finished_recordings_beyond_limit_are_deleted(self):
        # 停止済みの録画を際限なく残すと、10 分以内の録画でも本数で runner のディスクを使い切る
        agentd_module.MAX_FINISHED_RECORDINGS = 2
        paths = []
        try:
            for _ in range(3):
                _, started = self.post("/v1/record/start", {})
                status, stopped = self.post("/v1/record/stop", {"recordingId": started["recordingId"]})
                self.assertEqual(status, 200, stopped)
                paths.append(stopped["path"])
        finally:
            agentd_module.MAX_FINISHED_RECORDINGS = ORIGINAL_MAX_FINISHED_RECORDINGS
        self.assertFalse(os.path.exists(paths[0]))
        self.assertFalse(os.path.exists(paths[0] + ".log"))
        self.assertTrue(all(os.path.exists(path) for path in paths[1:]))

    def test_failed_recording_is_not_retained(self):
        # 開始に失敗した録画を保持枠に数えると、失敗の繰り返しだけで有効な録画が押し出される
        _, ok_recording = self.post("/v1/record/start", {})
        _, ok_stopped = self.post("/v1/record/stop", {"recordingId": ok_recording["recordingId"]})
        retained_before = len(self.server.agentd.finished_recordings)
        os.environ["XCRUN_RECORD_FAIL"] = "1"
        try:
            status, _ = self.post("/v1/record/start", {})
        finally:
            del os.environ["XCRUN_RECORD_FAIL"]
        self.assertEqual(status, 500)
        self.assertEqual(len(self.server.agentd.finished_recordings), retained_before)
        self.assertTrue(os.path.exists(ok_stopped["path"]))

    def test_record_start_replaces_running_recording_on_same_slot(self):
        # recordingId を受け取れなかったクライアントの録画を残さない
        _, first = self.post("/v1/record/start", {"slot": 0})
        _, second = self.post("/v1/record/start", {"slot": 0})
        self.assertNotEqual(first["recordingId"], second["recordingId"])
        status, _ = self.post("/v1/record/stop", {"recordingId": first["recordingId"]})
        self.assertEqual(status, 400)
        status, _ = self.post("/v1/record/stop", {"recordingId": second["recordingId"]})
        self.assertEqual(status, 200)

    def test_record_start_waits_for_slow_stop_on_same_slot(self):
        """停止待ちの最中に同じ slot の start が走ると simctl が Resource busy で失敗するため、
        stop の完了まで start を待たせる"""
        os.environ["XCRUN_RECORD_IGNORE_SIGINT"] = "1"
        agentd_module.RECORD_STOP_SIGNALS = ((signal.SIGINT, 2), (signal.SIGKILL, 2))
        try:
            _, first = self.post("/v1/record/start", {"slot": 0})
            os.environ["XCRUN_RECORD_IGNORE_SIGINT"] = "0"
            stop_finished_at = []

            def stop():
                self.post("/v1/record/stop", {"recordingId": first["recordingId"]})
                stop_finished_at.append(time.monotonic())

            stopper = threading.Thread(target=stop)
            stopper.start()
            time.sleep(0.3)  # stop が停止待ちに入ってから start を投げる
            self.post("/v1/record/start", {"slot": 0})
            start_returned_at = time.monotonic()
            stopper.join(timeout=15)
        finally:
            agentd_module.RECORD_STOP_SIGNALS = ORIGINAL_STOP_SIGNALS
            os.environ.pop("XCRUN_RECORD_IGNORE_SIGINT", None)
        self.assertTrue(stop_finished_at, "stop が完了しなかった")
        self.assertLess(stop_finished_at[0], start_returned_at)

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

    def test_record_start_fails_when_recording_never_starts(self):
        # simctl のプロセスは生きているが録画が始まらない場合を成功として返さない
        os.environ["XCRUN_RECORD_NEVER_READY"] = "1"
        agentd_module.RECORD_READY_TIMEOUT_SECONDS = 2
        try:
            status, body = self.post("/v1/record/start", {})
        finally:
            agentd_module.RECORD_READY_TIMEOUT_SECONDS = ORIGINAL_READY_TIMEOUT_SECONDS
            del os.environ["XCRUN_RECORD_NEVER_READY"]
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

    def test_trailing_newline_in_validated_values_is_rejected(self):
        # 末尾改行を許すと、想定と違う argv / 表示状態のまま 200 を返してしまう
        status, _ = self.post("/v1/status_bar", {"time": "09:41\n"})
        self.assertEqual(status, 400)
        status, _ = self.post("/v1/relaunch", {"bundleId": "com.example.sample\n"})
        self.assertEqual(status, 400)
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
            ["-UITEST\n"],  # Python の $ は末尾改行の直前にも一致するため fullmatch で弾く
            ["\n"],
            ["a" * (agentd_module.MAX_LAUNCH_ARG_LENGTH + 1)],
            ["ok"] * (agentd_module.MAX_LAUNCH_ARGS + 1),
            "not-a-list",
            [1],
        ):
            status, _ = self.post("/v1/relaunch", {"args": args})
            self.assertEqual(status, 400, args)
        self.assertEqual(self.simctl_calls(), [])

    def test_nan_and_infinity_in_body_are_rejected(self):
        # Python の json.loads は NaN / Infinity を受け付けるが JSON の仕様外で、simctl に渡す payload も壊れる
        for raw in (b'{"payload": {"aps": {"badge": NaN}}}', b'{"payload": {"aps": {"badge": Infinity}}}', b'{"slot": -Infinity}'):
            request = urllib.request.Request(
                self.base_url + "/v1/push", data=raw, headers={"Content-Type": "application/json"}, method="POST",
            )
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(request, timeout=10)
            self.assertEqual(raised.exception.code, 400, raw)
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
            # 1e400 は json.loads で float('inf') になり、dump すると仕様外の JSON になる
            {"aps": {"badge": 1e400}},
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

    def test_missing_or_invalid_content_length_is_rejected(self):
        # 本文を読めない形式のまま既定値で動詞を実行しない
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        connection.putrequest("POST", "/v1/relaunch", skip_accept_encoding=True)
        connection.endheaders()  # Content-Length も Transfer-Encoding も無い
        self.assertEqual(connection.getresponse().status, 411)
        connection.close()

        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        connection.putrequest("POST", "/v1/relaunch", skip_accept_encoding=True)
        connection.putheader("Content-Length", "-1")
        connection.endheaders()
        self.assertEqual(connection.getresponse().status, 400)
        connection.close()
        self.assertEqual(self.simctl_calls(), [])

    def test_chunked_body_is_rejected(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        connection.putrequest("POST", "/v1/relaunch", skip_accept_encoding=True)
        connection.putheader("Transfer-Encoding", "chunked")
        connection.endheaders()
        connection.send(b"2\r\n{}\r\n0\r\n\r\n")
        self.assertEqual(connection.getresponse().status, 400)
        connection.close()
        self.assertEqual(self.simctl_calls(), [])

    def test_status_bar_clear_with_override_options_is_rejected(self):
        # 「設定できたつもりで実際は全解除」になる指定を成功にしない
        status, _ = self.post("/v1/status_bar", {"action": "clear", "batteryLevel": 100})
        self.assertEqual(status, 400)
        self.assertEqual(self.simctl_calls(), [])

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
