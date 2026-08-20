"""The end-to-end paths — MISSION.md, Definition of done, Gate 3.

Two journeys, exactly as Rick ruled them (2026-08-15):

  PIPELINE (primary)   audio arrives -> upload -> transcribe -> clean -> extract ->
                       safety-check -> compile -> PDF generated -> distribution
                       recorded — driven over http against the local stack,
                       asserted at each observable stage.
  QUERY (secondary)    a known-answer question -> fn-query -> streamed answer with
                       citations that resolve to real entries.

REAL MODE, NOT MOCK. The serve env forces MOCK_MODE=false: Deepgram transcribes the
committed fixture (harness/fixtures/pipeline-audio.m4a), Claude cleans/extracts/
composes, DocRaptor renders (test mode — watermarked, never billed), Resend sends to
its own documented sink address (delivered@resend.dev — a real API call that is
deliverable to nobody, per FACTORY_RULES §2.8's local-sink rule). The pipeline's own
extracted entries become the query corpus via embed-on-write, so the secondary path
composes with the primary rather than running against seeded fiction.

WHY EACH STAGE IS CALLED EXPLICITLY: in production a DB trigger chain
(vox.pipeline_stage_router) dispatches the next stage through vault-stored secrets.
The local vault is empty, so the router's http hop no-ops — the harness drives each
hop itself with the same payload/headers the router sends, and asserts the DB state
transition the router would have observed. The `checked -> completed` hop IS pure SQL
inside the trigger and therefore runs locally — the E2E asserts the trigger did it,
not the harness.

Assertion rules (the template's, kept): assert what a user would notice, never a
status code alone; count the steps (the gate compares the count to a protected
floor); return None on failure having printed why.
"""
from __future__ import annotations

import datetime as dt
import json
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
AUDIO_FIXTURE = HERE / "fixtures" / "pipeline-audio.m4a"

# What the fixture audio says (see fixtures/README.md). Tokens chosen to be robust
# to STT variance: full words, no homophones.
EXPECT_TOKENS = ("duct bank", "concrete")
KNOWN_ANSWER_QUESTION = "What did we pour on the duct bank?"
UNANSWERABLE_QUESTION = "What color were the alpacas at the petting zoo yesterday?"
RESEND_SINK = "delivered@resend.dev"

STEPS = 0


def check(name: str, ok: bool, detail: str = "") -> bool:
    global STEPS
    STEPS += 1
    if ok:
        print(f"  ok    {name}", flush=True)
        return True
    print(f"  FAIL  {name}  {detail}", flush=True)
    return False


def _now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _poll(fn, want, timeout_s: int = 30, every: float = 0.5):
    """Poll fn() until it returns `want`-truthy or the deadline passes."""
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        last = fn()
        if want(last):
            return last
        time.sleep(every)
    return last


class Journey:
    """Per-run context shared between the pipeline and query journeys."""

    def __init__(self, app) -> None:
        self.app = app
        run = uuid.uuid4().hex[:10]
        self.email = f"gate-{run}@vox-harness.invalid"
        self.password = f"Gate!{run}x"
        self.user_id: str | None = None
        self.token: str | None = None
        self.observer_id: str | None = None
        self.project_id: str | None = None
        self.recording_id = str(uuid.uuid4())
        self.pipeline_run_id: str | None = None
        self.report_id: str | None = None
        self.entry_ids: list[str] = []
        self.storage_path: str | None = None
        self.pdf_path: str | None = None

    # ------------------------------------------------------------------ teardown
    def teardown(self) -> None:
        app, rid = self.app, self.recording_id
        try:
            if self.report_id:
                for tbl in ("report_distributions", "report_sections",
                            "report_entries"):
                    key = "report_id" if tbl == "report_distributions" \
                        else "daily_report_id"
                    app.rest("DELETE", f"{tbl}?{key}=eq.{self.report_id}",
                             schema="vox")
                app.rest("DELETE", f"daily_reports?id=eq.{self.report_id}",
                         schema="vox")
            app.rest("DELETE", f"search_chunks?recording_id=eq.{rid}", schema="vox")
            app.rest("DELETE", f"entries?recording_id=eq.{rid}", schema="vox")
            app.rest("DELETE", f"transcripts?recording_id=eq.{rid}", schema="vox")
            app.rest("DELETE", f"pipeline_runs?recording_id=eq.{rid}", schema="vox")
            app.rest("DELETE", f"recordings?id=eq.{rid}")
            if self.storage_path:
                app.storage_delete("audio", [self.storage_path])
            if self.pdf_path:
                app.storage_delete("reports", [self.pdf_path])
            if self.project_id:
                app.rest("DELETE", f"projects?id=eq.{self.project_id}")
            for uid in (self.user_id, self.observer_id):
                if uid:
                    app.admin_delete_user(uid)
        except Exception as e:                                     # noqa: BLE001
            print(f"  note  teardown left residue (local stack only): {e}",
                  flush=True)


