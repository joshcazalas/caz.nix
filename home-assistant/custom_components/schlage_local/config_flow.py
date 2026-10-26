"""Enable the panel without re-pairing the lock or editing configuration YAML."""

from homeassistant import config_entries
import voluptuous as vol

DOMAIN = "schlage_local"


class ConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        if user_input is not None:
            return self.async_create_entry(title="Schlage Local Codes", data={})
        return self.async_show_form(step_id="user", data_schema=vol.Schema({}))
