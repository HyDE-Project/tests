"""Guard the keybind hint's replay of Lua binds through Hyprland's own
registry reference.

`hyprctl binds -j` reports a bind whose action is a Lua handler only as an
opaque reference -- "__lua" on older builds, "HL.Dispatcher(...)" or
"function: 0x..." on 0.57+ -- with that reference in `arg`. hyde/binds.lua
publishes lua_bind_actions.json mapping every reference to the token of the
registration that owns it, and the hint turns that into
`hyde.binds.action("<ref>", "<token>")`. It must not rebuild a command,
dispatch by combo, or fall back to a no-op: each of those runs the wrong bind
or nothing at all. A reference the manifest does not cover stays exactly as
hyprctl reported it.

The manifest is published by tests/lua/bind_actions_harness.lua. When that ran,
HYDE_TEST_MANIFEST points at the file it wrote and the last test class checks
the real thing too.
"""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import shutil
import tempfile
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(os.environ.get("REPO_ROOT", "."))
HINT_SCRIPT = (
    REPO_ROOT / "Configs" / ".local" / "lib" / "hyde" / "keybinds" / "hint-hyprland.py"
)

_spec = importlib.util.spec_from_file_location("hyde_hint_hyprland", HINT_SCRIPT)
assert _spec and _spec.loader
hint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hint)

# hyprctl's SUPER bit; the combo itself no longer identifies a Lua bind.
SUPER = 64

REF = "107"
TOKEN = "table: 0x0:1"
REPLAY = f'hyde.binds.action("{REF}", "{TOKEN}")'

# `hyde.binds.action("<reference>", "<token>")`, as expand_meta_data builds it.
EXPRESSION = re.compile(r'hyde\.binds\.action\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)"\)')

_LUA_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}

MANIFEST = os.environ.get("HYDE_TEST_MANIFEST")


def lua_unescape(text: str) -> str:
    out, index = [], 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text):
            out.append(_LUA_ESCAPES.get(text[index + 1], text[index + 1]))
            index += 2
        else:
            out.append(char)
            index += 1
    return "".join(out)


def make_bind(
    dispatcher, arg, key="a", keycode=0, modmask=SUPER, description=None, submap="", mouse=False
):
    """Minimal `hyprctl binds -j` entry with no description, so
    expand_meta_data() synthesizes one from dispatcher/arg like the real Lua
    binds do."""
    return {
        "dispatcher": dispatcher,
        "arg": arg,
        "key": key,
        "keycode": keycode,
        "modmask": modmask,
        "submap": submap,
        "mouse": mouse,
        "description": description or "",
        "has_description": description is not None,
    }


def expand(bind, actions):
    binds = [bind]
    hint.expand_meta_data(binds, actions)
    return binds[0]


