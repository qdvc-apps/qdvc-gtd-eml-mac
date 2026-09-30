#!/usr/bin/env python3
"""Regenerate Tests/GTDCoreTests/Fixtures/parity.json from the Python edition.

The Swift core is a port of qdvc-gtd-eml's `gtd_modules` package. This script
feeds a fixed set of inputs through the Python code and records its outputs,
so `swift test` can check that the port behaves the same without needing
Python at test time.

Usage:

    python3 tools/make_fixtures.py --python-repo /path/to/qdvc-gtd-eml

Needs Python 3.10+ and PyYAML (the Python edition imports it). The outputs in
the committed fixture were produced with Python 3.12.

To add a case, add an input to one of the lists below; the Swift tests iterate
over whatever is in the fixture.
"""

import argparse
import base64
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Tests" / "GTDCoreTests" / "Fixtures" / "parity.json"

# The fixed "today" used for everything date-dependent, so the fixture is
# reproducible. The Swift tests pass the same values in.
TODAY = date(2026, 9, 30)
NOW_UTC = datetime(2026, 9, 30, 12, 0, 0, tzinfo=timezone.utc)

ACCOUNTS_RAW = [
    {"email_address": "Me@Example.com", "display_name": "Work account", "colour": "yellow"},
    {"email_address": "me.home@example.org", "colour": "purple"},
]


# ---------------------------------------------------------------------------
# Inputs

HEADER_CASES = [
    "Plain subject",
    "  padded subject  ",
    "=?utf-8?q?Z=C3=B6e?=",
    "=?utf-8?q?Z=C3=B6e?= and =?utf-8?b?w6k=?= x",
    "=?utf-8?q?a?=  =?utf-8?q?b?=",
    "pre =?utf-8?q?a_b?=post",
    "Re: =?ISO-8859-1?Q?caf=E9?=\n =?ISO-8859-1?Q?_bar?=",
    "=?bogus?q?abc?=",
    "=?utf-8?q?bad=ZZ?=",
    "=?utf-8?b?w6k?=",
    "=?utf-8?B?SGVsbG8gV29ybGQ=?=",
    "=?us-ascii?q?a?= b",
    "=?utf-8?q?=FF?=",
    "=?windows-1252?q?=93quoted=94?=",
    "Hello\n world",
    "=?UTF-8?Q?Caf=C3=A9_?= =?UTF-8?Q?cr=C3=A8me?=",
    "(comment) =?utf-8?q?x?=",
    "",
]

DATE_CASES = [
    "Wed, 03 Jun 2026 09:15:00 +0000",
    "Wed, 3 Jun 2026 09:15 +0100",
    "3 Jun 2026 09:15:00 -0500",
    "Wed, 03 Jun 26 09:15:00 EST",
    "Wed, 03 Jun 99 23:59:59 GMT",
    "Wed, 03 Jun 2026 09:15:00 -0000",
    "Wed, 03 Jun 2026 09:15:00",
    "Wed, 03 Jun 2026 09:15:00 +0530 (IST)",
    "Wed,03 Jun 2026 09:15:00 +0200",
    "June 3, 2026 09:15:00 +0000",
    "Jun 3 2026 09:15:00 +0000",
    "03-Jun-2026 09:15:00 +0000",
    "Wed, 03 Jun 2026 09.15.00 +0000",
    "Wed, 31 Feb 2026 09:15:00 +0000",
    "Wed, 03 Jun 2026 25:15:00 +0000",
    "Tue, 29 Sep 2026 23:30:00 -0700",
    "not a date",
    "",
]

SLUG_CASES = [
    "Meeting Minutes - Project Pudding!",
    "Re: Re: FW: hello",
    "Café crème",
    "   ",
    "ALL CAPS 123",
    "a--b__c",
    "\u212a kelvin",
]

