import unittest

from ovb_rc003 import (
    audio_output,
    ble_transport_winrt,
    identity,
    raw_input_windows,
    windows_diagnostics as diag,
)


class OsVersionCheckTests(unittest.TestCase):
    def test_non_windows_probe_reports_unsupported(self):
        result = diag.check_os_version(probe=lambda: None)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)
        self.assertEqual(result.group, diag.CheckGroup.ORDINARY_BUTTONS)

    def test_32bit_fails(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=19045, is_64bit=False)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_build_below_1809_fails(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=17134, is_64bit=True)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_build_at_or_above_1809_64bit_passes(self):
        info = diag.WindowsVersionInfo(major=10, minor=0, build=19045, is_64bit=True)
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_exact_minimum_build_passes(self):
        info = diag.WindowsVersionInfo(
            major=10, minor=0, build=diag.MIN_SUPPORTED_BUILD, is_64bit=True
        )
        result = diag.check_os_version(probe=lambda: info)
        self.assertEqual(result.status, diag.CheckStatus.PASS)


class RawInputCheckTests(unittest.TestCase):
    def test_zero_matches_fails(self):
        result = diag.check_raw_input(enumerate_paths=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_exactly_one_match_passes(self):
        result = diag.check_raw_input(enumerate_paths=lambda: ["\\\\?\\HID#VID_2717&PID_32B8#..."])
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_ambiguous_matches_fails(self):
        result = diag.check_raw_input(enumerate_paths=lambda: ["path1", "path2"])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_never_reports_the_device_path_itself(self):
        secret_path = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL"
        for paths in ([secret_path], [secret_path, secret_path + "x"]):
            result = diag.check_raw_input(enumerate_paths=lambda p=paths: p)
            self.assertNotIn(secret_path, result.detail)

    def test_unavailable_off_windows_is_unsupported(self):
        def _raise():
            raise raw_input_windows.RawInputUnavailableError("Raw Input is only available on Windows")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "darwin"):
            result = diag.check_raw_input(enumerate_paths=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_real_failure_on_windows_is_a_fail_not_unsupported(self):
        def _raise():
            raise raw_input_windows.RawInputUnavailableError("GetRawInputDeviceList failed: 1")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_raw_input(enumerate_paths=_raise)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_real_failure_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): a RawInputUnavailableError raised on
        # a real Windows failure path used to have its str(exc) interpolated
        # directly into the CheckResult detail - a backend/injected
        # exception is capable of carrying a real Raw Input device path.
        # Inject sentinels standing in for exactly that and prove neither
        # ever reaches the user-facing detail text, while the result stays
        # a real, actionable FAIL.
        secret_hid_path = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL#{deadbeef-0000}"
        # Deliberately avoids "\Users\" (this project's own boundary-scan
        # personal-path regex, tests/test_boundary_scan_replay.py/
        # build/check-public-boundary.ps1, flags any `<drive>:\Users\...`
        # literal in source, including test fixtures) - a ProgramData-style
        # path still stands in for "a local filesystem path" just as well.
        secret_local_path = r"C:\ProgramData\OpenVoiceBridge\RC003\SecretDeviceCache.db"

        def _raise():
            raise raw_input_windows.RawInputUnavailableError(
                f"GetRawInputDeviceList failed for {secret_hid_path} "
                f"(config at {secret_local_path})"
            )

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_raw_input(enumerate_paths=_raise)

        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertNotIn(secret_hid_path, result.detail)
        self.assertNotIn(secret_local_path, result.detail)
        self.assertNotIn("SecretDeviceCache", result.detail)
        self.assertNotIn("SUPERSECRETSERIAL", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("Raw Input", result.detail)


class BleCandidateCheckTests(unittest.TestCase):
    def test_no_candidates_fails(self):
        result = diag.check_ble_candidate(discover=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertEqual(result.group, diag.CheckGroup.VOICE_BRIDGE)

    def test_exactly_one_matching_candidate_passes(self):
        candidates = [identity.RC003Candidate(name="Mi RC", hardware_match=False)]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.PASS)

    def test_ambiguous_candidates_fails(self):
        candidates = [
            identity.RC003Candidate(name="Mi RC", hardware_match=False),
            identity.RC003Candidate(name="MI RC", hardware_match=False),
        ]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_non_matching_candidate_is_treated_as_no_candidate(self):
        candidates = [identity.RC003Candidate(name="Some Other Device", hardware_match=False)]
        result = diag.check_ble_candidate(discover=lambda: candidates)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_winrt_unavailable_off_windows_is_unsupported(self):
        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError("winrt not installed")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "darwin"):
            result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_winrt_unavailable_on_windows_is_still_unsupported_not_fail(self):
        # A missing optional dependency is not a real hardware/config
        # failure - it means this Windows machine never installed the
        # winrt packages at all, which the diagnostics page cannot fix.
        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError("winrt not installed")

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)

    def test_unexpected_exception_is_a_fail_not_a_crash(self):
        def _raise():
            raise RuntimeError("boom")

        result = diag.check_ble_candidate(discover=_raise)
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_winrt_unavailable_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): WinRTUnavailableError's real
        # production message is API-only today, but a dependency-
        # unavailable exception must not be trusted to stay that way
        # forever - inject a sentinel standing in for a leaked identifier
        # and prove it never reaches the detail text, status unchanged.
        #
        # Uses this project's own established MAC-address placeholder
        # ("AA:BB:CC:DD:EE:FF" - see tests/test_config.py and
        # tests/test_boundary_scan_replay.py's _MAC_ADDRESS_PLACEHOLDER)
        # rather than an arbitrary MAC-shaped literal: any OTHER
        # MAC-address-shaped string here would itself trip this project's
        # own public-boundary privacy scan on this test file - the exact
        # kind of accidental-identifier-in-source mistake that scan exists
        # to catch, which a test about NOT leaking identifiers should
        # obviously not commit either.
        secret_ble_address = "AA:BB:CC:DD:EE:FF (小米蓝牙遥控器 2 Pro)"

        def _raise():
            raise ble_transport_winrt.WinRTUnavailableError(
                f"winrt lookup failed for paired device {secret_ble_address}"
            )

        import sys
        import unittest.mock as mock

        with mock.patch.object(sys, "platform", "win32"):
            result = diag.check_ble_candidate(discover=_raise)

        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)
        self.assertNotIn(secret_ble_address, result.detail)
        self.assertNotIn("AA:BB:CC:DD:EE:FF", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("WinRT", result.detail)

    def test_unexpected_exception_message_never_echoes_the_raw_exception_text(self):
        # RETRY 3 (independent review): an unexpected exception surfacing
        # from WinRT/BLE plumbing could carry a real Bluetooth address,
        # device name, or local path in its own message - inject sentinels
        # for all three and prove none of them reach the detail text. See
        # the sibling WinRT test above for why the MAC-shaped sentinel is
        # this project's own established placeholder value, and why the
        # local-path sentinel avoids "\Users\" (this project's own
        # boundary-scan personal-path regex).
        secret_ble_address = "AA:BB:CC:DD:EE:FF"
        secret_device_name = "小米蓝牙遥控器 2 Pro"
        secret_local_path = r"C:\ProgramData\OpenVoiceBridge\RC003\SecretDeviceCache.db"

        def _raise():
            raise RuntimeError(
                f"failed to open device {secret_ble_address} "
                f"({secret_device_name}) using config at {secret_local_path}"
            )

        result = diag.check_ble_candidate(discover=_raise)

        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertNotIn(secret_ble_address, result.detail)
        self.assertNotIn(secret_device_name, result.detail)
        self.assertNotIn(secret_local_path, result.detail)
        self.assertNotIn("SecretDeviceCache", result.detail)
        self.assertTrue(result.detail.strip())
        self.assertIn("BLE", result.detail)


class VbCableEndpointsCheckTests(unittest.TestCase):
    def test_both_present_passes(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
            list_recording=lambda: [audio_output.AudioEndpoint(name="CABLE Output")],
        )
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertEqual(result.group, diag.CheckGroup.OPTIONAL_DRIVER)

    def test_neither_present_fails_but_is_optional(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")],
            list_recording=lambda: [audio_output.AudioEndpoint(name="Microphone")],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("可选", result.detail)

    def test_only_playback_present_fails_with_specific_missing_note(self):
        result = diag.check_vb_cable_endpoints(
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
            list_recording=lambda: [],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("CABLE Output", result.detail)

    def test_enumeration_failure_is_unsupported(self):
        def _raise():
            raise audio_output.AudioOutputUnavailableError("no sounddevice")

        result = diag.check_vb_cable_endpoints(list_playback=_raise, list_recording=lambda: [])
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)


class OutputEndpointResolutionCheckTests(unittest.TestCase):
    def test_resolves_to_cable_input_passes_with_positive_note(self):
        result = diag.check_output_endpoint_resolution(
            "CABLE Input", "",
            list_playback=lambda: [audio_output.AudioEndpoint(name="CABLE Input")],
        )
        self.assertEqual(result.status, diag.CheckStatus.PASS)
        self.assertIn("CABLE Input", result.detail)

    def test_resolves_to_non_cable_endpoint_fails_with_actionable_text(self):
        # RETRY 1 (independent review): this used to assert PASS here - a
        # false green readiness signal for the bundled VB-CABLE workflow
        # (taskbook line 77 requires the saved endpoint to point to CABLE
        # Input for that workflow). A real, present, non-CABLE endpoint is
        # a legitimate FAIL for this check, not a quieter kind of success.
        result = diag.check_output_endpoint_resolution(
            "Speakers", "",
            list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")],
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)
        self.assertIn("不是 CABLE Input", result.detail)
        self.assertIn("选择检测到的", result.detail)

    def test_empty_selection_fails(self):
        result = diag.check_output_endpoint_resolution(
            "", "", list_playback=lambda: [audio_output.AudioEndpoint(name="Speakers")]
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_missing_endpoint_fails_closed(self):
        result = diag.check_output_endpoint_resolution(
            "Gone Device", "", list_playback=lambda: []
        )
        self.assertEqual(result.status, diag.CheckStatus.FAIL)

    def test_enumeration_failure_is_unsupported(self):
        def _raise():
            raise audio_output.AudioOutputUnavailableError("no sounddevice")

        result = diag.check_output_endpoint_resolution("x", "", list_playback=_raise)
        self.assertEqual(result.status, diag.CheckStatus.UNSUPPORTED)


class DictationCheckTests(unittest.TestCase):
    def test_always_manual_never_fabricates_a_verdict(self):
        result = diag.check_dictation_manual()
        self.assertEqual(result.status, diag.CheckStatus.MANUAL)
        self.assertEqual(result.group, diag.CheckGroup.DICTATION)
        self.assertIn("Win+H", result.detail)


class RunDiagnosticsOrchestrationTests(unittest.TestCase):
    def test_returns_all_six_checks_with_stable_ids(self):
        report = diag.run_diagnostics()
        ids = {check.check_id for check in report.checks}
        self.assertEqual(
            ids,
            {
                "os_version",
                "raw_input",
                "ble_candidate",
                "vb_cable_endpoints",
                "output_endpoint",
                "dictation",
            },
        )

    def test_get_looks_up_by_id(self):
        report = diag.run_diagnostics()
        self.assertIsNotNone(report.get("dictation"))
        self.assertIsNone(report.get("nonexistent"))

    def test_source_environment_checks_degrade_to_unsupported_not_pass(self):
        # This test suite's own host is not Windows (or, even if it somehow
        # were, has no RC003/VB-CABLE attached) - the real, uninjected
        # checks must never claim PASS for something they cannot observe.
        report = diag.run_diagnostics()
        for check_id in ("ble_candidate", "raw_input"):
            result = report.get(check_id)
            self.assertIn(
                result.status,
                (diag.CheckStatus.UNSUPPORTED, diag.CheckStatus.FAIL),
                f"{check_id} unexpectedly reported {result.status} on a non-real-hardware host",
            )


class RunDiagnosticsIsolationTests(unittest.TestCase):
    """XRBM-031 RETRY 1 item 2: an unexpected exception from any ONE check
    function must never abort run_diagnostics() or leave the other five
    checks missing - it becomes only that check's own honest FAIL result.
    """

    def test_unexpected_exception_in_one_check_isolates_to_that_check_only(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        with mock.patch.object(
            module, "check_ble_candidate", side_effect=RuntimeError("boom")
        ):
            report = module.run_diagnostics()

        self.assertEqual(len(report.checks), 6)
        failed = report.get("ble_candidate")
        self.assertEqual(failed.status, diag.CheckStatus.FAIL)
        self.assertEqual(failed.group, diag.CheckGroup.VOICE_BRIDGE)
        self.assertNotIn("boom", failed.detail)
        # The other five checks still render their own real result -
        # nothing else was aborted or left missing.
        other_ids = {"os_version", "raw_input", "vb_cable_endpoints", "output_endpoint", "dictation"}
        self.assertEqual({c.check_id for c in report.checks} - {"ble_candidate"}, other_ids)
        for check_id in other_ids:
            result = report.get(check_id)
            self.assertIsNotNone(result)
            self.assertIsInstance(result.status, diag.CheckStatus)

    def test_unexpected_exception_never_leaks_into_the_detail_text(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        secret = "\\\\?\\HID#VID_2717&PID_32B8#SUPERSECRETSERIAL"

        with mock.patch.object(
            module, "check_raw_input", side_effect=RuntimeError(secret)
        ):
            report = module.run_diagnostics()

        self.assertNotIn(secret, report.get("raw_input").detail)
        self.assertEqual(report.get("raw_input").status, diag.CheckStatus.FAIL)

    def test_multiple_simultaneous_unexpected_failures_each_isolate_independently(self):
        import unittest.mock as mock

        from ovb_rc003 import windows_diagnostics as module

        with mock.patch.object(module, "check_os_version", side_effect=RuntimeError("a")):
            with mock.patch.object(module, "check_dictation_manual", side_effect=RuntimeError("b")):
                report = module.run_diagnostics()

        self.assertEqual(len(report.checks), 6)
        self.assertEqual(report.get("os_version").status, diag.CheckStatus.FAIL)
        self.assertEqual(report.get("dictation").status, diag.CheckStatus.FAIL)
        # Untouched checks are unaffected.
        self.assertIsNotNone(report.get("ble_candidate"))


if __name__ == "__main__":
    unittest.main()
