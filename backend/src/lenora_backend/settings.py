import os
from pathlib import Path
from typing import Literal

from dotenv import find_dotenv, load_dotenv
from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict


class CoreSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_", extra="ignore")

    env: Literal["development", "production"] = "development"
    token: SecretStr = Field(min_length=32)
    host: str | None = None
    port: int | None = Field(default=None, ge=0, le=65535, validation_alias=AliasChoices("LENORA_PORT", "PORT"))
    provider_timeout_seconds: float = Field(default=60.0, gt=0)
    # Shared with adapters that read LENORA_DATA_DIR themselves; results live in <data_dir>/results.
    data_dir: Path = Path(".data")
    # Proxies whose X-Forwarded-Proto uvicorn trusts in production; result URLs use the client-facing scheme.
    forwarded_allow_ips: str | None = None
    # Set by the app for its built-in backend; the backend exits when that process is gone.
    parent_pid: int | None = Field(default=None, gt=1)

    @property
    def bind_host(self) -> str:
        return self.host or ("127.0.0.1" if self.env == "development" else "0.0.0.0")

    @property
    def bind_port(self) -> int:
        if self.port is not None:
            return self.port
        if self.env == "development":
            return 8787
        raise ValueError("PORT is not set; production binds the platform-provided PORT.")

    @property
    def docs_enabled(self) -> bool:
        return self.env == "development"


def load_environment() -> CoreSettings:
    """Load `.env` into the process environment in development, then read core settings."""
    if os.environ.get("LENORA_ENV", "development") == "development":
        load_dotenv(find_dotenv(usecwd=True), override=False)
    return CoreSettings()
