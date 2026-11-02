"""Validate the public ESPHome template using disposable, synthetic inputs."""
import base64
import json
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='caz-esphome-check-') as directory:
    project = Path(directory)
    shutil.copyfile(ROOT / 'esphome' / 'bluetooth-proxy.yaml', project / 'bluetooth-proxy.yaml')
    # JSON is valid YAML. These values describe no deployed device or network.
    (project / 'secrets.yaml').write_text(json.dumps({
        'node_name': 'example-proxy',
        'wifi_ssid': 'example-network',
        'wifi_password': 'example-password',
        'static_ip': '192.0.2.2',
        'gateway': '192.0.2.1',
        'subnet': '255.255.255.0',
        'api_encryption_key': base64.b64encode(secrets.token_bytes(32)).decode(),
        'ota_password': 'example-ota-password',
    }))
    subprocess.run(['esphome', 'config', str(project / 'bluetooth-proxy.yaml')], check=True)
