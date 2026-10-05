import pytest
from fastapi.testclient import TestClient
from pydantic import AliasChoices, Field, ValidationError
from pydantic_settings import BaseSettings, SettingsConfigDict

from fakes import AUTH, FakeAdapter, build_app
from lenora_backend.errors import ProblemError
from lenora_backend.registry import AdapterStatus, Registry, missing_settings_reason


class NeedsKey(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_DEMO_")
    api_key: str = Field(min_length=1)


def test_missing_settings_reason_names_env_vars_not_values():
    with pytest.raises(ValidationError) as info:
        NeedsKey()
    assert missing_settings_reason("demo", info.value) == "missing or invalid: LENORA_DEMO_API_KEY"


def test_job_adapter_routes_on_prefix():
    adapter = FakeAdapter()
    registry = Registry({"fake": adapter}, [])
    assert registry.job_adapter("fake:url:abc") == (adapter, "url:abc")


@pytest.mark.parametrize("job_id", ["", "fake", "fake:", "other:job1", ":job1"])
def test_job_adapter_rejects_unknown(job_id):
    with pytest.raises(ProblemError) as info:
        Registry({"fake": FakeAdapter()}, []).job_adapter(job_id)
    assert info.value.code == "not_found"


def test_unknown_model():
    with pytest.raises(ProblemError) as info:
        Registry({"fake": FakeAdapter()}, []).model("fake/missing")
    assert info.value.code == "unknown_model"


def test_capabilities_lists_only_enabled_adapters(make_client):
    statuses = [
        AdapterStatus("fake", True, None, "0.0.1"),
        AdapterStatus("off", False, "missing or invalid: LENORA_OFF_KEY", "0.0.1"),
    ]
    body = make_client(FakeAdapter(), statuses=statuses).get("/v1/capabilities", headers=AUTH).json()
    assert body["protocolVersion"] == "1"
    assert body["adapters"] == [{"id": "fake", "version": "0.0.1"}]
    assert [m["id"] for m in body["models"]] == ["fake/cutout"]


class AliasedKey(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LENORA_DEMO_", populate_by_name=True)
    api_key: str = Field(min_length=1, validation_alias=AliasChoices("LENORA_DEMO_API_KEY", "DEMO_API_KEY"))


def test_missing_aliased_setting_names_the_lenora_variable(monkeypatch):
    monkeypatch.delenv("DEMO_API_KEY", raising=False)
    with pytest.raises(ValidationError) as info:
        AliasedKey()
    assert missing_settings_reason("demo", info.value) == "missing or invalid: LENORA_DEMO_API_KEY"


class StoppingAdapter(FakeAdapter):
    def __init__(self, settings=None, http=None):
        super().__init__(settings, http)
        self.stopped = 0

    async def stop(self) -> None:
        self.stopped += 1


def test_shutdown_stops_each_adapter_once():
    adapter = StoppingAdapter()
    with TestClient(build_app(adapter)):
        assert adapter.stopped == 0
    assert adapter.stopped == 1


def test_disabled_reason_names_fields_without_values(monkeypatch):
    import httpx as _httpx
    monkeypatch.setenv("LENORA_CLOUDINARY_CLOUD_NAME", "bad name!")
    monkeypatch.setenv("LENORA_CLOUDINARY_API_KEY", "123456789012345")
    monkeypatch.setenv("LENORA_CLOUDINARY_API_SECRET", "s3cr3t-value")
    monkeypatch.setenv("LENORA_OPENAI_API_KEY", "")
    registry = Registry.load(_httpx.AsyncClient())
    reasons = " ".join(s.reason or "" for s in registry.statuses)
    assert "LENORA_CLOUDINARY_CLOUD_NAME" in reasons
    assert "bad name!" not in reasons and "s3cr3t-value" not in reasons and "123456789012345" not in reasons
