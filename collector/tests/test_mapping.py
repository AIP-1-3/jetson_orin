import json

import pytest

from ts_collector.mapping import Mapper, SkipMessage, parse_timestamp, topic_matches

NOW = 1_760_918_460.0  # 2025-10-20 00:01:00 UTC

CFG = {
    "aliases": {"space": {"lecture1": "classroom_a"}, "metric": {"CO2": "co2"}},
    "sources": [
        {"name": "env-json", "topic": "sensors/+/env", "format": "json", "space": "{topic.1}",
         "sensor": "$.device", "timestamp": {"path": "$.ts", "unit": "s"},
         "metrics": {"co2": {"path": "$.co2"}, "temperature": {"path": "$.temp"},
                     "humidity": {"path": "$.hum"}}},
        {"name": "single", "topic": "building/+/+", "format": "raw", "space": "{topic.1}",
         "metric": "{topic.2}"},
    ],
}


def test_topic_wildcards():
    assert topic_matches("a/+/c", "a/b/c")
    assert not topic_matches("a/+/c", "a/b/c/d")
    assert topic_matches("a/#", "a/b/c")
    assert topic_matches("a/#", "a/b")
    assert not topic_matches("a/+", "a")


def test_json_message_to_records():
    m = Mapper(CFG)
    body = {"device": "s01", "ts": NOW - 30, "co2": 612, "temp": 23.4, "hum": 41}
    recs = m.parse("sensors/lecture1/env", json.dumps(body).encode(), NOW)
    by = {r.metric: r for r in recs}
    assert set(by) == {"co2", "temperature", "humidity"}
    assert by["co2"].space == "classroom_a"  # 별칭
    assert by["co2"].sensor == "s01"
    assert by["co2"].ts == NOW - 30 and by["co2"].ts_source == "sensor"  # 늦게 온 메시지는 센서 시각 그대로


def test_partial_message_keeps_present_metrics():
    recs = Mapper(CFG).parse("sensors/lounge/env", b'{"ts": 1, "co2": 500}', NOW)
    assert [r.metric for r in recs] == ["co2"]


def test_future_sensor_clock_falls_back_to_receive_time():
    recs = Mapper(CFG).parse("sensors/x/env", json.dumps({"ts": NOW + 3600, "co2": 1}).encode(), NOW)
    assert recs[0].ts == NOW and recs[0].ts_source == "recv"


def test_raw_payload_metric_from_topic():
    recs = Mapper(CFG).parse("building/meeting/CO2", b"640", NOW)
    assert (recs[0].space, recs[0].metric, recs[0].value, recs[0].ts_source) == ("meeting", "co2", 640.0, "recv")


@pytest.mark.parametrize("topic,payload", [
    ("sensors/x/env", b"not json"),
    ("sensors/x/env", b'{"co2": "abc"}'),
    ("other/topic", b"1"),
    ("building/meeting/CO2", b"nan"),
])
def test_bad_messages_are_skipped(topic, payload):
    with pytest.raises(SkipMessage):
        Mapper(CFG).parse(topic, payload, NOW)


def test_timestamp_units():
    assert parse_timestamp(1_760_918_400_000, "ms") == 1_760_918_400
    assert parse_timestamp("2025-10-20T00:00:00Z", "iso") == 1_760_918_400
    assert parse_timestamp("2025-10-20T09:00:00+09:00", "iso") == 1_760_918_400
    assert parse_timestamp("garbage", "s") is None


def test_format_change_needs_only_config():
    """과제 1 산출물 시나리오: 게이트웨이 펌웨어 업데이트로 메시지가 중첩 구조 + ms 시각으로 바뀜.

    전: sensors/lecture1/env  {"device":"s01","ts":1760918400,"co2":612,"temp":23.4}
    후: v2/sensors/lecture1   {"meta":{"id":"s01","time":1760918400000},"data":{"CO2":612,"T":23.4}}
    대응: sources 에 아래 항목 하나 추가. 코드 변경 없음.
    """
    cfg = {**CFG, "sources": [{
        "name": "env-json-v2", "topic": "v2/sensors/+", "space": "{topic.2}", "sensor": "$.meta.id",
        "timestamp": {"path": "$.meta.time", "unit": "ms"},
        "metrics": {"co2": {"path": "$.data.CO2"}, "temperature": {"path": "$.data.T"}},
    }] + CFG["sources"]}
    body = {"meta": {"id": "s01", "time": (NOW - 60) * 1000}, "data": {"CO2": 612, "T": 23.4}}
    recs = Mapper(cfg).parse("v2/sensors/lecture1", json.dumps(body).encode(), NOW)
    assert {(r.space, r.metric, r.value, r.sensor, r.ts) for r in recs} == {
        ("classroom_a", "co2", 612.0, "s01", NOW - 60),
        ("classroom_a", "temperature", 23.4, "s01", NOW - 60),
    }