BASE_FILENAME_CASES = [
    # (iso date, subject, max_chars, message_ref)
    ("2026-06-12", "Meeting Minutes", 40, None),
    ("2026-06-12", "Meeting Minutes", 40, "8FKnj9Tx8d"),
    ("2026-06-12", "A very long subject line that will certainly need truncating somewhere", 60, None),
    ("2026-06-12", "A very long subject line that will certainly need truncating somewhere", 60, "8FKnj9Tx8d"),
    ("2026-06-12", "", 60, None),
    ("2026-06-12", "!!!", 60, "abcdef"),
    ("2026-06-12", "Subject", 20, "abcdefghijklmnopqrstuvwxyz"),
    ("2026-06-12", "trailing-dash-at-the-cut-point", 30, None),
]

UNIQUE_FILENAME_CASES = [
    # (base, existing, max_chars, message_ref)
    ("2026-06-12-meeting", [], 60, None),
    ("2026-06-12-meeting", ["2026-06-12-meeting.eml"], 60, None),
    ("2026-06-12-meeting", ["2026-06-12-meeting.eml", "2026-06-12-meeting-2.eml"], 60, None),
    ("2026-06-12-meeting-ref-8FKnj9Tx8d", ["2026-06-12-meeting-ref-8FKnj9Tx8d.eml"], 40, "8FKnj9Tx8d"),
    ("2026-06-12-a-long-subject-slug-here", ["2026-06-12-a-long-subject-slug-here.eml"], 40, None),
]

STRIP_HTML_CASES = [
    "<p>Hi <b>Jane</b></p>",
    "<html><head><style>p{color:red}</style></head><body>Line<br>two<br/>three</body></html>",
    "<script>alert(1)</script>Safe &amp; sound &lt;tag&gt; &quot;q&quot; &#39;s&#39;&nbsp;x",
    "<p>a</p><p>b</p><p>c</p>\n\n\n\n<p>d</p>",
]

THREAD_CASES = [
    "Thanks!\n\nOn Wed, 3 Jun 2026, Jane <j@x.com> wrote:\n> Please review\n",
    "Top reply\n\nOn Wed, 3 Jun 2026 at 09:15, Jane Doe\n<jane@x.com> wrote:\n> First level\n> > Second level\n> back to first\n",
    "Hi\n\n-----Original Message-----\nFrom: Bob <bob@y.com>\nSent: Tuesday, 3 August 2026 12:34\nTo: Me\nSubject: Hello\n\nOriginal body\n",
    "Fwd below\n\nBegin forwarded message:\n\nFrom: Carol <c@z.com>\nDate: 1 June 2026 at 10:00:00 BST\nSubject: FYI\n\nForwarded text\n",
    "Reply\n\n________________________________\nFrom: Dan <d@q.com>\nSent: 2 Jun 2026 14:00\nTo: Me\n\nOutlook text\n",
    "From: the archives, a story\nNot a header block.\n",
    "Plain body with no quoting at all.\n",
    "",
    "> only quoted\n> text\n",
    "Line one\r\nLine two\r\n\r\n\r\n\r\nLine three",
]

DATE_TEXT_CASES = [
    "Tuesday, 3 August 2026 12:34",
    "Wed, 03 Jun 2026 09:15:00 +0100",
    "last Tuesday",
    "2026-08-03 12:34:56 UTC",
    "August 3rd, 2026 9:15 PM",
    "Jun 3 2026 at 12:00 AM GMT",
    "3 Sept 2026 23:59 -05:30",
    "1 June 2026 at 10:00:00 BST",
    "32 Jun 2026",
]

FLAG_CASES = ["pinned", "pinned, urgent", "", "  A  b,,C ", "Pinned"]

