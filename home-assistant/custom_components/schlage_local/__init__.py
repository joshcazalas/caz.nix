"""Local Schlage Encode Plus code management through an existing HA pairing."""

from pathlib import Path

import voluptuous as vol

from homeassistant.components import frontend, panel_custom, websocket_api
from homeassistant.components.homekit_controller.const import KNOWN_DEVICES
from homeassistant.components.http import StaticPathConfig
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.storage import Store

from .manager import Manager
from .privacy import install_filters
from .protocol import ProtocolError

DOMAIN = "schlage_local"
CONFIG_SCHEMA = cv.config_entry_only_config_schema(DOMAIN)


async def async_setup(hass, config):
    install_filters()
    websocket_api.async_register_command(hass, websocket_command)
    return True


async def async_setup_entry(hass, entry):
    manager = Manager(lambda: hass.data.get(KNOWN_DEVICES, {}).values(), Store(hass, 1, DOMAIN))
    await manager.load()
    hass.data[DOMAIN] = manager
    if not hass.data.get(f"{DOMAIN}_static"):
        await hass.http.async_register_static_paths([
            StaticPathConfig("/schlage-local/panel.js", str(Path(__file__).parent / "frontend" / "panel.js"), False)
        ])
        hass.data[f"{DOMAIN}_static"] = True
    await panel_custom.async_register_panel(
        hass, frontend_url_path="lock-codes", webcomponent_name="schlage-code-panel",
        sidebar_title="Lock codes", sidebar_icon="mdi:lock-smart",
        module_url="/schlage-local/panel.js?v=0.2.1", require_admin=True,
    )
    return True


async def async_unload_entry(hass, entry):
    frontend.async_remove_panel(hass, "lock-codes")
    hass.data.pop(DOMAIN, None)
    return True


@websocket_api.websocket_command({
    vol.Required("type"): "schlage_local/command",
    vol.Required("action"): vol.In(["discover", "list", "add", "remove", "rename", "reveal", "logs", "inspect_codes", "settings", "set_auto_lock"]),
    vol.Optional("lock_id"): str,
    vol.Optional("revision"): vol.All(str, vol.Length(max=64)),
    vol.Optional("code_id"): vol.All(str, vol.Length(max=128)),
    vol.Optional("name"): vol.All(str, vol.Length(max=64)),
    vol.Optional("pin"): vol.All(str, vol.Length(max=32)),
    vol.Optional("seconds"): vol.All(int, vol.Range(min=0, max=86400)),
    vol.Optional("expected"): vol.All(int, vol.Range(min=0, max=86400)),
})
@websocket_api.require_admin
@websocket_api.async_response
async def websocket_command(hass, connection, msg):
    try:
        manager = hass.data.get(DOMAIN)
        if manager is None:
            raise ProtocolError("Schlage Local Codes is not loaded. Check the integration.")
        if msg["action"] == "discover":
            result = {"schlage_local": True, "locks": manager.discover()}
        else:
            if "lock_id" not in msg:
                raise ProtocolError("Select a lock first.")
            result = await manager.execute(msg["action"], msg["lock_id"], **{
                key: msg[key] for key in ("revision", "code_id", "name", "pin", "seconds", "expected") if key in msg
            })
    except ProtocolError as err:
        connection.send_error(msg["id"], "schlage_local/error", str(err))
    except Exception:
        # The BLE stack may put plaintext into exception messages. Never forward
        # those messages or their traceback to HA's logs or the browser.
        connection.send_error(msg["id"], "schlage_local/unavailable",
                              "The local request failed. Check the Atom and HomeKit connection, then refresh.")
    else:
        connection.send_result(msg["id"], result)
