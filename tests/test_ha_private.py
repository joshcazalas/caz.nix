"""Private-input validation and non-destructive migration regression checks."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

prepare = module('prepare_ha_private', 'prepare-ha-private.py')
migration = module('migrate_ha_private', 'migrate-ha-private.py')
proxy = module('prepare_esphome_proxy', 'prepare-esphome-proxy.py')


def inputs():
    return {'hvac_thermostats': ['climate.example_a', 'climate.example_b'],
            'hvac_day_temperature': 77, 'hvac_night_temperature': 70}


def legacy():
    branches = [
        {'conditions': [{'condition': 'trigger', 'id': name}], 'sequence': [
            {'action': 'script.apply_hvac_sun_schedule', 'data': {'scheduled_temperature': temperature}}]}
        for name, temperature in [('sunrise', 77), ('sunset', 70)]
    ]
    return {'script': {'apply_hvac_sun_schedule': {'sequence': [
        {'variables': {'desired_temperature': "{{ 77 if is_state('sun.sun', 'above_horizon') else 70 }}"}},
        {'choose': [{'conditions': [{'condition': 'state', 'state': 'cool', 'entity_id': e}
                                   for e in inputs()['hvac_thermostats']]}]},
    ]}}, 'automation': [{'id': 'hvac_sun_schedule', 'actions': [{'choose': branches}]}]}


class Validation(unittest.TestCase):
    def test_proxy_proposal_avoids_pool_gateway_known_devices_and_used_ports(self):
        network = {'address': '192.168.70.1/24', 'dhcp': {'start': '192.168.70.20', 'end': '192.168.70.50'},
                   'tcp': {'example': {'listenPort': 19100, 'targetAddress': '192.168.70.254'}}}
        result = proxy.proposal(network, ['192.168.70.253'], [19101])
        self.assertEqual(result, {'direction': 'toNetwork', 'listenPort': 19102,
                                 'targetAddress': '192.168.70.252', 'targetPort': 6053})
        network['address'] = '192.168.70.1/29'
        network['dhcp'] = {'start': '192.168.70.2', 'end': '192.168.70.6'}
        with self.assertRaises(ValueError): proxy.proposal(network, [], [])

    def test_inputs_require_distinct_climate_entities_and_bounded_numbers(self):
        prepare.validate_inputs(inputs())
        for key, value in [('hvac_thermostats', []), ('hvac_thermostats', ['lock.example']),
                           ('hvac_thermostats', ['climate.example', 'climate.example']),
                           ('hvac_thermostats', ['climate.example;command']),
                           ('hvac_day_temperature', True), ('hvac_day_temperature', 90),
                           ('hvac_night_temperature', float('nan')), ('hvac_night_temperature', '70')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                prepare.validate_inputs(inputs() | {key: value})
        with self.assertRaises(ValueError):
            prepare.validate_inputs(inputs() | {'arbitrary': 'value'})

    def test_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            parent.chmod(0o700)
            file = parent / 'inputs.json'
            file.write_text(json.dumps(inputs()))
            file.chmod(0o600)
            self.assertEqual(prepare.private_json(file, os.geteuid()), inputs())
            for mode in [0o644, 0o660, 0o666]:
                file.chmod(mode)
                with self.assertRaises(ValueError): prepare.private_json(file, os.geteuid())
            file.chmod(0o600)
            link = parent / 'linked.json'
            link.symlink_to(file)
            with self.assertRaises(OSError): prepare.private_json(link, os.geteuid())
            parent.chmod(0o755)
            with self.assertRaises(ValueError): prepare.private_json(file, os.geteuid())

    def test_hardware_requires_one_stable_character_device(self):
        source = '/dev/serial/by-id/usb-Example_Coordinator'
        with patch.object(Path, 'stat', return_value=os.stat_result((stat.S_IFCHR,)*10)):
            self.assertEqual(prepare.validate_hardware({'serial_device': source}), source)
        for value in ['/dev/sda', '/dev/serial/by-id/../../sda', '/tmp/serial', source + ':rw']:
            with self.assertRaises(ValueError): prepare.validate_hardware({'serial_device': value})
        with patch.object(Path, 'stat', return_value=os.stat_result((stat.S_IFREG,)*10)):
            with self.assertRaises(ValueError): prepare.validate_hardware({'serial_device': source})
        with self.assertRaises(ValueError): prepare.validate_hardware({'serial_device': source, 'devices': []})

    def test_migration_preserves_targets_and_both_trigger_and_startup_temperatures(self):
        self.assertEqual(migration.extract_household(legacy()), inputs())
        changed = legacy()
        changed['script']['apply_hvac_sun_schedule']['sequence'][0]['variables']['desired_temperature'] = "{{ 78 if is_state('sun.sun', 'above_horizon') else 70 }}"
        with self.assertRaises(ValueError): migration.extract_household(changed)
        changed = legacy()
        changed['automation'][0]['actions'][0]['choose'][0]['sequence'][0]['action'] = 'lock.unlock'
        with self.assertRaises(ValueError): migration.extract_household(changed)

    def test_conflicting_file_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'config.json'
            migration.write_private(file, 'original')
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
            with self.assertRaises(ValueError): migration.write_private(file, 'changed')
            self.assertEqual(file.read_text(), 'original')
            symlink = Path(temporary) / 'link.json'
            symlink.symlink_to(file)
            with self.assertRaises(ValueError): migration.write_private(symlink, 'changed')
            self.assertEqual(file.read_text(), 'original')


if __name__ == '__main__':
    unittest.main()
