#!/usr/bin/env python3
"""
check-deps.py — is anything this builder pins behind upstream?

The builder pins every external input (build.sh / build-php<NN>.sh: a version + a
sha256 per tarball, and patches/[<nn>/]SOURCE per CloudLinux SRPM) rather than
pulling "latest" at build time — pinning keeps the build reproducible, lets us
sha256-verify a known release before it touches the crypto path, and keeps the
legacy-PHP repos agreeing on the ONE shared /opt/ngm/php/openssl-3.5 prefix.
What we automate is the *detection*, not the adoption: this tool reports what is
behind, and `--bump` rewrites the pins (and re-imports a newer CloudLinux series)
so a human reviews `git diff` and commits. The weekly GitHub Action
(.github/workflows/check-deps.yml) runs `--bump` and opens that diff as a PR.

Checked, each only where this repo pins it:

    openssl        latest patch on the LTS line (default 3.5), official .sha256
    curl           latest release (curl.se/info), sha256 of the .tar.xz we build
    snuffleupagus  highest vX.Y.Z tag, sha256 of the GitHub tag archive
    cloudlinux     newest ea-phpNN SRPM release per patches/[<nn>/]SOURCE;
                   --bump re-runs tools/import-cloudlinux-patches.py on it

    ./tools/check-deps.py                  # report (exit 0 current, 3 behind, 2 error)
    ./tools/check-deps.py --bump           # also rewrite pins / re-import series
    ./tools/check-deps.py --only openssl   # one or more checks, comma-separated
    ./tools/check-deps.py --summary f.md   # also write a markdown report (PR body)

Where upstream publishes no sha256 for the exact file we build (curl's .tar.xz,
GitHub tag archives) the bump downloads it once and records its digest — the
same TLS trust the build itself has; the pin then guards every later build.
Stdlib only (+ the git CLI for tag listing). The same file ships in php53, php56
and php; a check whose pin a repo doesn't carry is skipped.
"""
import argparse, glob, hashlib, os, re, subprocess, sys, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _default_build_sh():
    """The repo's build script: build.sh (chrismfz/php) or build-php<NN>.sh (php53/php56)."""
    cand = os.path.join(ROOT, "build.sh")
    if os.path.exists(cand):
        return cand
    hits = sorted(glob.glob(os.path.join(ROOT, "build-php*.sh")))
    return hits[0] if hits else cand


BUILD_SH = _default_build_sh()

OPENSSL_INDEX = "https://www.openssl.org/source/"
CURL_INFO = "https://curl.se/info"
CURL_DOWNLOAD = "https://curl.se/download/"
SNUFFLEUPAGUS_REPO = "https://github.com/jvoisin/snuffleupagus"
CHECKS = ("openssl", "curl", "snuffleupagus", "cloudlinux")


def _get(url, timeout=60):
    headers = {"User-Agent": "ngm-check-deps"}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
        return r.read()


def _sha256_of(url):
    return hashlib.sha256(_get(url, timeout=300)).hexdigest()


def _vkey(v):
    return tuple(int(x) for x in v.split("."))


class Result:
    """One pinned input: what we pin, what upstream has, and what --bump did."""

    def __init__(self, name, pinned, latest=None, note="", error=""):
        self.name, self.pinned, self.latest = name, pinned, latest
        self.note, self.error, self.bumped = note, error, False

    @property
    def behind(self):
        return not self.error and self.latest is not None and self.latest != self.pinned


# ── build-script pins ─────────────────────────────────────────────────────────

def read_pin(txt, var):
    m = re.search(rf'{var}="\$\{{{var}:-([^}}]*)\}}"', txt)
    return m.group(1) if m else None


def set_pin(txt, var, value):
    return re.sub(rf'({var}="\$\{{{var}:-)[^}}]*(\}}")', lambda m: m.group(1) + value + m.group(2), txt, count=1)


def set_comment(txt, var, old, new):
    """Keep the trailing provenance comment on a sha line honest (e.g. '# openssl-3.5.9.tar.gz')."""
    def fix(m):
        return m.group(0).replace(old, new)
    return re.sub(rf'^{var}=.*$', fix, txt, count=1, flags=re.M)


