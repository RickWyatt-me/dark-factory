"""Prod DB apply — the escalation policy engine (dark-factory, "Last Step").

Decides, per migration file, whether the factory may apply it to the production
database unattended or whether it parks needs-human. The shape is an ALLOWLIST,
never a blocklist: every top-level statement must be affirmatively recognized as
one of the benign classes below, or the whole file escalates. Fail-closed is the
doctrine — an unparseable or unrecognized statement is a human's, not a guess.

Benign (auto-apply) classes, v1 — deliberately narrow; loosen only by a human
edit to this file after the policy has earned it:

  create_table        CREATE TABLE in vox/public, not on the protected list
  create_index        CREATE [UNIQUE] INDEX; on a HOT table only with CONCURRENTLY
  add_column          ALTER TABLE ... ADD COLUMN only (no other action in the
                      statement), and never on a HOT table
  create_function     CREATE [OR REPLACE] FUNCTION without SECURITY DEFINER
  function_privilege  REVOKE ... ON FUNCTION, and GRANT EXECUTE ON FUNCTION to
                      authenticated/service_role only (the 00142 posture; a grant
                      that names anon escalates — the anon-fallback trap)
  create_type         CREATE TYPE / ALTER TYPE ... ADD VALUE
  create_trigger      CREATE TRIGGER, only on a table this same range created
  comment             COMMENT ON ...

Everything else escalates, with the class named in the verdict — and, per Rick's
2026-08-17 "all migrations move through" directive, each escalation carries a
FLOOR flag deciding who reviews it:

  floor=False  →  the MIGRATION JUDGE (factory/prompts/migration-judge.md), an
                  independent premium-model review at deploy time, may clear it.
  floor=True   →  a human, always. The floor is the MISSION constitution, not
                  caution: statements that DESTROY STORED DATA (TRUNCATE,
                  DROP TABLE/SCHEMA, DROP COLUMN, statement-initial DELETE — the
                  no-unprovenanced-destruction invariant) and statements touching
                  the money/identity/secret schemas (auth, marketing/Stripe,
                  vault, supabase_migrations — the ledger itself, pgsodium).

Judge-clearable classes: drop_recreatable (DROP FUNCTION/POLICY/INDEX/TRIGGER/
VIEW/TYPE — recreatable from source, incl. the skill's signature-change scar),
dml_backfill (INSERT/UPDATE/MERGE/COPY — the Portal-1.5 lesson), protection_
disable, privilege (grants, policies, RLS toggles, SECURITY DEFINER), hot_table_
lock, protected_table for the non-floor schemas (storage, realtime, ...) and
named tables (profiles, organizations, membership), procedural (DO/CALL),
unrecognized (fail-closed).

Also derives the positive verification probes for the benign classes: object-
existence SQL the applier runs AFTER the apply (deploy.sh doctrine — positive
evidence, never the exit code). A file from which zero probes can be derived
escalates: empty is not pass.

CLI:
  python3 factory/db_apply_policy.py <file.sql>            verdict lines; rc 0 allow / 1 escalate
  python3 factory/db_apply_policy.py --probes <file.sql>   probe JSON on stdout
  python3 factory/db_apply_policy.py --selftest
"""
from __future__ import annotations

import json
import os
import re
import sys

# Tables where an ACCESS EXCLUSIVE lock or a non-concurrent index build is an
# outage risk (the app's hot write/read paths). Overridable via the environment
# (config.sh may export FACTORY_DB_HOT_TABLES); the default list is the pipeline.
HOT_TABLES = set((os.environ.get("FACTORY_DB_HOT_TABLES") or
                  "recordings entries search_chunks transcripts photos reports "
                  "report_entries report_sections pipeline_stage_events "
                  "pipeline_runs recording_compositions").split())

# Any statement that so much as mentions these escalates. Whole schemas outside
# the factory's territory, plus the identity/payment-adjacent tables inside it.
PROTECTED_SCHEMAS = set((os.environ.get("FACTORY_DB_PROTECTED_SCHEMAS") or
                         "auth storage marketing realtime vault supabase_migrations "
                         "supabase_functions pgsodium graphql extensions cron net").split())
PROTECTED_TABLES = set((os.environ.get("FACTORY_DB_PROTECTED_TABLES") or
                        "profiles organizations organization_members company_members "
                        "project_members project_companies memberships").split())

# The FLOOR subset of the protected schemas: money, identity, secrets, and the
# migration ledger itself. A mention parks for a HUMAN — the judge never rules here.
FLOOR_SCHEMAS = set((os.environ.get("FACTORY_DB_FLOOR_SCHEMAS") or
                     "auth marketing vault supabase_migrations pgsodium").split())

ALLOWED_GRANT_ROLES = {"authenticated", "service_role"}