def run_e2e_pipeline(app, ctx: Journey) -> int | None:
    global STEPS
    STEPS = 0

    # --- the user exists and signs in --------------------------------------
    ctx.user_id = app.admin_create_user(ctx.email, ctx.password)
    ctx.token = app.sign_in(ctx.email, ctx.password)
    if not check("a user can be provisioned and sign in",
                 bool(ctx.user_id and ctx.token)):
        return None

    status, proj, _ = app.rest("POST", "projects", {
        "name": f"Harness Gate {ctx.recording_id[:8]}", "user_id": ctx.user_id,
        "is_test": True})
    ctx.project_id = proj[0]["id"] if status == 201 and proj else None
    if not check("a project exists for the recording", bool(ctx.project_id),
                 f"status={status} body={str(proj)[:200]}"):
        return None

    # --- audio arrives: upload + recording row -----------------------------
    ctx.storage_path = f"{ctx.user_id}/{ctx.recording_id}.m4a"
    app.storage_upload("audio", ctx.storage_path, AUDIO_FIXTURE.read_bytes(),
                       "audio/mp4")
    status, rec, _ = app.rest("POST", "recordings", {
        "id": ctx.recording_id, "user_id": ctx.user_id,
        "project_id": ctx.project_id, "recorded_at": _now_iso(),
        "duration_seconds": 11, "storage_path": ctx.storage_path,
        "status": "recorded"})
    if not check("the audio is uploaded and the recording row exists",
                 status == 201, f"status={status} body={str(rec)[:200]}"):
        return None

    # --- upload completes -> the REAL trigger chain runs the pipeline -------
    # The harness seeded the local vault (appproc._seed_vault), so marking the
    # upload complete fires the exact production path: the upload trigger opens
    # the run, vox.trigger_initial_pipeline_stage dispatches fn-transcribe over
    # http, and vox.pipeline_stage_router chains every hop after it. The harness
    # drives nothing by hand — it asserts each stage's OBSERVABLE ARTIFACT after
    # the chain lands, which is what "asserted at each observable stage" means
    # when the stages run themselves.
    status, _, _ = app.rest("PATCH", f"recordings?id=eq.{ctx.recording_id}",
                            {"status": "uploaded"})
    run_row = _poll(
        lambda: app.rest("GET", f"pipeline_runs?recording_id=eq.{ctx.recording_id}"
                         "&select=id,status", schema="vox")[1],
        lambda rows: isinstance(rows, list) and rows, timeout_s=15)
    ctx.pipeline_run_id = run_row[0]["id"] if run_row else None
    if not check("marking the upload complete opens a pipeline run (DB trigger)",
                 bool(ctx.pipeline_run_id), f"rows={str(run_row)[:200]}"):
        return None

    terminal = {"completed", "failed", "dead_letter"}
    row = _poll(
        lambda: app.rest("GET", f"pipeline_runs?id=eq.{ctx.pipeline_run_id}"
                         "&select=status,has_safety_signals", schema="vox")[1],
        lambda rows: rows and rows[0]["status"] in terminal,
        timeout_s=300, every=2.0)
    final = row[0]["status"] if row else "?"
    if not check("the trigger chain ran the whole pipeline to completed "
                 "(transcribe -> clean -> extract -> safety-check -> close)",
                 final == "completed", f"final={final}"):
        return None

    # Artifacts, stage by stage:
    _, tr, _ = app.rest("GET", f"transcripts?recording_id=eq.{ctx.recording_id}"
                        "&select=raw_transcript,cleaned_transcript,"
                        "safety_check_result", schema="vox")
    raw_text = (tr[0].get("raw_transcript") or "") if tr else ""
    cleaned = (tr[0].get("cleaned_transcript") or "") if tr else ""
    if not check("the transcript carries the words that were spoken",
                 all(t in raw_text.lower() for t in EXPECT_TOKENS),
                 f"transcript={raw_text[:200]!r}"):
        return None
    if not check("AI cleanup produced a cleaned transcript",
                 len(cleaned) > 40, f"len={len(cleaned)}"):
        return None

    _, entries, _ = app.rest(
        "GET", f"entries?recording_id=eq.{ctx.recording_id}"
        "&select=id,entry_text,category,is_report_worthy", schema="vox")
    entries = entries if isinstance(entries, list) else []
    ctx.entry_ids = [e["id"] for e in entries]
    joined = " ".join(e["entry_text"].lower() for e in entries)
    if not check("extraction produced structured entries",
                 len(entries) >= 1, f"entries={len(entries)}"):
        return None
    if not check("an entry captures the concrete pour", "concrete" in joined,
                 f"entries={joined[:200]!r}"):
        return None

    chunks = _poll(
        lambda: app.rest("GET", f"search_chunks?recording_id=eq.{ctx.recording_id}"
                         "&select=id", schema="vox")[1],
        lambda rows: isinstance(rows, list) and rows, timeout_s=10)
    if not check("embed-on-write indexed the entries for query",
                 isinstance(chunks, list) and len(chunks) >= 1,
                 f"chunks={str(chunks)[:120]}"):
        return None

    if not check("the safety check left its verdict on the transcript",
                 tr and tr[0].get("safety_check_result") is not None,
                 f"transcript row={str(tr)[:160]}"):
        return None
    _, rec, _ = app.rest("GET", f"recordings?id=eq.{ctx.recording_id}"
                         "&select=status")
    if not check("the recording the user sees reads completed",
                 rec and rec[0]["status"] == "completed", f"rec={str(rec)[:120]}"):
        return None

    # --- compile: the daily report the user opens --------------------------
    today = dt.date.today().isoformat()
    status, rep, _ = app.rest("POST", "daily_reports", {
        "user_id": ctx.user_id, "project_id": ctx.project_id,
        "report_date": today, "status": "draft"}, schema="vox")
    ctx.report_id = rep[0]["id"] if status == 201 and rep else None
    if ctx.report_id:
        rows = [{"daily_report_id": ctx.report_id, "source_entry_id": e["id"],
                 "entry_text": e["entry_text"], "category": e["category"],
                 "recording_timestamp": _now_iso(), "is_report_worthy": True,
                 "recording_id": ctx.recording_id} for e in entries]
        status, _, _ = app.rest("POST", "report_entries", rows, schema="vox")
    if not check("a draft report exists with the day's entries",
                 bool(ctx.report_id) and status == 201, f"status={status}"):
        return None

    code, raw, _ = app._request(
        f"{app.base}/functions/v1/fn-report-compile", "POST",
        json.dumps({"daily_report_id": ctx.report_id}).encode("utf-8"),
        {"Content-Type": "application/json",
         "Authorization": f"Bearer {ctx.token}"}, 300)
    _, secs, _ = app.rest("GET", f"report_sections?daily_report_id=eq.{ctx.report_id}"
                          "&select=section_number,content", schema="vox")
    secs = secs if isinstance(secs, list) else []
    all_text = " ".join((s.get("content") or "") for s in secs).lower()
    if not check("compile produced the 13-section report as the user's JWT",
                 code == 200 and len(secs) == 13,
                 f"code={code} sections={len(secs)} body={raw[:200]!r}"):
        return None
    if not check("the composed report tells the story of the pour",
                 "concrete" in all_text, f"sections={all_text[:200]!r}"):
        return None

    # --- PDF: approve, render, verify the artifact -------------------------
    app.rest("PATCH", f"daily_reports?id=eq.{ctx.report_id}",
             {"status": "approved",
              "approval_metadata": {"timestamp": _now_iso(),
                                    "approved_by": ctx.user_id}}, schema="vox")
    code, raw, _ = app._request(
        f"{app.base}/functions/v1/fn-pdf-generate", "POST",
        json.dumps({"daily_report_id": ctx.report_id, "mode": "approval",
                    "report_type": "daily"}).encode("utf-8"),
        {"Content-Type": "application/json",
         "Authorization": f"Bearer {ctx.token}"}, 300)
    _, rep, _ = app.rest("GET", f"daily_reports?id=eq.{ctx.report_id}"
                         "&select=status,pdf_url", schema="vox")
    pdf_url = rep[0].get("pdf_url") if rep else None
    ctx.pdf_path = pdf_url
    pdf_bytes = app.storage_download("reports", pdf_url) if pdf_url else None
    if not check("a real PDF exists in storage (DocRaptor test mode)",
                 code == 200 and rep and rep[0]["status"] == "pdf_generated"
                 and pdf_bytes is not None and pdf_bytes[:4] == b"%PDF"
                 and len(pdf_bytes) > 10_000,
                 f"code={code} status={rep and rep[0].get('status')} "
                 f"pdf={pdf_url} bytes={0 if pdf_bytes is None else len(pdf_bytes)}"):
        return None

    # --- distribution recorded ---------------------------------------------
    code, raw, _ = app._request(
        f"{app.base}/functions/v1/fn-report-distribute", "POST",
        json.dumps({"daily_report_id": ctx.report_id, "report_type": "daily",
                    "trigger": "initial",
                    "recipients": [{"name": "Harness Sink",
                                    "email": RESEND_SINK}]}).encode("utf-8"),
        {"Content-Type": "application/json",
         "Authorization": f"Bearer {ctx.token}"}, 240)
    _, dist, _ = app.rest(
        "GET", f"report_distributions?report_id=eq.{ctx.report_id}"
        "&select=recipient_email,status,resend_email_id", schema="vox")
    dist = dist if isinstance(dist, list) else []
    sink = next((d for d in dist if d["recipient_email"] == RESEND_SINK), None)
    if not check("distribution is recorded per recipient with a Resend id",
                 code == 200 and sink is not None and sink["status"] == "sent"
                 and bool(sink.get("resend_email_id")),
                 f"code={code} rows={str(dist)[:200]} body={raw[:200]!r}"):
        return None
    _, rep, _ = app.rest("GET", f"daily_reports?id=eq.{ctx.report_id}"
                         "&select=status,distributed_at", schema="vox")
    if not check("the report's own status tells the distribution truth",
                 rep and rep[0]["status"] == "distributed"
                 and bool(rep[0].get("distributed_at")),
                 f"report={str(rep)[:160]}"):
        return None

    return STEPS


