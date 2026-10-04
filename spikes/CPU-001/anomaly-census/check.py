"""Read calibrated census evidence without certifying CAS atomicity. Author: Timur Isaev."""

import re

SPLIT_FLAGS = {"64byte Split Locks", "16byte Split atomics"}
CAS_FLAGS = [f"{size}bit CAS Tear" for size in (16, 32, 64, 128)]
FAULT_NAMES = {"segv-entries", "resolved", "access-violations", "align-faults", "low-pc-faults",
               "x18-absorbs", "jit-store-emulated", "jit-store-unmatched", "jit-store-mismatched",
               "jit-store-unwritable"}
OUTCOMES = {"invalid-no-dispatcher", "decode-hit-non-executable", "partial-decode",
            "bad-relocation", "unimplemented"}
CASES = ("fault-clean", "fault-positive", "decoder-clean", "decoder-invalid",
         "decoder-unimplemented", "clean", "splitlock", "splitcas32", "splitcas64")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def snapshots(lines, marker, pid=None):
    """Only complete snapshots have zero-valued omitted decoder outcomes."""
    result, current = [], None
    for index, line in enumerate(lines):
        if marker + " " not in line:
            continue
        if pid is not None and not re.match(rf"^{pid}:[0-9a-f]+:", line):
            continue
        text = line.split(marker + " ", 1)[1]
        if text.startswith("begin "):
            require(current is None, "nested census snapshot")
            fields = dict(re.findall(r"([a-z_]+)=([^ ]+)", text))
            require("seq" in fields and "reason" in fields, "snapshot identity missing")
            current = {"fields": fields, "counts": {}, "begin": index}
        elif text.startswith("end "):
            require(current is not None, "snapshot end without begin")
            require(text == "end seq=" + current["fields"]["seq"], "snapshot sequence mismatch")
            current["end"] = index
            counts = current["counts"]
            if marker == "ALLOY_FAULT_CENSUS":
                require(set(counts) == FAULT_NAMES, "fault snapshot is missing counters")
                require(counts["segv-entries"] == counts["resolved"] + counts["access-violations"],
                        "fault conservation failed")
            else:
                fields = current["fields"]
                require({"decoded", "total_decode_calls", "live_threads"} <= fields.keys(),
                        "decoder totals missing")
                require(int(fields["total_decode_calls"]) == int(fields["decoded"]) + sum(counts.values()),
                        "decoder conservation failed")
            if result:
                require(int(current["fields"]["seq"]) > int(result[-1]["fields"]["seq"]),
                        "census sequence did not advance")
                require(all(counts.get(name, 0) >= value for name, value in result[-1]["counts"].items()),
                        "census count decreased")
            result.append(current)
            current = None
        elif text.startswith(("count ", "outcome ")):
            require(current is not None, "counter outside snapshot")
            match = re.fullmatch(r"(?:count|outcome) (\d+) ([a-z0-9-]+)", text)
            require(match is not None, "malformed census counter")
            name = match[2]
            allowed = FAULT_NAMES if marker == "ALLOY_FAULT_CENSUS" else OUTCOMES
            require(name in allowed and name not in current["counts"], "unknown or duplicate census counter")
            current["counts"][name] = int(match[1])
    require(current is None and result, "missing or truncated census snapshots")
    return result


def one_line(lines, pattern):
    matches = [(i, match) for i, line in enumerate(lines) if (match := re.fullmatch(pattern, line))]
    require(len(matches) == 1, "missing or duplicate guest result: " + pattern)
    return matches[0]