# ---- statement splitting (dollar-quote, quote, and comment aware) ------------

def split_statements(sql: str) -> list[str]:
    """Split SQL into top-level statements on ';', honoring '...', "...",
    $tag$...$tag$ bodies, -- line comments, and /* */ block comments."""
    stmts, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == "-" and sql[i:i + 2] == "--":
            j = sql.find("\n", i)
            i = n if j == -1 else j
            buf.append(" ")
            continue
        if c == "/" and sql[i:i + 2] == "/*":
            j = sql.find("*/", i + 2)
            if j == -1:
                i = n
            else:
                i = j + 2
            buf.append(" ")
            continue
        if c == "'" or c == '"':
            q, j = c, i + 1
            while j < n:
                if sql[j] == q:
                    if q == "'" and sql[j:j + 2] == "''":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(sql[i:j + 1])
            i = j + 1
            continue
        if c == "$":
            m = re.match(r"\$[A-Za-z_]*\$", sql[i:])
            if m:
                tag = m.group(0)
                j = sql.find(tag, i + len(tag))
                if j == -1:
                    buf.append(sql[i:])
                    i = n
                else:
                    buf.append(sql[i:j + len(tag)])
                    i = j + len(tag)
                continue
        if c == ";":
            s = "".join(buf).strip()
            if s:
                stmts.append(s)
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    s = "".join(buf).strip()
    if s:
        stmts.append(s)
    return stmts


# ---- identifier helpers ------------------------------------------------------

IDENT = r'(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)'
QUAL = rf"({IDENT})\s*\.\s*({IDENT})|({IDENT})"


def _norm(ident: str) -> str:
    return ident.strip().strip('"').lower()


def parse_rel(raw: str) -> tuple[str | None, str]:
    """'vox.things' -> ('vox','things'); 'things' -> (None,'things')."""
    parts = [p for p in re.split(r"\s*\.\s*", raw.strip()) if p]
    if len(parts) >= 2:
        return _norm(parts[-2]), _norm(parts[-1])
    return None, _norm(parts[-1])


def blind(stmt: str) -> str:
    """Blank out string literals AND dollar-quoted bodies, so a word like DROP
    inside a function body or a comment string never trips a structural check."""
    out = re.sub(r"\$([A-Za-z_]*)\$.*?\$\1\$", " $$ $$ ", stmt, flags=re.S)
    return re.sub(r"'(?:[^']|'')*'", "''", out)


def _targets_schema(low: str, s: str) -> bool:
    """True when the statement's TARGET is an object in schema `s` — DDL on it, DML
    into it, grants/policies/triggers ON it — as opposed to merely referencing it
    in an expression (an FK, a predicate subquery)."""
    e = re.escape(s)
    return bool(
        re.search(rf"\b(create|alter|drop)\s+(or\s+replace\s+)?(unique\s+)?"
                  rf"(table|schema|function|trigger|policy|index|view|type|sequence|"
                  rf"materialized\s+view)\s+(concurrently\s+)?(if\s+(not\s+)?exists\s+)?"
                  rf"(only\s+)?{e}\s*\.", low)
        or re.match(rf"(insert\s+into|update|delete\s+from|truncate(\s+table)?)\s+"
                    rf"(only\s+)?{e}\s*\.", low)
        or re.search(rf"\bon\s+(table\s+|function\s+|only\s+)?{e}\s*\.", low)
        or re.search(rf"\b(in|on)\s+schema\s+{e}\b", low)
        or re.search(rf"\balter\s+schema\s+{e}\b", low))


def mentions_protected(stmt: str) -> tuple[str, bool] | None:
    """Returns (why, floor) — floor=True when the statement TARGETS a floor schema.

    The standard RLS idiom CALLS auth helpers (auth.uid()/jwt()/role()/email())
    inside policy expressions — blanked before the scan. A floor schema mentioned
    only in an expression (an FK like `references auth.users`, a predicate
    subquery) is judge-level, not floor: it cannot modify the schema, and FK
    semantics against auth.users (CASCADE vs RESTRICT — the 00161 account-deletion
    decision) is exactly what the judge reads the signed decisions for."""
    low = blind(stmt).lower()
    low = re.sub(r"\bauth\s*\.\s*(uid|jwt|role|email)\s*\(", " __authfn__(", low)
    for s in sorted(PROTECTED_SCHEMAS):
        if re.search(rf"\b{re.escape(s)}\s*\.", low):
            if s in FLOOR_SCHEMAS and _targets_schema(low, s):
                return f"statement targets floor schema {s}.", True
            return f"references schema {s}.", False
    for t in sorted(PROTECTED_TABLES):
        if re.search(rf"\b{re.escape(t)}\b", low):
            return f"references protected table {t}", False
    return None