AUTOFIX_ROWS = [
    ("2026-06-01-a.eml", "04-delegated", {"ds_triage": "2026-06-02"}),
    ("2026-06-01-b.eml", "04-delegated", {"ds_delegated": "2026-06-05"}),
    ("2026-06-01-c.eml", "06-archive", {"ds_actionable": "2026-06-05", "ds_archive": "2026-06-10"}),
    ("2026-06-01-d.eml", "06-archive", {"ds_reference": "2026-06-05", "ds_archive": "2026-06-09"}),
    ("2026-06-01-e.eml", "02-triage", {}),
    ("2026-06-01-f.eml", "03-actionable", {}),
    ("2026-06-01-g.eml", "03-actionable", {"ds_triage": "2026-06-03"}),
    ("2026-06-01-h.eml", "05-reference", {"ds_triage": "2026-06-03", "ds_reference": "2026-06-04"}),
    ("2026-06-01-i.eml", "05-reference", {}),
    ("2026-06-01-j.eml", "06-archive", {}),
    ("2026-06-01-k.eml", "02-triage", {"ds_triage": "2026-06-02"}),
]

METRIC_ROWS = [
    ("2026-06-01-x.eml", {"ds_triage": "2026-06-03", "ds_actionable": "2026-06-05", "ds_archive": "2026-06-10"}),
    ("2026-06-01-y.eml", {"ds_triage": "2026-06-03"}),
    ("2026-06-05-z.eml", {"ds_triage": "2026-06-03"}),
    ("no-date.eml", {"ds_triage": "2026-06-03"}),
    ("2026-06-01-w.eml", {"ds_triage": "2026-06-02", "ds_actionable": "2026-06-02",
                          "ds_reference": "2026-06-09", "ds_archive": "2026-06-04"}),
    ("2026-06-01-v.eml", {"ds_triage": "2026-06-02", "ds_actionable": "2026-06-03",
                          "ds_delegated": "2026-06-04", "ds_archive": "2026-06-20"}),
    ("2026-07-15-u.eml", {"ds_triage": "2026-07-15", "ds_actionable": "2026-08-01"}),
    ("2026-08-30-t.eml", {"ds_triage": "2026-09-01"}),
    ("2026-09-28-s.eml", {"ds_triage": "2026-09-29", "ds_actionable": "2026-09-29",
                          "ds_delegated": "2026-09-30"}),
    ("2025-12-31-r.eml", {"ds_triage": "2026-01-02", "ds_actionable": "2026-01-05",
                          "ds_archive": "2026-02-01"}),
    ("2026-03-15-q.eml", {"ds_triage": "bogus", "ds_actionable": ""}),
]


def eml(*header_lines, body="", crlf=True):
    """Assemble an .eml from header lines and a body (both text, ASCII-safe)."""
    nl = "\r\n" if crlf else "\n"
    text = nl.join(header_lines) + nl + nl + body.replace("\n", nl)
    return text.encode("latin-1") if isinstance(text, str) else text


