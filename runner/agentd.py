#!/usr/bin/env python3
"""simtunnel-agentd: runner 上で simctl の一部だけを遠隔実行させる許可リスト式の HTTP 受け口。

到達経路は WDA / serve-sim と同じ（bind は 127.0.0.1、tailnet へは bridge.sh で公開）。
呼べるのは既に WDA でシミュレータを完全操作できる tailnet 内の自分のデバイスだけなので、
これで増えるのは「主体」ではなく「能力」だけになる（設計: PROJECT.md「simtunnel-agentd」）。

クライアントから受けるのは動詞 + スキーマ検証済みの引数のみで、コマンド文字列・ファイルパス・
スクリプト本文は一切受けない。対象 Simulator はサーバ側が slot から解決し、UDID は受けない。
"""
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY_BYTES = 16 * 1024
SIMCTL_TIMEOUT_SECONDS = 60

LAUNCH_ARG_PATTERN = re.compile(r"^[A-Za-z0-9_=-]+$")
MAX_LAUNCH_ARGS = 16
MAX_LAUNCH_ARG_LENGTH = 64

BUNDLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$")

# simctl privacy が受け付ける service（列挙型にして自由入力を排除する）
PRIVACY_SERVICES = (
    "all", "calendar", "contacts-limited", "contacts", "location", "location-always",
    "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri",
)
PRIVACY_ACTIONS = ("grant", "revoke", "reset")

STATUS_BAR_TIME_PATTERN = re.compile(r"^[0-9]{1,2}:[0-9]{2}$")
# status_bar override のオプション名 -> 値の検証器
STATUS_BAR_OPTIONS = {
    "time": lambda v: isinstance(v, str) and bool(STATUS_BAR_TIME_PATTERN.match(v)),
    "dataNetwork": lambda v: v in ("hide", "wifi", "3g", "4g", "lte", "lte-a", "lte+", "5g", "5g+", "5g-uwb", "5g-uc"),
    "wifiMode": lambda v: v in ("searching", "failed", "active"),
    "wifiBars": lambda v: isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 3,
    "cellularMode": lambda v: v in ("notSupported", "searching", "failed", "active"),
    "cellularBars": lambda v: isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 4,
    "batteryState": lambda v: v in ("charging", "charged", "discharging"),
    "batteryLevel": lambda v: isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 100,
}

# push payload の入れ子・要素数の上限（巨大 JSON / 深い入れ子で simctl を詰まらせないため）
MAX_PAYLOAD_DEPTH = 6
MAX_PAYLOAD_KEYS = 64