# ---- function-probe derivation (issue #65) -----------------------------------
# 00170's false DEPLOY_HALTED: a SECURITY DEFINER CREATE FUNCTION is denied above
# the probe-deriving branch, so the file carried zero derivable probes and the
# migration judge was forced to hand-author verify_sql — and wrote a probe
# comparing pg_get_function_identity_arguments to the bare type list ('uuid'),
# which Postgres never returns (it includes declared argument names:
# 'p_recording_id uuid'). The apply was good; the probe was wrong. So: derive a
# probe from the CREATE statement's OWN signature, resolved through
# to_regprocedure so Postgres canonicalizes the type spellings — never a
# hand-built identity string. When the signature does not parse cleanly, fall
# back to the proname-existence probe: weaker, never wrong. A wrong strong probe
# would recreate the exact false-halt this exists to remove.

# Multi-word type names start with one of these; an argument whose first token
# matches carries no name (e.g. `timestamp with time zone`), so the name/type
# split must not eat the first word as a name.
_TYPE_FIRST_WORDS = {"timestamp", "time", "character", "double", "bit",
                     "national", "interval"}

# Words that end a `RETURNS <type>` clause in the function options that follow it.
_FN_OPTION_WORDS = ("LANGUAGE|AS|SECURITY|SET|IMMUTABLE|STABLE|VOLATILE|CALLED|"
                    "STRICT|PARALLEL|COST|ROWS|WINDOW|LEAKPROOF|NOT|RETURNS|"
                    "TRANSFORM|SUPPORT|EXTERNAL")


def _split_args(argtext: str) -> list[str] | None:
    """Split an argument list on top-level commas ('a numeric(10,2), b int' is
    two items, not three). None when parens never balance."""
    items, buf, depth = [], [], 0
    for c in argtext:
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return None
        if c == "," and depth == 0:
            items.append("".join(buf).strip())
            buf = []
        else:
            buf.append(c)
    if depth != 0:
        return None
    last = "".join(buf).strip()
    if last:
        items.append(last)
    return items


def _arg_type(item: str) -> str | None:
    """'p_recording_id UUID' -> 'uuid'; 'uuid' -> 'uuid'; 'a numeric(10,2)' ->
    'numeric(10,2)'. None when unsure — OUT/INOUT/VARIADIC args (proargtypes
    holds inputs only), quoted identifiers, anything that does not read as
    [name] type [DEFAULT ...]."""
    it = re.sub(r"\s+", " ", item).strip()
    if not it or "'" in it or '"' in it:
        return None
    if re.match(r"(OUT|INOUT|VARIADIC)\b", it, re.I):
        return None
    it = re.sub(r"^IN\s+", "", it, flags=re.I)
    it = re.split(r"\s+DEFAULT\s+|\s*=", it, maxsplit=1, flags=re.I)[0].strip()
    toks = it.split(" ")
    if len(toks) > 1 and toks[0].lower() not in _TYPE_FIRST_WORDS:
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", toks[0]):
            return None
        it = " ".join(toks[1:])
    typ = it.lower()
    if not re.match(r"^[a-z_][a-z0-9_. ]*(\(\s*\d+(\s*,\s*\d+)?\s*\))?(\[\])*$", typ):
        return None
    return typ


def _fn_probe_sql(head: str, schema: str, fn: str, secdef: bool) -> str | None:
    """The strong probe: resolve the CREATE statement's own signature via
    to_regprocedure (Postgres canonicalizes the type names — the apply having
    succeeded guarantees they resolve), then assert prosecdef and, when a simple
    RETURNS <type> is present, prorettype. None when the signature does not
    parse cleanly — the caller falls back to the existence probe."""
    i = head.find("(")
    if i == -1:
        return None
    depth, j = 0, i
    for j in range(i, len(head)):
        if head[j] == "(":
            depth += 1
        elif head[j] == ")":
            depth -= 1
            if depth == 0:
                break
    if depth != 0:
        return None
    items = _split_args(head[i + 1:j])
    if items is None:
        return None
    types = []
    for item in items:
        t = _arg_type(item)
        if t is None:
            return None
        types.append(t)
    sig = f"{schema}.{fn}({', '.join(types)})"
    rm = re.match(rf"\s*RETURNS\s+(TABLE\s*\(|SETOF\s+)?"
                  rf"([A-Za-z_][A-Za-z0-9_. ]*?(?:\[\])*)\s+(?:{_FN_OPTION_WORDS})\b",
                  head[j + 1:], re.I)
    ret = rm.group(2).strip().lower() if rm and not rm.group(1) else None
    conds = [f"p.prosecdef = {'true' if secdef else 'false'}"]
    if ret:
        conds.append(f"p.prorettype = '{ret}'::regtype")
    return ("select coalesce((select " + " and ".join(conds) +
            f" from pg_proc p where p.oid = to_regprocedure('{sig}')), false) as ok")


