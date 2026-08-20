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
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY_BYTES = 16 * 1024
SIMCTL_TIMEOUT_SECONDS = 60
# recordingId を受け取れなかったクライアントは録画を止められない。ジョブが終わるまで
# 書き続けて runner のディスクを圧迫しないよう、サーバ側で必ず打ち切る
MAX_RECORDING_SECONDS = 600
# 録画を止める時に送るシグナルと、それぞれの待ち時間（秒）。
# recordVideo をきれいに終わらせられるのは SIGINT だけで、SIGTERM / SIGKILL で落とすと
# Simulator のホスト録画が Resource busy のまま残り、そのセッションでは以降の record/start が
# 全て失敗する（実測 2026-08-17: SIGTERM でも SIGKILL でも同じ状態になった）。
# そのため SIGINT を間を置いて繰り返し、SIGKILL は「放置するとディスクを食い潰す」場合の最後の手段にする
RECORD_STOP_SIGNALS = (
    (signal.SIGINT, 3), (signal.SIGINT, 5), (signal.SIGINT, 10), (signal.SIGINT, 15), (signal.SIGKILL, 5),
)
# 停止済みの録画を runner 上に残す本数。録画を転送するエンドポイントは持たないため、残す意味があるのは
# 同じセッション中に runner へ入って確認できる直近の数本だけで、それ以上は 10 分 × 録画本数で
# ディスクを食い潰す方が問題になる（1 本の上限は MAX_RECORDING_SECONDS、総量はこの本数で抑える）
MAX_FINISHED_RECORDINGS = 5
# 録画が実際に始まった（= simctl が SIGINT を受け付ける状態になった）ことを確認するまでの上限。
# Popen 直後は simctl がまだハンドラを張っておらず SIGINT を取りこぼす（実測 2026-08-17）ため、
# simctl が下記の行を出すまで待ってから start の応答を返す。
# 出力ファイルは録画の終了時にまとめて書かれるので開始の判定には使えない（実測 2026-08-17）
RECORD_READY_TIMEOUT_SECONDS = 20
RECORD_READY_LOG_LINE = "Recording started"

# 許可リストは fullmatch で使う（Python の $ は末尾改行の直前にも一致するため、
# "-UITEST\n" のような値が ^...$ の match をすり抜ける）
LAUNCH_ARG_PATTERN = re.compile(r"[A-Za-z0-9_=-]+")
MAX_LAUNCH_ARGS = 16
MAX_LAUNCH_ARG_LENGTH = 64

BUNDLE_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,127}")

# simctl privacy が受け付ける service（列挙型にして自由入力を排除する）
PRIVACY_SERVICES = (
    "all", "calendar", "contacts-limited", "contacts", "location", "location-always",
    "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri",
)
PRIVACY_ACTIONS = ("grant", "revoke", "reset")