def check_openssl(txt, line):
    pinned = read_pin(txt, "OPENSSL_VERSION")
    if not pinned:
        return None, txt
    html = _get(OPENSSL_INDEX).decode("utf-8", "replace")
    pat = re.compile(rf"openssl-({re.escape(line)}\.\d+)\.tar\.gz")
    found = sorted(set(pat.findall(html)), key=_vkey)
    if not found:
        return Result("openssl", pinned, error=f"no openssl-{line}.x on {OPENSSL_INDEX}"), txt
    r = Result("openssl", pinned, found[-1],
               note="shared /opt/ngm/php/openssl-3.5 prefix: bump php53, php56 and php together")
    if r.behind and ARGS.bump:
        sha = _get(f"{OPENSSL_INDEX}openssl-{r.latest}.tar.gz.sha256").decode().split()[0].strip()
        txt = set_pin(txt, "OPENSSL_VERSION", r.latest)
        txt = set_pin(txt, "OPENSSL_SHA256", sha)
        txt = set_comment(txt, "OPENSSL_SHA256", f"openssl-{pinned}", f"openssl-{r.latest}")
        r.bumped = True
    return r, txt


def check_curl(txt):
    pinned = read_pin(txt, "CURL_VERSION")
    if not pinned:
        return None, txt
    info = _get(CURL_INFO).decode("utf-8", "replace")
    m = re.search(r"^Version:\s*([0-9][0-9.]*)\s*$", info, re.M)
    if not m:
        return Result("curl", pinned, error=f"no Version: line in {CURL_INFO}"), txt
    r = Result("curl", pinned, m.group(1), note="libcurl is built against GnuTLS; check the release notes")
    if r.behind and ARGS.bump:
        sha = _sha256_of(f"{CURL_DOWNLOAD}curl-{r.latest}.tar.xz")
        txt = set_pin(txt, "CURL_VERSION", r.latest)
        txt = set_pin(txt, "CURL_SHA256", sha)
        txt = set_comment(txt, "CURL_SHA256", f"curl-{pinned}", f"curl-{r.latest}")
        r.bumped = True
    return r, txt