def run_e2e_query(app, ctx: Journey) -> int | None:
    global STEPS
    STEPS = 0

    def ask(text: str, token: str):
        return app.functions_sse("fn-query", {
            "mode": "query", "text": text, "scope": "own", "top_k": 8}, token)

    # --- the known-answer question ------------------------------------------
    events = ask(KNOWN_ANSWER_QUESTION, ctx.token)
    by_type: dict[str, list] = {}
    for ev, data in events:
        by_type.setdefault(ev, []).append(data)
    sources = (by_type.get("sources") or [{}])[0].get("sources") or []
    answer = "".join(d.get("t", "") for d in by_type.get("token", []))
    citations = [d.get("citation") or {} for d in by_type.get("citation", [])]

    if not check("the question finds the entries it should (sources > 0)",
                 len(sources) >= 1, f"sources={len(sources)}"):
        return None
    if not check("a streamed answer arrived and mentions the concrete pour",
                 len(answer) > 20 and "concrete" in answer.lower(),
                 f"answer={answer[:200]!r}"):
        return None
    cited_ids = {c.get("entry_id") for c in citations}
    if not check("at least one citation resolves to a real entry from the pipeline",
                 bool(cited_ids & set(ctx.entry_ids)),
                 f"cited={cited_ids} expected_any_of={ctx.entry_ids}"):
        return None
    if not check("the stream closed with a done event",
                 bool(by_type.get("done")), f"events={[e for e, _ in events]}"):
        return None

    # --- the honest abstention (unanswerable -> no model call) --------------
    events = ask(UNANSWERABLE_QUESTION, ctx.token)
    by_type = {}
    for ev, data in events:
        by_type.setdefault(ev, []).append(data)
    sources = (by_type.get("sources") or [{}])[0].get("sources") or []
    done = (by_type.get("done") or [{}])[0]
    first_token = (done.get("latency_ms") or {}).get("first_token")
    if not check("an unanswerable question abstains honestly "
                 "(0 sources, no model call)",
                 len(sources) == 0 and not by_type.get("citation")
                 and first_token == 0,
                 f"sources={len(sources)} first_token={first_token}"):
        return None

    # --- the company wall, asked as a user ----------------------------------
    run = uuid.uuid4().hex[:10]
    ctx.observer_id = app.admin_create_user(f"gate-obs-{run}@vox-harness.invalid",
                                            f"Gate!{run}x")
    observer_token = app.sign_in(f"gate-obs-{run}@vox-harness.invalid",
                                 f"Gate!{run}x")
    events = ask(KNOWN_ANSWER_QUESTION, observer_token)
    by_type = {}
    for ev, data in events:
        by_type.setdefault(ev, []).append(data)
    sources = (by_type.get("sources") or [{}])[0].get("sources") or []
    if not check("another user asking the same question sees nothing "
                 "(the wall holds in the query path)",
                 len(sources) == 0 and not by_type.get("citation"),
                 f"sources={len(sources)}"):
        return None

    return STEPS