def _fn_probe(head: str, schema: str | None, fn: str, secdef: bool) -> dict:
    strong = _fn_probe_sql(head, schema or "public", fn, secdef)
    weak = ("select count(*)>=1 as ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace "
            f"where p.proname='{fn}'" + (f" and n.nspname='{schema}'" if schema else ""))
    return {"kind": "function", "name": (f"{schema}.{fn}" if schema else fn),
            "sql": strong or weak, "md5_watch": {"schema": schema or "", "fn": fn}}


# ---- classification ----------------------------------------------------------

def classify_file(sql: str) -> tuple[list[dict], list[dict]]:
    """Returns (verdicts, probes). Each verdict: {stmt, class, allow, why}.
    File auto-applies only if every verdict allows AND probes is non-empty."""
    stmts = split_statements(sql)
    verdicts: list[dict] = []
    probes: list[dict] = []
    created_here: set[str] = set()          # tables this file creates

    for stmt in stmts:
        head = re.sub(r"\s+", " ", stmt).strip()
        up = head.upper()
        upb = re.sub(r"\s+", " ", blind(stmt)).strip().upper()  # structural checks
        short = head[:100]

        def deny(cls: str, why: str, floor: bool = False) -> None:
            verdicts.append({"stmt": short, "class": cls, "allow": False,
                             "floor": floor, "why": why})

        def allow(cls: str) -> None:
            verdicts.append({"stmt": short, "class": cls, "allow": True,
                             "floor": False, "why": ""})

        prot = mentions_protected(stmt)
        if prot:
            why, floor = prot
            deny("protected_table", why, floor)
            continue

        # escalation classes first — these win over any allow pattern.
        # THE FLOOR (floor=True — a human, never the judge): destroying stored data.
        if (re.search(r"\bTRUNCATE\b", upb)
                or re.search(r"\bDROP\s+(TABLE|SCHEMA)\b", upb)
                or re.search(r"\bDROP\s+COLUMN\b", upb)
                or re.match(r"DELETE\b", upb)):
            deny("destructive", "destroys stored data (TRUNCATE/DROP TABLE/DROP "
                                "COLUMN/DELETE) — the no-unprovenanced-destruction "
                                "invariant; permanently human", floor=True)
            continue
        # Judge-clearable from here down.
        if re.search(r"\bDROP\b", upb):
            deny("drop_recreatable", "drops a recreatable object (function/policy/"
                                     "index/trigger/view/type)")
            continue
        if re.match(r"(INSERT|UPDATE|MERGE|COPY)\b", upb):
            deny("dml_backfill", "data-modifying statement — the Portal-1.5 lesson: "
                                 "backfills need judgment about protection triggers")
            continue
        if re.search(r"\bDISABLE\s+(TRIGGER|ROW\s+LEVEL\s+SECURITY)\b", upb):
            deny("protection_disable", "disables a protection mechanism")
            continue
        if re.search(r"\bSECURITY\s+DEFINER\b", upb):
            # Denied, but still derive the verification probe (issue #65): probes
            # run AFTER the migration judge clears the file, and a file with zero
            # derivable probes forces the judge to hand-author verify_sql — the
            # 00170 false-halt. Deriving here cannot flip the verdict: file_allows
            # still requires every statement to allow.
            fm = re.match(rf"CREATE (?:OR REPLACE )?FUNCTION ({IDENT}(?:\s*\.\s*{IDENT})?)\s*\(", head, re.I)
            if fm:
                fschema, ffn = parse_rel(fm.group(1))
                if fschema in (None, "vox", "public"):
                    probes.append(_fn_probe(head, fschema, ffn, secdef=True))
            deny("privilege", "SECURITY DEFINER — privilege-bearing code")
            continue
        if re.match(r"(DO|CALL)\b", upb):
            deny("procedural", "anonymous code block — cannot be statically judged")
            continue
        if (re.search(r"\b(CREATE|ALTER)\s+POLICY\b", upb)
                or re.search(r"\bROW\s+LEVEL\s+SECURITY\b", upb)
                or re.search(r"\bALTER\s+DEFAULT\s+PRIVILEGES\b", upb)):
            deny("privilege", "RLS/policy/default-privilege change — "
                              "tenant-isolation-adjacent")
            continue

        m = re.match(rf"CREATE TABLE (?:IF NOT EXISTS )?({IDENT}(?:\s*\.\s*{IDENT})?)", head, re.I)
        if m:
            schema, table = parse_rel(m.group(1))
            if schema not in (None, "vox", "public"):
                deny("protected_table", f"table in schema {schema}")
                continue
            created_here.add(table)
            reg = f"{schema}.{table}" if schema else table
            probes.append({"kind": "table", "name": reg,
                           "sql": f"select to_regclass('{reg}') is not null as ok"})
            allow("create_table")
            continue

        m = re.match(rf"CREATE (?:UNIQUE )?INDEX (CONCURRENTLY )?(?:IF NOT EXISTS )?({IDENT}) ON (?:ONLY )?({IDENT}(?:\s*\.\s*{IDENT})?)", head, re.I)
        if m:
            # group numbering: 1=CONCURRENTLY, 2=index name, 3=relation
            conc = bool(m.group(1))
            idx = _norm(m.group(2))
            _, table = parse_rel(m.group(3))
            if table in HOT_TABLES and not conc:
                deny("hot_table_lock", f"non-CONCURRENTLY index on hot table {table}")
                continue
            probes.append({"kind": "index", "name": idx,
                           "sql": f"select count(*)=1 as ok from pg_indexes where indexname='{idx}'"})
            allow("create_index")
            continue

        m = re.match(rf"ALTER TABLE (?:IF EXISTS )?(?:ONLY )?({IDENT}(?:\s*\.\s*{IDENT})?)\s+(.*)", head, re.I | re.S)
        if m:
            schema, table = parse_rel(m.group(1))
            actions = m.group(2)
            if table in HOT_TABLES:
                deny("hot_table_lock", f"ALTER on hot table {table} — lock risk is human")
                continue
            parts = [p.strip() for p in actions.split(",")]
            cols = []
            if all(re.match(r"ADD (?:COLUMN )?", p, re.I) for p in parts):
                for p in parts:
                    cm = re.match(rf"ADD (?:COLUMN )?(?:IF NOT EXISTS )?({IDENT})", p, re.I)
                    if cm:
                        cols.append(_norm(cm.group(1)))
                if cols and len(cols) == len(parts):
                    reg = f"{schema}.{table}" if schema else table
                    for c in cols:
                        probes.append({"kind": "column", "name": f"{reg}.{c}",
                                       "sql": ("select count(*)=1 as ok from information_schema.columns "
                                               f"where table_name='{table}' and column_name='{c}'"
                                               + (f" and table_schema='{schema}'" if schema else ""))})
                    allow("add_column")
                    continue
            deny("unrecognized", "ALTER TABLE action beyond ADD COLUMN")
            continue

        m = re.match(rf"CREATE (?:OR REPLACE )?FUNCTION ({IDENT}(?:\s*\.\s*{IDENT})?)\s*\(", head, re.I)
        if m:
            schema, fn = parse_rel(m.group(1))
            if schema not in (None, "vox", "public"):
                deny("protected_table", f"function in schema {schema}")
                continue
            probes.append(_fn_probe(head, schema, fn, secdef=False))
            allow("create_function")
            continue

        m = re.match(r"REVOKE\b.*\bON FUNCTION\b", head, re.I)
        if m:
            allow("function_privilege")
            continue
        m = re.match(rf"GRANT EXECUTE ON FUNCTION .* TO (.+)$", head, re.I)
        if m:
            roles = {_norm(r) for r in m.group(1).split(",")}
            if roles <= ALLOWED_GRANT_ROLES:
                allow("function_privilege")
            else:
                deny("privilege", f"EXECUTE granted to {', '.join(sorted(roles - ALLOWED_GRANT_ROLES))} "
                                  "— only authenticated/service_role auto-apply")
            continue
        if re.match(r"(GRANT|REVOKE)\b", up):
            deny("privilege", "table/schema-level grant — human")
            continue

        m = re.match(rf"CREATE TYPE ({IDENT}(?:\s*\.\s*{IDENT})?)", head, re.I)
        if m:
            schema, typ = parse_rel(m.group(1))
            probes.append({"kind": "type", "name": typ,
                           "sql": f"select count(*)>=1 as ok from pg_type where typname='{typ}'"})
            allow("create_type")
            continue
        m = re.match(rf"ALTER TYPE ({IDENT}(?:\s*\.\s*{IDENT})?) ADD VALUE (?:IF NOT EXISTS )?'([^']+)'", head, re.I)
        if m:
            _, typ = parse_rel(m.group(1))
            val = m.group(2)
            probes.append({"kind": "enum_value", "name": f"{typ}.{val}",
                           "sql": ("select count(*)=1 as ok from pg_enum e join pg_type t on t.oid=e.enumtypid "
                                   f"where t.typname='{typ}' and e.enumlabel='{val}'")})
            allow("create_type")
            continue

        m = re.match(rf"CREATE (?:OR REPLACE )?TRIGGER ({IDENT})\s.*?\bON ({IDENT}(?:\s*\.\s*{IDENT})?)", head, re.I | re.S)
        if m:
            trg = _norm(m.group(1))
            _, table = parse_rel(m.group(2))
            if table not in created_here:
                deny("unrecognized", f"trigger on pre-existing table {table} — "
                                     "changes live write-path behavior, human")
                continue
            probes.append({"kind": "trigger", "name": trg,
                           "sql": f"select count(*)>=1 as ok from pg_trigger where tgname='{trg}'"})
            allow("create_trigger")
            continue

        m = re.match(rf"COMMENT ON (TABLE|COLUMN|FUNCTION|INDEX|TYPE|SCHEMA|VIEW) ({IDENT}(?:\s*\.\s*{IDENT})*(?:\s*\.\s*{IDENT})?)", head, re.I)
        if m and " IS NULL" not in up:
            kind = m.group(1).lower()
            target = m.group(2)
            if kind == "table":
                schema, table = parse_rel(target)
                reg = f"{schema}.{table}" if schema else table
                probes.append({"kind": "comment", "name": reg,
                               "sql": f"select obj_description(to_regclass('{reg}')) is not null as ok"})
            elif kind == "column":
                parts = [_norm(p) for p in re.split(r"\s*\.\s*", target)]
                if len(parts) >= 3:
                    schema, table, col = parts[-3], parts[-2], parts[-1]
                    probes.append({"kind": "comment", "name": f"{schema}.{table}.{col}",
                                   "sql": ("select col_description(to_regclass("
                                           f"'{schema}.{table}'), (select ordinal_position from "
                                           "information_schema.columns where "
                                           f"table_schema='{schema}' and table_name='{table}' "
                                           f"and column_name='{col}')::int) is not null as ok")})
            allow("comment")
            continue

        deny("unrecognized", "not an allowlisted statement class")

    return verdicts, probes