def check_snuffleupagus(txt):
    pinned = read_pin(txt, "SNUFFLEUPAGUS_VERSION")
    if not pinned:
        return None, txt
    out = subprocess.run(["git", "ls-remote", "--tags", SNUFFLEUPAGUS_REPO],
                         capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        return Result("snuffleupagus", pinned, error=f"git ls-remote failed: {out.stderr.strip()}"), txt
    tags = set(re.findall(r"refs/tags/v(\d+\.\d+\.\d+)$", out.stdout, re.M))
    if not tags:
        return Result("snuffleupagus", pinned, error="no vX.Y.Z tags upstream"), txt
    r = Result("snuffleupagus", pinned, max(tags, key=_vkey),
               note="0.14+ rejects non-ASCII bytes in rules; read the changelog before enabling")
    pinned_sha = read_pin(txt, "SNUFFLEUPAGUS_SHA256")
    if ARGS.bump and (r.behind or not pinned_sha):
        # A stale sha would abort the build, so it is always rewritten with the version:
        # to the archive's digest, or emptied (warn-only) if the archive can't be fetched.
        try:
            sha = _sha256_of(f"{SNUFFLEUPAGUS_REPO}/archive/refs/tags/v{r.latest}.tar.gz")
        except Exception as e:
            sha = ""
            r.note += f"; tag archive not fetched ({e}), SNUFFLEUPAGUS_SHA256 left empty"
        if sha != pinned_sha or r.behind:
            txt = set_pin(txt, "SNUFFLEUPAGUS_VERSION", r.latest)
            txt = set_pin(txt, "SNUFFLEUPAGUS_SHA256", sha)
            txt = set_comment(txt, "SNUFFLEUPAGUS_SHA256", f"v{pinned}", f"v{r.latest}")
            r.bumped = True
            if not r.behind:
                r.note += "; filled the missing SNUFFLEUPAGUS_SHA256 pin"
    return r, txt


# ── CloudLinux SRPM series ────────────────────────────────────────────────────

SRPM_RE = r"(\d+)\.(el\d+)\.cloudlinux\.(\d+)\.src\.rpm"


def check_cloudlinux():
    results, listings = [], {}
    sources = sorted(glob.glob(os.path.join(ROOT, "patches", "SOURCE")) +
                     glob.glob(os.path.join(ROOT, "patches", "*", "SOURCE")))
    for src in sources:
        fields = dict(ln.rstrip("\n").split("\t", 1) for ln in open(src, encoding="utf-8") if "\t" in ln)
        fname, url = fields.get("srpm_filename", ""), fields.get("source_url", "")
        minor = os.path.basename(os.path.dirname(src))
        minor = "" if minor == "patches" else minor
        m = re.match(rf"(ea-php\d+-php-[0-9.]+-){SRPM_RE}$", fname)
        ver = re.match(r"ea-php(\d+)", fname)
        label = f"cloudlinux {minor or (ver.group(1) if ver else '?')}"
        if not m or not url:
            results.append(Result(label, fname or "?", error=f"unparseable {os.path.relpath(src, ROOT)}"))
            continue
        prefix, el = m.group(1), m.group(3)
        base = url.rsplit("/", 1)[0] + "/"
        try:
            if base not in listings:
                listings[base] = _get(base, timeout=120).decode("utf-8", "replace")
        except Exception as e:
            results.append(Result(label, fname, error=f"listing {base}: {e}"))
            continue
        cands = {}
        for c in re.finditer(rf"{re.escape(prefix)}{SRPM_RE}", listings[base]):
            if c.group(2) == el:
                cands[(int(c.group(1)), int(c.group(3)))] = c.group(0)
        newest = cands[max(cands)] if cands else fname
        cur = (int(m.group(2)), int(m.group(4)))
        r = Result(label, fname, newest if cands and max(cands) > cur else fname,
                   note="new CloudLinux series: validate the apply + host-build before merge")
        if r.behind and ARGS.bump:
            cmd = [sys.executable, os.path.join(ROOT, "tools", "import-cloudlinux-patches.py")]
            if minor:
                cmd += ["--minor", minor]
            out = subprocess.run(cmd + [base + newest], cwd=ROOT, capture_output=True, text=True)
            if out.returncode != 0:
                r.error = f"importer failed: {(out.stderr or out.stdout).strip()[-400:]}"
            else:
                r.bumped = True
        results.append(r)
    return results


# ── report ────────────────────────────────────────────────────────────────────

def markdown(results, build_sh):
    rows = ["| input | pinned | latest | state |", "|---|---|---|---|"]
    for r in results:
        state = ("**error**: " + r.error) if r.error else (
            ("bumped" if r.bumped else "**behind**") if r.behind else
            ("pin updated" if r.bumped else "current"))
        rows.append(f"| {r.name} | `{r.pinned}` | `{r.latest or '?'}` | {state} |")
    notes = [f"- **{r.name}**: {r.note}" for r in results if (r.behind or r.bumped) and r.note]
    out = [f"Dependency check for `{os.path.relpath(build_sh, ROOT)}` (tools/check-deps.py).", ""] + rows
    if notes:
        out += ["", "Before merging:", ""] + notes
    return "\n".join(out) + "\n"


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--line", default="3.5", help="OpenSSL LTS line to track (default 3.5)")
    ap.add_argument("--bump", action="store_true", help="rewrite the pins and re-import newer SRPM series")
    ap.add_argument("--only", default=",".join(CHECKS), help="comma-separated subset of: " + ", ".join(CHECKS))
    ap.add_argument("--summary", help="also write a markdown report to this file")
    ap.add_argument("--build-sh", default=BUILD_SH)
    ARGS = ap.parse_args()
    only = {c.strip() for c in ARGS.only.split(",") if c.strip()}
    if only - set(CHECKS):
        ap.error(f"unknown check(s): {', '.join(sorted(only - set(CHECKS)))}")

    txt = orig = open(ARGS.build_sh, encoding="utf-8").read()
    results = []
    for name, fn in (("openssl", lambda t: check_openssl(t, ARGS.line)),
                     ("curl", check_curl), ("snuffleupagus", check_snuffleupagus)):
        if name not in only:
            continue
        try:
            r, txt = fn(txt)
        except Exception as e:
            r = Result(name, "?", error=str(e))
        if r:
            results.append(r)
    if txt != orig:
        open(ARGS.build_sh, "w", encoding="utf-8").write(txt)
    if "cloudlinux" in only:
        results += check_cloudlinux()

    for r in results:
        if r.error:
            print(f"{r.name:16} ERROR  {r.error}")
        elif r.behind or r.bumped:
            verb = "bumped" if r.bumped else "BEHIND"
            print(f"{r.name:16} {verb:6} {r.pinned} -> {r.latest}" + (f"  ({r.note})" if r.note else ""))
        else:
            print(f"{r.name:16} ok     {r.pinned}")
    if ARGS.summary:
        open(ARGS.summary, "w", encoding="utf-8").write(markdown(results, ARGS.build_sh))
    if any(r.behind or r.bumped for r in results):
        if not ARGS.bump:
            print("run with --bump to rewrite the pins, review `git diff`, commit + rebuild.")
        return 3
    return 2 if any(r.error for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
