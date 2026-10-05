import os
import re
import select
import subprocess
import sys

import httpx
import pytest

TOKEN = "t" * 64
READY = re.compile(r"^LENORA_READY port=([0-9]{1,5})$")


@pytest.fixture
def spawn(tmp_path):
    procs: list[subprocess.Popen] = []

    def start(data_dir=None, **extra) -> subprocess.Popen:
        env = {
            "PATH": os.environ["PATH"], "HOME": str(tmp_path),
            "LENORA_ENV": "production", "LENORA_TOKEN": TOKEN, "LENORA_HOST": "127.0.0.1", "LENORA_PORT": "0",
            "LENORA_DATA_DIR": str(data_dir or tmp_path / "data"), **extra,
        }
        proc = subprocess.Popen([sys.executable, "-m", "lenora_backend"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        procs.append(proc)
        return proc

    yield start
    for proc in procs:
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=10)


def read_line(proc: subprocess.Popen, timeout: float = 60) -> str:
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    assert ready, "backend printed nothing"
    return proc.stdout.readline().rstrip("\n")


def test_port_zero_announces_a_port_that_serves_health(spawn):
    proc = spawn()
    match = READY.match(read_line(proc))
    assert match, "first stdout line is not the ready line"
    port = int(match.group(1))
    assert 1 <= port <= 65535
    response = httpx.get(f"http://127.0.0.1:{port}/v1/health", headers={"Authorization": f"Bearer {TOKEN}"}, timeout=10)
    assert response.status_code == 200


def test_second_backend_on_same_data_dir_exits_with_code_3(spawn, tmp_path):
    first = spawn(tmp_path / "shared")
    assert READY.match(read_line(first))
    second = spawn(tmp_path / "shared")
    assert second.wait(timeout=30) == 3
    assert "another backend is using" in second.stderr.read()


def test_backends_on_different_data_dirs_both_run(spawn, tmp_path):
    a, b = spawn(tmp_path / "a"), spawn(tmp_path / "b")
    assert READY.match(read_line(a)) and READY.match(read_line(b))


def test_backend_exits_when_parent_pid_is_not_its_parent(spawn):
    proc = spawn(LENORA_PARENT_PID="999999")
    assert proc.wait(timeout=30) is not None


def test_backend_keeps_running_while_its_parent_lives(spawn):
    proc = spawn(LENORA_PARENT_PID=str(os.getpid()))
    match = READY.match(read_line(proc))
    assert match
    response = httpx.get(f"http://127.0.0.1:{match.group(1)}/v1/health", timeout=10)
    assert response.status_code == 200 and proc.poll() is None
