"""opx_sandy_view 1.4.17 -- tools/songbird/patch.py: Phantom Liberty's story waits for a switch.

WHY. A female V's pristine world never started Phantom Liberty, so 1.4.13 sets the two
facts the expansion's graph waits on (`ep1_active`, `ep1_side_content`): Dogtown's
people, its gate, its gigs and minor quests open. But the same `ep1_active` also lets the
expansion's MAIN story start: `ep1\\quest\\ep1.questphase`, top-level node [14]
(questPauseCondition `ep1_active >= 1`) -> [16] -> [22] -> [9] `ep1_main_quests`, whose
q301 waits ten seconds, then rings Songbird's holocall, activates "Dog Eat Dog" and tracks
"Go to the Dogtown border". 1.4.16 refused the call in the phone system, but the quest
still went active (`q301_started 1` in the 2026-10-01 12:04 UTC log) and the holocall
scene still played her voice: refusing the phone screen is not refusing the scene.

WHAT THIS CHANGES. One string in one chunk: node [14]'s fact `ep1_active` becomes
`opx_songbird_on`. Nothing else in the file changes (checked below, chunk by chunk). The
expansion's main story then waits until `opx_songbird_on >= 1` -- which nothing sets
unless an operator wants the story back. Every other reader of `ep1_active` (the open
world, the minor quests, the additional game elements, the bug fixing phase) is
untouched, so what 1.4.13 opened stays open. A world whose story already started (the
male save: node [14] passed long ago, its state is in the save) is not affected.

Usage (on the machine with the game's ep1 archives):
  python3 patch.py <ep1_2_gamedata.archive> <out dir>
Writes <out dir>/ep1.questphase (patched), <out dir>/opx_songbird.archive and prints
what changed. Needs cr2wscene.py (this folder or PYTHONPATH), and for the archive
~/rdar.py, ~/kark.py and ~/ooz/libooz.so as mkarchive.py does.
"""
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.expanduser("~"))
import cr2wscene as C  # noqa: E402

DEPOT = r"ep1\quest\ep1.questphase"
NODE = 14
OLD = "ep1_active"
NEW = "opx_songbird_on"
MAIN_QUESTS = r"ep1\quest\main_quests\ep1_main_quests.questphase"


def P(e, name):
    for n, t, v in e["props"]:
        if n == name:
            return v
    return None


def set_prop(e, name, value):
    for i, (n, t, v) in enumerate(e["props"]):
        if n == name:
            e["props"][i] = (n, t, value)
            return t
    raise KeyError(name)


def index_of(doc, e):
    for i, x in enumerate(doc["exports"], start=1):
        if x is e:
            return i
    raise AssertionError("not an export of this doc")


def deref(doc, h):
    assert h is not None and h[0] == "h" and h[1] > 0, h
    return doc["exports"][h[1] - 1]


def handle_refs(doc):
    counts = {}

    def walk(v):
        tag = v[0]
        if tag == "h" and v[1] > 0:
            counts[v[1]] = counts.get(v[1], 0) + 1
        elif tag == "a":
            for x in v[1]:
                walk(x)
        elif tag == "c":
            for _, _, x in v[1]:
                walk(x)
    for e in doc["exports"]:
        for _, _, v in e["props"]:
            walk(v)
    return counts


def top_node(doc, nid):
    graph = deref(doc, P(doc["exports"][0], "graph"))
    for h in P(graph, "nodes")[1]:
        e = deref(doc, h)
        if P(e, "id") == ("p", nid):
            return e
    raise AssertionError(("no top-level node", nid))


def comparison_of(doc, nid):
    q = top_node(doc, nid)
    assert q["cls"] == "questPauseConditionNodeDefinition", q["cls"]
    cond = deref(doc, P(q, "condition"))
    assert cond["cls"] == "questFactsDBCondition", cond["cls"]
    cmp_ = deref(doc, P(cond, "type"))
    assert cmp_["cls"] == "questVarComparison_ConditionType", cmp_["cls"]
    return cmp_


def phase_resource(e):
    """The depot path a questPhaseNodeDefinition loads (its phaseResource import)."""
    v = P(e, "phaseResource")
    return v


def patch(data):
    doc = C.read_doc(data)
    # the main story's phase is node [9], and [14] is what it waits on (via [16] -> [22])
    nine = top_node(doc, 9)
    assert nine["cls"] == "questPhaseNodeDefinition", nine["cls"]
    ref = phase_resource(nine)
    assert ref is not None and ref[0] == "r", ref
    path = doc["imports"][ref[1] - 1][0] if ref[1] > 0 else None
    assert path is not None and path.replace("/", "\\").lower() == MAIN_QUESTS.lower(), path
    cmp_ = comparison_of(doc, NODE)
    cur = P(cmp_, "factName")
    assert cur is not None and cur[1] == OLD, cur
    value = P(cmp_, "value")
    how = P(cmp_, "comparisonType")
    assert value is not None and value[1] == 1, value
    assert how is not None and how[1] == "GreaterOrEqual", how
    idx = index_of(doc, cmp_)
    assert handle_refs(doc).get(idx, 0) == 1, "the comparison chunk is shared"
    set_prop(cmp_, "factName", (cur[0], NEW) + tuple(cur[2:]))
    out = C.write_doc(doc, allow_new_names=True)
    # every chunk but the one is unchanged; existing names keep their indices
    before, after = C.read_doc(data), C.read_doc(out)
    assert len(before["exports"]) == len(after["exports"])
    if before.get("names") is not None:
        assert after["names"][:len(before["names"])] == before["names"]
    for i, (a, b) in enumerate(zip(before["exports"], after["exports"]), start=1):
        if i == idx:
            assert a["cls"] == b["cls"] and a["props"] != b["props"], i
        else:
            assert a == b, ("unexpected change", i)
    assert P(comparison_of(after, NODE), "factName")[1] == NEW
    return out, idx, path


if __name__ == "__main__":
    from rdar import Archive, fnv1a64  # noqa: E402
    import mkarchive  # noqa: E402
    src, outdir = sys.argv[1], sys.argv[2]
    base = Archive(src)
    data = base.read(DEPOT)
    assert data, "ep1.questphase is not in " + src
    assert fnv1a64(DEPOT.lower()) in base.files, "the depot path's hash is not the base game's"
    out, idx, path = patch(data)
    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "ep1.questphase"), "wb").write(out)
    arc = mkarchive.build({DEPOT: out})
    open(os.path.join(outdir, "opx_songbird.archive"), "wb").write(arc)
    back = Archive(os.path.join(outdir, "opx_songbird.archive")).read(DEPOT)
    assert back == out, "the archive does not give the patched file back"
    print("base     %s  %d bytes  sha256 %s" % (DEPOT, len(data), hashlib.sha256(data).hexdigest()))
    print("patched  %s  %d bytes  sha256 %s" % (DEPOT, len(out), hashlib.sha256(out).hexdigest()))
    print("node [%d] (chunk %d) waits on %s >= 1 -> %s >= 1; node [9] loads %s" % (NODE, idx, OLD, NEW, path))
    print("archive  opx_songbird.archive  %d bytes  sha256 %s" % (len(arc), hashlib.sha256(arc).hexdigest()))
