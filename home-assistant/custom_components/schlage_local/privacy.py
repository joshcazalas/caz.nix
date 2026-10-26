"""Prevent the HA websocket and HAP debug loggers from recording PINs."""

import logging


class SensitiveTrafficFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        # Transport debug logs can include decrypted TLVs, including responses to
        # HA's own startup reads. Do not depend on our request's async context.
        if record.name.startswith("aiohomekit"):
            return record.levelno >= logging.INFO
        message = record.getMessage()
        if "schlage_local/" in message or '"schlage_local"' in message:
            record.msg = "Local lock code message (content withheld)"
            record.args = ()
            record.exc_info = None
            record.exc_text = None
        return True


def install_filters() -> None:
    # Logger filters do not propagate to parents. These are the emitters in
    # aiohomekit 4.0.0 / HA 2026.8.3, verified by compatibility tests.
    for name in (
        "aiohomekit.controller.ble.pairing",
        "aiohomekit.controller.ble.client",
        "aiohomekit.protocol.tlv",
        "aiohomekit.pdu",
        "homeassistant.components.websocket_api.http.connection",
        "homeassistant.components.websocket_api.connection",
    ):
        logger = logging.getLogger(name)
        if not any(isinstance(f, SensitiveTrafficFilter) for f in logger.filters):
            logger.addFilter(SensitiveTrafficFilter())
