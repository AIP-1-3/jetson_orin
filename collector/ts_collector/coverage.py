"""수집 현황 보고: 공간·항목별 건수, 마지막 수신, 커버율, 결측 구간과 추정 원인.

  python -m ts_collector.coverage -c config.yaml               # 최근 24시간
  python -m ts_collector.coverage -c config.yaml --hours 168 --min-gap 5 -o report.md

커버율 = 1분 칸 중 값이 하나라도 있는 칸의 비율.
결측 원인은 수집기가 1분마다 남기는 상태 기록(collector_status)과 다른 공간 결측을
함께 보고 추정한다.
"""
from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))


@dataclass
class Gap:
    space: str
    metric: str
    start: int  # 분 (epoch // 60), 포함
    end: int  # 분, 미포함
    cause: str

    @property
    def minutes(self) -> int:
        return self.end - self.start


@dataclass
class SeriesReport:
    space: str
    metric: str
    count: int
    last_ts: float | None
    covered: int
    total: int
    gaps: list[Gap]

    @property
    def coverage(self) -> float:
        return self.covered / self.total if self.total else 0.0


def _runs(missing: list[int]) -> list[tuple[int, int]]:
    out = []
    for m in missing:
        if out and out[-1][1] == m:
            out[-1][1] = m + 1
        else:
            out.append([m, m + 1])
    return [tuple(r) for r in out]


def classify(start: int, end: int, space: str, metric: str, heartbeat: dict[int, bool] | None,
             missing_by_series: dict[tuple[str, str], set[int]]) -> str:
    """결측 구간 하나의 추정 원인."""
    mins = range(start, end)
    if heartbeat is not None:
        # 상태 기록은 1분마다라서 앞뒤 1분은 비어 있을 수 있다
        down = sum(1 for m in mins if not any(heartbeat.get(m + d) is not None for d in (-1, 0, 1)))
        if down >= len(mins) / 2:
            return "수집기 정지(상태 기록 없음)"
        disc = sum(1 for m in mins if heartbeat.get(m) is False)
        if disc >= len(mins) / 2:
            return "브로커/네트워크 끊김(수집기는 동작)"
    others = [k for k in missing_by_series if k != (space, metric)]
    if others:
        def share(keys):
            if not keys:
                return 0.0
            hit = sum(1 for k in keys for m in mins if m in missing_by_series[k])
            return hit / (len(keys) * len(mins))

        if share(others) >= 0.8:
            return "전체 동시 결측: 브로커 쪽 송신 없음 또는 게이트웨이"
        same_space = [k for k in others if k[0] == space]
        if same_space and share(same_space) >= 0.8:
            return "이 공간 전체 결측: 해당 공간 센서/게이트웨이"
    return "이 항목만 결측: 센서 또는 해당 항목 송신"


