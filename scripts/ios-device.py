#!/usr/bin/env python3
"""Targeted iPhone deployment/smoke checks; never uninstall or clear app data.

Run on the USB host directly, or through SSH over Tailscale. --host optionally
uses a previously paired Wi-Fi lockdown endpoint (must be reachable on 62078).
"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import zipfile
import plistlib

ROOT = Path(__file__).resolve().parent.parent
UDID = "00008140-00154CE21468401C"
BUNDLE = "dev.gapul.tofupos.v3"
PACKAGE = "pymobiledevice3==11.61.0"
DB_PATH = "Library/Application Support/tofu-pos.sqlite"
QUERIES = {
    "products": "SELECT id,name,price FROM products ORDER BY id",
    "orders": "SELECT id,created_at,total,received,change_yen,cancelled_at,cancellation_reason FROM orders ORDER BY id",
    "lines": "SELECT * FROM order_lines ORDER BY order_id,line_no",
}


def verify_snapshots(before, after):
    if before["business"] != after["business"]:
        raise RuntimeError("Business data differ; snapshots retained for diagnosis")
    if before["version"] == after["version"]:
        if before["sync"] != after["sync"]:
            raise RuntimeError("Sync/restore state differ; snapshots retained for diagnosis")
    elif before["version"] == 1 and after["version"] == 2:
        expected = [(row[0], 2 if row[5] is not None else 1, 0, None) for row in before["business"]["orders"]]
        if after["sync"]["orders"] != expected or after["sync"]["metadata"]:
            raise RuntimeError("Unexpected version-1 migration state")
    else:
        raise RuntimeError("Unsupported database migration during deployment")


def run(command, timeout=90):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip()[-3000:])
    return result.stdout


class Device:
    def __init__(self, host, output):
        uvx = shutil.which("uvx") or str(Path.home() / ".local/state/nix/profile/bin/uvx")
        self.prefix = [uvx, "--from", PACKAGE, "pymobiledevice3"]
        self.options = ["--udid", UDID]
        if host:
            with socket.create_connection((host, 62078), timeout=3):
                pass
            self.options += ["--mobdev2-host", host]
        self.output = output
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)

    def command(self, group, arguments=(), developer=False, timeout=90):
        return run(self.prefix + group + self.options + (["--userspace"] if developer else []) + list(arguments), timeout)

    def verify(self):
        info = json.loads(self.command(["lockdown", "info"]))
        if info.get("UniqueDeviceID") != UDID:
            raise RuntimeError("Unexpected iPhone; refusing to operate")
        return {key: info.get(key) for key in ("DeviceName", "ProductType", "ProductVersion", "UniqueDeviceID")}

    def app(self):
        return json.loads(self.command(["apps", "query"], [BUNDLE])).get(BUNDLE)

    def snapshot(self, name):
        path = self.output / (name + ".sqlite")
        self.command(["apps", "pull"], [BUNDLE, DB_PATH, str(path)])
        with sqlite3.connect(path) as db:
            rows = {name: db.execute(query).fetchall() for name, query in QUERIES.items()}
            version = db.execute("PRAGMA user_version").fetchone()[0]
            sync = None if version < 2 else {
                "orders": db.execute("SELECT id,revision,synced_revision,sync_error FROM orders ORDER BY id").fetchall(),
                "metadata": db.execute("SELECT key,value FROM sync_metadata ORDER BY key").fetchall(),
            }
        return {"business": rows, "version": version, "sync": sync}

    def launch(self):
        # No forced termination of a cashier process or input in progress.
        result = self.command(["developer", "core-device", "launch-application"], ["--no-kill-existing", BUNDLE], developer=True)
        (self.output / "launch.json").write_text(result)
        return result

    def screenshot(self):
        path = self.output / "screen.png"
        self.command(["developer", "dvt", "screenshot"], [str(path)], developer=True)
        if path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("Invalid screenshot")
        return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="Previously paired iPhone Wi-Fi/Tailscale IP, not an SSH host")
    parser.add_argument("--output", type=Path)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("status", "wireless", "smoke", "screenshot"):
        sub.add_parser(name)
    install = sub.add_parser("install")
    install.add_argument("ipa", type=Path)
    logs = sub.add_parser("logs")
    logs.add_argument("--seconds", type=int, default=15)
    args = parser.parse_args()
    output = args.output or ROOT / "artifacts" / "ios-device" / datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime("%Y%m%d-%H%M%S")
    lock_path = ROOT / "artifacts" / ".ios-device.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = lock_path.open("a")
    with lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another iPhone operation is running; retry after it finishes")
        device = Device(args.host, output)
        info = device.verify()
        print(json.dumps(info, ensure_ascii=False))
        if args.action == "status":
            app = device.app()
            print(json.dumps({key: app.get(key) for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")} if app else {"installed": False}))
        elif args.action == "wireless":
            if args.host:
                raise RuntimeError("Enable wireless initially over USB")
            device.command(["lockdown", "wifi-connections"], ["on"])
            # The pairing handshake can contain device secrets: never print it.
            private = output / "remotepairing-private.log"
            private.write_text(device.command(["lockdown", "remotepairing"], ["--pair"]))
            private.chmod(0o600)
            print(device.command(["lockdown", "wifi-connections"]).strip())
        elif args.action == "install":
            ipa = args.ipa.resolve()
            with zipfile.ZipFile(ipa) as archive:
                candidates = [p for p in archive.namelist() if p.startswith("Payload/") and p.count("/") == 2 and p.endswith("/Info.plist")]
                if len(candidates) != 1:
                    raise RuntimeError("Expected a single application IPA")
                manifest = plistlib.loads(archive.read(candidates[0]))
            if manifest.get("CFBundleIdentifier") != BUNDLE:
                raise RuntimeError("Wrong IPA bundle identifier")
            existing = device.app()
            before = device.snapshot("before") if existing else None
            (output / "install.log").write_text(device.command(["apps", "install"], [str(ipa)], timeout=180))
            installed = device.app()
            if not installed or installed.get("CFBundleVersion") != manifest["CFBundleVersion"] or installed.get("CFBundleShortVersionString") != manifest["CFBundleShortVersionString"]:
                raise RuntimeError("Installed version does not match IPA")
            device.launch()
            if before is not None:
                verify_snapshots(before, device.snapshot("after"))
            print("Installed", manifest["CFBundleShortVersionString"], manifest["CFBundleVersion"], "— existing data verified" if before is not None else "")
        elif args.action == "smoke":
            before = device.snapshot("before")
            device.launch()
            pid = device.command(["developer", "dvt", "process-id-for-bundle-id"], [BUNDLE], developer=True).strip()
            if not pid.isdigit() or int(pid) <= 0:
                raise RuntimeError("App is not running")
            screenshot = device.screenshot()
            verify_snapshots(before, device.snapshot("after"))
            (output / "result.json").write_text(json.dumps({"pid": int(pid), "business_data_preserved": True, "screenshot": str(screenshot)}))
            print("PASS: app running, screenshot captured, business data unchanged;", screenshot)
        elif args.action == "screenshot":
            print(device.screenshot())
        elif args.action == "logs":
            if not 1 <= args.seconds <= 60:
                raise RuntimeError("Log capture duration must be 1..60 seconds")
            path = output / "TofuPOS.log"
            with path.open("w") as stream:
                process = subprocess.Popen(device.prefix + ["syslog", "live"] + device.options + ["--process-name", "TofuPOS"], stdout=stream, stderr=subprocess.STDOUT)
                try:
                    process.wait(timeout=args.seconds)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                else:
                    raise RuntimeError("Log stream ended before the requested duration; see " + str(path))
            print("Log captured:", path)
        print("Artifacts:", output)

if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, sqlite3.Error, zipfile.BadZipFile) as error:
        print("iPhone operation failed:", error, file=sys.stderr)
        raise SystemExit(1)
