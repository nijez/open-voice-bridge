"""Qt-free "检查与修复" (check-and-repair) diagnostics (XRBM-031).

Every check below is a plain function returning a typed, stable
``CheckResult`` - no Tk/Qt import anywhere in this module, matching this
package's existing convention (``settings_ui.py``, ``remote_layout.py``,
``shell_targets.py``) of keeping business logic directly unit-testable
without constructing a window. ``qt_settings_app.py`` is the only place that
runs ``run_diagnostics()`` off the Qt GUI thread and renders its results.

Every check that touches a real OS/WinRT/PortAudio call accepts an
injectable override (a ``probe``/``discover``/``enumerate_*`` callable) so
its PASS/FAIL/MANUAL branching is exercised directly in tests on any OS,
while the real, uninjected default degrades to ``UNSUPPORTED`` off Windows
or when an optional dependency is missing - it never fabricates a result it
cannot actually observe (In-scope item 2/4's core honesty contract: a live
process or a paired device must never be reported as proof that buttons or
speech are working).

Raw Input and BLE candidate checks deliberately report only a COUNT/status,
never a device path or Bluetooth name/address - this module must not become
a second place that leaks the identifiers ``config.py``/``logging_setup.py``
already refuse to persist.
"""

from __future__ import annotations

import platform
import sys
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Optional, Sequence, Tuple

from . import audio_output
from . import ble_transport_winrt
from . import identity
from . import raw_input_windows

# Windows 10 version 1809's build number - the lowest build this project's
# own README/installer already claim as the supported floor (see
# installer/OpenVoiceBridgeRC003Setup.iss's ``MinVersion=10.0.17763``).
MIN_SUPPORTED_BUILD = 17763


class CheckStatus(Enum):
    PASS = "pass"
    FAIL = "fail"
    MANUAL = "manual"  # 待手动验证：Windows exposes no reliable automatic verdict
    UNSUPPORTED = "unsupported"  # not Windows, or a required dependency is missing


class CheckGroup(Enum):
    """The four groups In-scope item 4 requires the summary to distinguish
    - never collapsed into one another, since a passing optional-driver
    check must never look like proof that voice or dictation works.
    """

    ORDINARY_BUTTONS = "ordinary_buttons"
    VOICE_BRIDGE = "voice_bridge"
    DICTATION = "dictation"
    OPTIONAL_DRIVER = "optional_driver"


@dataclass(frozen=True)
class CheckResult:
    check_id: str
    title: str
    group: CheckGroup
    status: CheckStatus
    detail: str


@dataclass(frozen=True)
class DiagnosticsReport:
    checks: Tuple[CheckResult, ...]

    def get(self, check_id: str) -> Optional[CheckResult]:
        for check in self.checks:
            if check.check_id == check_id:
                return check
        return None


# -- OS version/architecture ------------------------------------------------


@dataclass(frozen=True)
class WindowsVersionInfo:
    major: int
    minor: int
    build: int
    is_64bit: bool


def _probe_windows_version() -> Optional[WindowsVersionInfo]:
    """Real probe: None off Windows. Never raises."""

    if sys.platform != "win32":
        return None
    version_info = sys.getwindowsversion()  # type: ignore[attr-defined]
    is_64bit = platform.machine().lower() in ("amd64", "x86_64", "arm64")
    return WindowsVersionInfo(
        major=version_info.major,
        minor=version_info.minor,
        build=version_info.build,
        is_64bit=is_64bit,
    )


def check_os_version(
    *, probe: Callable[[], Optional[WindowsVersionInfo]] = _probe_windows_version
) -> CheckResult:
    version_info = probe()
    if version_info is None:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.UNSUPPORTED,
            "当前不是 Windows，无法核验版本/位数契约。",
        )
    if not version_info.is_64bit:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "检测到非 64 位系统；本程序需要 64 位 Windows 10 1809 (17763) 或以上。",
        )
    if version_info.build < MIN_SUPPORTED_BUILD:
        return CheckResult(
            "os_version",
            "Windows 版本与 64 位架构",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            f"当前 build {version_info.build} 低于 Windows 10 1809 "
            f"({MIN_SUPPORTED_BUILD}) 的支持下限。",
        )
    return CheckResult(
        "os_version",
        "Windows 版本与 64 位架构",
        CheckGroup.ORDINARY_BUTTONS,
        CheckStatus.PASS,
        f"Windows build {version_info.build}，64 位，满足 1809+ 契约。",
    )


