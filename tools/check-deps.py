#!/usr/bin/env python3
"""
check-deps.py — is the pinned private OpenSSL behind the latest LTS patch?

The builder pins a private OpenSSL (build.sh: OPENSSL_VERSION + OPENSSL_SHA256)
rather than pulling "latest" at build time — pinning keeps the build reproducible,
lets us sha256-verify a known release before it touches the crypto path, and keeps
the three legacy-PHP repos agreeing on the ONE shared /opt/ngm/php/openssl-3.5
prefix. What we automate is the *detection*, not the adoption: this tool asks the
OpenSSL GitHub for the newest patch on our LTS line (default 3.5) and its official
sha256, and reports whether our pin is behind. Adoption stays a reviewed edit
(or `--bump`, which only rewrites the two pin lines for you to commit).

    ./tools/check-deps.py                 # report only (exit 0 current, 3 behind)
    ./tools/check-deps.py --bump          # also rewrite build.sh's pin lines
    ./tools/check-deps.py --line 3.5      # track a specific LTS line (default 3.5)

Stdlib only; reads the canonical openssl.org/source index + .sha256 over TLS —
the same host build.sh already downloads from, and it lists only the latest patch
per branch, so scraping it IS "the latest 3.5 LTS".
"""
import argparse, glob, os, re, sys, urllib.request


def _default_build_sh():
    """The repo's build script: build.sh (php7) or build-php<NN>.sh (php53/php56)."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cand = os.path.join(root, "build.sh")
    if os.path.exists(cand):
        return cand
    hits = sorted(glob.glob(os.path.join(root, "build-php*.sh")))
    return hits[0] if hits else cand


BUILD_SH = _default_build_sh()


SOURCE_INDEX = "https://www.openssl.org/source/"


def _get(url):
    headers = {"User-Agent": "ngm-check-deps"}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return r.read()


def latest_openssl(line):
    """Highest patch on the given LTS line, e.g. line '3.5' -> '3.5.8'. The
    openssl.org source index carries only the current release per branch, so the
    highest openssl-<line>.<n>.tar.gz it lists is the latest LTS patch."""
    html = _get(SOURCE_INDEX).decode("utf-8", "replace")
    pat = re.compile(rf"openssl-({re.escape(line)}\.(\d+))\.tar\.gz")
    best = None
    for m in pat.finditer(html):
        if best is None or int(m.group(2)) > best[0]:
            best = (int(m.group(2)), m.group(1))
    return best[1] if best else None


def official_sha256(version):
    txt = _get(f"{SOURCE_INDEX}openssl-{version}.tar.gz.sha256").decode()
    return txt.split()[0].strip()


def current_pin(path):
    txt = open(path, encoding="utf-8").read()
    v = re.search(r"OPENSSL_VERSION:-([0-9][0-9.]*)", txt)
    s = re.search(r"OPENSSL_SHA256:-([0-9a-f]{64})", txt)
    return (v.group(1) if v else None), (s.group(1) if s else None)


def bump(path, new_ver, new_sha):
    txt = open(path, encoding="utf-8").read()
    txt2 = re.sub(r"(OPENSSL_VERSION:-)[0-9][0-9.]*", rf"\g<1>{new_ver}", txt, count=1)
    txt2 = re.sub(r"(OPENSSL_SHA256:-)[0-9a-f]{64}", rf"\g<1>{new_sha}", txt2, count=1)
    # keep the trailing "# openssl-<ver>.tar.gz" provenance comment honest
    txt2 = re.sub(r"(#\s*)openssl-[0-9][0-9.]*(\.tar\.gz)", rf"\g<1>openssl-{new_ver}\g<2>", txt2, count=1)
    if txt2 == txt:
        return False
    open(path, "w", encoding="utf-8").write(txt2)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--line", default="3.5", help="OpenSSL LTS line to track (default 3.5)")
    ap.add_argument("--bump", action="store_true", help="rewrite build.sh's OPENSSL_VERSION + OPENSSL_SHA256")
    ap.add_argument("--build-sh", default=BUILD_SH)
    args = ap.parse_args()

    cur_ver, cur_sha = current_pin(args.build_sh)
    if not cur_ver:
        print("could not read OPENSSL_VERSION from", args.build_sh, file=sys.stderr)
        return 2
    latest = latest_openssl(args.line)
    if not latest:
        print(f"no openssl-{args.line}.x tags found upstream", file=sys.stderr)
        return 2

    print(f"pinned : OpenSSL {cur_ver}")
    print(f"latest : OpenSSL {latest} (line {args.line})")
    if latest == cur_ver:
        print("=> up to date.")
        return 0

    new_sha = official_sha256(latest)
    print(f"=> BEHIND. newest {args.line} LTS is {latest}, sha256:\n   {new_sha}")
    if args.bump:
        if bump(args.build_sh, latest, new_sha):
            print(f"bumped {os.path.relpath(args.build_sh)} to {latest} — review & commit, then rebuild "
                  f"(and bump the sibling php53/php56 repos to match the shared prefix).")
        else:
            print("nothing rewritten (pin lines not found in expected form)", file=sys.stderr)
            return 2
    else:
        print("run with --bump to rewrite the pin (or edit build.sh by hand), then commit + rebuild.")
    return 3


if __name__ == "__main__":
    sys.exit(main())
