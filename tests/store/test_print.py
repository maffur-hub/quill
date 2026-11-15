"""Contract tests for scripts/quill-print.

Every case runs against stub ``lpstat`` and ``lp`` executables placed at the
front of ``PATH``, plus a fake Node PDF renderer, so the suite never contacts a
real CUPS queue and never starts a print job. Each test owns a disposable
TemporaryDirectory; the live data directory is never touched.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PRINT = ROOT / "scripts" / "quill-print"
NODE = shutil.which("node")
PRINTER = "EPSON_ET_8500"


@unittest.skipUnless(NODE, "node is not installed")
class PrintTestCase(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="quill-print-test-")
        self.folder = Path(self._temp.name)
        self.bin = self.folder / "bin"
        self.bin.mkdir()
        self.empty_bin = self.folder / "empty-bin"
        self.empty_bin.mkdir()
        self.log = self.folder / "stub.log"
        self.renderer = self.folder / "renderer.js"
        self.failing_renderer = self.folder / "failing-renderer.js"
        self.states_path = self.folder / "lpstat-p.txt"
        self.print_options_path = self.folder / "lpoptions.txt"
        self.write_states(
            f"printer {PRINTER} is idle.  enabled since Sat 24 Oct 2026 10:10:15\n"
        )
        self.write_print_options(
            "PageSize/Media Size: *A4 Letter A5\n"
            "ColorModel/Output Mode: *RGB Gray\n"
            "Duplex/Duplex: *None DuplexNoTumble DuplexTumble\n"
            "cupsPrintQuality/cupsPrintQuality: Draft *Normal High\n"
            "MediaType/Media Type: *Stationery Photographic\n"
        )
        self.write_stubs()
        self.note_path = self.note()
        self.env = dict(os.environ)
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env.get("PATH", "")
        self.env["STUB_LOG"] = str(self.log)
        self.env["STUB_PRINTER"] = PRINTER
        self.env["STUB_DEFAULT"] = PRINTER
        self.env["STUB_STATES"] = str(self.states_path)
        self.env["STUB_PRINTER_OPTIONS"] = str(self.print_options_path)

    def tearDown(self):
        self._temp.cleanup()

    # -- process helpers ---------------------------------------------------

    def run_print(self, *args, env=None):
        return subprocess.run(
            [NODE, str(PRINT), *[str(arg) for arg in args]],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(ROOT),
            env=env or self.env,
        )

    def success(self, *args, env=None):
        process = self.run_print(*args, env=env)
        self.assertEqual(
            process.returncode, 0,
            f"{args} failed: {process.stderr.strip()}",
        )
        self.assertEqual(process.stderr, "", f"{args} wrote to stderr")
        lines = process.stdout.splitlines()
        self.assertEqual(len(lines), 1, f"{args} did not print exactly one line")
        value = json.loads(lines[0])
        self.assertIsInstance(value, dict)
        self.assertTrue(value.get("ok"))
        return value

    def failure(self, *args, code=1, prefix="quill-print:"):
        process = self.run_print(*args)
        self.assertEqual(process.returncode, code, f"{args} exited wrongly")
        self.assertEqual(process.stdout, "", f"{args} wrote to stdout")
        self.assertTrue(
            process.stderr.startswith(prefix),
            f"{args} stderr: {process.stderr!r}",
        )
        return process.stderr

    # -- fixture helpers ---------------------------------------------------

    def note(self, name="note.md"):
        path = self.folder / name
        path.write_text("# Note\n\nbody\n", encoding="utf-8")
        return path

    def write_states(self, text):
        self.states_path.write_text(text, encoding="utf-8")
        return self.states_path

    def write_print_options(self, text):
        self.print_options_path.write_text(text, encoding="utf-8")
        return self.print_options_path

    def write_executable(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        return path

    def write_stubs(self):
        self.write_executable("lpstat", """#!/bin/sh
{
  echo LPSTAT
  printf '%s\\n' "$@"
} >> "$STUB_LOG"
case "$1" in
  -d) printf 'system default destination: %s\\n' "$STUB_DEFAULT" ;;
  -p) cat "$STUB_STATES" ;;
  *) printf '%s accepting requests since Sat 24 Oct 2026 10:10:15\\n' "$STUB_PRINTER" ;;
