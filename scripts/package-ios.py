"""Sign an Xcode-built app with an existing development identity and profile.

Usage: python3 scripts/package-ios.py APP PROFILE IDENTITY_SHA1 OUTPUT_IPA
The app must have no extensions. Run on macOS with an unlocked signing keychain.
"""
import datetime
import fnmatch
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile


def package(app, profile, identity, output):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString", "CFBundleExecutable"):
        if not info.get(key):
            raise ValueError(f"Missing app metadata: {key}")
    if list(app.rglob("*.appex")):
        raise ValueError("App extensions require separate provisioning")
    data = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile)]))
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in data["DeveloperCertificates"]}
    if identity.upper() not in allowed:
        raise ValueError("Signing certificate is not included in the provisioning profile")
    if data["ExpirationDate"].replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("Provisioning profile has expired")
    prefix = data["ApplicationIdentifierPrefix"][0]
    app_id = prefix + "." + info["CFBundleIdentifier"]
    entitlements = data["Entitlements"].copy()
    if not fnmatch.fnmatchcase(app_id, entitlements["application-identifier"]):
        raise ValueError("Provisioning profile does not cover the bundle identifier")
    entitlements["application-identifier"] = app_id
    if "keychain-access-groups" in entitlements:
        entitlements["keychain-access-groups"] = [app_id]
    shutil.copy2(profile, app / "embedded.mobileprovision")
    with tempfile.TemporaryDirectory(prefix="tofu-sign-") as temporary:
        entitlements_file = pathlib.Path(temporary) / "entitlements.plist"
        entitlements_file.write_bytes(plistlib.dumps(entitlements))
        for library in app.rglob("*.dylib"):
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", identity, "--entitlements", str(entitlements_file), "--generate-entitlement-der", "--timestamp=none", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in app.rglob("*"):
            if file.is_file():
                archive.write(file, "Payload/" + app.name + "/" + file.relative_to(app).as_posix())
    print(f"Verified IPA: {output} ({output.stat().st_size} bytes), version {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    package(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]))
