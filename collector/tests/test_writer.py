from ts_collector.mapping import Record
from ts_collector.writer import BufferedWriter, Dedup, Spool, line, record_line


def rec(ts=100.0, value=600.0, space="lecture 1", metric="co2"):
    return Record(space, metric, "s01", ts, value, ts + 2, "sensor", "src")


def test_line_protocol_escaping():
    ln = line("env", {"space": "a b,c", "sensor": ""}, {"value": 1.5, "n": 3, "ok": True}, 7)
    assert ln == "env,space=a\\ b\\,c value=1.5,n=3i,ok=true 7"
    assert record_line("env", rec()) == (
        "env,metric=co2,sensor=s01,space=lecture\\ 1,ts_source=sensor value=600.0,recv_lag_s=2.0 100000000000")


def test_dedup_detects_resend_and_conflict():
    d = Dedup(size=10)
    assert d.check(rec()) == "new"
    assert d.check(rec()) == "duplicate"
    assert d.check(rec(value=601)) == "conflict"
    assert d.check(rec(ts=160)) == "new"


class FakeInflux:
    def __init__(self):
        self.lines, self.up = [], True

    def __call__(self, lines):
        if not self.up:
            raise ConnectionError("down")
        self.lines.extend(lines)


def test_outage_spools_then_replays_in_order(tmp_path):
    db = FakeInflux()
    w = BufferedWriter(db, Spool(str(tmp_path / "spool.lp")), "env")
    w.add_records([rec(ts=1)])
    w.flush()
    db.up = False
    w.add_records([rec(ts=2), rec(ts=3)])
    w.flush()
    w.add_records([rec(ts=4)])
    w.flush()
    assert not w.influx_ok and w.stats["spooled"] == 3 and len(db.lines) == 1
    db.up = True
    w.add_records([rec(ts=5)])
    w.flush()
    assert w.influx_ok and w.spool.size() == 0
    assert [int(ln.split()[-1]) // 10**9 for ln in db.lines] == [1, 2, 3, 4, 5]
    assert w.stats["written"] == 5


def test_duplicates_not_written(tmp_path):
    db = FakeInflux()
    w = BufferedWriter(db, Spool(str(tmp_path / "s.lp")), "env")
    w.add_records([rec(), rec(), rec(value=700)])
    w.flush()
    assert len(db.lines) == 2 and w.stats["duplicates"] == 1 and w.stats["conflicts"] == 1


def test_spool_cap_drops_instead_of_filling_disk(tmp_path):
    db = FakeInflux()
    db.up = False
    w = BufferedWriter(db, Spool(str(tmp_path / "s.lp"), max_bytes=1), "env")
    w.add_records([rec(ts=1)])
    w.flush()  # 첫 줄은 들어감 (빈 파일)
    w.add_records([rec(ts=2)])
    w.flush()
    assert w.stats["spooled"] == 1 and w.stats["dropped"] == 1


def test_partial_replay_keeps_remaining(tmp_path):
    s = Spool(str(tmp_path / "s.lp"))
    s.append([f"l{i}" for i in range(10)])
    calls = []

    def flaky(lines):
        if calls:
            raise ConnectionError
        calls.append(lines)

    try:
        s.drain(flaky, chunk=4)
    except ConnectionError:
        pass
    assert calls == [["l0", "l1", "l2", "l3"]]
    assert open(s.path).read().split() == [f"l{i}" for i in range(4, 10)]
