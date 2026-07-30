from __future__ import annotations

import os
from pathlib import Path

from lupa import LuaRuntime


def main() -> int:
    repository = Path(__file__).resolve().parents[1]
    specs = sorted((repository / "tests").glob("*_spec.lua"))
    if not specs:
        raise RuntimeError("No Lua specifications found")

    previous_directory = Path.cwd()
    failures: list[str] = []
    try:
        os.chdir(repository)
        for spec in specs:
            runtime = LuaRuntime(unpack_returned_tuples=True)
            try:
                runtime.execute(spec.read_text(encoding="utf-8"))
            except Exception as error:
                failures.append(f"{spec.name}: {error}")
    finally:
        os.chdir(previous_directory)

    if failures:
        print("\n".join(failures))
        return 1

    print(f"Lua specifications: {len(specs)}/{len(specs)} files passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
