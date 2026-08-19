import json
import logging
from logging.handlers import QueueHandler, QueueListener, RotatingFileHandler
from pathlib import Path
from queue import Queue

from app.config import get_settings

_LEVELS = {
    "DEBUG": logging.DEBUG,
    "INFO": logging.INFO,
    "WARNING": logging.WARNING,
    "ERROR": logging.ERROR,
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=False)


class AsyncLoggingSetup:
    def __init__(self) -> None:
        self._listener: QueueListener | None = None

    def configure(self) -> None:
        settings = get_settings()
        level = _LEVELS.get(settings.log_level.upper(), logging.INFO)

        root = logging.getLogger()
        root.setLevel(level)
        queue_handler = QueueHandler(Queue(-1))
        root.addHandler(queue_handler)

        console = logging.StreamHandler()
        console.setFormatter(JsonFormatter())

        log_dir = Path(settings.log_dir)
        log_dir.mkdir(parents=True, exist_ok=True)
        file_handler = RotatingFileHandler(log_dir / "app.log", maxBytes=10 * 1024 * 1024, backupCount=5)
        file_handler.setFormatter(JsonFormatter())

        self._listener = QueueListener(queue_handler.queue, console, file_handler)
        self._listener.start()

    def shutdown(self) -> None:
        if self._listener:
            self._listener.stop()
