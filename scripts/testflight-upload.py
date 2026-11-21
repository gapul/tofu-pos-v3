"""Upload a signed IPA and distribute the processed build to an internal group."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def token():
    key = Path(os.environ['RUNNER_TEMP']) / 'asc-key.p8'
    key.write_text(os.environ['ASC_PRIVATE_KEY'])
    key.chmod(0o600)
    now = int(time.time())
    header = b64(json.dumps({'alg': 'ES256', 'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'}).encode())
    payload = b64(json.dumps({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now,
                             'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    message = (header + '.' + payload).encode()
    der = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=message)
    # P-256 ECDSA DER sequence -> JOSE fixed-width r || s.
    offset = 2
    parts = []
    for _ in range(2):
        if der[offset] != 2:
            raise ValueError('Invalid ECDSA signature')
        length = der[offset + 1]
        parts.append(der[offset + 2:offset + 2 + length].lstrip(b'\0').rjust(32, b'\0'))
        offset += 2 + length
    return message.decode() + '.' + b64(b''.join(parts))


def api(method, path, body=None):
    request = urllib.request.Request(
        'https://api.appstoreconnect.apple.com/v1/' + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method, headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        # API errors contain resource validation details, never signed upload URLs.
        raise RuntimeError(f'{method} {path}: HTTP {error.code}: {error.read().decode()[:1500]}') from None


def main():
    app = os.environ['ASC_APP_ID']
    group = os.environ['ASC_BETA_GROUP_ID']
    if not group:
        raise ValueError('ASC_BETA_GROUP_ID is required')
    group_info = api('GET', 'betaGroups/' + group)['data']['attributes']
    ipa = Path(sys.argv[1])
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(names) != 1:
            raise ValueError('Expected exactly one app Info.plist')
        info = plistlib.loads(archive.read(names[0]))
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    data = ipa.read_bytes()
    upload = api('POST', 'buildUploads', {'data': {'type': 'buildUploads', 'attributes': {
        'cfBundleShortVersionString': version, 'cfBundleVersion': build, 'platform': 'IOS'},
        'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']
    file = api('POST', 'buildUploadFiles', {'data': {'type': 'buildUploadFiles', 'attributes': {
        'assetType': 'ASSET', 'fileName': ipa.name, 'fileSize': len(data), 'uti': 'com.apple.ipa'},
        'relationships': {'buildUpload': {'data': {'type': 'buildUploads', 'id': upload['id']}}}}})['data']
    print(f'Uploading {version} ({build})', flush=True)
    for operation in file['attributes']['uploadOperations']:
        request = urllib.request.Request(operation['url'], method=operation['method'],
            data=data[operation['offset']:operation['offset'] + operation['length']],
            headers={h['name']: h['value'] for h in operation.get('requestHeaders', [])})
        with urllib.request.urlopen(request, timeout=300) as response:
            response.read()
    api('PATCH', 'buildUploadFiles/' + file['id'], {'data': {'type': 'buildUploadFiles', 'id': file['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksums': {'file': {
            'hash': hashlib.md5(data).hexdigest(), 'algorithm': 'MD5'}}}}})
    deadline = time.monotonic() + 1200
    query = urllib.parse.urlencode({'filter[app]': app, 'filter[version]': build})
    while time.monotonic() < deadline:
        uploads = api('GET', 'buildUploads/' + upload['id'])['data']['attributes']
        if uploads.get('state') == 'FAILED':
            raise RuntimeError('Apple rejected the build upload')
        builds = api('GET', 'builds?' + query)['data']
        for entry in builds:
            state = entry['attributes']['processingState']
            print(f'Apple processing: {state}', flush=True)
            if state in ('FAILED', 'INVALID'):
                raise RuntimeError('Apple rejected the build')
            if state == 'VALID':
                # Automatic internal groups already receive every processed build.
                if not group_info.get('hasAccessToAllBuilds'):
                    api('POST', f'betaGroups/{group}/relationships/builds', {'data': [{'type': 'builds', 'id': entry['id']}]})
                print(f'TestFlight distribution complete: {version} ({build})', flush=True)
                return
        time.sleep(20)
    raise TimeoutError('Apple processing exceeded 20 minutes; inspect App Store Connect')


if __name__ == '__main__':
    main()
