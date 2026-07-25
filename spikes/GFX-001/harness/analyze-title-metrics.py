#!/usr/bin/env python3
"""Summarize DXMT title telemetry and optional process-memory samples.

Author: Timur Isaev
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence


EXPECTED_METRIC_COLUMNS = (
    "timestamp_ns",
    "event",
    "object",
    "duration_ns",
    "status",
    "detail",
)
EXPECTED_MEMORY_COLUMNS = (
    "elapsed_s",
    "pid",
    "rss_kb",
    "vsz_kb",
    "percent_mem",
)


@dataclass(frozen=True)
class MetricEvent:
    timestamp_ns: int
    event: str
    object_id: int
    duration_ns: int
    status: str
    detail: str


@dataclass(frozen=True)
class MemorySample:
    elapsed_s: int
    pid: int
    rss_kb: int
    vsz_kb: int
    percent_mem: float


@dataclass(frozen=True)
class MetricInputOrdering:
    adjacent_reversal_count: int
    maximum_backward_ns: int


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * fraction
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[lower]
    weight = rank - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def rounded(value: float | None, digits: int = 3) -> float | None:
    if value is None:
        return None
    return round(value, digits)


def distribution(values: Sequence[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "p50": None,
            "p95": None,
            "p99": None,
            "max": None,
        }
    return {
        "count": len(values),
        "mean": rounded(sum(values) / len(values)),
        "p50": rounded(percentile(values, 0.50)),
        "p95": rounded(percentile(values, 0.95)),
        "p99": rounded(percentile(values, 0.99)),
        "max": rounded(max(values)),
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_columns(
    path: Path, actual: Iterable[str] | None, expected: Sequence[str]
) -> None:
    columns = tuple(actual or ())
    if columns != tuple(expected):
        raise ValueError(
            f"{path}: expected columns {tuple(expected)!r}, got {columns!r}"
        )


def read_metrics(path: Path) -> tuple[list[MetricEvent], MetricInputOrdering]:
    events: list[MetricEvent] = []
    with path.open(newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source, delimiter="\t")
        validate_columns(path, reader.fieldnames, EXPECTED_METRIC_COLUMNS)
        for line_number, row in enumerate(reader, start=2):
            try:
                events.append(
                    MetricEvent(
                        timestamp_ns=int(row["timestamp_ns"]),
                        event=row["event"].strip(),
                        object_id=int(row["object"]),
                        duration_ns=int(row["duration_ns"]),
                        status=row["status"].strip(),
                        detail=row["detail"].strip(),
                    )
                )
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"{path}:{line_number}: invalid metric row") from error
    if not events:
        raise ValueError(f"{path}: telemetry contains no events")
    backward_deltas = [
        previous.timestamp_ns - current.timestamp_ns
        for previous, current in zip(events, events[1:])
        if current.timestamp_ns < previous.timestamp_ns
    ]
    ordering = MetricInputOrdering(
        adjacent_reversal_count=len(backward_deltas),
        maximum_backward_ns=max(backward_deltas, default=0),
    )
    return sorted(events, key=lambda event: event.timestamp_ns), ordering


def read_memory(path: Path) -> list[MemorySample]:
    samples: list[MemorySample] = []
    with path.open(newline="", encoding="utf-8-sig") as source:
        reader = csv.DictReader(source, delimiter="\t")
        validate_columns(path, reader.fieldnames, EXPECTED_MEMORY_COLUMNS)
        for line_number, row in enumerate(reader, start=2):
            try:
                samples.append(
                    MemorySample(
                        elapsed_s=int(row["elapsed_s"]),
                        pid=int(row["pid"]),
                        rss_kb=int(row["rss_kb"]),
                        vsz_kb=int(row["vsz_kb"]),
                        percent_mem=float(row["percent_mem"]),
                    )
                )
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(f"{path}:{line_number}: invalid memory row") from error
    if not samples:
        raise ValueError(f"{path}: memory telemetry contains no samples")
    if len({sample.pid for sample in samples}) != 1:
        raise ValueError(f"{path}: memory telemetry contains multiple PIDs")
    if any(
        current.elapsed_s <= previous.elapsed_s
        for previous, current in zip(samples, samples[1:])
    ):
        raise ValueError(f"{path}: memory sample times are not strictly increasing")
    return samples


def linear_slope(samples: Sequence[MemorySample]) -> float | None:
    if len(samples) < 2:
        return None
    mean_time = sum(sample.elapsed_s for sample in samples) / len(samples)
    mean_rss = sum(sample.rss_kb for sample in samples) / len(samples)
    denominator = sum((sample.elapsed_s - mean_time) ** 2 for sample in samples)
    if denominator == 0:
        return None
    numerator = sum(
        (sample.elapsed_s - mean_time) * (sample.rss_kb - mean_rss)
        for sample in samples
    )
    return numerator / denominator


def summarize_memory(
    samples: Sequence[MemorySample], path: Path
) -> dict[str, object]:
    rss_values = [sample.rss_kb / 1024.0 for sample in samples]
    vsz_values = [sample.vsz_kb / 1024.0 for sample in samples]
    slope_kb_per_second = linear_slope(samples)
    tail_samples = samples[len(samples) // 2 :]
    tail_rss_values = [sample.rss_kb / 1024.0 for sample in tail_samples]
    tail_vsz_values = [sample.vsz_kb / 1024.0 for sample in tail_samples]
    tail_slope_kb_per_second = linear_slope(tail_samples)
    return {
        "source": str(path),
        "sha256": sha256(path),
        "pid": samples[0].pid,
        "sampleCount": len(samples),
        "durationSeconds": samples[-1].elapsed_s - samples[0].elapsed_s,
        "rssMiB": {
            "start": rounded(rss_values[0]),
            "end": rounded(rss_values[-1]),
            "minimum": rounded(min(rss_values)),
            "peak": rounded(max(rss_values)),
            "delta": rounded(rss_values[-1] - rss_values[0]),
            "linearSlopeMiBPerHour": rounded(
                None
                if slope_kb_per_second is None
                else slope_kb_per_second * 3600.0 / 1024.0
            ),
            "tailHalf": {
                "durationSeconds": (
                    tail_samples[-1].elapsed_s - tail_samples[0].elapsed_s
                ),
                "start": rounded(tail_rss_values[0]),
                "end": rounded(tail_rss_values[-1]),
                "peak": rounded(max(tail_rss_values)),
                "delta": rounded(tail_rss_values[-1] - tail_rss_values[0]),
                "linearSlopeMiBPerHour": rounded(
                    None
                    if tail_slope_kb_per_second is None
                    else tail_slope_kb_per_second * 3600.0 / 1024.0
                ),
            },
        },
        "virtualMiB": {
            "start": rounded(vsz_values[0]),
            "end": rounded(vsz_values[-1]),
            "peak": rounded(max(vsz_values)),
            "delta": rounded(vsz_values[-1] - vsz_values[0]),
            "tailHalf": {
                "start": rounded(tail_vsz_values[0]),
                "end": rounded(tail_vsz_values[-1]),
                "peak": rounded(max(tail_vsz_values)),
                "delta": rounded(tail_vsz_values[-1] - tail_vsz_values[0]),
            },
        },
    }


def summarize_metrics(
    events: Sequence[MetricEvent],
    path: Path,
    input_ordering: MetricInputOrdering,
    start_seconds: float | None,
    end_seconds: float | None,
    longest_count: int,
) -> dict[str, object]:
    start_ns = 0 if start_seconds is None else round(start_seconds * 1_000_000_000)
    end_ns = (
        events[-1].timestamp_ns
        if end_seconds is None
        else round(end_seconds * 1_000_000_000)
    )
    if start_ns < 0 or end_ns <= start_ns:
        raise ValueError("metric window must have 0 <= start < end")

    selected = [
        event
        for event in events
        if (
            event.timestamp_ns >= start_ns
            if start_seconds is None
            else event.timestamp_ns > start_ns
        )
        and event.timestamp_ns <= end_ns
    ]
    if not selected:
        raise ValueError("metric window contains no events")

    presents = [event for event in selected if event.event == "present"]
    interval_rows: list[tuple[MetricEvent, MetricEvent, float]] = []
    for previous, current in zip(presents, presents[1:]):
        interval_rows.append(
            (
                previous,
                current,
                (current.timestamp_ns - previous.timestamp_ns) / 1_000_000.0,
            )
        )
    interval_ms = [row[2] for row in interval_rows]
    present_call_ms = [event.duration_ns / 1_000_000.0 for event in presents]

    shader_events = [event for event in selected if event.event == "shader"]
    shader_compiles = [
        event for event in shader_events if event.detail.startswith("compile:")
    ]
    shader_cache_hits = [
        event for event in shader_events if event.detail.startswith("cache:")
    ]
    pipelines = [event for event in selected if event.event == "pipeline"]
    failed = [event for event in selected if event.status != "ok"]

    stall_events = shader_compiles + pipelines
    longest_frames: list[dict[str, object]] = []
    for previous, current, interval in sorted(
        interval_rows, key=lambda row: row[2], reverse=True
    )[:longest_count]:
        correlated = [
            event
            for event in stall_events
            if previous.timestamp_ns < event.timestamp_ns <= current.timestamp_ns
        ]
        longest_frames.append(
            {
                "endTimestampMs": rounded(current.timestamp_ns / 1_000_000.0),
                "presentObject": current.object_id,
                "intervalMs": rounded(interval),
                "correlatedEvents": [
                    {
                        "event": event.event,
                        "detail": event.detail,
                        "durationMs": rounded(event.duration_ns / 1_000_000.0),
                        "status": event.status,
                    }
                    for event in correlated
                ],
            }
        )

    effective_first_ns = selected[0].timestamp_ns
    effective_last_ns = selected[-1].timestamp_ns
    present_span_seconds = (
        (presents[-1].timestamp_ns - presents[0].timestamp_ns) / 1_000_000_000.0
        if len(presents) >= 2
        else None
    )
    threshold_counts = {
        "over16_667ms": sum(value > 16.667 for value in interval_ms),
        "over20_833ms": sum(value > 20.833 for value in interval_ms),
        "over33_333ms": sum(value > 33.333 for value in interval_ms),
        "over50ms": sum(value > 50.0 for value in interval_ms),
        "over100ms": sum(value > 100.0 for value in interval_ms),
    }

    return {
        "source": str(path),
        "sha256": sha256(path),
        "inputOrdering": {
            "adjacentReversalCount": input_ordering.adjacent_reversal_count,
            "maximumBackwardNs": input_ordering.maximum_backward_ns,
            "stablySortedByTimestamp": True,
        },
        "window": {
            "requestedStartSeconds": start_seconds,
            "requestedEndSeconds": end_seconds,
            "firstEventTimestampMs": rounded(effective_first_ns / 1_000_000.0),
            "lastEventTimestampMs": rounded(effective_last_ns / 1_000_000.0),
            "durationSeconds": rounded(
                (effective_last_ns - effective_first_ns) / 1_000_000_000.0
            ),
        },
        "eventCount": len(selected),
        "failedEventCount": len(failed),
        "framePacing": {
            "presentCount": len(presents),
            "firstPresentTimestampMs": rounded(
                None if not presents else presents[0].timestamp_ns / 1_000_000.0
            ),
            "lastPresentTimestampMs": rounded(
                None if not presents else presents[-1].timestamp_ns / 1_000_000.0
            ),
            "meanFps": rounded(
                None
                if present_span_seconds in (None, 0)
                else (len(presents) - 1) / present_span_seconds
            ),
            "intervalMs": distribution(interval_ms),
            "presentCallMs": distribution(present_call_ms),
            "thresholdCounts": threshold_counts,
            "thresholdPercentages": {
                key: rounded(
                    None if not interval_ms else value * 100.0 / len(interval_ms)
                )
                for key, value in threshold_counts.items()
            },
            "longestFrames": longest_frames,
        },
        "shader": {
            "eventCount": len(shader_events),
            "cacheHitCount": len(shader_cache_hits),
            "compileCount": len(shader_compiles),
            "failureCount": sum(event.status != "ok" for event in shader_events),
            "compileDurationMs": distribution(
                [event.duration_ns / 1_000_000.0 for event in shader_compiles]
            ),
        },
        "pipeline": {
            "eventCount": len(pipelines),
            "failureCount": sum(event.status != "ok" for event in pipelines),
            "durationMs": distribution(
                [event.duration_ns / 1_000_000.0 for event in pipelines]
            ),
            "byType": {
                detail: sum(event.detail == detail for event in pipelines)
                for detail in sorted({event.detail for event in pipelines})
            },
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize DXMT title telemetry and process-memory samples."
    )
    parser.add_argument("metrics", type=Path, help="DXMT title-metrics TSV")
    parser.add_argument("--memory", type=Path, help="optional memory-sample TSV")
    parser.add_argument("--start-seconds", type=float)
    parser.add_argument("--end-seconds", type=float)
    parser.add_argument("--longest-frames", type=int, default=10)
    parser.add_argument("--label", default="")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.longest_frames < 1:
        raise ValueError("--longest-frames must be positive")

    metrics, input_ordering = read_metrics(args.metrics)
    payload: dict[str, object] = {
        "schemaVersion": 1,
        "author": "Timur Isaev",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "label": args.label or None,
        "metrics": summarize_metrics(
            metrics,
            args.metrics,
            input_ordering,
            args.start_seconds,
            args.end_seconds,
            args.longest_frames,
        ),
        "memory": None,
    }
    if args.memory is not None:
        payload["memory"] = summarize_memory(read_memory(args.memory), args.memory)

    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(rendered, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
