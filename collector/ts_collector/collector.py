"""MQTT → InfluxDB 상시 수집기.

  python -m ts_collector.collector -c config.yaml            # 수집
  python -m ts_collector.collector -c config.yaml --dry-run  # 해석 결과만 출력, 저장 안 함
  python -m ts_collector.collector -c config.yaml --check    # 설정만 검사

비밀값(MQTT 비밀번호, InfluxDB 토큰)은 설정 파일이 아니라 환경 변수로 받는다.
"""
from __future__ import annotations

import argparse
import logging
import os
import signal
import socket
import sys
import threading
import time

import yaml

from .mapping import Mapper, SkipMessage
from .writer import BufferedWriter, Dedup, Spool, line

log = logging.getLogger("ts_collector")


def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
    for sec in ("mqtt", "influx"):
        cfg.setdefault(sec, {})
    return cfg


def _env(cfg: dict, key: str) -> str | None:
    """cfg 에 key_env 가 있으면 그 환경 변수, 없으면 cfg[key]."""
    name = cfg.get(f"{key}_env")
    if name:
        return os.environ.get(name)
    return cfg.get(key)


def make_influx_write(icfg: dict):
    from influxdb_client import InfluxDBClient, WritePrecision
    from influxdb_client.client.write_api import SYNCHRONOUS

    client = InfluxDBClient(url=icfg.get("url", "http://localhost:8086"), token=_env(icfg, "token") or "",
                            org=icfg.get("org", "-"), timeout=int(icfg.get("timeout_ms", 10_000)))
    api = client.write_api(write_options=SYNCHRONOUS)
    bucket, org = icfg.get("bucket", "sensors"), icfg.get("org", "-")

    def write(lines: list[str]) -> None:
        api.write(bucket=bucket, org=org, record=lines, write_precision=WritePrecision.NS)

    return write


