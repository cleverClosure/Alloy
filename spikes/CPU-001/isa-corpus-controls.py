"""Synthetic Wine orchestration controls; never execute an emulator. Author: Timur Isaev."""

from contextlib import redirect_stdout
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch


def exercise(run_fex, complete, digest, families, manifest):
    loader_source = '''#!/usr/bin/env python3
# Author: Timur Isaev
import os,sys
from pathlib import Path
prefix=Path(os.environ['WINEPREFIX'])
if sys.argv[1]=='wineboot': sys.exit(0)
if sys.argv[1]=='regedit':
    (prefix/'registered').write_text('yes')
    sys.exit(0)
if not (prefix/'registered').exists():
    print('x64 emulation not implemented')
    sys.exit(53)
if os.environ['ALLOY_SYNTHETIC_CONTROL']=='lookup-only':
    print('find_builtin_dll looking for "libarm64ecfex.dll"')
else:
    print('0024:trace:loaddll:build_module Loaded L"C:\\\\windows\\\\system32\\\\libarm64ecfex.dll" at 00001234: builtin')
if os.environ['ALLOY_SYNTHETIC_CONTROL']=='runtime-write':
    (Path(__file__).resolve().parents[1]/'unexpected').write_text('a forbidden write')
guest=Path(sys.argv[1])
print(guest.read_text(),end='')
sys.exit(0 if guest.name.endswith('-clean.exe') else 1)
'''
    server_source = '''#!/usr/bin/env python3
# Author: Timur Isaev
import os,sys
from pathlib import Path
with (Path(os.environ['WINEPREFIX'])/'server-actions').open('a') as output:
    output.write(os.environ['WINEPREFIX']+' '+sys.argv[1]+'\\n')
'''
    total = 0
    with tempfile.TemporaryDirectory(prefix="alloy-isa-synthetic-") as scratch:
        for control in ("valid", "lookup-only", "runtime-write"):
            root = Path(scratch) / control
            build, work = root / "runtime", root / "work"
            work.mkdir(parents=True)
            files = {"loader/wine": loader_source, "server/wineserver": server_source,
                     "dlls/ntdll/ntdll.so": "synthetic ntdll",
                     "dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll": "synthetic FEX"}
            for name, source in files.items():
                path = build / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source)
                path.chmod(0o755)
            report = {"mode": "fex", "kind": "synthetic control", "families": {}}
            for family in families:
                report["families"][family] = {kind: {"status": "NOT RUN"} for kind in ("clean", "mutation")}
                report["families"][family]["native_proof"] = {}
                for mutated in (False, True):
                    kind = "mutation" if mutated else "clean"
                    guest = (work if family == "sse2" else work / "native/families") / f"isa_corpus_{family}-{kind}.exe"
                    guest.parent.mkdir(parents=True, exist_ok=True)
                    if family == "sse2":
                        tag = "paddb" if mutated else "none"
                        checksum = "eb480915973927bd" if mutated else "21ba41417def5d07"
                        failures = 237 if mutated else 0
                        text = "FAIL hand-vector paddb mismatch\nFAIL paddb mismatch\n" if mutated else ""
                        text += f"cpu-001 isa-corpus sse2: cases=12736 failures={failures} checksum={checksum} mutate={tag}\n"
                    else:
                        spec = manifest["families"][family]
                        tag = spec["mutation"] if mutated else "none"
                        mode = spec.get("instruction_mode", "instruction-parity")
                        text = f"cpu-001 isa-corpus {family} mode={mode} seed={manifest['seed']} mutate={tag}\n"
                        if mutated:
                            text += f"FAIL {tag} hand-vector mismatch\nFAIL {tag} parity mismatch\n"
                        text += "".join(f"op={op['name']} cases={op['cases']} checksum=0000000000000000\n"
                                        for op in spec["operations"])
                        failures = spec["mutation_instruction_failures"] if mutated else 0
                        checksum = spec["mutation_checksum"] if mutated else spec["checksum"]
                        text += f"cpu-001 isa-corpus {family}: cases={spec['cases']} failures={failures} checksum={checksum} mutate={tag}\n"
                    guest.write_text(text)
                    fingerprint = {"pe_sha256": digest(guest)}
                    if family == "sse2":
                        report["families"][family]["native_" + kind] = fingerprint
                    else:
                        report["families"][family]["native_proof"][kind] = fingerprint
            spec = manifest["families"]["atomics"]
            ticket = work / "isa_corpus_atomics-tickets.exe"
            text = f"cpu-001 isa-corpus atomics mode=instruction-parity seed={manifest['seed']} mutate=tickets\n"
            text += spec["ticket_control"]["diagnostic"] + "\n"
            text += "".join(f"op={op['name']} cases={op['cases']} checksum=0000000000000000\n" for op in spec["operations"])
            text += (f"cpu-001 isa-corpus atomics: cases={spec['cases']} failures=1 "
                     f"checksum={spec['ticket_control']['checksum']} mutate=tickets\n")
            ticket.write_text(text)
            report["families"]["atomics"]["ticket_pe_sha256"] = digest(ticket)
            args = SimpleNamespace(wine_build=build, wine_source=root / "wine-source", fex_source=root / "fex-source")
            failed = False
            # The contention parser has its own busy/idle controls. The isolated
            # simulated runtime needs no access to the host's process table.
            with patch.dict(run_fex.__globals__, {
                "revision": lambda path: {"head": "0" * 40, "branch": "synthetic", "dirty_paths": []},
                "assert_idle": lambda build: {"checked_at": "synthetic", "busy_processes": []},
            }):
                with patch.dict("os.environ", {"ALLOY_SYNTHETIC_CONTROL": control}), redirect_stdout(io.StringIO()):
                    try:
                        run_fex(args, work, report)
                    except (RuntimeError, ValueError) as error:
                        failed = True
                        report["error"] = str(error)
            if control == "valid":
                assert not failed and complete(report), report
            else:
                assert failed and not complete(report), control
                if control == "lookup-only":
                    assert "actual libarm64ecfex builtin" in report["error"]
                    assert report["runtime_unchanged"]
                else:
                    assert not report["runtime_unchanged"]
            actions = (work / "prefix/server-actions").read_text().splitlines()
            assert actions and all(line.startswith(str(work / "prefix") + " ") for line in actions)
            assert actions[-1].endswith(" -w")
            total += 1
    print(f"PASS synthetic Wine orchestration: {total} controlled paths; no emulator executed", flush=True)
