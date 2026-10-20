"""InfluxDB 쓰기: 묶어서 쓰기, 중복(재전송) 걸러내기, 쓰기 실패 시 디스크에 임시 저장.

InfluxDB 는 (measurement, 태그, 시각)이 같은 점을 덮어쓴다. 그래서 같은 메시지가
두 번 와도 저장 결과는 한 점이지만, 재전송이 얼마나 일어나는지 알 수 있도록
최근에 쓴 점을 기억해 두고 중복 건수를 센다.
"""
from __future__ import annotations

import logging
import os
import threading
from collections import OrderedDict
from typing import Callable, Iterable

from .mapping import Record

log = logging.getLogger(__name__)


def _esc_key(s: str) -> str:
    return s.replace("\\", "\\\\").replace(",", "\\,").replace("=", "\\=").replace(" ", "\\ ")


def _esc_measurement(s: str) -> str:
    return s.replace("\\", "\\\\").replace(",", "\\,").replace(" ", "\\ ")


def line(measurement: str, tags: dict, fields: dict, ts_ns: int) -> str:
    tag_s = "".join(f",{_esc_key(k)}={_esc_key(str(v))}" for k, v in sorted(tags.items()) if v != "")
    parts = []
    for k, v in fields.items():
        if isinstance(v, bool):
            fv = "true" if v else "false"
        elif isinstance(v, int):
            fv = f"{v}i"
        elif isinstance(v, float):
            fv = repr(v)
        else:
            fv = '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'
        parts.append(f"{_esc_key(k)}={fv}")
    return f"{_esc_measurement(measurement)}{tag_s} {','.join(parts)} {ts_ns}"


def record_line(measurement: str, r: Record) -> str:
    return line(
        measurement,
        {"space": r.space, "metric": r.metric, "sensor": r.sensor, "ts_source": r.ts_source},
        {"value": float(r.value), "recv_lag_s": round(r.recv_ts - r.ts, 3)},
        int(round(r.ts * 1e9)),
    )


class Dedup:
    """최근 N개 점의 (공간, 항목, 센서, 시각) → 값."""

    def __init__(self, size: int = 50_000):
        self.size = size
        self._seen: OrderedDict[tuple, float] = OrderedDict()

    def check(self, r: Record) -> str:
        """'new' | 'duplicate'(같은 값 재전송) | 'conflict'(같은 시각 다른 값)."""
        key = (r.space, r.metric, r.sensor, int(round(r.ts * 1e3)))
        old = self._seen.get(key)
        self._seen[key] = r.value
        self._seen.move_to_end(key)
        while len(self._seen) > self.size:
            self._seen.popitem(last=False)
        if old is None:
            return "new"
        return "duplicate" if old == r.value else "conflict"


class Spool:
    """쓰기 실패한 줄을 파일에 모아 두었다가 InfluxDB 가 돌아오면 다시 쓴다."""

    def __init__(self, path: str, max_bytes: int = 200 * 1024 * 1024):
        self.path = path
        self.max_bytes = max_bytes
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)

    def size(self) -> int:
        try:
            return os.path.getsize(self.path)
        except FileNotFoundError:
            return 0

    def append(self, lines: list[str]) -> int:
        """저장한 줄 수. 용량 상한을 넘으면 새 줄은 버린다(디스크 보호)."""
        if self.size() >= self.max_bytes:
            return 0
        with open(self.path, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
            f.flush()
            os.fsync(f.fileno())
        return len(lines)

    def drain(self, write: Callable[[list[str]], None], chunk: int = 5000) -> int:
        """임시 저장분을 모두 다시 쓴다. 중간에 실패하면 남은 줄만 파일에 남긴다."""
        if self.size() == 0:
            return 0
        with open(self.path, encoding="utf-8") as f:
            lines = [ln for ln in f.read().splitlines() if ln]
        done = 0
        try:
            for i in range(0, len(lines), chunk):
                write(lines[i : i + chunk])
                done = i + len(lines[i : i + chunk])
        finally:
            rest = lines[done:]
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                if rest:
                    f.write("\n".join(rest) + "\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, self.path)
        return done


class BufferedWriter:
    """레코드를 모아서 flush 때 한 번에 쓴다. 스레드 안전."""

    def __init__(self, write: Callable[[list[str]], None], spool: Spool, measurement: str,
                 dedup: Dedup | None = None, max_batch: int = 5000):
        self._write = write
        self.spool = spool
        self.measurement = measurement
        self.dedup = dedup or Dedup()
        self.max_batch = max_batch
        self._buf: list[str] = []
        self._lock = threading.Lock()
        self.stats = {"written": 0, "duplicates": 0, "conflicts": 0, "spooled": 0,
                      "dropped": 0, "write_errors": 0}
        self.influx_ok = True

    def add_records(self, records: Iterable[Record]) -> None:
        with self._lock:
            for r in records:
                kind = self.dedup.check(r)
                if kind == "duplicate":
                    self.stats["duplicates"] += 1
                    continue
                if kind == "conflict":
                    # 같은 시각에 다른 값: 나중 값으로 덮어쓰되 건수는 남긴다
                    self.stats["conflicts"] += 1
                self._buf.append(record_line(self.measurement, r))

    def add_line(self, ln: str) -> None:
        with self._lock:
            self._buf.append(ln)

    def flush(self) -> None:
        with self._lock:
            batch, self._buf = self._buf, []
        # InfluxDB 가 돌아왔으면 밀린 것부터 쓴다 (실패하면 이번 것도 임시 저장)
        if self.spool.size() > 0:
            try:
                n = self.spool.drain(self._write)
                if n:
                    log.info("임시 저장분 %d줄 다시 씀", n)
                    self.stats["written"] += n
                self._set_ok(True)
            except Exception as e:  # noqa: BLE001 — 어떤 오류든 수집은 계속
                self._fail(batch, e)
                return
        for i in range(0, len(batch), self.max_batch):
            part = batch[i : i + self.max_batch]
            try:
                self._write(part)
                self.stats["written"] += len(part)
                self._set_ok(True)
            except Exception as e:  # noqa: BLE001
                self._fail(batch[i:], e)
                return

    def _fail(self, lines: list[str], err: Exception) -> None:
        self.stats["write_errors"] += 1
        if self.influx_ok:
            log.warning("InfluxDB 쓰기 실패, 디스크에 임시 저장: %s", err)
        self._set_ok(False)
        if not lines:
            return
        saved = self.spool.append(lines)
        self.stats["spooled"] += saved
        self.stats["dropped"] += len(lines) - saved
        if saved < len(lines):
            log.error("임시 저장 용량 초과로 %d줄 버림", len(lines) - saved)

    def _set_ok(self, ok: bool) -> None:
        if ok and not self.influx_ok:
            log.info("InfluxDB 쓰기 복구")
        self.influx_ok = ok