EML_CASES = {
    "plain": eml(
        "From: Jane Doe <jane@example.com>",
        "To: Me <me@example.com>, Bob <bob@y.com>",
        "Cc: carol@z.com",
        "Subject: Project pudding: budget",
        "Date: Wed, 30 Sep 2026 09:14:00 +0100",
        "Message-ID: <1@example.com>",
        body="Hi,\n\nAttached are the numbers.\n\nJane\n"),
    "encoded-subject-lf": eml(
        "From: =?utf-8?q?Z=C3=B6e_Smith?= <zoe@example.com>",
        "To: me@example.com",
        "Subject: =?utf-8?q?Caf=C3=A9_menu?=",
        " =?utf-8?b?IGZvciBGcmlkYXk=?=",
        "Date: Tue, 29 Sep 2026 23:30:00 -0700",
        body="Menu attached.\n", crlf=False),
    "eightbit-subject": (
        b"From: Anon <anon@example.com>\r\n"
        b"To: me@example.com\r\n"
        b"Subject: Caf\xc3\xa9 time\r\n"
        b"Date: Mon, 28 Sep 2026 08:00:00 +0000\r\n"
        b"Content-Type: text/plain; charset=utf-8\r\n"
        b"Content-Transfer-Encoding: 8bit\r\n\r\n"
        b"Coffee at caf\xc3\xa9?\r\n"),
    "alternative": eml(
        "From: News <news@example.com>",
        "To: me.home@example.org",
        "Subject: Weekly digest",
        "Date: Sun, 27 Sep 2026 10:00:00 +0000",
        "MIME-Version: 1.0",
        'Content-Type: multipart/alternative; boundary="b1"',
        body=("preamble\n--b1\nContent-Type: text/plain; charset=us-ascii\n\nPlain part\n"
              "Message ref. PLAIN12345\n--b1\nContent-Type: text/html; charset=us-ascii\n\n"
              "<p>HTML part</p>\n--b1--\nepilogue\n")),
    "html-only-ref": eml(
        "From: Service <svc@example.com>",
        "To: me@example.com",
        "Subject: Your ticket",
        "Date: Sat, 26 Sep 2026 10:00:00 +0000",
        "Content-Type: text/html; charset=utf-8",
        body="<html><body><p>Thanks.</p><p>Message ref: HtMl_Ref-01</p></body></html>\n"),
    "base64-ref": eml(
        "From: Me <me@example.com>",
        "To: Me <me@example.com>",
        "Subject: Note to self",
        "Date: Fri, 25 Sep 2026 07:00:00 +1000",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        body=base64.encodebytes(
            "Remember the milk.\n\n\u2014\n\nMessage ref. 8FKnj9Tx8d\n\n"
            "> Message ref. OLDREF9999\n".encode("utf-8")).decode("ascii")),
    "qp-latin1": eml(
        "From: =?iso-8859-1?q?Jos=E9?= <jose@example.es>",
        "To: me@example.com",
        "Subject: =?iso-8859-1?q?Informaci=F3n?=",
        "Date: Thu, 24 Sep 2026 12:00:00 +0200",
        "Content-Type: text/plain; charset=iso-8859-1",
        "Content-Transfer-Encoding: quoted-printable",
        body="Hola, aqu=ED est=E1 la informaci=F3n que ped=EDs=\nte, con una l=EDnea larga.\n= \nFin\n"),
    "mixed-attachment": eml(
        "From: Bob <bob@y.com>",
        "To: me@example.com",
        "Subject: Report",
        "Date: Wed, 23 Sep 2026 12:00:00 +0000",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=outer",
        body=("--outer\nContent-Type: text/plain\n\nSee attached.\n"
              "--outer\nContent-Type: application/pdf; name=\"report.pdf\"\n"
              "Content-Disposition: attachment; filename=\"report.pdf\"\n"
              "Content-Transfer-Encoding: base64\n\nJVBERi0xLjQK\n"
              "--outer\nContent-Type: image/png\n"
              "Content-Disposition: attachment; filename*=UTF-8''caf%C3%A9.png\n\niVBORw0K\n"
              "--outer\nContent-Type: text/plain; name=\"notes.txt\"\n\nnamed text\n"
              "--outer--\n")),
    "attachment-only": eml(
        "From: Scanner <scan@example.com>",
        "To: me@example.com",
        "Subject: Scan",
        "Date: Tue, 22 Sep 2026 12:00:00 +0000",
        "Content-Type: multipart/mixed; boundary=zz",
        body=("--zz\nContent-Type: application/octet-stream\n"
              "Content-Disposition: attachment\n\nAAAA\n--zz--\n")),
    "reply-thread": eml(
        "From: Jane Doe <jane@example.com>",
        "To: me@example.com",
        "Subject: Re: Lunch?",
        "Date: Mon, 21 Sep 2026 13:00:00 +0000",
        body=("Sounds good.\n\nOn Mon, 21 Sep 2026 at 12:00, Me <me@example.com> wrote:\n"
              "> How about Friday?\n>\n> > On Sun, Jane wrote:\n> > > Lunch?\n> Cheers\n")),
    "outlook-chain": eml(
        "From: Dan <dan@example.com>",
        "To: me@example.com",
        "Subject: RE: Contract",
        "Date: Sun, 20 Sep 2026 13:00:00 +0000",
        body=("Agreed.\n\n-----Original Message-----\nFrom: Me <me@example.com>\n"
              "Sent: Saturday, 19 September 2026 17:00\nTo: Dan\nSubject: Contract\n\n"
              "Please sign.\n")),
    "forwarded-rfc822": eml(
        "From: Me <me@example.com>",
        "To: me.home@example.org",
        "Subject: Fwd: Invoice",
        "Date: Sat, 19 Sep 2026 13:00:00 +0000",
        "Content-Type: multipart/mixed; boundary=fw",
        body=("--fw\nContent-Type: text/plain\n\nForwarding this.\n"
              "--fw\nContent-Type: message/rfc822\n\n"
              "From: Billing <bill@example.com>\nSubject: Invoice\n"
              "Content-Type: text/plain\n\nInvoice body\n"
              "--fw--\n")),
    "named-timezone": eml(
        "From: jane@example.com (Jane Comment)",
        'To: "Doe, Jane" <jane.doe@example.com>, Team: a@x.com, b@y.com;',
        "Subject: Timezones",
        "Date: Fri, 18 Sep 26 20:00:00 EST",
        body="Body\n"),
    "no-boundary": eml(
        "From: x@example.com",
        "Subject: Broken multipart",
        "Date: Thu, 17 Sep 2026 12:00:00 +0000",
        "Content-Type: multipart/mixed",
        body="Just text really.\n"),
    "long-subject-ref": eml(
        "From: x@example.com",
        "Subject: An extremely long subject line that goes on and on about the quarterly figures",
        "Date: Wed, 16 Sep 2026 12:00:00 +0000",
        body="Text\n\nMessage  ref.:  LongRef_123456\n"),
    "unknown-charset": eml(
        "From: x@example.com",
        "Subject: Odd charset",
        "Date: Tue, 15 Sep 2026 12:00:00 +0000",
        "Content-Type: text/plain; charset=x-unknown-thing",
        body="caf\xe9\n"),
    "cp1252": (
        b"From: x@example.com\r\nSubject: Smart quotes\r\n"
        b"Date: Mon, 14 Sep 2026 12:00:00 +0000\r\n"
        b"Content-Type: text/plain; charset=\"windows-1252\"\r\n\r\n"
        b"\x93Hello\x94 \x96 it\x92s here\r\n"),
    "unix-from": eml(
        "From sender@example.com Mon Sep 14 12:00:00 2026",
        "From: sender@example.com",
        "Subject: Mbox style",
        "Date: Sun, 13 Sep 2026 12:00:00 +0000",
        body="Body\n"),
    "missing-separator": (
        b"From: x@example.com\nSubject: No blank line\nDate: Sat, 12 Sep 2026 12:00:00 +0000\n"
        b"This line is not a header\nMore body\n"),
    "folded-plain-subject": eml(
        "From: x@example.com",
        "Subject: A subject folded",
        "   across two lines",
        "Date: Fri, 11 Sep 2026 12:00:00 +0000",
        body="Body\n"),
    "digest": eml(
        "From: list@example.com",
        "Subject: Digest",
        "Date: Thu, 10 Sep 2026 12:00:00 +0000",
        "Content-Type: multipart/digest; boundary=dg",
        body=("--dg\n\nFrom: a@example.com\nSubject: One\n\nFirst digest item\n"
              "--dg\n\nFrom: b@example.com\nSubject: Two\n\nSecond\n--dg--\n")),
}


