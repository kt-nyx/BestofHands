# SPDX-License-Identifier: Unlicense

from pathlib import Path

from lupa import LuaRuntime
import yaml


ROOT = Path(__file__).resolve().parents[1]
LUA_ROOT = ROOT / "src" / "BestOfHands" / "Mods" / "BestOfHands" / "ScriptExtender" / "Lua"


def main() -> None:
    yaml_files = sorted((ROOT / ".github").rglob("*.yml")) + sorted(
        (ROOT / ".github").rglob("*.yaml")
    )
    for path in yaml_files:
        parsed = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError(f"Expected a YAML mapping in {path}")

    lua = LuaRuntime(unpack_returned_tuples=True)
    parse = lua.eval(
        "function(code, name) local fn, err = load(code, '@' .. name); "
        "if not fn then error(err) end; return true end"
    )

    lua_files = sorted(LUA_ROOT.rglob("*.lua"))
    for path in lua_files:
        parse(path.read_text(encoding="utf-8"), path.as_posix())

    lua.globals().BEST_OF_HANDS_ROOT = ROOT.as_posix()
    test_path = ROOT / "tests" / "lua" / "test_runner.lua"
    lua.execute(test_path.read_text(encoding="utf-8"), name=test_path.as_posix())

    print(f"Lua syntax passed: {len(lua_files)} files")
    print(f"YAML syntax passed: {len(yaml_files)} files")


if __name__ == "__main__":
    main()
