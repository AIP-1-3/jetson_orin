"""MQTT 메시지 → (공간, 항목, 시각, 값) 레코드 변환.

메시지 형식은 전부 설정(YAML 의 sources)으로 정한다. 새 센서나 형식 변경은
여기 코드를 고치지 않고 sources 항목을 추가/수정해서 대응한다.

값을 꺼내는 표현식 (space, sensor, metric, timestamp.path, metrics.*.path 공통):
  "{topic.1}"     토픽을 '/' 로 나눈 1번째 조각 (0부터)
  "$.a.b.0.c"     JSON 본문의 경로 (숫자는 리스트 인덱스)
  "lecture-1"     그 외는 고정 문자열
  "{topic.1}-{topic.2}" 처럼 섞어 쓸 수 있다 (JSON 경로는 단독으로만)
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

_TOPIC_REF = re.compile(r"\{topic\.(\d+)\}")


class SkipMessage(Exception):
    """이 소스로는 해석할 수 없는 메시지 (파싱 오류로 집계)."""


@dataclass(frozen=True)
class Record:
    space: str
    metric: str
    sensor: str
    ts: float  # 저장에 쓰는 시각 (epoch 초)
    value: float
    recv_ts: float  # 수집기가 받은 시각 (epoch 초)
    ts_source: str  # "sensor" | "recv" — ts 를 어디서 가져왔나
    source: str  # 설정의 sources[].name


def topic_matches(pattern: str, topic: str) -> bool:
    """MQTT 와일드카드(+, #) 매칭."""
    p_parts = pattern.split("/")
    t_parts = topic.split("/")
    for i, p in enumerate(p_parts):
        if p == "#":
            return True
        if i >= len(t_parts):
            return False
        if p != "+" and p != t_parts[i]:
            return False
    return len(p_parts) == len(t_parts)


def _json_path(body: Any, path: str) -> Any:
    cur = body
    for key in path[2:].split(".") if path != "$" else []:
        if isinstance(cur, list):
            try:
                cur = cur[int(key)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            if key not in cur:
                return None
            cur = cur[key]
        else:
            return None
    return cur


def resolve(expr: Any, topic_parts: list[str], body: Any) -> Any:
    if not isinstance(expr, str):
        return expr
    if expr.startswith("$"):
        return _json_path(body, expr)

    def sub(m: re.Match) -> str:
        i = int(m.group(1))
        if i >= len(topic_parts):
            raise SkipMessage(f"토픽 조각 {i} 없음")
        return topic_parts[i]

    return _TOPIC_REF.sub(sub, expr)


def parse_timestamp(raw: Any, unit: str) -> float | None:
    if raw is None or raw == "":
        return None
    try:
        if unit == "iso":
            dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        v = float(raw)
    except (TypeError, ValueError):
        return None
    return {"s": v, "ms": v / 1e3, "us": v / 1e6, "ns": v / 1e9}.get(unit)


class Source:
    """설정 파일의 sources 항목 하나."""

    def __init__(self, cfg: dict, aliases: dict | None = None):
        self.name = cfg["name"]
        self.topic = cfg["topic"]
        self.format = cfg.get("format", "json")
        if self.format not in ("json", "raw"):
            raise ValueError(f"{self.name}: format 은 json 또는 raw")
        self.space = cfg["space"]
        self.sensor = cfg.get("sensor", "")
        ts = cfg.get("timestamp") or {}
        self.ts_path = ts.get("path")
        self.ts_unit = ts.get("unit", "s")
        if self.format == "raw":
            if "metric" not in cfg:
                raise ValueError(f"{self.name}: raw 형식은 metric 이 필요")
            self.metrics = {cfg["metric"]: {"path": None}}
        else:
            self.metrics = cfg.get("metrics") or {}
            if not self.metrics:
                raise ValueError(f"{self.name}: metrics 가 비어 있음")
        aliases = aliases or {}
        self.space_alias = aliases.get("space", {})
        self.metric_alias = aliases.get("metric", {})

    def matches(self, topic: str) -> bool:
        return topic_matches(self.topic, topic)

    def parse(self, topic: str, payload: bytes, recv_ts: float, max_skew_s: float) -> list[Record]:
        parts = topic.split("/")
        text = payload.decode("utf-8", errors="replace").strip()
        if self.format == "json":
            try:
                body = json.loads(text)
            except json.JSONDecodeError as e:
                raise SkipMessage(f"JSON 아님: {e}") from None
        else:
            body = text

        space = resolve(self.space, parts, body)
        if not space:
            raise SkipMessage("공간을 알 수 없음")
        space = self.space_alias.get(str(space), str(space))
        sensor = str(resolve(self.sensor, parts, body) or "")

        ts, ts_source = recv_ts, "recv"
        if self.ts_path:
            sensor_ts = parse_timestamp(resolve(self.ts_path, parts, body), self.ts_unit)
            # 센서 시각이 미래로 너무 앞서 있으면(시계 틀어짐) 받은 시각을 쓴다.
            # 늦게 도착한 과거 시각은 그대로 쓴다: 네트워크 지연분이 제자리로 들어간다.
            if sensor_ts is not None and sensor_ts <= recv_ts + max_skew_s:
                ts, ts_source = sensor_ts, "sensor"

        out = []
        for metric_expr, mcfg in self.metrics.items():
            mcfg = mcfg or {}
            raw = body if self.format == "raw" else resolve(mcfg.get("path"), parts, body)
            if raw is None:
                continue  # 이 메시지엔 이 항목이 없음 (센서마다 보내는 항목이 다를 수 있음)
            try:
                value = float(raw) * float(mcfg.get("scale", 1)) + float(mcfg.get("offset", 0))
            except (TypeError, ValueError):
                continue
            if value != value:  # NaN
                continue
            metric = str(resolve(metric_expr, parts, body))
            metric = self.metric_alias.get(metric, metric)
            out.append(Record(space, metric, sensor, ts, value, recv_ts, ts_source, self.name))
        if not out:
            raise SkipMessage("값이 하나도 없음")
        return out


class Mapper:
    def __init__(self, cfg: dict):
        aliases = cfg.get("aliases") or {}
        self.sources = [Source(s, aliases) for s in cfg.get("sources") or []]
        if not self.sources:
            raise ValueError("sources 가 비어 있음")
        self.max_skew_s = float((cfg.get("time") or {}).get("max_future_skew_s", 120))

    def subscriptions(self) -> list[str]:
        return sorted({s.topic for s in self.sources})

    def parse(self, topic: str, payload: bytes, recv_ts: float) -> list[Record]:
        """첫 번째로 맞는 소스로 해석한다. 맞는 소스가 없으면 SkipMessage."""
        for s in self.sources:
            if s.matches(topic):
                return s.parse(topic, payload, recv_ts, self.max_skew_s)
        raise SkipMessage(f"맞는 소스 없음: {topic}")