# -- Raw Input (ordinary buttons) -------------------------------------------


def check_raw_input(
    *,
    enumerate_paths: Callable[
        [], Sequence[str]
    ] = raw_input_windows.enumerate_matching_device_paths,
) -> CheckResult:
    try:
        paths = enumerate_paths()
    except raw_input_windows.RawInputUnavailableError:
        if sys.platform != "win32":
            return CheckResult(
                "raw_input",
                "Raw Input 按键设备",
                CheckGroup.ORDINARY_BUTTONS,
                CheckStatus.UNSUPPORTED,
                "当前不是 Windows，无法枚举 Raw Input 设备。",
            )
        # RETRY 3 (independent review): this used to interpolate str(exc)
        # here. RawInputUnavailableError's real production message is
        # API-only today, but nothing stops a future/injected raise from
        # carrying a real Raw Input device path in its message - and this
        # module's own contract (see module docstring) is that Raw Input
        # output never surfaces an identifier, not "never surfaces one
        # unless the exception happens to be safe". Generic and actionable
        # instead, with no exception text at all.
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "Raw Input 设备枚举失败，出现意外错误；请检查遥控器连接后点击"
            "「重新检测」重试。",
        )

    count = len(paths)
    # Never report the path itself - count/status only (In-scope item 2).
    if count == 0:
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            "未发现匹配 RC003 VID/PID 的 Raw Input 设备；请先在 Windows 蓝牙设置中配对。",
        )
    if count > 1:
        return CheckResult(
            "raw_input",
            "Raw Input 按键设备",
            CheckGroup.ORDINARY_BUTTONS,
            CheckStatus.FAIL,
            f"发现 {count} 个匹配设备，无法唯一确定；请仅保留一个已连接设备后重试。",
        )
    return CheckResult(
        "raw_input",
        "Raw Input 按键设备",
        CheckGroup.ORDINARY_BUTTONS,
        CheckStatus.PASS,
        "发现恰好一个匹配的 Raw Input 设备。",
    )


# -- BLE candidate (voice bridge) -------------------------------------------


def _discover_ble_candidates_sync() -> Sequence[identity.RC003Candidate]:
    """Real probe: runs the existing async WinRT discovery path to
    completion via ``asyncio.run()`` (which always creates and closes its
    own event loop, so nothing is left running afterward) - this is the same
    ``discover_candidates()`` app.py itself uses, not a second, independently
    written discovery path.
    """

    import asyncio

    return asyncio.run(ble_transport_winrt.discover_candidates())