def file_allows(verdicts: list[dict], probes: list[dict]) -> bool:
    return bool(verdicts) and all(v["allow"] for v in verdicts) and bool(probes)


def file_floor(verdicts: list[dict]) -> bool:
    """True when any statement hit the human floor — the judge never rules here."""
    return any(v.get("floor") for v in verdicts)


# ---- CLI ---------------------------------------------------------------------

def run_file(path: str, emit_probes: bool, emit_json: bool = False) -> int:
    sql = open(path, encoding="utf-8", errors="replace").read()
    verdicts, probes = classify_file(sql)
    rc = 0 if file_allows(verdicts, probes) else 1
    if emit_json:
        print(json.dumps({"verdicts": verdicts, "probes": probes,
                          "allow": file_allows(verdicts, probes),
                          "floor": file_floor(verdicts)}, indent=1))
        return rc
    if emit_probes:
        print(json.dumps(probes, indent=2))
        return rc
    for v in verdicts:
        mark = "ALLOW" if v["allow"] else ("ESCALATE_FLOOR" if v.get("floor") else "ESCALATE")
        why = f" — {v['why']}" if v["why"] else ""
        print(f"DB_POLICY_{mark} class={v['class']}{why} :: {v['stmt']}")
    if rc == 0:
        print(f"DB_POLICY_OK statements={len(verdicts)} probes={len(probes)}")
        return 0
    if verdicts and all(v["allow"] for v in verdicts) and not probes:
        print("DB_POLICY_ESCALATE class=no_probes — zero verification probes derivable; "
              "empty is not pass")
    print(f"DB_POLICY_ESCALATED statements={len(verdicts)}"
          + (" FLOOR" if file_floor(verdicts) else ""))
    return 1