def test_scale_and_offset():
    cfg = {"sources": [{"name": "t", "topic": "t/+", "space": "{topic.1}",
                        "metrics": {"temperature": {"path": "$.t", "scale": 0.1, "offset": -1}}}]}
    assert Mapper(cfg).parse("t/a", b'{"t": 235}', NOW)[0].value == pytest.approx(22.5)


def test_invalid_config_rejected():
    with pytest.raises(ValueError):
        Mapper({"sources": []})
    with pytest.raises(ValueError):
        Mapper({"sources": [{"name": "r", "topic": "x", "format": "raw", "space": "a"}]})


def test_wildcard_key_for_device_named_objects():
    """xflow 냉난방 상태처럼 값이 기기 이름 키 아래 있을 때."""
    cfg = {"sources": [{"name": "idu", "topic": "xflow/hvacr/idu/+/status", "space": "$.values.@key",
                        "sensor": "{topic.3}", "timestamp": {"path": "$.ts", "unit": "ms"},
                        "metrics": {"hvac_temperature": {"path": "$.values.*.current_temperature"},
                                    "hvac_power": {"path": "$.values.*.power"}}}]}
    body = {"ts": 1792459429395, "values": {"대표실-실내기": {"current_temperature": 20.7, "power": False}}}
    recs = Mapper(cfg).parse("xflow/hvacr/idu/4a84/status", json.dumps(body, ensure_ascii=False).encode(),
                             1792459430.0)
    by = {r.metric: r for r in recs}
    assert by["hvac_temperature"].space == "대표실-실내기" and by["hvac_temperature"].value == 20.7
    assert by["hvac_power"].value == 0.0 and by["hvac_power"].ts == 1792459429.395


def test_example_config_parses_real_chirpstack_and_hvac_messages():
    """2026-10-20 실제 브로커에서 받은 메시지 (rxInfo/txInfo 제외)."""
    import os

    import yaml

    cfg = yaml.safe_load(open(os.path.join(os.path.dirname(__file__), "..", "config.example.yaml"), encoding="utf-8"))
    m = Mapper(cfg)
    up = {"time": "2026-10-20T01:27:47.816+00:00",
          "deviceInfo": {"deviceProfileName": "AM107", "deviceName": "AM107-067999", "devEui": "24e124128c067999",
                         "tags": {"location": "실습실", "point": "후면 오른쪽", "spot": "후면 오른쪽"}},
          "fCnt": 106257, "object": {"infrared_and_visible": 31, "temperature": 23.4, "humidity": 60.5,
                                     "infrared": 5, "co2": 980, "pressure": 1002.8, "tvoc": 266,
                                     "activity": 0, "illumination": 44}}
    recs = m.parse("application/96b4d719-f23f-40aa-9f94-a0f2d0354342/device/24e124128c067999/event/up",
                   json.dumps(up, ensure_ascii=False).encode(), 1792459670.0)
    by = {r.metric: r for r in recs}
    assert by["co2"].value == 980 and by["co2"].space == "실습실" and by["co2"].sensor == "24e124128c067999"
    assert by["co2"].ts == pytest.approx(1792459667.816) and by["co2"].ts_source == "sensor"
    assert set(by) == {"co2", "temperature", "humidity", "tvoc", "pressure", "illumination", "activity", "infrared"}

    th = {"time": "2026-10-20T01:33:07.800+00:00", "deviceInfo": {"tags": {"location": "사무실"}},
          "object": {"humidity": 59, "battery": 35, "temperature": 22.5}}
    recs = m.parse("application/x/device/24e124785c389010/event/up", json.dumps(th).encode(), 1792459990.0)
    assert {r.metric for r in recs} == {"humidity", "battery", "temperature"}

    idu = {"ts": 1792459580627, "values": {"개발실-실내기": {
        "current_humidity": 48, "current_temperature": 22.3, "error_code": 0, "fan_speed": 0, "mode": 0,
        "online": True, "power": False, "target_temperature": 18}}}
    recs = m.parse("xflow/hvacr/idu/54427240-8598-11f1-bcac-bdfb397bbe8a/status",
                   json.dumps(idu, ensure_ascii=False).encode(), 1792459581.0)
    by = {r.metric: r for r in recs}
    assert by["hvac_power"].value == 0 and by["hvac_online"].value == 1
    assert by["hvac_current_temperature"].space == "개발실-실내기"

    with pytest.raises(SkipMessage):  # 게이트웨이 접속 상태(protobuf)는 수집 대상 아님
        m.parse("gateway/24e124fffef5dccc/state/conn", b"\x1a\x1024e124fffef5dccc", 1792459581.0)