def check_ble_candidate(
    *,
    discover: Callable[
        [], Sequence[identity.RC003Candidate]
    ] = _discover_ble_candidates_sync,
) -> CheckResult:
    try:
        candidates = list(discover())
    except ble_transport_winrt.WinRTUnavailableError:
        if sys.platform != "win32":
            return CheckResult(
                "ble_candidate",
                "已配对的 RC003 (BLE)",
                CheckGroup.VOICE_BRIDGE,
                CheckStatus.UNSUPPORTED,
                "当前不是 Windows，无法枚举已配对的 BLE 候选。",
            )
        # RETRY 3 (independent review): this used to interpolate str(exc)
        # here. The real production message this raises today is API-only,
        # but a dependency-unavailable exception must never be trusted to
        # stay that way forever - use a fixed, generic message so a future
        # change to that exception's text can never smuggle a Bluetooth
        # address/name/identifier into this module's own output (the one
        # thing its docstring promises never happens).
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.UNSUPPORTED,
            "WinRT 蓝牙依赖不可用；请确认已按 requirements.txt 安装 winrt 组件后重试。",
        )
    except Exception:  # noqa: BLE001 - report, never crash the diagnostics page
        # RETRY 3 (independent review): a genuinely unexpected exception
        # here could be raised by WinRT/BLE plumbing carrying a real
        # Bluetooth address, device name, or other identifier in its
        # message - never interpolate it, matching this module's own
        # never-surface-an-identifier contract.
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "BLE 候选枚举失败，出现意外错误；请点击「重新检测」重试。",
        )

    try:
        identity.select_single_candidate(candidates)
    except identity.NoCandidateFoundError:
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            "未发现已配对的 RC003；请在 Windows 蓝牙设置中完成配对后重试。",
        )
    except identity.AmbiguousCandidateError as exc:
        return CheckResult(
            "ble_candidate",
            "已配对的 RC003 (BLE)",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            f"发现 {exc.count} 个候选，无法唯一确定；请仅保留一个已配对设备后重试。",
        )
    return CheckResult(
        "ble_candidate",
        "已配对的 RC003 (BLE)",
        CheckGroup.VOICE_BRIDGE,
        CheckStatus.PASS,
        "发现恰好一个已配对的 RC003 候选。",
    )


# -- VB-CABLE endpoints (optional driver) -----------------------------------


def check_vb_cable_endpoints(
    *,
    list_playback: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_output_endpoints,
    list_recording: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_input_endpoints,
) -> CheckResult:
    try:
        playback = list(list_playback())
        recording = list(list_recording())
    except audio_output.AudioOutputUnavailableError as exc:
        return CheckResult(
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            CheckStatus.UNSUPPORTED,
            f"无法枚举音频端点：{exc}",
        )

    has_input = any(audio_output.is_cable_input_endpoint(e.name) for e in playback)
    has_output = any(audio_output.is_cable_output_endpoint(e.name) for e in recording)

    if has_input and has_output:
        return CheckResult(
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            CheckStatus.PASS,
            "已发现 CABLE Input（播放）与 CABLE Output（录音）两个端点。",
        )
    missing = []
    if not has_input:
        missing.append("CABLE Input（播放）")
    if not has_output:
        missing.append("CABLE Output（录音）")
    return CheckResult(
        "vb_cable_endpoints",
        "VB-CABLE 虚拟音频端点（可选）",
        CheckGroup.OPTIONAL_DRIVER,
        CheckStatus.FAIL,
        "尚未发现：" + "、".join(missing) + "。这是可选项——不安装 VB-CABLE 时，"
        "普通按键仍然正常工作，只有把 RC003 语音当作系统麦克风使用时才需要它。",
    )


# -- Output endpoint resolution (voice bridge) ------------------------------


def check_output_endpoint_resolution(
    saved_name: str,
    saved_host_api: str,
    *,
    list_playback: Callable[
        [], Sequence[audio_output.AudioEndpoint]
    ] = audio_output.enumerate_output_endpoints,
) -> CheckResult:
    try:
        endpoints = list(list_playback())
    except audio_output.AudioOutputUnavailableError as exc:
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.UNSUPPORTED,
            f"无法枚举播放端点：{exc}",
        )

    try:
        endpoint = audio_output.resolve_selected_endpoint(
            endpoints, saved_name, saved_host_api
        )
    except audio_output.AudioOutputUnavailableError as exc:
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.FAIL,
            str(exc),
        )

    if audio_output.is_cable_input_endpoint(endpoint.name):
        return CheckResult(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            CheckStatus.PASS,
            f"已选择端点 {endpoint.name!r} 存在，且为 CABLE Input（VB-CABLE 语音链路）。",
        )
    # RETRY 1 (independent review): resolving to a real but non-CABLE-Input
    # endpoint used to still return PASS here - a false green readiness
    # signal for the bundled VB-CABLE workflow this page exists to support
    # (taskbook line 77: "...points to CABLE Input when the bundled driver
    # workflow is used"). This check exists specifically to gate that
    # workflow's readiness, so anything other than CABLE Input is FAIL with
    # actionable text, not a second, quieter kind of success.
    return CheckResult(
        "output_endpoint",
        "语音输出端点",
        CheckGroup.VOICE_BRIDGE,
        CheckStatus.FAIL,
        f"已选择端点 {endpoint.name!r} 存在，但不是 CABLE Input——如果计划使用"
        "本页的 VB-CABLE 语音链路，需要在「检查与修复」页点击「选择检测到的 "
        "CABLE Input 作为输出」，或在「连接」页手动改选 CABLE Input。",
    )