# ---- selftest ----------------------------------------------------------------

def selftest() -> int:
    n = 0

    def case(sql: str, expect_allow: bool, what: str, expect_floor: bool | None = None) -> None:
        nonlocal n
        n += 1
        v, p = classify_file(sql)
        got = file_allows(v, p)
        if got != expect_allow:
            print(f"DB_POLICY_SELFTEST_FAIL {what} (expected "
                  f"{'allow' if expect_allow else 'escalate'}, got {'allow' if got else 'escalate'})")
            for x in v:
                print("   ", x)
            raise SystemExit(1)
        if expect_floor is not None and file_floor(v) != expect_floor:
            print(f"DB_POLICY_SELFTEST_FAIL {what} (expected floor={expect_floor}, "
                  f"got floor={file_floor(v)})")
            for x in v:
                print("   ", x)
            raise SystemExit(1)

    case("CREATE TABLE vox.widgets (id uuid primary key);", True, "new table allows")
    case("CREATE TABLE IF NOT EXISTS widgets (id uuid);", True, "IF NOT EXISTS table allows")
    case("CREATE TABLE auth.widgets (id uuid);", False, "auth-schema table escalates")
    case("ALTER TABLE public.profiles ADD COLUMN note text;", False, "protected-table mention escalates")
    case("CREATE TABLE vox.profiles_copy (id uuid);", True, "similarly-named table is NOT the protected one")
    case("DROP TABLE vox.widgets;", False, "DROP TABLE floors", expect_floor=True)
    case("TRUNCATE vox.widgets;", False, "TRUNCATE floors", expect_floor=True)
    case("ALTER TABLE vox.widgets DROP COLUMN a;", False, "DROP COLUMN floors", expect_floor=True)
    case("DELETE FROM vox.widgets;", False, "DELETE floors", expect_floor=True)
    case("DROP FUNCTION IF EXISTS vox.f(uuid);", False,
         "DROP FUNCTION is judge-clearable (recreatable)", expect_floor=False)
    case("DROP POLICY IF EXISTS p ON vox.widgets;", False,
         "DROP POLICY is judge-clearable", expect_floor=False)
    case("UPDATE vox.widgets SET a=1;", False, "UPDATE escalates to the judge", expect_floor=False)
    case("INSERT INTO vox.widgets VALUES (1);", False, "INSERT escalates to the judge", expect_floor=False)
    case("CREATE TABLE marketing.things (id uuid);", False, "marketing schema floors", expect_floor=True)
    case("CREATE POLICY p ON vox.widgets FOR SELECT USING (auth.uid() = owner_id);",
         False, "auth.uid() in a policy is the RLS idiom - judge, not floor", expect_floor=False)
    case("GRANT SELECT ON auth.users TO authenticated;", False,
         "granting on an auth table floors", expect_floor=True)
    case("CREATE TABLE vox.widgets (id uuid, user_id uuid references auth.users(id));",
         False, "FK to auth.users is judge-level, not floor", expect_floor=False)
    case("ALTER TABLE auth.users ADD COLUMN note text;", False,
         "DDL targeting auth floors", expect_floor=True)
    case("INSERT INTO marketing.stripe_customers VALUES (1);", False,
         "DML into a floor schema floors", expect_floor=True)
    case("ALTER TABLE storage.objects ADD COLUMN note text;", False,
         "storage schema escalates to the judge, not the floor", expect_floor=False)
    case("CREATE TABLE vox.widgets (id uuid references vox.parents(id) on delete cascade);",
         True, "ON DELETE CASCADE inside a table definition is not a DELETE")
    case("CREATE OR REPLACE FUNCTION vox.f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN "
         "DELETE FROM vox.widgets; RETURN 1; END $$;", True,
         "body-blinding: DML inside a dollar-quoted body does not floor the CREATE")
    case("CREATE INDEX idx_w_a ON vox.widgets (a);", True, "index on cold table allows")
    case("CREATE INDEX idx_e_a ON vox.entries (a);", False, "non-concurrent index on hot table escalates")
    case("CREATE INDEX CONCURRENTLY idx_e_a ON vox.entries (a);", True, "concurrent index on hot table allows")
    case("ALTER TABLE vox.widgets ADD COLUMN note text;", True, "add column allows")
    case("ALTER TABLE vox.entries ADD COLUMN note text;", False, "alter on hot table escalates")
    case("ALTER TABLE vox.widgets ALTER COLUMN a TYPE bigint;", False, "column type change escalates")
    case("CREATE OR REPLACE FUNCTION vox.f() RETURNS int LANGUAGE sql AS $$ select 1; $$;",
         True, "plain function allows (dollar-quoted body with semicolon)")
    case("CREATE FUNCTION vox.f() RETURNS int LANGUAGE sql SECURITY DEFINER AS $$ select 1; $$;",
         False, "security definer escalates")
    case("CREATE OR REPLACE FUNCTION vox.f() RETURNS int LANGUAGE sql AS $$ select 1; $$;\n"
         "REVOKE ALL ON FUNCTION vox.f() FROM PUBLIC, anon;\n"
         "GRANT EXECUTE ON FUNCTION vox.f() TO authenticated, service_role;",
         True, "function + 00142 grant posture allows")
    case("GRANT EXECUTE ON FUNCTION vox.f() TO anon;", False, "grant to anon escalates")
    case("GRANT SELECT ON vox.widgets TO authenticated;", False, "table grant escalates")
    case("CREATE POLICY p ON vox.widgets USING (true);", False, "policy escalates")
    case("ALTER TABLE vox.widgets ENABLE ROW LEVEL SECURITY;", False, "RLS toggle escalates")
    case("ALTER TABLE vox.widgets DISABLE TRIGGER ALL;", False, "protection disable escalates")
    case("DO $$ BEGIN NULL; END $$;", False, "DO block escalates")
    case("CREATE TABLE vox.widgets (id uuid);\n"
         "CREATE TRIGGER t_w BEFORE INSERT ON vox.widgets EXECUTE FUNCTION vox.f();",
         True, "trigger on same-file table allows")
    case("CREATE TRIGGER t_w BEFORE INSERT ON vox.widgets EXECUTE FUNCTION vox.f();",
         False, "trigger on pre-existing table escalates")
    case("COMMENT ON TABLE vox.widgets IS 'the widgets';", True, "comment allows")
    case("CREATE TYPE vox.mood AS ENUM ('a','b');", True, "create type allows")
    case("ALTER TYPE vox.mood ADD VALUE 'c';", True, "enum add value allows")
    case("SELECT 1;", False, "unrecognized escalates")
    case("", False, "empty file escalates (no statements, no probes)")
    case("-- comment only\n", False, "comment-only file escalates (nothing to verify)")
    case("UPDATE vox.widgets SET a=1 -- ; not a split\n;", False,
         "line comment does not hide DML")

    stmts = split_statements("select '$a$; not a tag'; select $body$ x; y $body$;")
    assert len(stmts) == 2, f"splitter: got {len(stmts)}"
    n += 1

    # --- issue #65 regressions: function-probe derivation ---------------------
    def probe_case(sql: str, contains: list[str], absent: list[str], what: str) -> None:
        nonlocal n
        n += 1
        _, p = classify_file(sql)
        fns = [x for x in p if x["kind"] == "function"]
        if not fns:
            print(f"DB_POLICY_SELFTEST_FAIL {what} (no function probe derived)")
            raise SystemExit(1)
        s = fns[0]["sql"]
        for frag in contains:
            if frag not in s:
                print(f"DB_POLICY_SELFTEST_FAIL {what} (probe missing {frag!r}) :: {s}")
                raise SystemExit(1)
        for frag in absent:
            if frag in s:
                print(f"DB_POLICY_SELFTEST_FAIL {what} (probe must not contain {frag!r}) :: {s}")
                raise SystemExit(1)

    # 00170's exact shape: named arg, SECURITY DEFINER, RETURNS UUID. The file
    # still escalates (privilege class), but now carries a derivable probe that
    # resolves the real signature — never a hand-built identity string.
    sql_00170 = ("CREATE OR REPLACE FUNCTION vox.reprocess_recording(p_recording_id UUID)\n"
                 "RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER\n"
                 "SET search_path = vox, public, pg_temp\n"
                 "AS $$ BEGIN RETURN p_recording_id; END $$;")
    case(sql_00170, False, "secdef function still escalates with a probe derived")
    probe_case(sql_00170,
               ["to_regprocedure('vox.reprocess_recording(uuid)')",
                "p.prosecdef = true", "p.prorettype = 'uuid'::regtype"],
               ["pg_get_function_identity_arguments"],
               "00170 regression: named-arg secdef derives signature probe")
    probe_case("CREATE OR REPLACE FUNCTION vox.g(p_id uuid, p_note text DEFAULT null) "
               "RETURNS integer LANGUAGE sql AS $$ select 1; $$;",
               ["to_regprocedure('vox.g(uuid, text)')",
                "p.prosecdef = false", "p.prorettype = 'integer'::regtype"],
               ["pg_get_function_identity_arguments"],
               "named args + DEFAULT derive bare-type signature")
    probe_case("CREATE OR REPLACE FUNCTION vox.f() RETURNS int LANGUAGE sql AS $$ select 1; $$;",
               ["to_regprocedure('vox.f()')"], [],
               "zero-arg function derives signature probe")
    probe_case("CREATE FUNCTION vox.h(ts timestamp with time zone, a numeric(10,2)) "
               "RETURNS int LANGUAGE sql AS $$ select 1; $$;",
               ["to_regprocedure('vox.h(timestamp with time zone, numeric(10,2))')"], [],
               "multi-word and precision types survive the split")
    probe_case("CREATE FUNCTION vox.j(OUT x int) RETURNS int LANGUAGE sql AS $$ select 1; $$;",
               ["count(*)>=1", "proname='j'"], ["to_regprocedure"],
               "unparseable signature (OUT arg) falls back to existence probe")
    probe_case("CREATE FUNCTION vox.s(p_ids uuid[]) RETURNS SETOF uuid LANGUAGE sql "
               "AS $$ select 1; $$;",
               ["to_regprocedure('vox.s(uuid[])')"], ["prorettype"],
               "SETOF return skips the rettype assertion")

    print(f"DB_POLICY_SELFTEST_OK n={n}")
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    if "--selftest" in argv:
        sys.exit(selftest())
    if "--json" in argv:
        argv.remove("--json")
        sys.exit(run_file(argv[0], False, emit_json=True))
    if "--probes" in argv:
        argv.remove("--probes")
        sys.exit(run_file(argv[0], True))
    sys.exit(run_file(argv[0], False))