STATUS_BAR_TIME_PATTERN = re.compile(r"([01]?[0-9]|2[0-3]):[0-5][0-9]")
# status_bar override のオプション名 -> 値の検証器
STATUS_BAR_OPTIONS = {
    "time": lambda v: isinstance(v, str) and bool(STATUS_BAR_TIME_PATTERN.fullmatch(v)),
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


def reject_json_constant(name):
    """json.loads の parse_constant。NaN / Infinity / -Infinity を受け付けず ValueError にする"""
    raise ValueError(f"JSON の仕様外の定数: {name}")


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
        # recordingId -> 実行中の録画。watchdog スレッドからも触るためロックで守る
        self.recordings = {}
        # 停止済みの録画の (動画パス, ログパス) を古い順に持ち、MAX_FINISHED_RECORDINGS を超えた分を消す
        self.finished_recordings = []
        self.recordings_lock = threading.Lock()
        # slot ごとの録画の停止・開始を直列化する（ThreadingHTTPServer はリクエストを並行処理するため、
        # 停止待ちの最中に start が割り込むと simctl が Host recording is already in progress で失敗する）。
        # start が保持したまま stop_recording を呼ぶため再入可能にする
        self.slot_locks = {slot: threading.RLock() for slot in range(len(self.udids))}

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
        if not isinstance(requested, str) or not BUNDLE_ID_PATTERN.fullmatch(requested):
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
            if not isinstance(arg, str) or len(arg) > MAX_LAUNCH_ARG_LENGTH or not LAUNCH_ARG_PATTERN.fullmatch(arg):
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

    def stop_recording(self, recording_id):
        """録画プロセスを止めて (出力パス, バイト数, エラー内容) を返す。停止済みなら None。

        プロセスが実際に終了するまで slot のロックを保持し、停止待ちの最中に
        同じ slot の start が走らないようにする"""
        with self.recordings_lock:
            slot = self.recordings[recording_id]["slot"] if recording_id in self.recordings else None
        if slot is None:
            return None
        with self.slot_locks[slot]:
            # ロック待ちの間に別のスレッドが停止し終えている場合がある
            with self.recordings_lock:
                recording = self.recordings.pop(recording_id, None)
            if recording is None:
                return None
            return self.finish_recording(recording)

    def finish_recording(self, recording):
        """停止対象から外した録画を実際に終了させ、(出力パス, バイト数, エラー内容) を返す"""
        recording["watchdog"].cancel()
        process = recording["process"]
        stopped_by = self.terminate_recording(process)
        size = os.path.getsize(recording["path"]) if os.path.exists(recording["path"]) else 0
        if stopped_by != signal.SIGINT:
            error = f"SIGINT で録画を停止できず {getattr(stopped_by, 'name', stopped_by)} まで進めた（動画は壊れている可能性がある）"
        elif size == 0:
            error = f"録画ファイルが空（simctl 終了コード {process.returncode}）: {self.tail_log(recording['log_path'])}"
        else:
            error = None
        self.retain_finished_recording(recording["path"], recording["log_path"])
        return recording["path"], size, error

    def retain_finished_recording(self, path, log_path):
        """停止済みの録画を保持リストに加え、上限を超えた古い録画を runner から消す"""
        with self.recordings_lock:
            self.finished_recordings.append((path, log_path))
            expired = self.finished_recordings[:-MAX_FINISHED_RECORDINGS]
            del self.finished_recordings[:-MAX_FINISHED_RECORDINGS]
        for expired_path, expired_log_path in expired:
            for file_path in (expired_path, expired_log_path):
                try:
                    os.remove(file_path)
                except FileNotFoundError:
                    pass

    @staticmethod
    def terminate_recording(process):
        """録画プロセスを段階的に止め、実際に効いたシグナルを返す（既に終了していれば SIGINT 扱い）"""
        if process.poll() is not None:
            return signal.SIGINT
        for stop_signal, wait_seconds in RECORD_STOP_SIGNALS:
            process.send_signal(stop_signal)
            try:
                process.wait(timeout=wait_seconds)
                return stop_signal
            except subprocess.TimeoutExpired:
                continue
        return None

    @staticmethod
    def tail_log(path):
        if not os.path.exists(path):
            return ""
        with open(path, "rb") as f:
            return f.read()[-500:].decode("utf-8", "replace").strip()

    def verb_record_start(self, body):
        self.reject_unknown_keys(body, ("slot",))
        udid = self.udid(body)
        slot = body.get("slot", 0)
        recording_id = uuid.uuid4().hex
        path = os.path.join(self.work_dir, f"agentd-record-{recording_id}.mp4")
        log_path = path + ".log"
        with self.slot_locks[slot]:
            # 1 slot につき 1 本に限る。recordingId を受け取れなかったクライアントが止められない
            # 録画を残しても、次の start で回収できる
            with self.recordings_lock:
                running_ids = [running_id for running_id, recording in self.recordings.items() if recording["slot"] == slot]
            for running_id in running_ids:
                self.stop_recording(running_id)

            with open(log_path, "wb") as log:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path],
                    stdout=log, stderr=log,
                )
            watchdog = threading.Timer(MAX_RECORDING_SECONDS, self.stop_recording, args=(recording_id,))
            watchdog.daemon = True
            with self.recordings_lock:
                self.recordings[recording_id] = {
                    "process": process, "path": path, "slot": slot, "log_path": log_path, "watchdog": watchdog,
                }
            watchdog.start()

            # Popen はコマンドの起動に成功しただけで返る。録画が実際に始まる（simctl が
            # RECORD_READY_LOG_LINE を出す）までロック内で待ち、simctl の失敗を成功として返さない。ここで待つことは
            # 「SIGINT を受け付ける状態になってから応答する」ことでもあり、直後の stop の取りこぼしも防ぐ
            deadline = time.monotonic() + RECORD_READY_TIMEOUT_SECONDS
            while True:
                if process.poll() is not None:
                    self.stop_recording(recording_id)
                    raise RequestError(500, f"録画を開始できなかった: {self.tail_log(log_path)}")
                if RECORD_READY_LOG_LINE in self.tail_log(log_path):
                    break
                if time.monotonic() >= deadline:
                    self.stop_recording(recording_id)
                    raise RequestError(500, f"{RECORD_READY_TIMEOUT_SECONDS} 秒待っても録画が始まらなかった: {self.tail_log(log_path)}")
                time.sleep(0.5)
        return {"recordingId": recording_id, "path": path, "maxSeconds": MAX_RECORDING_SECONDS}

    def verb_record_stop(self, body):
        self.reject_unknown_keys(body, ("recordingId",))
        recording_id = body.get("recordingId")
        if not isinstance(recording_id, str):
            raise RequestError(400, "recordingId が不正（record/start が返した値を渡す）")
        stopped = self.stop_recording(recording_id)
        if stopped is None:
            raise RequestError(400, "この recordingId の録画は実行中ではない（停止済み・上限時間で自動停止・不正な値）")
        path, size, error = stopped
        if error:
            raise RequestError(500, error)
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
            # clear は全 override を解除する。同じリクエストに override のオプションがあると
            # 「設定できたつもりで実際は解除された」状態になるため、矛盾した指定を成功にしない
            self.reject_unknown_keys(body, ("slot", "action"))
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

    def stop_all_recordings(self):
        """実行中の録画をすべて止める（プロセスを残さないための後片付け）"""
        with self.recordings_lock:
            recording_ids = list(self.recordings)
        for recording_id in recording_ids:
            self.stop_recording(recording_id)

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
            # chunked は実装しない。本文があるのに読まずに既定値で動詞を実行すると、
            # 意図と違う slot / 引数で Simulator を操作してしまうため、受け取れない形式は拒否する
            if self.headers.get("Transfer-Encoding"):
                raise RequestError(400, "Transfer-Encoding は非対応（Content-Length を付ける）")
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                raise RequestError(411, "Content-Length が必要（引数なしの場合も {} を送る）")
            try:
                length = int(raw_length)
            except ValueError as error:
                raise RequestError(400, "Content-Length が不正") from error
            if length < 0:
                raise RequestError(400, "Content-Length が不正")
            if length > MAX_BODY_BYTES:
                raise RequestError(413, f"body は {MAX_BODY_BYTES} bytes まで")
            raw = self.rfile.read(length) if length > 0 else b"{}"
            try:
                # Python の json は NaN / Infinity を既定で受け付けるが JSON の仕様外で、
                # そのまま書き出すと simctl に渡す payload も不正な JSON になるため拒否する
                body = json.loads(raw.decode("utf-8"), parse_constant=reject_json_constant)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
                raise RequestError(400, "body が JSON として不正") from error
            if not isinstance(body, dict):
                raise RequestError(400, "body は JSON オブジェクト")
            return body

    return Handler


def build_server(udids, work_dir, port):
    agentd = Agentd(udids, work_dir)
    server = ThreadingHTTPServer(("127.0.0.1", port), make_handler(agentd))
    # 実行中の録画を後片付けできるよう、セッション状態への参照を server から辿れるようにする
    server.agentd = agentd
    return server


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