# -- Windows dictation / Win+H (always manual) ------------------------------


def check_dictation_manual() -> CheckResult:
    return CheckResult(
        "dictation",
        "Windows 听写 (Win+H)",
        CheckGroup.DICTATION,
        CheckStatus.MANUAL,
        "Windows 未公开一个可核验听写是否可用的 API，这里不能给出自动结论。"
        "请手动验证：打开记事本等可编辑文本框并点入光标，确认已启用「联机语音"
        "识别」（Windows 11：设置 → 隐私和安全性 → 语音；Windows 10：设置 → "
        "隐私 → 语音），按一次 Win+H，说话后确认文字被输入。",
    )


# -- Orchestration -----------------------------------------------------------


def _isolated(
    check_id: str, title: str, group: CheckGroup, run: Callable[[], CheckResult]
) -> CheckResult:
    """Runs one check function, isolated from every other one (XRBM-031
    RETRY 1 item 2): each ``check_*`` function above already anticipates
    and handles its own documented failure modes (``AudioOutputUnavailableError``,
    ``WinRTUnavailableError``, etc.), but this is the outer safety net for
    whatever it does NOT anticipate - a genuinely unexpected exception type
    must become this ONE check's own honest ``FAIL`` result, with a generic
    detail that never echoes the raw exception text (which could otherwise
    leak a device identifier/path this project's privacy contract forbids
    surfacing), rather than aborting ``run_diagnostics()`` entirely and
    leaving every OTHER check's result missing/stale.
    """

    try:
        return run()
    except Exception:  # noqa: BLE001 - the entire purpose of this wrapper
        return CheckResult(
            check_id,
            title,
            group,
            CheckStatus.FAIL,
            "该检测项出现意外错误，未能得出结论；其他检测项结果不受影响，可点击"
            "「重新检测」重试。",
        )


def run_diagnostics(
    *,
    saved_output_name: str = "",
    saved_output_host_api: str = "",
) -> DiagnosticsReport:
    """Runs every check and returns a stable report. Pure aside from the
    real OS/WinRT/PortAudio calls each check function makes on Windows;
    intended to be called from a background thread (see
    ``qt_settings_app.DiagnosticsController``), never on the Qt GUI thread.

    Every check is isolated (see ``_isolated()``): one check's unexpected
    failure can never prevent the other five from rendering their own real
    result.
    """

    checks = (
        _isolated("os_version", "Windows 版本与 64 位架构", CheckGroup.ORDINARY_BUTTONS, check_os_version),
        _isolated("raw_input", "Raw Input 按键设备", CheckGroup.ORDINARY_BUTTONS, check_raw_input),
        _isolated("ble_candidate", "已配对的 RC003 (BLE)", CheckGroup.VOICE_BRIDGE, check_ble_candidate),
        _isolated(
            "vb_cable_endpoints",
            "VB-CABLE 虚拟音频端点（可选）",
            CheckGroup.OPTIONAL_DRIVER,
            check_vb_cable_endpoints,
        ),
        _isolated(
            "output_endpoint",
            "语音输出端点",
            CheckGroup.VOICE_BRIDGE,
            lambda: check_output_endpoint_resolution(saved_output_name, saved_output_host_api),
        ),
        _isolated("dictation", "Windows 听写 (Win+H)", CheckGroup.DICTATION, check_dictation_manual),
    )
    return DiagnosticsReport(checks=checks)