class Collector:
    def __init__(self, cfg: dict, write=None, dry_run: bool = False):
        self.cfg = cfg
        self.mapper = Mapper(cfg)
        self.dry_run = dry_run
        icfg = cfg["influx"]
        self.measurement = icfg.get("measurement", "env")
        self.status_measurement = icfg.get("status_measurement", "collector_status")
        scfg = cfg.get("spool") or {}
        spool = Spool(scfg.get("path", "/var/lib/ts-collector/spool.lp"),
                      int(scfg.get("max_mb", 200)) * 1024 * 1024)
        if write is None and not dry_run:
            write = make_influx_write(icfg)
        self.writer = BufferedWriter(write or (lambda lines: None), spool, self.measurement,
                                     Dedup(int(cfg.get("dedup_window", 50_000))))
        self.flush_s = float(icfg.get("flush_interval_s", 2))
        self.heartbeat_s = float(cfg.get("heartbeat_interval_s", 60))
        self.host = socket.gethostname()
        self.started = time.time()
        self.counts = {"messages": 0, "records": 0, "parse_errors": 0, "reconnects": 0}
        self.mqtt_connected = False
        self._ever_connected = False
        self._stop = threading.Event()
        self.client = self._make_mqtt()

    # ---- MQTT ----
    def _make_mqtt(self):
        import paho.mqtt.client as mqtt

        m = self.cfg["mqtt"]
        client_id = m.get("client_id") or f"ts-collector-{self.host}"
        # clean_session=False + 고정 client_id: 수집기가 잠깐 죽어도 브로커가 QoS1 메시지를 보관
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id,
                        clean_session=bool(m.get("clean_session", False)))
        user = _env(m, "username")
        if user:
            c.username_pw_set(user, _env(m, "password"))
        if m.get("tls"):
            c.tls_set()
        c.reconnect_delay_set(min_delay=1, max_delay=int(m.get("max_reconnect_delay_s", 15)))
        c.on_connect = self._on_connect
        c.on_disconnect = self._on_disconnect
        c.on_message = self._on_message
        return c

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            log.error("MQTT 접속 거부: %s", reason_code)
            return
        if self._ever_connected:
            self.counts["reconnects"] += 1
        self._ever_connected = True
        self.mqtt_connected = True
        qos = int(self.cfg["mqtt"].get("qos", 1))
        # 재접속마다 다시 구독 (브로커가 세션을 잃었어도 복구)
        client.subscribe([(t, qos) for t in self.mapper.subscriptions()])
        log.info("MQTT 접속, 구독: %s", ", ".join(self.mapper.subscriptions()))

    def _on_disconnect(self, client, userdata, flags, reason_code, properties):
        self.mqtt_connected = False
        if not self._stop.is_set():
            log.warning("MQTT 끊김(%s), 자동 재접속 대기", reason_code)

    def _on_message(self, client, userdata, msg):
        self.handle(msg.topic, msg.payload, time.time())

    def handle(self, topic: str, payload: bytes, recv_ts: float) -> None:
        self.counts["messages"] += 1
        try:
            records = self.mapper.parse(topic, payload, recv_ts)
        except SkipMessage as e:
            self.counts["parse_errors"] += 1
            log.debug("건너뜀 %s: %s", topic, e)
            return
        except Exception:  # noqa: BLE001 — 메시지 하나 때문에 수집기가 죽으면 안 된다
            self.counts["parse_errors"] += 1
            log.exception("해석 중 오류: %s", topic)
            return
        self.counts["records"] += len(records)
        if self.dry_run:
            for r in records:
                print(f"{r.space:>12} {r.metric:<12} {r.value:>10.2f}  ts={r.ts:.0f}({r.ts_source}) "
                      f"lag={r.recv_ts - r.ts:.1f}s sensor={r.sensor} src={r.source}", flush=True)
            return
        self.writer.add_records(records)

    # ---- 주기 작업 ----
    def status_line(self) -> str:
        s = self.writer.stats
        fields = {**self.counts, **s, "spool_bytes": self.writer.spool.size(),
                  "mqtt_connected": self.mqtt_connected, "influx_ok": self.writer.influx_ok,
                  "uptime_s": int(time.time() - self.started)}
        return line(self.status_measurement, {"host": self.host}, fields, time.time_ns())

    def _periodic(self) -> None:
        next_hb = time.monotonic()
        while not self._stop.wait(self.flush_s):
            try:
                if not self.dry_run and time.monotonic() >= next_hb:
                    self.writer.add_line(self.status_line())
                    next_hb = time.monotonic() + self.heartbeat_s
                    log.info("상태 %s spool=%dB", {**self.counts, **self.writer.stats},
                             self.writer.spool.size())
                if not self.dry_run:
                    self.writer.flush()
            except Exception:  # noqa: BLE001
                log.exception("주기 작업 오류 (다음 주기에 재시도)")

    def run(self) -> None:
        m = self.cfg["mqtt"]
        t = threading.Thread(target=self._periodic, name="flush", daemon=True)
        t.start()
        host, port = m.get("host", "localhost"), int(m.get("port", 1883))
        log.info("MQTT %s:%d 접속 시도", host, port)
        self.client.connect_async(host, port, keepalive=int(m.get("keepalive", 30)))
        self.client.loop_start()
        try:
            while not self._stop.wait(1):
                pass
        finally:
            self.client.loop_stop()
            self.client.disconnect()
            if not self.dry_run:
                self.writer.flush()
            log.info("종료")

    def stop(self, *_):
        self._stop.set()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="MQTT → InfluxDB 수집기")
    ap.add_argument("-c", "--config", default=os.environ.get("TS_COLLECTOR_CONFIG", "config.yaml"))
    ap.add_argument("--dry-run", action="store_true", help="해석 결과만 출력하고 저장하지 않음")
    ap.add_argument("--check", action="store_true", help="설정 파일만 검사")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    cfg = load_config(a.config)
    if a.check:
        mapper = Mapper(cfg)
        print("설정 OK. 구독 토픽:", ", ".join(mapper.subscriptions()))
        return 0
    c = Collector(cfg, dry_run=a.dry_run)
    signal.signal(signal.SIGTERM, c.stop)
    signal.signal(signal.SIGINT, c.stop)
    c.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
