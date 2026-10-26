"""Exercise the reusable HVAC script in HA with synthetic state and services.

Run in the pinned Home Assistant environment. No network or physical devices.
"""
import asyncio
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from annotatedyaml import Secrets, load_yaml
from homeassistant.core import Context, HomeAssistant
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.script import Script

ROOT = Path(__file__).resolve().parents[1]


class HVACCompatibility(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        folder = Path(self.directory.name)
        shutil.copytree(ROOT / 'home-assistant/packages', folder / 'packages')
        (folder / 'packages/secrets.yaml').write_text(json.dumps({
            'hvac_thermostats': ['climate.example_a', 'climate.example_b'],
            'hvac_day_temperature': 77, 'hvac_night_temperature': 70}))
        self.package = load_yaml(folder / 'packages/hvac.yaml', secrets=Secrets(folder))
        self.hass = HomeAssistant(str(folder))
        self.calls = []
        async def service(call):
            self.calls.append((call.domain, call.service, dict(call.data)))
        for domain, name in [('climate', 'set_temperature'), ('persistent_notification', 'create'),
                             ('persistent_notification', 'dismiss')]:
            self.hass.services.async_register(domain, name, service)
        self.hass.states.async_set('sun.sun', 'above_horizon')
        for entity in ['climate.example_a', 'climate.example_b']:
            self.hass.states.async_set(entity, 'cool', {'temperature': 74})

    async def asyncTearDown(self):
        with patch('homeassistant.core.shutdown_run_callback_threadsafe'):
            await asyncio.wait_for(self.hass.async_stop(force=True), 3)
        self.directory.cleanup()

    async def run_script(self, variables=None):
        sequence = cv.SCRIPT_SCHEMA(self.package['script']['apply_hvac_sun_schedule']['sequence'])
        script = Script(self.hass, sequence, 'Synthetic schedule', 'script')
        await asyncio.wait_for(script.async_run(variables or {}, Context()), 5)
        await self.hass.async_block_till_done()
        return [data for domain, service, data in self.calls if domain == 'climate']

    async def test_day_and_night_use_private_inputs(self):
        calls = await self.run_script()
        self.assertEqual({x['temperature'] for x in calls}, {77})
        self.assertEqual({e for x in calls for e in x['entity_id']}, {'climate.example_a', 'climate.example_b'})
        self.calls.clear()
        self.hass.states.async_set('sun.sun', 'below_horizon')
        calls = await self.run_script()
        self.assertEqual({x['temperature'] for x in calls}, {70})

    async def test_missing_or_non_cooling_target_blocks_all_changes(self):
        for state in ['unavailable', 'unknown', 'heat']:
            self.hass.states.async_set('climate.example_b', state)
            self.calls.clear()
            self.assertEqual(await self.run_script(), [])
        self.hass.states.async_remove('climate.example_b')
        self.calls.clear()
        self.assertEqual(await self.run_script(), [])

    async def test_invalid_setpoint_or_unknown_sun_blocks_all_changes(self):
        for temperature in [None, 'bad', 90, 20]:
            if temperature is None:
                self.hass.states.async_set('sun.sun', 'unknown')
            else:
                self.hass.states.async_set('sun.sun', 'above_horizon')
            self.calls.clear()
            self.assertEqual(await self.run_script({'scheduled_temperature': temperature}), [])

    async def test_matching_targets_are_not_written_and_caller_cannot_replace_targets(self):
        self.hass.states.async_set('climate.example_a', 'cool', {'temperature': 77})
        calls = await self.run_script({'thermostat_entities': ['climate.unrelated'], 'day_temperature': 85})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['entity_id'], ['climate.example_b'])
        self.assertEqual(calls[0]['temperature'], 77)

    async def test_sun_trigger_setpoints_and_availability_targets_resolve_privately(self):
        schedule = next(a for a in self.package['automation'] if a['id'] == 'hvac_sun_schedule')
        branches = next(a['choose'] for a in schedule['actions'] if 'choose' in a)
        self.assertEqual({b['conditions'][0]['id']: b['sequence'][0]['data']['scheduled_temperature']
                          for b in branches}, {'sunrise': 77, 'sunset': 70})
        availability = next(a for a in self.package['automation'] if a['id'] == 'hvac_thermostat_availability')
        self.assertTrue(all(t['entity_id'] == ['climate.example_a', 'climate.example_b'] for t in availability['triggers']))

    async def test_root_configuration_resolves_private_inputs_without_loading_secrets_as_package(self):
        folder = Path(self.directory.name)
        shutil.copy(ROOT / 'home-assistant/configuration.yaml', folder / 'configuration.yaml')
        for name, content in [('automations.yaml', '[]'), ('scripts.yaml', '{}'), ('scenes.yaml', '[]')]:
            (folder / name).write_text(content)
        config = load_yaml(folder / 'configuration.yaml', secrets=Secrets(folder))
        self.assertEqual(config['homeassistant']['auth_mfa_modules'], [{'type': 'totp'}])
        self.assertEqual(set(config['homeassistant']['packages']), {'hvac'})


if __name__ == '__main__':
    unittest.main()
