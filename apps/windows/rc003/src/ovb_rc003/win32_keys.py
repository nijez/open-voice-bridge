"""Virtual-key code table and pure key-token resolution.

Split out from the actual Win32 ``SendInput`` call (see app.py) so the token
-> VK mapping is unit-testable without ctypes/user32 on any OS.
"""

from __future__ import annotations

from typing import List, Sequence

# Standard Windows virtual-key codes (winuser.h).
VK_CODES = {
    "backspace": 0x08,
    "tab": 0x09,
    "enter": 0x0D,
    "shift": 0x10,
    "ctrl": 0x11,
    "alt": 0x12,
    "escape": 0x1B,
    "esc": 0x1B,
    "space": 0x20,
    "page_up": 0x21,
    "pageup": 0x21,
    "page_down": 0x22,
    "pagedown": 0x22,
    "end": 0x23,
    "home": 0x24,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "insert": 0x2D,
    "delete": 0x2E,
    "win": 0x5B,
    "volume_mute": 0xAD,
    "volume_down": 0xAE,
    "volume_up": 0xAF,
    "caps_lock": 0x14,
    "num_lock": 0x90,
    "scroll_lock": 0x91,
    "print_screen": 0x2C,
    "pause": 0x13,
    "browser_back": 0xA6,
    "browser_forward": 0xA7,
    "media_next": 0xB0,
    "media_previous": 0xB1,
    "media_stop": 0xB2,
    "media_play_pause": 0xB3,
    "semicolon": 0xBA,
    "equals": 0xBB,
    "comma": 0xBC,
    "minus": 0xBD,
    "period": 0xBE,
    "slash": 0xBF,
    "backtick": 0xC0,
    "left_bracket": 0xDB,
    "backslash": 0xDC,
    "right_bracket": 0xDD,
    "quote": 0xDE,
    "numpad_multiply": 0x6A,
    "numpad_add": 0x6B,
    "numpad_subtract": 0x6D,
    "numpad_decimal": 0x6E,
    "numpad_divide": 0x6F,
}

for _digit in range(10):
    VK_CODES[str(_digit)] = 0x30 + _digit
for _letter_ord in range(ord("a"), ord("z") + 1):
    VK_CODES[chr(_letter_ord)] = 0x41 + (_letter_ord - ord("a"))
for _function in range(1, 25):
    VK_CODES[f"f{_function}"] = 0x6F + _function
for _digit in range(10):
    VK_CODES[f"numpad{_digit}"] = 0x60 + _digit


class UnknownKeyTokenError(ValueError):
    pass


def resolve_vk_codes(tokens: Sequence[str]) -> List[int]:
    """Resolve an ordered sequence of key tokens (e.g. ``("win", "d")``) into
    Windows virtual-key codes, raising if any token is unrecognized.
    """

    codes = []
    for token in tokens:
        key = token.strip().lower()
        if key not in VK_CODES:
            raise UnknownKeyTokenError(f"unknown key token: {token!r}")
        codes.append(VK_CODES[key])
    return codes