def analyze(points: dict[tuple[str, str], list[float]], start_ts: float, end_ts: float,
            heartbeat: dict[int, bool] | None = None, min_gap: int = 3) -> list[SeriesReport]:
    """points: (공간, 항목) → 시각(epoch 초) 목록. heartbeat: 분 → MQTT 접속 여부."""
    m0, m1 = int(start_ts // 60), int(end_ts // 60)
    total = m1 - m0
    present = {k: {int(t // 60) for t in ts if m0 <= t // 60 < m1} for k, ts in points.items()}
    missing = {k: set(range(m0, m1)) - p for k, p in present.items()}
    reports = []
    for (space, metric), ts in sorted(points.items()):
        gaps = []
        for a, b in _runs(sorted(missing[(space, metric)])):
            if b - a >= min_gap:
                gaps.append(Gap(space, metric, a, b, classify(a, b, space, metric, heartbeat, missing)))
        in_range = [t for t in ts if m0 <= t // 60 < m1]
        reports.append(SeriesReport(space, metric, len(in_range), max(ts) if ts else None,
                                    len(present[(space, metric)]), total, gaps))
    return reports


def _fmt_min(m: int) -> str:
    return datetime.fromtimestamp(m * 60, KST).strftime("%m-%d %H:%M")


def render(reports: list[SeriesReport], start_ts: float, end_ts: float, target: float = 0.95,
           now: float | None = None) -> str:
    now = now or end_ts
    lines = [
        "# 수집 현황 보고",
        "",
        f"기간: {datetime.fromtimestamp(start_ts, KST):%Y-%m-%d %H:%M} ~ "
        f"{datetime.fromtimestamp(end_ts, KST):%Y-%m-%d %H:%M} (KST), 1분 칸 {reports[0].total if reports else 0}개",
        "",
        "| 공간 | 항목 | 건수 | 마지막 수신 | 커버율 | 결측 구간 | 판정 |",
        "|---|---|---:|---|---:|---:|---|",
    ]
    for r in reports:
        last = "-"
        if r.last_ts:
            ago = int((now - r.last_ts) // 60)
            last = f"{datetime.fromtimestamp(r.last_ts, KST):%m-%d %H:%M} ({ago}분 전)"
        ok = "OK" if r.coverage >= target else "미달"
        lines.append(f"| {r.space} | {r.metric} | {r.count} | {last} | {r.coverage:.1%} | "
                     f"{len(r.gaps)} | {ok} |")
    gaps = sorted((g for r in reports for g in r.gaps), key=lambda g: (g.start, g.space, g.metric))
    lines += ["", "## 결측 구간과 추정 원인", ""]
    if not gaps:
        lines.append("없음")
    else:
        # 같은 시각에 여러 항목이 함께 빠진 구간은 한 줄로 묶는다
        grouped = defaultdict(list)
        for g in gaps:
            grouped[(g.start, g.end, g.cause)].append(f"{g.space}/{g.metric}")
        lines += ["| 시작 | 끝 | 길이(분) | 대상 | 추정 원인 |", "|---|---|---:|---|---|"]
        for (a, b, cause), who in grouped.items():
            target_s = ", ".join(who) if len(who) <= 4 else f"{len(who)}개 항목"
            lines.append(f"| {_fmt_min(a)} | {_fmt_min(b)} | {b - a} | {target_s} | {cause} |")
    return "\n".join(lines) + "\n"


def fetch(cfg: dict, start_ts: float, end_ts: float):
    """InfluxDB 2.x(Flux)에서 시각 목록과 수집기 상태를 읽는다."""
    from influxdb_client import InfluxDBClient

    from .collector import _env

    icfg = cfg["influx"]
    meas = icfg.get("measurement", "env")
    status = icfg.get("status_measurement", "collector_status")
    bucket = icfg.get("bucket", "sensors")
    start = datetime.fromtimestamp(start_ts, timezone.utc).isoformat()
    stop = datetime.fromtimestamp(end_ts, timezone.utc).isoformat()
    with InfluxDBClient(url=icfg.get("url", "http://localhost:8086"), token=_env(icfg, "token") or "",
                        org=icfg.get("org", "-"), timeout=60_000) as client:
        q = client.query_api()
        points = defaultdict(list)
        flux = (f'from(bucket: "{bucket}") |> range(start: {start}, stop: {stop}) '
                f'|> filter(fn: (r) => r._measurement == "{meas}" and r._field == "value") '
                f'|> keep(columns: ["_time", "space", "metric"])')
        for table in q.query(flux):
            for rec in table.records:
                points[(rec.values["space"], rec.values["metric"])].append(rec.get_time().timestamp())
        heartbeat = {}
        flux = (f'from(bucket: "{bucket}") |> range(start: {start}, stop: {stop}) '
                f'|> filter(fn: (r) => r._measurement == "{status}" and r._field == "mqtt_connected")')
        for table in q.query(flux):
            for rec in table.records:
                m = int(rec.get_time().timestamp() // 60)
                heartbeat[m] = heartbeat.get(m, False) or bool(rec.get_value())
    return dict(points), heartbeat


def main(argv=None) -> int:
    from .collector import load_config

    ap = argparse.ArgumentParser(description="수집 현황 보고")
    ap.add_argument("-c", "--config", default="config.yaml")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--min-gap", type=int, default=3, help="이 분 수 이상 비면 결측 구간으로 표시")
    ap.add_argument("--target", type=float, default=0.95)
    ap.add_argument("-o", "--output")
    a = ap.parse_args(argv)
    cfg = load_config(a.config)
    end = datetime.now(timezone.utc).timestamp() // 60 * 60
    start = end - a.hours * 3600
    points, heartbeat = fetch(cfg, start, end)
    text = render(analyze(points, start, end, heartbeat or None, a.min_gap), start, end, a.target)
    if a.output:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