esac
""")
        self.write_executable("lp", """#!/bin/sh
{
  echo LP
  printf '%s\\n' "$@"
} >> "$STUB_LOG"
printf 'request id is %s-42 (1 file(s))\\n' "$STUB_PRINTER"
""")
        self.write_executable("lpoptions", """#!/bin/sh
{
  echo LPOPTIONS
  printf '%s\\n' "$@"
} >> "$STUB_LOG"
cat "$STUB_PRINTER_OPTIONS"
""")
        self.renderer.write_text(
            """const fs = require("fs")
const args = process.argv.slice(2)
fs.appendFileSync(process.env.STUB_LOG, "RENDERER\\n" + args.join("\\n") + "\\n")
let output = ""
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--output") output = args[i + 1]
}
if (!output) {
  process.stderr.write("no --output\\n")
  process.exit(1)
}
const body = "%PDF-1.4\\n" + "0".repeat(600) + "\\n%%EOF\\n"
fs.writeFileSync(output, body)
""",
            encoding="utf-8",
        )
        self.failing_renderer.write_text(
            """process.stderr.write("renderer exploded\\n")
process.exit(1)
""",
            encoding="utf-8",
        )

    def records(self):
        if not self.log.exists():
            return []
        records = []
        current = None
        for line in self.log.read_text(encoding="utf-8").splitlines():
            if line in {"LP", "LPSTAT", "LPOPTIONS", "RENDERER"}:
                current = (line, [])
                records.append(current)
            elif current is not None:
                current[1].append(line)
        return records

    def lp_calls(self):
        return [args for kind, args in self.records() if kind == "LP"]

    def lpoptions_calls(self):
        return [args for kind, args in self.records() if kind == "LPOPTIONS"]

    def renderer_calls(self):
        return [args for kind, args in self.records() if kind == "RENDERER"]

    def option(self, args, flag):
        index = args.index(flag)
        return args[index + 1]

    # -- tests -------------------------------------------------------------

    def test_list_reports_the_default_printer(self):
        result = self.success("--list")
        self.assertTrue(result["cups"])
        self.assertEqual(result["default"], PRINTER)
        self.assertEqual(
            result["printers"],
            [{"name": PRINTER, "accepting": True, "state": "idle", "detail": ""}],
        )

    def test_list_reports_a_printing_printer_with_its_detail(self):
        self.write_states(
            f"printer {PRINTER} now printing {PRINTER}-3."
            "  enabled since Sat 14 Nov 2026 15:18:23\n"
            "\tThe printer may not exist or is unavailable at this time.\n"
        )
        result = self.success("--list")
        printer = result["printers"][0]
        self.assertEqual(printer["state"], "printing")
        self.assertEqual(
            printer["detail"],
            "The printer may not exist or is unavailable at this time.",
        )

    def test_list_reports_a_disabled_printer(self):
        self.write_states(
            f"printer {PRINTER} disabled since Sat 14 Nov 2026 15:18:23 -\n"
            "\t/cups missing\n"
        )
        result = self.success("--list")
        self.assertEqual(result["printers"][0]["state"], "disabled")

    def test_list_ignores_the_benign_waiting_detail(self):
        self.write_states(
            f"printer {PRINTER} is idle.  enabled since Sat 14 Nov 2026 15:18:39\n"
            "\tWaiting for job to complete.\n"
        )
        result = self.success("--list")
        self.assertEqual(result["printers"][0]["state"], "idle")
        self.assertEqual(result["printers"][0]["detail"], "")

    def test_list_keeps_a_genuine_detail_on_an_idle_queue(self):
        self.write_states(
            f"printer {PRINTER} is idle.  enabled since Sat 14 Nov 2026 15:18:39\n"
            "\tgstoraster filter failed.\n"
        )
        result = self.success("--list")
        self.assertEqual(
            result["printers"][0]["detail"], "gstoraster filter failed."
        )

    def test_list_printer_absent_from_p_has_unknown_state(self):
        env = dict(self.env)
        env["STUB_PRINTER"] = "Office"
        result = self.success("--list", env=env)
        self.assertEqual(
            result["printers"],
            [{"name": "Office", "accepting": True, "state": "", "detail": ""}],
        )

    def test_list_without_lpstat_reports_no_printers(self):
        env = dict(self.env)
        env["PATH"] = str(self.empty_bin)
        result = self.success("--list", env=env)
        self.assertFalse(result["cups"])
        self.assertEqual(result["default"], "")
        self.assertEqual(result["printers"], [])

    def test_list_reports_the_whitelisted_print_options(self):
        result = self.success("--list")
        options = result["options"]
        self.assertEqual(
            [option["key"] for option in options],
            ["PageSize", "ColorModel", "Duplex", "cupsPrintQuality"],
        )
        self.assertEqual(
            [option["label"] for option in options],
            ["Paper", "Colour", "Two-sided", "Quality"],
        )
        self.assertEqual(
            options[0],
            {
                "key": "PageSize",
                "label": "Paper",
                "values": ["A4", "Letter", "A5"],
                "default": "A4",
            },
        )
        self.assertEqual(
            [option["default"] for option in options],
            ["A4", "RGB", "None", "Normal"],
        )
        self.assertNotIn(
            "MediaType", [option["key"] for option in options],
        )

    def test_list_explicit_printer_reports_its_options(self):
        result = self.success("--list", "--printer", "Office")
        self.assertEqual(result["default"], PRINTER)
        self.assertEqual(
            [option["key"] for option in result["options"]],
            ["PageSize", "ColorModel", "Duplex", "cupsPrintQuality"],
        )
        calls = self.lpoptions_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0], ["-p", "Office", "-l"])

    def test_list_curates_paper_to_the_shortlist_in_order(self):
        self.write_print_options(
            "PageSize/Media Size: *A4 4x6 Letter 101.6x180.6mm "
            "A4.Borderless A5.Borderless 5x7\n"
        )
        result = self.success("--list")
        paper = result["options"][0]
        self.assertEqual(paper["key"], "PageSize")
        self.assertEqual(paper["values"], ["A4", "Letter", "4x6", "5x7"])

    def test_list_keeps_an_unsupported_default_first(self):
        self.write_print_options(
            "PageSize/Media Size: A4 Letter *A4.Borderless\n"
        )
        result = self.success("--list")
        paper = result["options"][0]
        self.assertEqual(paper["values"], ["A4.Borderless", "A4", "Letter"])
        self.assertEqual(paper["default"], "A4.Borderless")

    def test_list_falls_back_to_the_full_paper_list(self):
        self.write_print_options(
            "PageSize/Media Size: *215x345mm 101.6x180.6mm Custom.WIDTHxHEIGHT\n"
        )
        result = self.success("--list")
        paper = result["options"][0]
        self.assertEqual(paper["values"], ["215x345mm", "101.6x180.6mm"])

    def test_list_without_lpoptions_has_empty_options(self):
        # A PATH with lpstat and lp but no lpoptions, so the real tool cannot
        # answer when the stub is absent. The stubs use shell builtins only,
        # because this PATH has no /bin either.
        no_options = self.folder / "no-lpoptions-bin"
        no_options.mkdir()
        (no_options / "lpstat").write_text(f"""#!/bin/sh