def analyze(label, text, result):
    require(label in CASES, "unknown control")
    require(result["exit"] == 0 and result["failure"] is None, "guest failed or timed out")
    lines = text.replace("\r", "").splitlines()
    binary = label if label.startswith(("fault-", "decoder-")) else "telemetry"
    loads = re.findall(r'^([0-9a-f]+):[0-9a-f]+:trace:loaddll:build_module Loaded L"[^"\n]*' +
                       re.escape(binary) + r'\.exe" at [0-9A-Fa-f]+: native$', text, re.MULTILINE)
    require(len(loads) == 1, "guest image load is missing or ambiguous")
    pid = loads[0]
    require(re.search(rf'^{pid}:[0-9a-f]+:trace:loaddll:build_module Loaded L"[^"\n]*'
                      r'libarm64ecfex\.dll" at [0-9A-Fa-f]+: builtin$', text, re.MULTILINE),
            "no actual builtin FEX load in the guest process")
    require(sum("ALLOY_CENSUS telemetry_snapshot reason=process-init nonzero=0" in line
                for line in lines) == 1, "missing or ambiguous telemetry baseline")
    faults = snapshots(lines, "ALLOY_FAULT_CENSUS", pid)
    require(faults[-1]["fields"]["reason"] == "exit", "fault census lacks the final exit snapshot")
    decoder = snapshots(lines, "ALLOY_CENSUS")
    require(int(decoder[-1]["fields"]["live_threads"]) == 1, "control is not a single decoder thread")
    flags = {}
    for line in lines:
        match = re.search(r"ALLOY_CENSUS telemetry_value reason=[^ ]+ value=(\d+) name=(.*?) "
                          r"\(flag-or-mask, not a frequency\)$", line)
        if match:
            flags[match[2]] = flags.get(match[2], 0) | int(match[1])
    final = faults[-1]["counts"]
    metrics = {"fault_totals": final, "decoder_outcomes": decoder[-1]["counts"],
               "observed_flags": flags, "cas_absence_proven": False}
    if label.startswith("fault-"):
        positive = int(label == "fault-positive")
        begin, _ = one_line(lines, rf"anomaly_fault begin provoke={positive} iterations=64")
        end, _ = one_line(lines, rf"anomaly_fault end caught={64 * positive} expected={64 * positive}")
        before = [row for row in faults if row["end"] < begin]
        require(before and begin < end < faults[-1]["begin"], "missing before/after fault coverage")
        delta = final["access-violations"] - before[-1]["counts"]["access-violations"]
        require(delta == 64 * positive, "access-violation control count mismatch")
        require(final["align-faults"] == 0, "unexpected alignment fault")
        metrics["controlled_access_violations"] = delta
    elif label.startswith("decoder-"):
        kind = {"decoder-clean": 0, "decoder-invalid": 1, "decoder-unimplemented": 2}[label]
        begin, address = one_line(lines, rf"anomaly_decoder begin kind={kind} address=([0-9A-Fa-f]+)")
        end, _ = one_line(lines, rf"anomaly_decoder end kind={kind} caught={int(kind != 0)} expected={int(kind != 0)}")
        require(begin < end and any(row["begin"] > begin for row in decoder),
                "decoder was not sampled after the operation began")
        expected = {} if kind == 0 else {"invalid-no-dispatcher" if kind == 1 else "unimplemented": 1}
        require(decoder[-1]["counts"] == expected, "decoder outcome control mismatch")
        if kind == 1:
            require(re.search(rf"ALLOY_CENSUS invalid #0 rip=0x{int(address[1], 16):x} .*bytes=06 c3 ", text),
                    "invalid decode was not attributed to the allocated control instruction")
    else:
        positive = label != "clean"
        end, _ = one_line(lines, rf"telemetry_probe {label} iterations=2000 misaligned={int(positive)} ok")
        require(end < faults[-1]["begin"], "split operation has no final fault snapshot")
        require(final["align-faults"] == (2000 if positive else 0), "alignment control count mismatch")
        require({name for name in flags if name in SPLIT_FLAGS} == (SPLIT_FLAGS if positive else set()),
                "split flag control mismatch")
        if positive:
            require(all(flags[name] == 1 for name in SPLIT_FLAGS), "split telemetry is not a one-bit flag")
    return metrics


def coverage():
    return {"calibrated": ["handled alignment faults", "guest access violations",
                           "supported split-operation flags", "invalid decoder outcomes",
                           "unimplemented decoder outcomes"],
            "cas_tearing": {"status": "retired-from-clean-run-claims", "flags": CAS_FLAGS,
                            "absence_proven": False,
                            "reason": "No deterministic guest control for the partial-commit race.",
                            "gap": "Fault and decoder controls cannot detect every silent partial atomic write."}}


def mutation_controls(texts, results):
    """Damage actual positive evidence; every named corruption must be rejected."""
    trials = [
        ("missing-census", "fault-positive", re.sub(r"^.*ALLOY_FAULT_CENSUS.*\n?", "", texts["fault-positive"], flags=re.MULTILINE)),
        ("truncated-census", "fault-positive", re.sub(r"^.*ALLOY_FAULT_CENSUS end.*\n?", "", texts["fault-positive"], flags=re.MULTILINE)),
        ("no-builtin-load", "fault-positive", texts["fault-positive"].replace("libarm64ecfex.dll", "unverified.dll")),
        ("wrong-fault-count", "fault-positive",
         re.sub(r"(ALLOY_FAULT_CENSUS count )(\d+)( access-violations)",
                lambda match: match[1] + str(int(match[2]) + 1) + match[3], texts["fault-positive"])),
        ("missing-split-flag", "splitlock", texts["splitlock"].replace("64byte Split Locks", "unqualified flag")),
        ("lost-invalid-outcome", "decoder-invalid", re.sub(r"^.*ALLOY_CENSUS outcome.*\n?", "", texts["decoder-invalid"], flags=re.MULTILINE)),
        ("lost-unimplemented-outcome", "decoder-unimplemented", re.sub(r"^.*ALLOY_CENSUS outcome.*\n?", "", texts["decoder-unimplemented"], flags=re.MULTILINE)),
        ("missing-baseline", "clean", texts["clean"].replace("reason=process-init", "reason=unknown")),
    ]
    before, marker, after = texts["decoder-invalid"].partition("anomaly_decoder begin ")
    trials.append(("stale-decoder-sample", "decoder-invalid", before + marker +
                   re.sub(r"^.*ALLOY_CENSUS.*\n?", "", after, flags=re.MULTILINE)))
    trials.append(("wrong-process-census", "fault-positive",
                   re.sub(r"^[0-9a-f]+:(?=[^\n]*ALLOY_FAULT_CENSUS)", "ffff:",
                          texts["fault-positive"], flags=re.MULTILINE)))
    rejected = []
    for name, label, damaged in trials:
        try:
            analyze(label, damaged, results[label])
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError("reader accepted corrupted evidence: " + name)
    for name, changed in (("timeout", {"exit": 0, "failure": "timeout"}),
                          ("nonzero-exit", {"exit": 1, "failure": None})):
        try:
            analyze("clean", texts["clean"], changed)
        except ValueError:
            rejected.append(name)
        else:
            raise ValueError("reader accepted " + name)
    return rejected