# ---------------------------------------------------------------------------
# Helpers

def jdate(d):
    return d.isoformat() if d else None


def date_result(dt):
    """Serialise an aware datetime: epoch, offset, local day and minute."""
    off = dt.utcoffset()
    return {"epoch": int(dt.timestamp()),
            "offset": int(off.total_seconds()) if off is not None else None,
            "day": dt.strftime("%Y-%m-%d"),
            "minute": dt.strftime("%Y-%m-%d %H:%M")}


@contextlib.contextmanager
def quiet():
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        yield


def snapshot(base):
    """Every workflow file (folder/name) plus metadata.csv's exact bytes."""
    files = []
    for folder in ["01-input", "02-triage", "03-actionable", "04-delegated", "05-reference", "06-archive"]:
        p = base / folder
        if p.is_dir():
            files.extend(f"{folder}/{n}" for n in sorted(os.listdir(p)))
    meta = base / "metadata.csv"
    return {"files": files,
            "metadata_csv": meta.read_bytes().decode("utf-8") if meta.exists() else None}


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--python-repo", default=str(ROOT.parent / "qdvc-gtd-eml"),
                        help="checkout of qdvc-gtd-eml (default: a sibling folder)")
    args = parser.parse_args()
    repo = Path(args.python_repo).resolve()
    if not (repo / "gtd_modules").is_dir():
        sys.exit(f"error: {repo} does not contain gtd_modules/")
    sys.path.insert(0, str(repo))

    from email import message_from_binary_file
    from email.utils import parsedate_to_datetime

    from gtd_modules import config, dashboard, emailutil, metadata, metrics, naming, thread
    from gtd_modules import report
    from gtd_modules.ingest import ingest_input_files
    from gtd_modules import commands

    accounts = config.normalise_accounts(ACCOUNTS_RAW)
    out = {"today": TODAY.isoformat(), "now_utc": int(NOW_UTC.timestamp()),
           "accounts_raw": ACCOUNTS_RAW, "accounts": accounts}

    out["normalise_accounts"] = [
        {"input": ACCOUNTS_RAW + [{"email_address": "  "}, "not-a-dict", {"email_address": "X@Y.Z", "display_name": " Pad "}],
         "output": config.normalise_accounts(ACCOUNTS_RAW + [{"email_address": "  "}, "not-a-dict", {"email_address": "X@Y.Z", "display_name": " Pad "}])}]
    out["normalise_hashtags"] = [
        {"input": ["#urgent", " #family ", "#URGENT", "", 7], "output": config.normalise_hashtags(["#urgent", " #family ", "#URGENT", "", 7])}]

    out["decode_mime"] = [{"input": c, "output": emailutil.decode_mime(c)} for c in HEADER_CASES]

    dates = []
    for c in DATE_CASES:
        try:
            dt = parsedate_to_datetime(c)
            dates.append({"input": c, "naive": dt.tzinfo is None,
                          "output": date_result(dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc))})
        except Exception:
            dates.append({"input": c, "naive": None, "output": None})
    out["parse_date"] = dates

    out["slugify"] = [{"input": c, "output": naming.slugify(c)} for c in SLUG_CASES]
    out["build_base_filename"] = [
        {"date": d, "subject": s, "max_chars": m, "ref": r,
         "output": naming.build_base_filename(date.fromisoformat(d), s, m, message_ref=r)}
        for d, s, m, r in BASE_FILENAME_CASES]
    out["unique_filename"] = [
        {"base": b, "existing": e, "max_chars": m, "ref": r,
         "output": naming.unique_filename(b, set(e), m, message_ref=r)}
        for b, e, m, r in UNIQUE_FILENAME_CASES]
    out["strip_html"] = [{"input": c, "output": emailutil.strip_html(c)} for c in STRIP_HTML_CASES]
    out["split_history"] = [{"input": c, "output": thread.split_history(c),
                             "summary": thread.summarise(c)} for c in THREAD_CASES]
    out["parse_date_text"] = [{"input": c, "output": thread.parse_date_text(c)} for c in DATE_TEXT_CASES]
    out["parse_flags"] = [{"input": c, "output": sorted(report.parse_flags(c))} for c in FLAG_CASES]
    out["colour_for_days"] = [{"days": d, "output": report.colour_for_days(d, 2, 14)}
                              for d in (-1, 0, 1, 2, 13, 14, 100)]

    # --- Emails -----------------------------------------------------------
    emails = []
    for name, raw in EML_CASES.items():
        with tempfile.NamedTemporaryFile(suffix=".eml", delete=False) as f:
            f.write(raw)
            path = f.name
        try:
            msg = emailutil.read_eml_message(path)
        finally:
            os.unlink(path)
        has_date = bool(msg.get("Date"))
        try:
            dt = parsedate_to_datetime(msg.get("Date", ""))
            date_ok = dt is not None
        except Exception:
            date_ok = False
        d = emailutil.get_email_date(msg) if date_ok else None
        subject = emailutil.get_email_subject(msg)
        ref = emailutil.find_message_ref(msg)
        body_raw = emailutil.get_email_body_text(msg)
        body = emailutil.get_email_body_text(msg, render_html=True)
        by_role = emailutil.match_own_accounts_by_role(msg, accounts)
        own = emailutil.match_own_account(msg, accounts)
        emails.append({
            "name": name,
            "raw_base64": base64.b64encode(raw).decode("ascii"),
            "subject": subject,
            "date": date_result(d) if d else None,
            "has_date_header": has_date,
            "message_ref": ref,
            "body_raw": body_raw,
            "body": body,
            "attachments": emailutil.list_attachments(msg),
            "from": emailutil.format_addresses(msg, "From"),
            "to": emailutil.format_addresses(msg, "To"),
            "cc": emailutil.format_addresses(msg, "Cc"),
            "correspondents": emailutil.get_email_correspondents(
                msg, exclude=[a["email_address"] for a in accounts]),
            "own_account": own["display_name"] if own else None,
            "inbox": [a["display_name"] for a in by_role["recipient"]],
            "sent": [a["display_name"] for a in by_role["sender"]],
            "base_filename_60": (naming.build_base_filename(d, subject, 60, message_ref=ref)
                                 if d else None),
            "base_filename_40": (naming.build_base_filename(d, subject, 40, message_ref=ref)
                                 if d else None),
            "thread": thread.split_history(body),
            "preview": thread.summarise(body),
            "age_days": (NOW_UTC.date() - d.date()).days if d else None,
        })
    out["emails"] = emails

    # --- Analytics --------------------------------------------------------
    records = [{"filename": f, "folder": folder, "row": row} for f, folder, row in AUTOFIX_ROWS]
    fixes, blockers = metrics.plan_autofix(records, today=TODAY)
    out["plan_autofix"] = {"records": records, "fixes": fixes, "blockers": blockers}

    computed = []
    for f, row in METRIC_ROWS:
        c = metrics.compute_email_metrics(f, row)
        computed.append(c)
    out["metrics"] = [
        {"filename": f, "row": row, "status": c["status"], "metrics": c["metrics"],
         "email_date": jdate(c["email_date"]), "triage_date": jdate(c["triage_date"]),
         "actionable_date": jdate(c["actionable_date"]),
         "resolution_date": jdate(c["resolution_date"]),
         "stages": [[label, jdate(d)] for label, d in c["stages"]]}
        for (f, row), c in zip(METRIC_ROWS, computed)]
    labels, counts = dashboard.build_backlog_age_histogram(computed, TODAY)
    out["backlog"] = {"stats": dashboard.build_backlog_stats(computed, TODAY),
                      "histogram": {"labels": labels, "counts": counts},
                      "weekly": dashboard.build_flow_series(computed, "weekly"),
                      "monthly": dashboard.build_flow_series(computed, "monthly")}

    # --- Workspace scenario ----------------------------------------------
    out["scenario"] = run_scenario(config, metadata, commands, ingest_input_files, accounts)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False, default=str) + "\n",
                   encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)}: {len(emails)} emails, "
          f"{len(out['decode_mime'])} headers, {len(out['parse_date'])} dates")


