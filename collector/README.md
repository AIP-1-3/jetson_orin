# 과제 1. MQTT → InfluxDB 상시 수집기

센서 메시지를 MQTT 브로커에서 받아 **공간·항목·시각별로 InfluxDB 에 저장**한다.
메시지 형식은 전부 `config.yaml` 의 `sources` 로 정하므로, 형식이 바뀌거나 센서가 늘어도 코드는 고치지 않는다.

```
MQTT 브로커 ──► 수집기 ──(2초마다 묶어서)──► InfluxDB
  data.withio.net:1883    │                     measurement env: 태그 space, metric, sensor, ts_source
                          │                                      필드 value, recv_lag_s
                          ├─ 쓰기 실패 → /var/lib/ts-collector/spool.lp 에 모았다가 복구되면 순서대로 다시 씀
                          └─ 1분마다 collector_status (받은 건수, 중복, 오류, MQTT 접속 여부 …)
```

## 빠른 시작 (Jetson)

```bash
cd ~/jetson_orin/collector
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp config.example.yaml config.yaml          # host, bucket, sources 를 실제 값으로
export INFLUX_TOKEN=...                      # 비밀값은 환경 변수로만
.venv/bin/python -m ts_collector.collector -c config.yaml --check     # 설정 검사
.venv/bin/python -m ts_collector.collector -c config.yaml --dry-run   # 실제 메시지를 해석만 해서 출력 (저장 안 함)
.venv/bin/python -m ts_collector.collector -c config.yaml             # 수집
```

`--dry-run` 출력에서 공간·항목·값·시각이 맞게 나오는지 먼저 보고 저장을 켠다.

## 상시 가동 (재부팅 후 자동 시작)

systemd 등록은 sudo 가 필요하므로 팀 합의 후 관리자가 한 번 한다.

```bash
sudo useradd --system --no-create-home ts-collector
sudo mkdir -p /opt/ts-collector /etc/ts-collector
sudo cp -r ts_collector requirements.txt /opt/ts-collector/
sudo python3 -m venv /opt/ts-collector/.venv && sudo /opt/ts-collector/.venv/bin/pip install -r /opt/ts-collector/requirements.txt
sudo cp config.yaml /etc/ts-collector/config.yaml
sudo install -m 600 /dev/null /etc/ts-collector/env && sudoedit /etc/ts-collector/env   # INFLUX_TOKEN=... (MQTT_USERNAME/PASSWORD)
sudo cp ../config/ts-collector.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ts-collector
journalctl -u ts-collector -f
```

### sudo 권한이 없을 때 (임시)

관리자가 등록하기 전까지는 본인 계정 crontab 으로도 재부팅 후 자동 시작할 수 있다.
이때 `config.yaml` 의 `spool.path` 는 쓰기 가능한 곳(예: `/home/<id>/ts-collector/spool.lp`)으로 바꾼다.

```bash
crontab -e
# 아래 한 줄 추가: 재부팅 후 시작, 죽으면 5초 뒤 다시 실행
@reboot cd $HOME/jetson_orin/collector && . $HOME/.ts-collector.env && while true; do .venv/bin/python -m ts_collector.collector -c config.yaml >> $HOME/ts-collector.log 2>&1; sleep 5; done
```

`~/.ts-collector.env` 에는 `export INFLUX_TOKEN=...` 를 넣고 `chmod 600` 한다.

## 수집 현황 보고

```bash
.venv/bin/python -m ts_collector.coverage -c config.yaml --hours 24 -o coverage.md
```

공간·항목별 건수, 마지막 수신 시각, **커버율(1분 칸 중 값이 있는 비율)**, 3분 이상 빈 구간과 **추정 원인**을 표로 낸다.
원인은 수집기 상태 기록과 다른 항목의 결측을 같이 보고 아래처럼 나눈다.

| 판정 | 근거 |
|---|---|
| 수집기 정지 | 그 시간에 `collector_status` 기록이 없음 |
| 브로커/네트워크 끊김 | 수집기는 돌았지만 `mqtt_connected=false` |
| 전체 동시 결측 | 수집기·접속 정상인데 모든 항목이 함께 빔 → 브로커 쪽 송신 없음 |
| 이 공간 전체 결측 | 같은 공간 항목만 빔 → 그 공간 센서/게이트웨이 |
| 이 항목만 결측 | 한 항목만 빔 → 센서 |