class ReplayRewriteTest(unittest.TestCase):
    def test_every_lua_handler_label_replays_by_reference(self):
        # All of these are Lua handlers, whatever Hyprland version reports
        # them: the reference in `arg` is the identity, never the combo.
        for dispatcher in (
            "__lua",
            "HL.Dispatcher(exec_cmd)",
            "HL.Dispatcher(window)",
            "HL.Dispatcher(workspace)",
            "function: 0x55d0c3a1b2c0",
            "table: 0x55d0c3a1b2c0",
        ):
            with self.subTest(dispatcher=dispatcher):
                bind = expand(make_bind(dispatcher, 107), {REF: TOKEN})
                self.assertEqual(bind["dispatcher"], REPLAY)
                self.assertEqual(bind["arg"], "")

    def test_no_command_is_reconstructed(self):
        # The old cache rebuilt `hl.dsp.exec_cmd("<command>")` from the
        # reported label; a replay keeps the bind's own action instead.
        bind = expand(make_bind("__lua", 107), {REF: TOKEN})
        self.assertNotIn("hl.dsp.exec_cmd", bind["dispatcher"])
        self.assertNotIn("hyde-shell", bind["dispatcher"])

    def test_same_combo_distinct_references_replay_distinct_actions(self):
        # A combo can carry a press and a release bind and repeat across
        # submaps; only the registry reference tells them apart.
        actions = {"107": "table: 0x0:1", "108": "table: 0x0:2", "109": "table: 0x0:3"}
        binds = [
            make_bind("__lua", 107),
            make_bind("__lua", 108, submap="resize"),
            make_bind("__lua", 109, key="a"),
        ]
        hint.expand_meta_data(binds, actions)
        self.assertEqual(
            [bind["dispatcher"] for bind in binds],
            [f'hyde.binds.action("{ref}", "{actions[ref]}")' for ref in ("107", "108", "109")],
        )
        for bind in binds:
            self.assertNotIn("SUPER", bind["dispatcher"])

    def test_unknown_reference_is_left_as_reported(self):
        # No combo-keyed fallback: the hint shows the bind but does not run a
        # guessed action for it.
        for dispatcher in ("__lua", "HL.Dispatcher(window)", "function: 0x55d0c3a1b2c0"):
            with self.subTest(dispatcher=dispatcher):
                bind = expand(make_bind(dispatcher, 107), {"108": TOKEN, "SUPER + A": TOKEN})
                self.assertEqual(bind["dispatcher"], dispatcher)
                self.assertEqual(bind["arg"], 107)

    def test_native_dispatchers_are_not_rewritten(self):
        # Their `arg` is real data, not a registry reference, even when it
        # happens to equal one.
        actions = {"3": TOKEN, "kitty": TOKEN}
        for dispatcher, arg in (("exec", "kitty"), ("workspace", "3"), ("submap", "resize")):
            with self.subTest(dispatcher=dispatcher):
                bind = expand(make_bind(dispatcher, arg), actions)
                self.assertEqual(bind["dispatcher"], dispatcher)
                self.assertEqual(bind["arg"], arg)

    def test_mouse_bind_is_not_rewritten(self):
        # Mouse binds only act on a drag, so there is nothing to dispatch.
        bind = expand(make_bind("__lua", 107, key="mouse:272", modmask=0), {REF: TOKEN})
        self.assertEqual(bind["dispatcher"], "__lua")
        self.assertEqual(bind["arg"], 107)

    def test_missing_arg_is_left_alone(self):
        bind = expand(make_bind("__lua", None), {REF: TOKEN})
        self.assertEqual(bind["dispatcher"], "__lua")
        self.assertIsNone(bind["arg"])

    def test_mouse_flag_is_not_rewritten(self):
        # A native drag can be declared over an ordinary key, so the reported
        # flag, not only the "mouse:" key, decides that there is nothing to
        # dispatch.
        bind = expand(make_bind("__lua", 107, key="z", mouse=True), {REF: TOKEN})
        self.assertEqual(bind["dispatcher"], "__lua")
        self.assertEqual(bind["arg"], 107)
        self.assertEqual(bind["key"], "z")

    def test_hostile_token_cannot_break_out_of_the_lua_string(self):
        # The token comes from a cache file, so it is treated as data: quote,
        # backslash and statement separators have to stay inside the literal.
        for token in ('g:1"', "g:1\\", 'g:1"\\2', 'x") hl.dispatch("y'):
            with self.subTest(token=token):
                expression = expand(make_bind("__lua", 107), {REF: token})["dispatcher"]
                match = EXPRESSION.fullmatch(expression)
                self.assertIsNotNone(match, expression)
                self.assertEqual(lua_unescape(match.group(1)), REF)
                self.assertEqual(lua_unescape(match.group(2)), token)
                self.assertNotIn("\n", expression)
                self.assertEqual(expression.count("hyde.binds.action("), 1)

    def test_keycode_mapping_still_applies(self):
        bind = expand(make_bind("__lua", 107, key="Slash", keycode=61), {REF: TOKEN})
        self.assertEqual(bind["key"], "slash")
        self.assertEqual(bind["key_display"], "slash")
        self.assertEqual(bind["dispatcher"], REPLAY)

    def test_description_headers_survive_the_rewrite(self):
        bind = expand(
            make_bind("HL.Dispatcher(window)", 107, description="[Window|Float] toggle"),
            {REF: TOKEN},
        )
        self.assertEqual(bind["header1"], "Window")
        self.assertEqual(bind["header2"], "Float")
        self.assertEqual(bind["description"], "toggle")
        self.assertEqual(bind["dispatcher"], REPLAY)

    def test_without_a_map_nothing_is_rewritten(self):
        # expand_meta_data() must not reach for a combo or an installed cache
        # on its own; the caller passes the published map.
        binds = [make_bind("__lua", 107)]
        hint.expand_meta_data(binds)
        self.assertEqual(binds[0]["dispatcher"], "__lua")
        self.assertEqual(binds[0]["arg"], 107)


