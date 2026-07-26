"""Settings-window pure logic: button mapping list, voice hotkey, output
endpoint, bridge-launch and log-location status text.

This module is deliberately Tk/Qt-free (XRBM-030 replaced the previous Tk
view with a PySide6-Essentials + Qt Quick/QML one - see
``qt_settings_app.py`` and ``qml/`` - but every piece of validation/save/
launch/log-status logic below is unchanged and stays here so it keeps being
directly unit-testable without constructing any window at all, matching the
contract fixed after XRBM-014 review RETRY P1 #7): every piece of
validation/save logic is a plain function (``_action_to_display``,
``_display_to_action``, ``build_save_model``, ``_endpoint_display``,
``_parse_endpoint_display``, ``describe_launch_result``,
``describe_log_open_result``) that tests call directly - see
tests/test_settings_ui_helpers.py. The previous bug (the default "mic"
mapping's display string had no reverse mapping back to
``ActionKind.VOICE``, so a user who changed nothing - or clicked "restore
defaults" - could not save) is covered by an explicit round-trip test on
``_VOICE_DISPLAY``.

``main()`` at the bottom of this module is the only place that touches Qt at
all, and does so via a lazy import inside the function body - importing this
module (e.g. from ``__main__.py``'s ``--dry-run`` smoke check) never
requires PySide6 to be installed, the same optional-dependency convention
this package already uses for ``sounddevice``/``numpy``/``winrt`` (see
``qt_settings_app.py``'s module docstring for the exact error raised when
Qt is missing).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional, Tuple

from . import (
    audio_output,
    bridge_launcher,
    device_catalog,
    device_profile,
    hotkey,
    key_mapping,
    logging_setup,
)

# Preset key-combo choices shown in the mapping dropdown, covering every
# default action plus a few common alternates. Any other "mod+mod+key" text
# is also accepted via hotkey.HotkeySpec.parse.
_PRESET_KEY_COMBOS = (
    "escape", "enter", "backspace", "up", "down", "left", "right",
    "win+d", "shift+f10", "alt+esc", "tab", "space",
)

_TRIGGER_MODE_LABELS = {
    key_mapping.VoiceTriggerMode.TOGGLE: "开关型 (toggle)",
    key_mapping.VoiceTriggerMode.HOLD: "按住型 (hold)",
}

# The exact display string for a "mic" (ActionKind.VOICE) button mapping.
# _display_to_action must recognize this literal string and round-trip it
# back to ActionKind.VOICE - it must NOT be handed to HotkeySpec.parse.
_VOICE_DISPLAY = "语音（使用专用组合键）"

# The microphone button remains a VOICE lifecycle action (it cannot be changed
# into an unrelated normal-key mapping), but the host chord it emits is
# editable through SettingsController.hotkeyText in the same row.
_MIC_ROW_DISPLAY = "触发语音（组合键可编辑）"

# device_profile.ALL_BUTTON_IDS also carries "volume_mute", a HID usage-table
# entry kept for protocol compatibility (see key_mapping.py's module
# docstring) even though the physical RC003 has no dedicated mute key - only
# Volume + and Volume -. The settings window must not offer a mapping row a
# real remote can never actually trigger (XRBM-019 review round 1 P2), so
# every button list this module builds for display uses this narrowed set
# instead of ALL_BUTTON_IDS directly.
_USER_FACING_BUTTON_IDS = frozenset(device_profile.ALL_BUTTON_IDS - {"volume_mute"})

_ENDPOINT_NAME_HOST_API_SEPARATOR = " — "


class SettingsValidationError(Exception):
    """Raised by build_save_model on invalid input. ``button_id`` is None
    for a hotkey-level error, or the offending button's id for a mapping
    error.
    """

    def __init__(self, button_id: Optional[str], message: str) -> None:
        super().__init__(message)
        self.button_id = button_id
        self.message = message


def _action_to_display(action: key_mapping.ButtonAction) -> str:
    if action.kind == key_mapping.ActionKind.VOICE:
        return _VOICE_DISPLAY
    if action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_UP:
        return "系统音量 +"
    if action.kind == key_mapping.ActionKind.SYSTEM_VOLUME_DOWN:
        return "系统音量 −"
    return "+".join(action.keys)


def _display_to_action(text: str) -> key_mapping.ButtonAction:
    text = text.strip()
    if text == _VOICE_DISPLAY:
        return key_mapping.ButtonAction(key_mapping.ActionKind.VOICE)
    if text in ("系统音量 +",):
        return key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_UP)
    if text in ("系统音量 −", "系统音量 -"):
        return key_mapping.ButtonAction(key_mapping.ActionKind.SYSTEM_VOLUME_DOWN)
    parsed = hotkey.HotkeySpec.parse(text)
    return key_mapping.ButtonAction(
        key_mapping.ActionKind.KEY_COMBO, tuple(parsed.modifiers) + (parsed.key,)
    )


def _endpoint_display(endpoint: audio_output.AudioEndpoint) -> str:
    if endpoint.host_api:
        return f"{endpoint.name}{_ENDPOINT_NAME_HOST_API_SEPARATOR}{endpoint.host_api}"
    return endpoint.name


def _parse_endpoint_display(text: str) -> Tuple[str, str]:
    """Inverse of _endpoint_display: returns (name, host_api), where
    host_api is "" if the text has no disambiguating suffix.
    """

    text = text.strip()
    if _ENDPOINT_NAME_HOST_API_SEPARATOR in text:
        name, host_api = text.rsplit(_ENDPOINT_NAME_HOST_API_SEPARATOR, 1)
        return name.strip(), host_api.strip()
    return text, ""


def build_save_model(
    *,
    button_display_map: Dict[str, str],
    hotkey_text: str,
    trigger_mode: key_mapping.VoiceTriggerMode,
    endpoint_display_text: str,
    base_config: dict,
    base_bindings: dict,
    selected_device_profile: str = device_catalog.RC003_ID,
) -> Tuple[dict, dict]:
    """Pure validation+build step for "Save"/"Restore defaults", with no Tk
    dependency at all - directly unit tested without constructing any
    window (see tests/test_settings_ui_helpers.py). Raises
    SettingsValidationError on invalid input; never raises a Tk exception.
    """

    try:
        hotkey.HotkeySpec.parse(hotkey_text)
    except hotkey.HotkeyParseError as exc:
        raise SettingsValidationError(None, str(exc)) from exc

    bindings: Dict[str, dict] = {}
    for button_id, text in button_display_map.items():
        text = text.strip()
        if not text:
            continue
        try:
            action = _display_to_action(text)
        except hotkey.HotkeyParseError as exc:
            raise SettingsValidationError(button_id, str(exc)) from exc
        bindings[button_id] = action.to_dict()

    # The physical mic button is always driven directly by the ATVV voice
    # lifecycle (see app.py) - the runtime never consults a stored "mic"
    # binding at all. Force it to VOICE unconditionally regardless of what
    # button_display_map contained: the settings window no longer offers an
    # editable mic row (see ButtonMappingModel in qt_settings_app.py), but
    # this is the authoritative, UI-independent guarantee that this save
    # path can never
    # persist a stale/misleading non-voice mic action (XRBM-019 In-scope
    # item 6, folded in from XRBM-018's independent review round 2's
    # product-contract follow-up).
    bindings["mic"] = key_mapping.ButtonAction(key_mapping.ActionKind.VOICE).to_dict()

    endpoint_name, endpoint_host_api = _parse_endpoint_display(endpoint_display_text)

    new_config = dict(base_config)
    new_config["selected_device_profile"] = device_catalog.normalize_device_id(
        selected_device_profile
    )
    new_config["voice_hotkey"] = hotkey_text.strip()
    new_config["voice_trigger_mode"] = trigger_mode.value
    new_config["output_endpoint_name"] = endpoint_name
    new_config["output_endpoint_host_api"] = endpoint_host_api

    new_bindings = dict(base_bindings)
    new_bindings["bindings"] = bindings

    return new_config, new_bindings


@dataclass(frozen=True)
class DefaultDisplayState:
    """What "restore defaults" resets every widget to - a pure snapshot, so
    it can be asserted on directly in tests without touching a StringVar.
    """

    button_display_map: Dict[str, str]
    hotkey_text: str
    trigger_mode_label: str


def default_display_state() -> DefaultDisplayState:
    defaults = key_mapping.default_button_actions()
    button_display_map = {
        button_id: _action_to_display(action) for button_id, action in defaults.items()
    }
    for button_id in _USER_FACING_BUTTON_IDS:
        button_display_map.setdefault(button_id, "")
    return DefaultDisplayState(
        button_display_map=button_display_map,
        hotkey_text=hotkey.DEFAULT_VOICE_HOTKEY.serialize(),
        trigger_mode_label=_TRIGGER_MODE_LABELS[key_mapping.VoiceTriggerMode.TOGGLE],
    )


# Bridge-control status text (XRBM-029). Kept as pure, Tk-free functions -
# same testability contract as the save-model helpers above (see
# tests/test_settings_ui_helpers.py) - so every one of the four required
# stable states (not-started / running / already-running / abnormal-quick-
# exit) is asserted on directly without constructing a window or a real
# subprocess.
#
# Wording contract: a STARTED result is deliberately never described as
# "RC003 已连接"/"RC003 connected" - only as the process itself still being
# alive. Whether the bridge actually reached a working BLE/HID/audio
# connection is only observable from app.log, which every branch below
# points the user at.
LAUNCH_NOT_STARTED_TEXT = "未启动（本次设置窗口打开后还没有尝试启动桥接）"


def describe_launch_result(result: bridge_launcher.LaunchResult) -> str:
    if result.outcome is bridge_launcher.LaunchOutcome.STARTED:
        pid_text = f"（PID {result.pid}）" if result.pid is not None else ""
        return (
            f"已启动桥接进程{pid_text}，目前仍在运行。这只说明进程本身存活，"
            "不代表已经与 RC003 建立连接——请用下方“打开日志目录”查看 app.log "
            "确认实际连接、按键与语音状态。"
        )
    if result.outcome is bridge_launcher.LaunchOutcome.ALREADY_RUNNING:
        return (
            "已经在运行：这次启动被单实例保护拒绝，进程立即退出（退出码 "
            f"{result.exit_code}）。不需要再次启动；如需重启，请先从任务管理器结束 "
            "现有 OpenVoiceBridgeRC003 进程，或使用 Start Menu 的“停止”条目/"
            "便携版的手动停止步骤。"
        )
    if result.outcome is bridge_launcher.LaunchOutcome.QUICK_EXIT:
        return (
            f"启动异常：进程在短时间内退出（退出码 {result.exit_code}），可能没有成功"
            "建立 BLE/HID/音频连接。请用下方“打开日志目录”查看 app.log 了解具体原因。"
        )
    # LAUNCH_FAILED
    return (
        f"启动失败：无法创建桥接进程（{result.error}）。请用下方“打开日志目录”查看 "
        "app.log，并确认安装/便携版文件是否完整。"
    )


def describe_log_open_result(result: logging_setup.LogOpenResult) -> str:
    if result.outcome is logging_setup.LogOpenOutcome.OPENED:
        note = ""
        if result.location.status is logging_setup.LogLocationStatus.FILE_MISSING:
            note = "（该目录存在，但 app.log 尚不存在——桥接可能还没有运行过一次，这不是错误。）"
        return f"已打开日志目录：{result.location.directory}{note}"
    if result.outcome is logging_setup.LogOpenOutcome.DIRECTORY_MISSING:
        return (
            f"日志目录尚不存在：{result.location.directory}。这通常表示桥接程序在这台"
            "电脑上还没有运行过；本程序不会为了显示而伪造日志。"
        )
    return f"无法打开日志目录（{result.error}）：{result.location.directory}"


def main() -> None:
    """Launches the Qt Quick/QML settings window (XRBM-030). Imports
    ``qt_settings_app`` lazily so importing THIS module (e.g. from
    ``__main__.py``'s ``--dry-run`` smoke check, or from any test that only
    needs the pure functions above) never requires PySide6 to be installed -
    see ``qt_settings_app.py``'s module docstring for the exact, clear error
    raised here if it is missing.
    """

    from . import qt_settings_app

    qt_settings_app.run_settings_window()


if __name__ == "__main__":
    main()
