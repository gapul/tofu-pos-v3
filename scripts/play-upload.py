"""Upload a signed AAB to a Google Play testing track with a service account (no extra deps)."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE = 'dev.gapul.tofupos.v3'
API = f'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}'
UPLOAD = f'https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}'


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def access_token():
    account = json.loads(os.environ['PLAY_SERVICE_ACCOUNT_JSON'])
    key = Path(os.environ['RUNNER_TEMP']) / 'play-key.pem'
    key.write_text(account['private_key'])
    key.chmod(0o600)
    now = int(time.time())
    header = b64(json.dumps({'alg': 'RS256', 'typ': 'JWT'}).encode())
    claims = b64(json.dumps({'iss': account['client_email'], 'scope': 'https://www.googleapis.com/auth/androidpublisher',
                             'aud': account['token_uri'], 'iat': now, 'exp': now + 600}).encode())
    message = (header + '.' + claims).encode()
    signature = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=message)
    body = urllib.parse.urlencode({'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                                   'assertion': message.decode() + '.' + b64(signature)}).encode()
    with urllib.request.urlopen(urllib.request.Request(account['token_uri'], data=body), timeout=30) as r:
        return json.load(r)['access_token']


def call(token, method, url, data=None, content_type='application/json'):
    body = json.dumps(data).encode() if isinstance(data, dict) else data
    request = urllib.request.Request(url, data=body, method=method,
                                     headers={'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
    try:
        with urllib.request.urlopen(request, timeout=600) as r:
            text = r.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        raise SystemExit(f'{method} {url.split("?")[0]} -> {error.code}: {error.read()[:1000].decode(errors="replace")}')


def main():
    aab, track = Path(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else os.environ.get('PLAY_TRACK', 'alpha')
    token = access_token()
    edit = call(token, 'POST', f'{API}/edits', {})['id']
    bundle = call(token, 'POST', f'{UPLOAD}/edits/{edit}/bundles?uploadType=media', aab.read_bytes(), 'application/octet-stream')
    code = bundle['versionCode']
    print('uploaded versionCode', code)
    call(token, 'PUT', f'{API}/edits/{edit}/tracks/{track}',
         {'track': track, 'releases': [{'versionCodes': [str(code)], 'status': 'completed'}]})
    call(token, 'POST', f'{API}/edits/{edit}:commit')
    print(f'committed versionCode {code} to track {track}')


if __name__ == '__main__':
    main()
