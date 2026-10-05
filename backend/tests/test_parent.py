import asyncio

from lenora_backend.parent import watch_parent


def test_watch_parent_calls_on_gone_once_the_parent_changes():
    parents = iter([10, 10, 1])
    gone: list[bool] = []
    asyncio.run(watch_parent(10, lambda: gone.append(True), getppid=lambda: next(parents), interval=0))
    assert gone == [True]
