"""Reach the software under test. For VOX that is the LOCAL SUPABASE STACK plus
`supabase functions serve` — driver `http`, with three VOX-specific departures from
the template (templates/harness/appproc.py), each stated because it changes what
`APP_STARTED` means:

  1. FIXED PORTS, SINGLE INSTANCE. The stack is keyed to this directory (54321/54322);
     there is no dynamic port. Two runs cannot collide on ports — instead they would
     silently SHARE an environment, which is worse. So the driver FAILS if another
     process already owns the functions gateway: this run must be the only owner of
     what it is asserting against.
  2. THE ENV IS ASSEMBLED, NOT INHERITED. `supabase functions serve` gets a generated
     env file (written to .factory/runs/, gitignored, mode 600) merged from
     supabase/functions/.env plus named keys lifted from .env.local, plus forced
     values from harness.config.json — MOCK_MODE=false so the E2E exercises the real
     pipeline, DOCRAPTOR_TEST_MODE=true so a gate can never bill a production PDF.
     The harness never edits the protected .env* files themselves.
  3. SERVE OUTPUT GOES TO A REAL FILE, NEVER A PIPE. The serve process wraps a Docker
     edge runtime — a daemon-shaped child. Capturing its stdout in a pipe is the
     exact deadlock the template README documents for browser CLIs.

The universal parts are kept: WAIT for an answer rather than sleeping; FAIL HARD if
it never comes up (never "not testable"); TEAR DOWN on every path.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RUNS = ROOT / ".factory" / "runs"


class AppDidNotStart(RuntimeError):
    pass


def _parse_env_text(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"').strip("'")
        out[k.strip()] = v
    return out


def stack_env(start_timeout_s: int = 300) -> dict[str, str]:
    """Resolve the local stack's URL and keys, starting the stack if it is down.

    Handles both key namings (`ANON_KEY`/`SERVICE_ROLE_KEY` and the newer
    `PUBLISHABLE_KEY`/`SECRET_KEY`) — the CI key-drift scar, encoded once.
    """
    def status() -> dict[str, str] | None:
        p = subprocess.run(["supabase", "status", "-o", "env"], cwd=ROOT,
                           capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return None
        env = _parse_env_text(p.stdout)
        return env if env.get("API_URL") else None

    env = status()
    if env is None:
        print("stack is down — running `supabase start` "
              f"(up to {start_timeout_s}s)", flush=True)
        p = subprocess.run(["supabase", "start"], cwd=ROOT, capture_output=True,
                           text=True, timeout=start_timeout_s)
        if p.returncode != 0:
            raise AppDidNotStart(
                f"`supabase start` failed:\n{(p.stdout + p.stderr)[-1500:]}")
        env = status()
        if env is None:
            raise AppDidNotStart("`supabase status` still reports no stack after start")

    anon = env.get("ANON_KEY") or env.get("PUBLISHABLE_KEY")
    service = env.get("SERVICE_ROLE_KEY") or env.get("SECRET_KEY")
    if not anon or not service:
        raise AppDidNotStart("could not resolve anon/service keys from supabase status")
    return {
        "url": env["API_URL"],
        "db_url": env.get("DB_URL", ""),
        "anon_key": anon,
        "service_role_key": service,
    }


class VoxStack:
    """The local Supabase stack + a functions-serve process this driver owns."""

    def __init__(self, cfg: dict) -> None:
        self.cfg = cfg.get("app", {})
        self.env = stack_env(int(self.cfg.get("stack_start_timeout_s", 300)))
        self.base = self.env["url"]
        self.anon_key = self.env["anon_key"]
        self.service_key = self.env["service_role_key"]
        self.proc: subprocess.Popen | None = None
        self._serve_log = None

    # ------------------------------------------------------------------ lifecycle
    def __enter__(self) -> "VoxStack":
        health_fn = self.cfg.get("health_function", "fn-hello")
        if self._fn_answers(health_fn):
            raise AppDidNotStart(
                "another `supabase functions serve` already owns the gateway. The "
                "gate must be the only owner of the environment it asserts against — "
                "stop the dev serve first.")

        RUNS.mkdir(parents=True, exist_ok=True)
        self._seed_vault()
        env_file = self._write_serve_env()
        log_path = RUNS / "functions-serve.log"
        self._serve_log = open(log_path, "w", encoding="utf-8")
        self.proc = subprocess.Popen(
            ["supabase", "functions", "serve", "--env-file", str(env_file)],
            cwd=ROOT, stdout=self._serve_log, stderr=subprocess.STDOUT,
            start_new_session=True)

        deadline = time.time() + int(self.cfg.get("boot_timeout_s", 90))
        while time.time() < deadline:
            if self.proc.poll() is not None:
                tail = log_path.read_text(encoding="utf-8", errors="replace")[-1500:]
                raise AppDidNotStart(
                    f"functions serve exited with {self.proc.returncode}:\n{tail}")
            if self._fn_answers(health_fn):
                print(f"APP_STARTED base={self.base} serve=harness-owned "
                      f"health={health_fn}", flush=True)
                return self
            time.sleep(0.5)
        self.__exit__(None, None, None)
        raise AppDidNotStart(
            f"functions gateway never became healthy — this is a FAILURE, not "
            f"'not testable'. See {log_path}")

    def __exit__(self, *exc) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGINT)
                self.proc.wait(timeout=15)
            except (subprocess.TimeoutExpired, ProcessLookupError, PermissionError):
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        if self._serve_log:
            self._serve_log.close()
            self._serve_log = None

    def _seed_vault(self) -> None:
        """Seed the LOCAL vault so the production trigger chain runs locally.

        In production, vox.trigger_initial_pipeline_stage() and the stage router
        dispatch each pipeline hop via net.http_post using `project_url` and
        `service_role_key` from vault. A fresh local stack has an EMPTY vault, so
        the very first INSERT into vox.pipeline_runs crashes on a NULL url — the
        documented manual setup step nobody automates. The harness seeds it
        idempotently (LOCAL EMULATOR ONLY — the url is asserted local first) with
        host.docker.internal, which is how the db container reaches the host's
        kong gateway on macOS. This makes the E2E ride the REAL chain instead of
        hand-cranking each stage.
        """
        if "127.0.0.1" not in self.base and "localhost" not in self.base:
            raise AppDidNotStart(
                f"refusing to seed vault: {self.base} is not the local stack")
        docker_url = self.base.replace("127.0.0.1", "host.docker.internal") \
                              .replace("localhost", "host.docker.internal")
        sql = (
            "delete from vault.secrets where name in "
            "('project_url','service_role_key');\n"
            f"select vault.create_secret('{docker_url}', 'project_url');\n"
            f"select vault.create_secret('{self.service_key}', "
            f"'service_role_key');\n")
        sql_path = RUNS / "seed-vault.sql"
        sql_path.write_text(sql, encoding="utf-8")
        sql_path.chmod(0o600)
        p = subprocess.run(["psql", self.env["db_url"], "-v", "ON_ERROR_STOP=1",
                            "-q", "-f", str(sql_path)],
                           capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            raise AppDidNotStart(f"local vault seed failed:\n{p.stderr[-800:]}")

    def _write_serve_env(self) -> Path:
        merged: dict[str, str] = {}
        src = ROOT / self.cfg.get("serve_env_source", "supabase/functions/.env")
        if src.exists():
            merged.update(_parse_env_text(src.read_text(encoding="utf-8")))
        overlay = self.cfg.get("serve_env_overlay_from_dotenv_local", [])
        dotenv_local = ROOT / ".env.local"
        if overlay and dotenv_local.exists():
            local = _parse_env_text(dotenv_local.read_text(encoding="utf-8"))
            for key in overlay:
                if local.get(key):
                    merged[key] = local[key]
        merged.update(self.cfg.get("serve_env_force", {}))
        merged["SUPABASE_URL"] = self.base
        merged["SUPABASE_SERVICE_ROLE_KEY"] = self.service_key
        merged["SUPABASE_ANON_KEY"] = self.anon_key

        missing = [k for k in overlay if not merged.get(k)]
        if missing:
            raise AppDidNotStart(
                f"required keys absent from supabase/functions/.env and .env.local: "
                f"{', '.join(missing)}. A gate that skips the stages needing them "
                f"would be a skip counted as a pass — add the keys, then rerun.")

        path = RUNS / "serve.env"
        path.write_text("".join(f"{k}={v}\n" for k, v in merged.items()),
                        encoding="utf-8")
        path.chmod(0o600)
        return path

    def _fn_answers(self, name: str) -> bool:
        try:
            status, _, _ = self.functions_post(name, {}, timeout=3)
            return status < 500
        except (urllib.error.URLError, OSError):
            return False

    # ------------------------------------------------------------------ http
    def _request(self, url: str, method: str, body: bytes | None,
                 headers: dict[str, str], timeout: int):
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def functions_post(self, name: str, payload: dict, headers: dict | None = None,
                       timeout: int = 180):
        h = {"Content-Type": "application/json",
             "Authorization": f"Bearer {self.service_key}"}
        h.update(headers or {})
        return self._request(f"{self.base}/functions/v1/{name}", "POST",
                             json.dumps(payload).encode("utf-8"), h, timeout)

    def rest(self, method: str, path: str, payload=None, token: str | None = None,
             schema: str | None = None, timeout: int = 30):
        """PostgREST. `path` starts with the table/rpc segment incl. query string."""
        tok = token or self.service_key
        h = {"apikey": self.anon_key if token else self.service_key,
             "Authorization": f"Bearer {tok}",
             "Content-Type": "application/json",
             "Prefer": "return=representation"}
        if schema:
            h["Accept-Profile"] = schema
            h["Content-Profile"] = schema
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        status, raw, hdrs = self._request(f"{self.base}/rest/v1/{path}", method,
                                          body, h, timeout)
        try:
            data = json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            data = raw.decode("utf-8", "replace")
        return status, data, hdrs

    def admin_create_user(self, email: str, password: str) -> str:
        status, raw, _ = self._request(
            f"{self.base}/auth/v1/admin/users", "POST",
            json.dumps({"email": email, "password": password,
                        "email_confirm": True}).encode("utf-8"),
            {"apikey": self.service_key,
             "Authorization": f"Bearer {self.service_key}",
             "Content-Type": "application/json"}, 30)
        body = json.loads(raw.decode("utf-8"))
        if status not in (200, 201):
            raise RuntimeError(f"admin createUser failed {status}: {body}")
        return body["id"]

    def admin_delete_user(self, user_id: str) -> None:
        self._request(f"{self.base}/auth/v1/admin/users/{user_id}", "DELETE", None,
                      {"apikey": self.service_key,
                       "Authorization": f"Bearer {self.service_key}"}, 30)

    def sign_in(self, email: str, password: str) -> str:
        status, raw, _ = self._request(
            f"{self.base}/auth/v1/token?grant_type=password", "POST",
            json.dumps({"email": email, "password": password}).encode("utf-8"),
            {"apikey": self.anon_key, "Content-Type": "application/json"}, 30)
        body = json.loads(raw.decode("utf-8"))
        if status != 200 or "access_token" not in body:
            raise RuntimeError(f"sign-in failed {status}: {body}")
        return body["access_token"]

    def storage_upload(self, bucket: str, path: str, data: bytes,
                       content_type: str) -> None:
        status, raw, _ = self._request(
            f"{self.base}/storage/v1/object/{bucket}/{path}", "POST", data,
            {"Authorization": f"Bearer {self.service_key}",
             "Content-Type": content_type, "x-upsert": "true"}, 60)
        if status not in (200, 201):
            raise RuntimeError(
                f"storage upload {bucket}/{path} failed {status}: "
                f"{raw.decode('utf-8', 'replace')[:300]}")

    def storage_download(self, bucket: str, path: str) -> bytes | None:
        status, raw, _ = self._request(
            f"{self.base}/storage/v1/object/{bucket}/{path}", "GET", None,
            {"Authorization": f"Bearer {self.service_key}"}, 60)
        return raw if status == 200 else None

    def storage_delete(self, bucket: str, paths: list[str]) -> None:
        self._request(
            f"{self.base}/storage/v1/object/{bucket}", "DELETE",
            json.dumps({"prefixes": paths}).encode("utf-8"),
            {"Authorization": f"Bearer {self.service_key}",
             "Content-Type": "application/json"}, 30)

    def functions_sse(self, name: str, payload: dict, token: str,
                      timeout: int = 180) -> list[tuple[str, dict]]:
        """POST and parse a text/event-stream response into (event, data) pairs."""
        req = urllib.request.Request(
            f"{self.base}/functions/v1/{name}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {token}",
                     "Accept": "text/event-stream"}, method="POST")
        events: list[tuple[str, dict]] = []
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                raise RuntimeError(f"{name} returned {r.status}")
            current_event = "message"
            for raw_line in r:
                line = raw_line.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
                if line.startswith("event:"):
                    current_event = line[6:].strip()
                elif line.startswith("data:"):
                    try:
                        events.append((current_event, json.loads(line[5:].strip())))
                    except ValueError:
                        events.append((current_event, {"_raw": line[5:].strip()}))
        return events


def make_driver(cfg: dict) -> VoxStack:
    return VoxStack(cfg)