class LoadBindActionsTest(unittest.TestCase):
    def setUp(self):
        self.cache_home = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.cache_home, ignore_errors=True)
        patcher = mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(self.cache_home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.manifest = self.cache_home / "hyde" / "lua_bind_actions.json"
        self.manifest.parent.mkdir(parents=True)

    def write(self, text):
        self.manifest.write_text(text)

    def test_reads_the_published_token_map(self):
        tokens = {"107": TOKEN, "108": "table: 0x0:2"}
        self.write(json.dumps(tokens))
        self.assertEqual(hint.load_bind_actions(), tokens)

    def test_missing_file_is_empty(self):
        self.manifest.unlink(missing_ok=True)
        self.assertEqual(hint.load_bind_actions(), {})

    def test_malformed_json_is_empty(self):
        self.write('{"107": ')
        self.assertEqual(hint.load_bind_actions(), {})

    def test_non_object_is_empty(self):
        for text in ("[]", '"107"', '{"107": {"token": "g:1"}}', '{"107": 7}'):
            with self.subTest(text=text):
                self.write(text)
                self.assertEqual(hint.load_bind_actions(), {})

    def test_non_decimal_keys_are_dropped(self):
        # A reference is Hyprland's decimal handle; anything else is not a
        # reference and must not be dispatched.
        tokens = {"107": TOKEN, "SUPER + A": TOKEN, "0x64": TOKEN, "": TOKEN}
        self.write(json.dumps(tokens))
        self.assertEqual(hint.load_bind_actions(), {"107": TOKEN})

    def test_token_with_a_newline_is_dropped(self):
        # The dispatch field is single-line, so a token carrying a newline is
        # refused instead of splitting it into a second command.
        tokens = {"107": TOKEN, "108": 'g:1"\n', "109": "g:1\r"}
        self.write(json.dumps(tokens))
        self.assertEqual(hint.load_bind_actions(), {"107": TOKEN})

    def test_empty_and_unprintable_tokens_are_dropped(self):
        tokens = {"107": TOKEN, "108": "", "109": "\t", "110": "g\x00:1"}
        self.write(json.dumps(tokens))
        self.assertEqual(hint.load_bind_actions(), {"107": TOKEN})


@unittest.skipUnless(MANIFEST, "the Lua harness did not run, so nothing published a manifest")
class PublishedManifestTest(unittest.TestCase):
    """Reads the manifest the real hyde/binds.lua wrote, not a fixture."""

    @classmethod
    def setUpClass(cls):
        cls.raw = pathlib.Path(MANIFEST).read_text()
        cls.tokens = json.loads(cls.raw)

    def test_is_a_single_line_reference_to_token_map(self):
        self.assertNotIn("\n", self.raw.rstrip("\n"))
        self.assertTrue(self.tokens, "the published manifest is empty")
        for reference, token in self.tokens.items():
            with self.subTest(reference=reference):
                self.assertTrue(reference.isdigit(), f"not a registry reference: {reference!r}")
                self.assertIsInstance(token, str)
                self.assertTrue(token, "the published token is empty")
                self.assertTrue(token.isprintable(), "the published token is not printable")
                self.assertNotIn("\n", token)
                self.assertNotIn("\r", token)
        self.assertNotIn("hyde.binds.action", self.raw)
        self.assertNotIn("exec_cmd", self.raw)

    def test_loader_reads_the_published_manifest(self):
        cache_home = pathlib.Path(MANIFEST).parent.parent
        with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": str(cache_home)}):
            self.assertEqual(hint.load_bind_actions(), self.tokens)

    def test_expand_replays_a_published_reference(self):
        for reference, token in self.tokens.items():
            with self.subTest(dispatcher="__lua", reference=reference):
                bind = expand(make_bind("__lua", reference), self.tokens)
                match = EXPRESSION.fullmatch(bind["dispatcher"])
                self.assertIsNotNone(match, bind["dispatcher"])
                self.assertEqual(lua_unescape(match.group(1)), reference)
                self.assertEqual(lua_unescape(match.group(2)), token)
                self.assertEqual(bind["arg"], "")
        # hyprctl reports the reference as a number on some builds.
        reference, token = next(iter(self.tokens.items()))
        if reference.isdigit():
            bind = expand(make_bind("HL.Dispatcher(window)", int(reference)), self.tokens)
            self.assertEqual(bind["dispatcher"], f'hyde.binds.action("{reference}", "{token}")')


if __name__ == "__main__":
    unittest.main()