def run_scenario(config, metadata, commands, ingest_input_files, accounts):
    """Replay a series of CLI operations on a scratch workspace, recording the
    files and metadata.csv bytes after each step."""
    base = Path(tempfile.mkdtemp())
    try:
        for folder in config.ALL_DIRS:
            (base / folder).mkdir()
        # Seed an older metadata.csv missing the newer columns (migration).
        inputs = {
            "inbox1.eml": EML_CASES["plain"],
            "inbox2.eml": EML_CASES["base64-ref"],
            "zz 3.eml": EML_CASES["long-subject-ref"],
            "dup.eml": EML_CASES["plain"],
        }
        for name, raw in inputs.items():
            (base / "01-input" / name).write_bytes(raw)
        (base / "05-reference" / "2026-01-01-hand-filed.eml").write_bytes(EML_CASES["qp-latin1"])
        (base / "metadata.csv").write_bytes(
            b"eml_filename,general_notes,project,next_action\r\n"
            b"2026-01-01-hand-filed.eml,\"note, with comma\",Proj,\"Closed with gone.eml\"\r\n"
            b"vanished.eml,,,\r\n")

        stamp = TODAY.isoformat()
        metadata.today_stamp = lambda: stamp
        cfg = dict(config.DEFAULTS, working_directory=str(base), my_own_accounts=accounts,
                   monitored_hashtags=[])
        config.load_config = lambda *a, **k: cfg

        contents = {}
        for folder in config.ALL_DIRS:
            for n in sorted(os.listdir(base / folder)):
                contents[f"{folder}/{n}"] = base64.b64encode((base / folder / n).read_bytes()).decode("ascii")
        steps = [{"op": "initial", "contents": contents, "state": snapshot(base)}]

        # ingest (what `gtd list` does)
        moved = ingest_input_files(str(base), cfg["max_filename_chars"])
        seeds = {}
        for _, new_name, ref in moved:
            seed = {"ds_triage": stamp}
            if ref:
                seed["message_ref"] = ref
            seeds[new_name] = seed
        metadata.sync_metadata(str(base), new_values=seeds)
        steps.append({"op": "ingest", "moved": [list(m) for m in moved], "state": snapshot(base)})
        names = [m[1] for m in moved]

        def run(op, argv, fn):
            with quiet():
                code = fn(argv)
            steps.append({"op": op, "argv": argv, "code": code, "state": snapshot(base)})

        run("alloc", [names[0], "actionable"], commands.cmd_alloc)
        run("alloc", [names[0], "actionable"], commands.cmd_alloc)          # no-op
        run("alloc", [names[1], "archive"], commands.cmd_alloc)
        run("alloc", [names[1], "triage"], commands.cmd_alloc)              # refused: ds_triage set
        run("metadata", [names[0], "set", "next_action", "=", "Reply", "by", "Friday", "#urgent"],
            commands.cmd_metadata)
        run("metadata", [names[0], "set", "general_notes", "=", 'Multi\nline, "quoted"'],
            commands.cmd_metadata)
        run("metadata", [names[0], "set", "due_date", "=", "end of Q3"], commands.cmd_metadata)
        run("pin", [names[0]], commands.cmd_pin)
        run("pin", [names[0]], commands.cmd_pin)                            # no-op
        run("metadata", [names[2], "set", "flags", "=", "a,  b"], commands.cmd_metadata)
        run("pin", [names[2]], commands.cmd_pin)
        run("unpin", [names[0]], commands.cmd_unpin)
        run("close", [names[2], "with", names[0]], commands.cmd_close)
        run("close", [names[2], "with", names[0]], commands.cmd_close)      # refused: archived
        run("close", [names[3], "with", "missing.eml"], commands.cmd_close)  # refused: missing
        run("alloc", ["2026-01-01-hand-filed.eml", "archive"], commands.cmd_alloc)

        # metadata_check, then autofix plan + apply
        with quiet():
            code = commands.cmd_metadata_check([])
        steps.append({"op": "metadata_check", "code": code, "state": snapshot(base)})

        from gtd_modules import metrics
        meta_rows = metadata.load_metadata(str(base))
        records = []
        for folder in config.ALL_DIRS[1:]:
            for n in sorted(os.listdir(base / folder)):
                records.append({"filename": n, "folder": folder, "row": meta_rows.get(n, {})})
        fixes, blockers = metrics.plan_autofix(records, today=TODAY)
        for fx in fixes:
            metadata.set_metadata_value(str(base), fx["filename"], fx["field"], fx["new"])
        steps.append({"op": "autofix", "fixes": fixes, "blockers": blockers, "state": snapshot(base)})
        return steps
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