class RequestError(Exception):
    """クライアント起因のエラー。HTTP ステータスと一緒に返す"""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Agentd:
    """セッション状態（Simulator の UDID / 作業ディレクトリ）と、許可した動詞の実装をまとめたもの"""

    def __init__(self, udids, work_dir):
        if not udids:
            raise ValueError("SIMULATOR_UDIDS が空")
        self.udids = list(udids)
        self.work_dir = work_dir
        os.makedirs(self.work_dir, exist_ok=True)
        self.audit_path = os.path.join(self.work_dir, "agentd-audit.log")
        self.recordings = {}

    # --- 監査ログ -------------------------------------------------------
    # public repo では run のログ・ステップサマリを誰でも読めるため、呼び出しの記録は
    # runner ローカルのファイルだけに残す（参照: PROJECT.md「リポジトリ公開に耐える安全性」）
    def audit(self, entry):
        line = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **entry}, ensure_ascii=False)
        with open(self.audit_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    # --- 引数の検証 -----------------------------------------------------
    def udid(self, body):
        if "udid" in body:
            raise RequestError(400, "udid はクライアントから受け付けない（slot で指定する）")
        slot = body.get("slot", 0)
        if not isinstance(slot, int) or isinstance(slot, bool) or not 0 <= slot < len(self.udids):
            raise RequestError(400, f"slot は 0〜{len(self.udids) - 1} の整数")
        return self.udids[slot]

    def user_bundle_ids(self, udid):
        """Simulator に install 済みで、操作してよいアプリの bundle id。

        runner の Simulator は毎回まっさらなため、ユーザーアプリ = このセッションで install した
        アプリになる。許可リストを別ファイルで持たず Simulator の実態から引く。
        WDA / maestro のドライバも XCUITest runner (*.xctrunner) としてユーザーアプリに並ぶが、
        これを terminate できるとセッション自体を殺せてしまうため対象から外す"""
        listed = self.run_simctl(["listapps", udid])
        converted = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", "--", "-"],
            input=listed.encode("utf-8"), capture_output=True, timeout=SIMCTL_TIMEOUT_SECONDS,
        )
        if converted.returncode != 0:
            raise RequestError(500, "simctl listapps の出力を解釈できない")
        apps = json.loads(converted.stdout.decode("utf-8"))
        return {
            bundle_id for bundle_id, info in apps.items()
            if info.get("ApplicationType") == "User" and not bundle_id.endswith(".xctrunner")
        }

    def bundle_id(self, body, udid):
        allowed = self.user_bundle_ids(udid)
        requested = body.get("bundleId")
        if requested is None:
            if len(allowed) != 1:
                raise RequestError(400, f"bundleId を指定する（install 済み: {sorted(allowed)}）")
            return next(iter(allowed))
        if not isinstance(requested, str) or not BUNDLE_ID_PATTERN.match(requested):
            raise RequestError(400, "bundleId の形式が不正")
        if requested not in allowed:
            raise RequestError(403, "このセッションで install していない bundleId は操作できない")
        return requested

    @staticmethod
    def reject_unknown_keys(body, allowed_keys):
        unknown = sorted(set(body) - set(allowed_keys))
        if unknown:
            raise RequestError(400, f"未知のキー: {unknown}")

    @staticmethod
    def launch_args(body):
        args = body.get("args", [])
        if not isinstance(args, list):
            raise RequestError(400, "args は文字列の配列")
        if len(args) > MAX_LAUNCH_ARGS:
            raise RequestError(400, f"args は {MAX_LAUNCH_ARGS} 個まで")
        for arg in args:
            if not isinstance(arg, str) or len(arg) > MAX_LAUNCH_ARG_LENGTH or not LAUNCH_ARG_PATTERN.match(arg):
                raise RequestError(400, f"args は {LAUNCH_ARG_PATTERN.pattern} に一致する {MAX_LAUNCH_ARG_LENGTH} 文字以内の文字列のみ")
        return args

    @staticmethod
    def push_payload(body):
        payload = body.get("payload")
        if not isinstance(payload, dict):
            raise RequestError(400, "payload は JSON オブジェクト")
        if not isinstance(payload.get("aps"), dict):
            raise RequestError(400, "payload には aps オブジェクトが必要")
        # simctl push は payload 内の "Simulator Target Bundle" を宛先として優先するため、
        # 宛先の決定をサーバ側（許可リスト検証済みの bundleId）に一本化する
        if "Simulator Target Bundle" in payload:
            raise RequestError(400, "payload に Simulator Target Bundle は書けない（bundleId で指定する）")

        def walk(node, depth):
            if depth > MAX_PAYLOAD_DEPTH:
                raise RequestError(400, f"payload の入れ子は {MAX_PAYLOAD_DEPTH} 段まで")
            if isinstance(node, dict):
                if len(node) > MAX_PAYLOAD_KEYS:
                    raise RequestError(400, f"payload のキーは 1 階層あたり {MAX_PAYLOAD_KEYS} 個まで")
                for key, value in node.items():
                    if not isinstance(key, str):
                        raise RequestError(400, "payload のキーは文字列のみ")
                    walk(value, depth + 1)
            elif isinstance(node, list):
                if len(node) > MAX_PAYLOAD_KEYS:
                    raise RequestError(400, f"payload の配列要素は {MAX_PAYLOAD_KEYS} 個まで")
                for value in node:
                    walk(value, depth + 1)
            elif not isinstance(node, (str, int, float, bool)) and node is not None:
                raise RequestError(400, "payload に使えるのは JSON の基本型のみ")

        walk(payload, 0)
        return payload

    # --- simctl 実行 ----------------------------------------------------
    def run_simctl(self, args, allow_failure=False):
        completed = subprocess.run(
            ["xcrun", "simctl", *args], capture_output=True, timeout=SIMCTL_TIMEOUT_SECONDS,
        )
        if completed.returncode != 0 and not allow_failure:
            detail = completed.stderr.decode("utf-8", "replace").strip()[:500]
            raise RequestError(500, f"simctl {args[0]} に失敗: {detail}")
        return completed.stdout.decode("utf-8", "replace")

    # --- 許可した動詞 ---------------------------------------------------
    def verb_relaunch(self, body):
        self.reject_unknown_keys(body, ("slot", "bundleId", "args"))
        udid = self.udid(body)
        # 引数の検証を bundleId の解決より先に行う（simctl を呼ばずに弾ける入力を先に落とす）
        args = self.launch_args(body)
        bundle_id = self.bundle_id(body, udid)
        # 起動していないアプリの terminate は失敗するため、失敗を許容して launch へ進む
        self.run_simctl(["terminate", udid, bundle_id], allow_failure=True)
        self.run_simctl(["launch", udid, bundle_id, *args])
        return {"bundleId": bundle_id, "args": args}

    def verb_push(self, body):
        self.reject_unknown_keys(body, ("slot", "bundleId", "payload"))
        udid = self.udid(body)
        payload = self.push_payload(body)
        bundle_id = self.bundle_id(body, udid)
        path = os.path.join(self.work_dir, f"agentd-push-{uuid.uuid4().hex}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        try:
            self.run_simctl(["push", udid, bundle_id, path])
        finally:
            os.remove(path)
        return {"bundleId": bundle_id}

    def verb_record_start(self, body):
        self.reject_unknown_keys(body, ("slot",))
        udid = self.udid(body)
        recording_id = uuid.uuid4().hex
        path = os.path.join(self.work_dir, f"agentd-record-{recording_id}.mp4")
        process = subprocess.Popen(
            ["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.recordings[recording_id] = (process, path)
        return {"recordingId": recording_id, "path": path}

    def verb_record_stop(self, body):
        self.reject_unknown_keys(body, ("recordingId",))
        recording_id = body.get("recordingId")
        if not isinstance(recording_id, str) or recording_id not in self.recordings:
            raise RequestError(400, "recordingId が不正（record/start が返した値を渡す）")
        process, path = self.recordings.pop(recording_id)
        # recordVideo は SIGINT でファイルを閉じて正常終了する
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=SIMCTL_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            raise RequestError(500, "録画の停止がタイムアウトした")
        size = os.path.getsize(path) if os.path.exists(path) else 0
        # 動画は runner ローカルに残す。DERP 経由の帯域では取り出しに現実的な時間がかからないため、
        # 転送用のエンドポイントは持たない（参照: PROJECT.md「simtunnel-agentd」）
        return {"path": path, "bytes": size}

    def verb_privacy(self, body):
        self.reject_unknown_keys(body, ("slot", "action", "service", "bundleId"))
        udid = self.udid(body)
        action = body.get("action")
        if action not in PRIVACY_ACTIONS:
            raise RequestError(400, f"action は {list(PRIVACY_ACTIONS)} のいずれか")
        service = body.get("service")
        if service not in PRIVACY_SERVICES:
            raise RequestError(400, f"service は {list(PRIVACY_SERVICES)} のいずれか")
        bundle_id = self.bundle_id(body, udid)
        self.run_simctl(["privacy", udid, action, service, bundle_id])
        return {"action": action, "service": service, "bundleId": bundle_id}

    def verb_status_bar(self, body):
        self.reject_unknown_keys(body, ("slot", "action", *STATUS_BAR_OPTIONS))
        udid = self.udid(body)
        action = body.get("action", "override")
        if action not in ("override", "clear"):
            raise RequestError(400, "action は override か clear")
        if action == "clear":
            self.run_simctl(["status_bar", udid, "clear"])
            return {"action": "clear"}
        options = []
        for name, is_valid in STATUS_BAR_OPTIONS.items():
            if name not in body:
                continue
            value = body[name]
            if not is_valid(value):
                raise RequestError(400, f"{name} の値が不正")
            options += [f"--{name}", str(value)]
        if not options:
            raise RequestError(400, f"override には {sorted(STATUS_BAR_OPTIONS)} のいずれかが必要")
        self.run_simctl(["status_bar", udid, "override", *options])
        return {"action": "override", "options": options}

    def verbs(self):
        return {
            "relaunch": self.verb_relaunch,
            "push": self.verb_push,
            "record/start": self.verb_record_start,
            "record/stop": self.verb_record_stop,
            "privacy": self.verb_privacy,
            "status_bar": self.verb_status_bar,
        }


def make_handler(agentd):
    verbs = agentd.verbs()

    class Handler(BaseHTTPRequestHandler):
        server_version = "simtunnel-agentd"
        # 既定の実装はアクセスログを stderr に出す。public repo では run のログを誰でも読めるため、
        # 呼び出しの記録は監査ログ（runner ローカル）だけに寄せる
        def log_message(self, format, *args):
            agentd.audit({"kind": "http", "message": format % args})

        def respond(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?")[0] != "/status":
                self.respond(404, {"error": "not found"})
                return
            self.respond(200, {"ok": True, "slots": len(agentd.udids), "verbs": sorted(verbs)})

        def do_POST(self):
            path = self.path.split("?")[0]
            verb = path[len("/v1/"):] if path.startswith("/v1/") else None
            handler = verbs.get(verb)
            if handler is None:
                agentd.audit({"verb": verb, "status": 404})
                self.respond(404, {"error": "許可されていない動詞"})
                return
            try:
                body = self.read_body()
                result = handler(body)
            except RequestError as error:
                agentd.audit({"verb": verb, "status": error.status, "detail": error.message})
                self.respond(error.status, {"error": error.message})
                return
            except Exception as error:  # noqa: BLE001 - 予期しない失敗もクライアントに 500 で返す
                agentd.audit({"verb": verb, "status": 500, "detail": repr(error)})
                self.respond(500, {"error": "内部エラー"})
                return
            agentd.audit({"verb": verb, "status": 200, "detail": result})
            self.respond(200, {"ok": True, **result})

        def read_body(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise RequestError(400, "Content-Length が不正")
            if length > MAX_BODY_BYTES:
                raise RequestError(413, f"body は {MAX_BODY_BYTES} bytes まで")
            raw = self.rfile.read(length) if length > 0 else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise RequestError(400, "body が JSON として不正")
            if not isinstance(body, dict):
                raise RequestError(400, "body は JSON オブジェクト")
            return body

    return Handler


def build_server(udids, work_dir, port):
    agentd = Agentd(udids, work_dir)
    return ThreadingHTTPServer(("127.0.0.1", port), make_handler(agentd))


def main():
    udids = shlex.split(os.environ.get("SIMULATOR_UDIDS", os.environ.get("SIMULATOR_UDID", "")))
    if not udids:
        print("SIMULATOR_UDIDS / SIMULATOR_UDID が未設定", file=sys.stderr)
        return 1
    work_dir = os.environ.get("RUNNER_TEMP") or os.path.join(os.getcwd(), "tmp")
    port = int(os.environ.get("SIMTUNNEL_AGENTD_PORT", "8200"))
    server = build_server(udids, work_dir, port)
    print(f"agentd listening: http://127.0.0.1:{port} (slots: {len(udids)})")
    sys.stdout.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