## 확인 기준과 대응

| 기준 | 어떻게 충족하나 | 시험 |
|---|---|---|
| 브로커를 껐다 켜도 1분 안에 재개 | 자동 재접속(최대 15초 간격), 재접속마다 재구독 | `tests/test_integration.py::test_broker_restart_resumes_within_a_minute` |
| 재부팅 후 자동 재개 | systemd `Restart=always`, `WantedBy=multi-user.target` | 실제 장비에서 재부팅 시험 (팀 합의 후) |
| 24시간 커버율 95% | 결측 원인 판정 포함 보고 | `ts_collector.coverage` |
| InfluxDB 장애 시 손실 없음 | 디스크 임시 저장 후 순서대로 재전송 (상한 200MB) | `test_influx_outage_spools_and_replays` |

## 설계 결정 (보고서 "생각해 볼 점" 답)

- **어떤 시각을 저장하나**: 센서가 찍은 시각을 쓴다. 네트워크가 30초 밀려 한꺼번에 와도 각 값이 제자리 시각에 들어간다.
  받은 시각과의 차이는 `recv_lag_s` 로 같이 남겨 지연을 볼 수 있다. 센서 시각이 없거나 2분 넘게 미래(센서 시계 틀어짐)면
  받은 시각을 쓰고 `ts_source=recv` 로 표시한다.
- **재전송(심화 B)**: 최근 5만 점의 (공간, 항목, 센서, 시각)을 기억해 같은 값이 또 오면 쓰지 않고 `duplicates` 로 센다.
  같은 시각에 다른 값이 오면 덮어쓰고 `conflicts` 로 센다. InfluxDB 도 같은 시각의 점은 덮어쓰므로 저장 결과는 항상 한 점이다.
- **수집과 학습·추론이 같은 저장소를 쓸 때**: InfluxDB 는 읽기·쓰기를 동시에 처리하지만, 큰 학습용 조회가 쓰기를 늦출 수 있다.
  학습은 기간을 잘라 Parquet 로 내보낸 스냅샷으로 하고, 서비스는 최근 몇 시간만 조회한다.
  막 쓰이는 최근 1~2분은 아직 덜 들어왔을 수 있다 (과제 8 의 "막 시작된 5분 칸" 문제와 같음).
- **정제는 여기서 하지 않는다**: 0ppm 같은 값도 원본 그대로 저장한다. 정제 규칙은 과제 2 에서 정하고, 원본이 있어야 나중에 규칙을 바꿀 수 있다.

## 메시지 형식이 바뀐 상황 (산출물 예시)

게이트웨이 펌웨어 업데이트로 토픽과 본문 구조, 시각 단위가 바뀌었다고 가정한다.

```
전: sensors/lecture1/env  {"device":"s01","ts":1760918400,"co2":612,"temp":23.4}
후: v2/sensors/lecture1   {"meta":{"id":"s01","time":1760918400000},"data":{"CO2":612,"T":23.4}}
```

대응은 `config.yaml` 의 `sources` 맨 앞에 항목 하나 추가, 수집기 재시작. 코드 변경 없음.

```yaml
  - name: env-json-v2
    topic: v2/sensors/+
    space: "{topic.2}"
    sensor: $.meta.id
    timestamp: {path: $.meta.time, unit: ms}
    metrics:
      co2: {path: $.data.CO2}
      temperature: {path: $.data.T}
```

`tests/test_mapping.py::test_format_change_needs_only_config` 가 이 시나리오를 확인한다.

## 1년 저장 용량 추정 (심화 B)

4공간 × 3항목 × 1분 = 하루 17,280점, 1년 약 630만 점. InfluxDB 는 압축 후 점당 수 바이트라 **원본 1년이 수십 MB 수준**이다.
센서 종류가 10배로 늘어도 1GB 안쪽이라 원본 보관이 가능하다. 그래도 조회 속도를 위해:

- `sensors` 버킷: 원본, 보존 90일
- `sensors_5m` 버킷: 5분 평균·최소·최대·건수, 보존 무기한 (InfluxDB task 로 매시간 다운샘플)

실제 크기는 2주 수집 뒤 `du -sh` 로 재서 이 추정을 고친다.

## 테스트

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest -q        # 실제 MQTT 브로커(amqtt)와 가짜 InfluxDB 로 장애 시험 포함
```
