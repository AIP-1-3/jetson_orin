"""실제 MQTT 브로커(amqtt, 프로세스 안)와 가짜 InfluxDB HTTP 서버로 장애 시험.

확인 기준 대응:
  - 브로커를 껐다 켜도 1분 안에 수집 재개
  - InfluxDB 가 잠깐 죽어도 값을 잃지 않음 (임시 저장 → 복구 후 다시 씀)
  - 같은 메시지 재전송은 한 번만 저장
"""
import asyncio
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

amqtt_broker = pytest.importorskip("amqtt.broker")
mqtt = pytest.importorskip("paho.mqtt.client")

from ts_collector.collector import Collector  # noqa: E402


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class BrokerThread:
    def __init__(self, port):
        self.port = port
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        self.broker = None

    def _run(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(15)

    def start(self):
        async def mk():
            b = amqtt_broker.Broker({"listeners": {"default": {"type": "tcp", "bind": f"127.0.0.1:{self.port}"}}})
            await b.start()
            return b
        self.broker = self._run(mk())

    def stop(self):
        self._run(self.broker.shutdown())


class FakeInflux:
    def __init__(self):
        self.lines, self.up = [], True
        outer = self

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
                if not outer.up:
                    self.send_response(503)
                    self.end_headers()
                    return
                outer.lines.extend(ln for ln in body.splitlines() if ln)
                self.send_response(204)
                self.end_headers()

            def log_message(self, *a):
                pass

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def env_lines(self):
        return [ln for ln in self.lines if ln.startswith("env,")]


def wait_for(cond, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.2)
    return False


def publish(port, topic, body):
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    c.connect("127.0.0.1", port)
    c.loop_start()
    c.publish(topic, json.dumps(body), qos=1).wait_for_publish(5)
    c.loop_stop()
    c.disconnect()


@pytest.fixture
def env(tmp_path):
    port = free_port()
    broker = BrokerThread(port)
    broker.start()
    influx = FakeInflux()
    cfg = {
        "mqtt": {"host": "127.0.0.1", "port": port, "client_id": f"t-{port}", "max_reconnect_delay_s": 2},
        "influx": {"url": influx.url, "org": "o", "bucket": "b", "flush_interval_s": 0.3},
        "spool": {"path": str(tmp_path / "spool.lp")},
        "heartbeat_interval_s": 1,
        "sources": [{"name": "env", "topic": "sensors/+/env", "space": "{topic.1}",
                     "timestamp": {"path": "$.ts", "unit": "s"},
                     "metrics": {"co2": {"path": "$.co2"}, "temperature": {"path": "$.temp"}}}],
    }
    from ts_collector.collector import make_influx_write
    col = Collector(cfg, write=make_influx_write(cfg["influx"]))
    t = threading.Thread(target=col.run, daemon=True)
    t.start()
    assert wait_for(lambda: col.mqtt_connected, 10)
    yield broker, influx, col, port
    col.stop()
    t.join(10)
    try:
        broker.stop()
    except Exception:
        pass


def test_end_to_end_dedup_and_heartbeat(env):
    broker, influx, col, port = env
    now = int(time.time())
    msg = {"ts": now, "co2": 612, "temp": 23.4}
    publish(port, "sensors/lecture1/env", msg)
    publish(port, "sensors/lecture1/env", msg)  # 재전송
    publish(port, "sensors/lecture1/env", {"ts": now, "co2": "broken"})  # 해석 불가 → 건너뜀
    assert wait_for(lambda: len(influx.env_lines()) == 2 and col.writer.stats["duplicates"] == 2, 10)
    assert any("space=lecture1" in ln and "value=612.0" in ln for ln in influx.env_lines())
    assert wait_for(lambda: any(ln.startswith("collector_status,") for ln in influx.lines), 5)
    assert col.counts["parse_errors"] >= 1


def test_broker_restart_resumes_within_a_minute(env):
    broker, influx, col, port = env
    broker.stop()
    assert wait_for(lambda: not col.mqtt_connected, 10)
    time.sleep(3)
    t0 = time.time()
    broker.start()
    assert wait_for(lambda: col.mqtt_connected, 60), "브로커 재시작 후 재접속 실패"
    elapsed = time.time() - t0
    publish(port, "sensors/lounge/env", {"ts": int(time.time()), "co2": 450})
    assert wait_for(lambda: any("space=lounge" in ln for ln in influx.env_lines()), 10)
    assert elapsed < 60
    assert col.counts["reconnects"] >= 1


def test_influx_outage_spools_and_replays(env):
    broker, influx, col, port = env
    influx.up = False
    base = int(time.time()) - 600
    for i in range(5):
        publish(port, "sensors/meeting/env", {"ts": base + 60 * i, "co2": 500 + i})
    assert wait_for(lambda: col.writer.stats["spooled"] >= 5 and not col.writer.influx_ok, 10)
    assert not influx.env_lines()
    influx.up = True
    assert wait_for(lambda: len([ln for ln in influx.env_lines() if "space=meeting" in ln]) == 5, 10)
    assert col.writer.influx_ok and col.writer.spool.size() == 0