case "$1" in
  -d) echo "system default destination: {PRINTER}" ;;
  -p) echo "printer {PRINTER} is idle.  enabled since Sat 24 Oct 2026 10:10:15" ;;
  *) echo "{PRINTER} accepting requests since Sat 24 Oct 2026 10:10:15" ;;
esac
""")
        (no_options / "lpstat").chmod(0o755)
        env = dict(self.env)
        env["PATH"] = str(no_options)
        result = self.success("--list", env=env)
        self.assertTrue(result["cups"])
        self.assertEqual(result["default"], PRINTER)
        self.assertEqual(
            result["printers"],
            [{"name": PRINTER, "accepting": True, "state": "idle", "detail": ""}],
        )
        self.assertEqual(result["options"], [])

    def test_print_to_the_default_printer(self):
        result = self.success("--input", self.note_path, "--title", "Daily notes")
        self.assertEqual(result["printer"], PRINTER)
        self.assertEqual(result["job"], "42")
        self.assertGreater(result["bytes"], 0)
        self.assertNotIn("pdf", result)

        calls = self.lp_calls()
        self.assertEqual(len(calls), 1)
        args = calls[0]
        self.assertNotIn("-d", args)
        self.assertNotIn("-n", args)
        self.assertEqual(self.option(args, "-t"), "Daily notes")
        pdf = args[-1]
        self.assertTrue(pdf.endswith(".pdf"), pdf)
        self.assertFalse(Path(pdf).exists(), "the temporary PDF should be removed")

    def test_explicit_printer_and_title_reach_lp(self):
        result = self.success(
            "--input", self.note_path, "--printer", PRINTER, "--title", "Weekly review"
        )
        self.assertEqual(result["printer"], PRINTER)
        args = self.lp_calls()[0]
        self.assertEqual(self.option(args, "-d"), PRINTER)
        self.assertEqual(self.option(args, "-t"), "Weekly review")

    def test_copies_are_passed_as_n(self):
        result = self.success("--input", self.note_path, "--title", "Three", "--copies", "3")
        self.assertEqual(result["job"], "42")
        args = self.lp_calls()[0]
        self.assertEqual(self.option(args, "-n"), "3")

    def test_copies_out_of_range_fails_before_printing(self):
        for copies in ("0", "100", "many"):
            error = self.failure(
                "--input", self.note_path, "--title", "Bad copies", "--copies", copies
            )
            self.assertIn("--copies must be between 1 and 99", error)
            self.assertEqual(self.lp_calls(), [])
            self.assertEqual(self.renderer_calls(), [])

    def test_unknown_printer_fails_before_printing(self):
        error = self.failure("--input", self.note_path, "--title", "Unknown", "--printer", "NOPE")
        self.assertIn('No printer named "NOPE"', error)
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_renderer_failure_is_reported_and_not_printed(self):
        error = self.failure(
            "--input",
            self.note_path,
            "--title",
            "Broken",
            "--renderer",
            self.failing_renderer,
        )
        self.assertIn("renderer exploded", error)
        self.assertEqual(self.lp_calls(), [])

    def test_dry_run_resolves_the_default_printer_without_spawning(self):
        result = self.success("--input", self.note_path, "--title", "Dry", "--dry-run")
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["printer"], PRINTER)
        self.assertEqual(result["copies"], 1)
        self.assertEqual(result["input"], str(self.note_path.resolve()))
        # lpstat -d legitimately runs to resolve the default, so the log holds
        # an LPSTAT record; neither the renderer nor lp may appear.
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_dry_run_equals_true_is_still_a_dry_run(self):
        result = self.success("--input", self.note_path, "--dry-run=true")
        self.assertTrue(result["dryRun"])
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_render_only_equals_true_never_submits(self):
        result = self.success(
            "--input", self.note_path, "--renderer", str(self.renderer),
            "--render-only=true",
        )
        try:
            self.assertEqual(result["job"], "")
            self.assertTrue(Path(result["pdf"]).read_bytes().startswith(b"%PDF-"))
        finally:
            shutil.rmtree(Path(result["pdf"]).parent, ignore_errors=True)
        self.assertEqual(self.lp_calls(), [])

    def test_dry_run_equals_false_is_not_dry(self):
        result = self.success("--input", self.note_path, "--dry-run=false")
        self.assertFalse(result.get("dryRun", False))
        self.assertEqual(len(self.lp_calls()), 1)

    def test_a_malformed_boolean_fails_before_submitting(self):
        stderr = self.failure("--input", self.note_path, "--dry-run=maybe")
        self.assertIn("expects true or false", stderr)
        self.assertEqual(self.lp_calls(), [])

    def test_render_only_keeps_the_pdf_and_never_submits(self):
        result = self.success(
            "--input", self.note_path, "--title", "Preview",
            "--renderer", str(self.renderer), "--render-only",
        )
        try:
            self.assertEqual(result["printer"], "")
            self.assertEqual(result["job"], "")
            self.assertGreaterEqual(result["bytes"], 512)
            pdf = Path(result["pdf"])
            self.assertTrue(pdf.is_file(), f"{pdf} was not kept")
            self.assertTrue(pdf.read_bytes().startswith(b"%PDF-"))
        finally:
            shutil.rmtree(Path(result["pdf"]).parent, ignore_errors=True)
        # Rendering happens locally; nothing may reach CUPS.
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(len(self.renderer_calls()), 1)

    def test_keep_pdf_leaves_the_file_and_reports_its_path(self):
        result = self.success(
            "--input", self.note_path, "--title", "Kept", "--keep-pdf"
        )
        try:
            pdf = Path(result["pdf"])
            self.assertTrue(pdf.is_file(), f"{pdf} was not kept")
            self.assertTrue(pdf.name.endswith(".pdf"))
            self.assertTrue(pdf.read_bytes().startswith(b"%PDF-"))
        finally:
            shutil.rmtree(Path(result["pdf"]).parent, ignore_errors=True)

    def test_options_reach_lp_before_the_pdf(self):
        self.success(
            "--input", self.note_path, "--title", "Options",
            "--option", "ColorModel=Gray",
            "--option", "Duplex=DuplexNoTumble",
        )
        args = self.lp_calls()[0]
        start = args.index("-o")
        self.assertEqual(
            args[start:start + 4],
            ["-o", "ColorModel=Gray", "-o", "Duplex=DuplexNoTumble"],
        )
        self.assertGreater(start, args.index("-t"))
        self.assertTrue(args[-1].endswith(".pdf"), args[-1])
        self.assertLess(start + 3, len(args) - 1)

    def test_option_equals_form_is_accepted(self):
        self.success(
            "--input", self.note_path, "--title", "Equals",
            "--option=ColorModel=Gray",
        )
        args = self.lp_calls()[0]
        self.assertEqual(args[args.index("-o"):args.index("-o") + 2],
                         ["-o", "ColorModel=Gray"])

    def test_option_accepts_a_paper_outside_the_shortlist(self):
        self.write_print_options(
            "PageSize/Media Size: *A4 A4.Borderless Letter\n"
        )
        self.success(
            "--input", self.note_path, "--title", "Borderless",
            "--option", "PageSize=A4.Borderless",
        )
        args = self.lp_calls()[0]
        self.assertEqual(
            args[args.index("-o"):args.index("-o") + 2],
            ["-o", "PageSize=A4.Borderless"],
        )

    def test_unknown_option_key_fails_before_submitting(self):
        error = self.failure(
            "--input", self.note_path, "--title", "Unknown",
            "--option", "Nonsense=1",
        )
        self.assertIn("Unsupported print option: Nonsense", error)
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_unknown_option_value_fails_before_submitting(self):
        error = self.failure(
            "--input", self.note_path, "--title", "Bad value",
            "--option", "Duplex=Sideways",
        )
        self.assertIn("Unsupported value for Duplex: Sideways", error)
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_malformed_option_fails(self):
        for argument in ("ColorModel", "=Gray"):
            error = self.failure(
                "--input", self.note_path, "--title", "Malformed",
                "--option", argument,
            )
            self.assertIn("--option expects KEY=VALUE", error)
            self.assertEqual(self.lp_calls(), [])

    def test_dry_run_reports_options_without_spawning(self):
        result = self.success(
            "--input", self.note_path, "--title", "Options dry run",
            "--dry-run", "--option", "ColorModel=Gray",
        )
        self.assertTrue(result["dryRun"])
        self.assertEqual(result["options"], {"ColorModel": "Gray"})
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(self.renderer_calls(), [])

    def test_render_only_accepts_options_and_never_submits(self):
        result = self.success(
            "--input", self.note_path, "--title", "Preview",
            "--renderer", str(self.renderer), "--render-only",
            "--option", "Duplex=DuplexTumble",
        )
        try:
            self.assertEqual(result["printer"], "")
            self.assertEqual(result["job"], "")
            self.assertTrue(Path(result["pdf"]).is_file())
        finally:
            shutil.rmtree(Path(result["pdf"]).parent, ignore_errors=True)
        self.assertEqual(self.lp_calls(), [])
        self.assertEqual(len(self.renderer_calls()), 1)


if __name__ == "__main__":
    unittest.main()
