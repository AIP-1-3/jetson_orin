from ts_collector.coverage import analyze, render

T0 = 1_760_918_400.0  # 분 경계
H = 60  # 1시간 = 60칸


def minutes(*ranges):
    return [T0 + m * 60 + 5 for a, b in ranges for m in range(a, b)]


def test_coverage_and_gap_causes():
    points = {
        ("a", "co2"): minutes((0, 20), (30, 60)),  # 20~30분: 전체 결측 (a, b 모두)
        ("a", "temperature"): minutes((0, 20), (30, 45), (50, 60)),  # 45~50: 이 항목만
        ("b", "co2"): minutes((0, 20), (30, 60)),
    }
    hb = {int(T0 // 60) + m: True for m in range(0, 60)}
    reps = {(r.space, r.metric): r for r in analyze(points, T0, T0 + H * 60, hb, min_gap=3)}
    assert reps[("a", "co2")].covered == 50 and abs(reps[("a", "co2")].coverage - 50 / 60) < 1e-9
    gaps = [(g.start - T0 // 60, g.end - T0 // 60, g.cause) for g in reps[("a", "temperature")].gaps]
    assert gaps[0][:2] == (20, 30) and gaps[0][2].startswith("전체 동시 결측")
    assert gaps[1][:2] == (45, 50) and gaps[1][2].startswith("이 항목만")


def test_collector_down_and_mqtt_disconnect_are_distinguished():
    points = {("a", "co2"): minutes((0, 10), (20, 30), (40, 60))}
    hb = {}
    for m in range(60):
        if 10 <= m < 20:
            continue  # 수집기 정지: 상태 기록 없음
        hb[int(T0 // 60) + m] = not (30 <= m < 40)  # 30~40: 접속 끊김
    causes = [g.cause for g in analyze(points, T0, T0 + H * 60, hb)[0].gaps]
    assert causes[0].startswith("수집기 정지")
    assert causes[1].startswith("브로커/네트워크 끊김")


def test_same_space_gap():
    points = {
        ("a", "co2"): minutes((0, 10), (30, 60)),
        ("a", "humidity"): minutes((0, 10), (30, 60)),
        ("b", "co2"): minutes((0, 60)),
    }
    gap = analyze(points, T0, T0 + H * 60)[0].gaps[0]
    assert gap.cause.startswith("이 공간 전체 결측")


def test_short_gaps_ignored_and_render():
    points = {("a", "co2"): minutes((0, 58))}  # 마지막 2분은 min_gap(3) 미만
    reps = analyze(points, T0, T0 + H * 60)
    assert reps[0].gaps == []
    md = render(reps, T0, T0 + H * 60)
    assert "| a | co2 | 58 |" in md and "96.7%" in md and "OK" in md
