#!/usr/bin/env python3
"""
import-cloudlinux-patches.py — refresh this repo's security patch series from a
public CloudLinux EA4 SRPM.

CloudLinux keeps backporting security/bug fixes to EOL PHP (5.3/5.6) long past
php.net's end-of-life and ships them, one patch per fix, inside the public EA4
source RPMs at https://repo.cloudlinux.com/cloudlinux/EA4/ . This tool cracks a
downloaded .src.rpm open (no rpm/rpm2cpio needed — stdlib only), reads the spec's
applied %patch series, keeps only the source security/bug backports we want
(CVE-*, bugNNNNN, hardened-*), drops the CloudLinux/LiteSpeed/EA4 runtime and
build-packaging patches, and regenerates patches/ deterministically:

    patches/series        the kept patches, in the spec's apply order (+ -pN)
    patches/MANIFEST.tsv   every applied patch, kept or skipped, with sha256
    patches/SOURCE         which SRPM this series was generated from
    patches/README.md      the human-readable record (CVE list, skip reasons)
    patches/*.patch        the kept patch files, verbatim

Determinism is the whole point: the same SRPM always produces byte-identical
output (no wall-clock anywhere), so refreshing to a newer release is just:

    ./tools/import-cloudlinux-patches.py ea-php53-...-<newer>.src.rpm
    git diff patches/          # <-- exactly the new/changed/removed fixes

Usage:
    ./tools/import-cloudlinux-patches.py <path-or-URL to ea-phpNN-...src.rpm>
                                         [--out patches] [--source-url BASEURL]

Licence: PHP is under the PHP License 3.01; these patches are derivatives of the
PHP source under the same terms, redistributed publicly by CloudLinux. We keep
full provenance (SRPM name + sha256 + release) in SOURCE/MANIFEST and carry no
CloudLinux branding. Not legal advice.
"""
import sys, os, re, struct, lzma, gzip, bz2, hashlib, tempfile, subprocess, shutil, argparse

DEFAULT_SOURCE_URL = "https://repo.cloudlinux.com/cloudlinux/EA4/8.1/updates/src/"

# ── SRPM payload extraction (RPM lead + 2 headers + compressed cpio) ──────────
def _header_end(buf, off):
    if buf[off:off+3] != b"\x8e\xad\xe8":
        raise SystemExit(f"bad RPM header magic at {off}: {buf[off:off+4]!r}")
    nindex = struct.unpack(">I", buf[off+8:off+12])[0]
    hsize  = struct.unpack(">I", buf[off+12:off+16])[0]
    return off + 16 + nindex*16 + hsize

def extract_srpm(path, dest):
    data = open(path, "rb").read()
    sig_end = _header_end(data, 96)          # after the 96-byte lead
    sig_end = (sig_end + 7) & ~7             # signature header padded to 8
    payload = data[_header_end(data, sig_end):]
    if   payload[:6] == b"\xfd7zXZ\x00": raw = lzma.decompress(payload)
    elif payload[:2] == b"\x1f\x8b":     raw = gzip.decompress(payload)
    elif payload[:3] == b"BZh":          raw = bz2.decompress(payload)
    else: raise SystemExit(f"unsupported payload compression: {payload[:8]!r}")
    p, n = 0, len(raw)
    while p < n:
        if raw[p:p+6] != b"070701": break            # cpio "newc"
        f = [int(raw[p+6+i*8:p+14+i*8], 16) for i in range(13)]
        mode, fsize, namesize = f[1], f[6], f[11]
        name = raw[p+110:p+110+namesize-1].decode("utf-8", "replace")
        hlen = 110 + namesize; hlen += (-hlen) % 4
        fdata = raw[p+hlen:p+hlen+fsize]
        p = p + hlen + fsize + ((-fsize) % 4)
        if name == "TRAILER!!!": break
        name = name.lstrip("./")
        if not name or (mode & 0o170000) == 0o040000:
            continue
        out = os.path.join(dest, name)
        os.makedirs(os.path.dirname(out) or dest, exist_ok=True)
        with open(out, "wb") as fh: fh.write(fdata)

# ── classification: keep source security/bug backports, drop runtime/packaging ─
# Matched against the lowercased basename. DENY (CloudLinux/LiteSpeed/EA4 runtime,
# SAPI glue, the cPanel WordPress-URL patch, asset files) wins first; then the
# security/bug backports we keep. The bug rule matches a php.net bug number
# anywhere (files are named e.g. "php-5.3.29-bug72837.patch"), with a boundary so
# it never fires on "debug"; the lve rule is boundaried the same way.
_DENY = re.compile(r"litespeed|lsapi|lsphp|cloudlinux|cagefs|jailshell"
                   r"|(?:^|[^a-z])lve(?:[^a-z]|$)|selinux|wordpress-update|\.tgz$|\.jpg$")
_CVE  = re.compile(r"cve-\d{4}-\d+")
_HARD = re.compile(r"(?:^|[^a-z])hardened-")
_BUG  = re.compile(r"(?:^|[^a-z])bug\d{3,}")

def classify(fn):
    """returns (category, keep, reason). fn is a basename."""
    low = fn.lower()
    if _DENY.search(low):
        return ("vendor/sapi", False, "CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific")
    if _CVE.search(low):  return ("CVE", True, "")
    if _HARD.search(low): return ("hardened", True, "")
    if _BUG.search(low):  return ("bug", True, "")
    return ("build/packaging", False, "build/packaging glue, not a source security/bug backport")

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""): h.update(chunk)
    return h.hexdigest()

def parse_spec(spec_path):
    """returns (decls {n:filename}, applied [(order, n, plevel)])."""
    decls, applied = {}, []
    order = 0
    for ln in open(spec_path, encoding="utf-8", errors="replace"):
        m = re.match(r"^Patch(\d+):\s*(\S+)", ln)
        if m:
            decls[int(m.group(1))] = os.path.basename(m.group(2))
            continue
        m = re.match(r"^%patch(\d+)\b(.*)", ln)
        if m:
            order += 1
            pm = re.search(r"-p\s?(\d+)", m.group(2))
            applied.append((order, int(m.group(1)), int(pm.group(1)) if pm else 1))
    return decls, applied

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("srpm", help="path or URL to an ea-phpNN-...src.rpm")
    ap.add_argument("--out", default="patches", help="output directory (default: patches)")
    ap.add_argument("--source-url", default=DEFAULT_SOURCE_URL,
                    help="base URL the SRPM is published at (recorded for provenance)")
    ap.add_argument("--include-list", default="patches-local/include",
                    help="file of patch basenames to force-keep despite classification")
    args = ap.parse_args()

    include = set()
    if os.path.exists(args.include_list):
        for ln in open(args.include_list, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                include.add(ln)

    tmp = tempfile.mkdtemp(prefix="clsrpm.")
    try:
        srpm = args.srpm
        if srpm.startswith(("http://", "https://")):
            local = os.path.join(tmp, os.path.basename(srpm.split("?")[0]))
            subprocess.run(["curl", "-fsSL", "-o", local, srpm], check=True)
            srpm = local
        srpm_name = os.path.basename(srpm)
        srpm_sha = sha256(srpm)
        rel = re.search(r"-([0-9][^-]*\.cloudlinux\.\d+)\.src\.rpm$", srpm_name)
        srpm_release = rel.group(1) if rel else "unknown"

        payload = os.path.join(tmp, "payload"); os.makedirs(payload)
        extract_srpm(srpm, payload)
        specs = [f for f in os.listdir(payload) if f.endswith(".spec")]
        if len(specs) != 1:
            raise SystemExit(f"expected exactly one .spec, found: {specs}")
        decls, applied = parse_spec(os.path.join(payload, specs[0]))

        rows = []          # (order, n, filename, plevel, category, keep, reason, sha)
        for order, n, plevel in applied:
            fn = decls.get(n)
            if not fn:
                rows.append((order, n, f"<undeclared Patch{n}>", plevel,
                             "missing", False, "no matching PatchN: declaration", ""))
                continue
            src = os.path.join(payload, fn)
            cat, keep, reason = classify(fn)
            if fn in include:
                cat, keep, reason = "forced", True, "force-kept via patches-local/include"
            sh = sha256(src) if os.path.exists(src) else ""
            if keep and not os.path.exists(src):
                keep, reason = False, "declared+applied but file absent in SRPM"
            rows.append((order, n, fn, plevel, cat, keep, reason, sh))

        out = args.out
        if os.path.isdir(out): shutil.rmtree(out)
        os.makedirs(out)
        kept = [r for r in rows if r[5]]
        for r in kept:
            shutil.copyfile(os.path.join(payload, r[2]), os.path.join(out, r[2]))

        # series — kept patches in apply order, quilt-style "file -pN"
        with open(os.path.join(out, "series"), "w") as f:
            for r in kept:
                f.write(f"{r[2]} -p{r[3]}\n")

        # MANIFEST.tsv — every applied patch, kept or skipped, auditable
        with open(os.path.join(out, "MANIFEST.tsv"), "w") as f:
            f.write("order\tpatch_no\tdecision\tcategory\tsha256\tfilename\treason\n")
            for r in rows:
                dec = "keep" if r[5] else "skip"
                f.write(f"{r[0]}\t{r[1]}\t{dec}\t{r[4]}\t{r[7]}\t{r[2]}\t{r[6]}\n")

        # SOURCE — the exact upstream this series came from
        with open(os.path.join(out, "SOURCE"), "w") as f:
            f.write(f"srpm_filename\t{srpm_name}\n")
            f.write(f"srpm_sha256\t{srpm_sha}\n")
            f.write(f"srpm_release\t{srpm_release}\n")
            f.write(f"source_url\t{args.source_url.rstrip('/')}/{srpm_name}\n")

        # README.md — human record, generated from the manifest (never hand-edited)
        cves = sorted(set(m.group(0).upper()
                          for r in kept for m in [_CVE.search(r[2].lower())] if m),
                      key=lambda c: tuple(int(x) for x in re.findall(r"\d+", c)))
        by_cat = {}
        for r in rows:
            by_cat.setdefault((r[4], r[5]), 0)
            by_cat[(r[4], r[5])] += 1
        skipped = [r for r in rows if not r[5]]
        with open(os.path.join(out, "README.md"), "w") as f:
            f.write("# CloudLinux backported security patches\n\n")
            f.write("**Generated** by `tools/import-cloudlinux-patches.py` — do not hand-edit.\n")
            f.write("Re-run the tool on a newer SRPM and review `git diff patches/`.\n\n")
            f.write("## Source\n\n")
            f.write(f"- SRPM: `{srpm_name}`\n")
            f.write(f"- release: `{srpm_release}`\n")
            f.write(f"- sha256: `{srpm_sha}`\n")
            f.write(f"- url: {args.source_url.rstrip('/')}/{srpm_name}\n\n")
            f.write("## What is kept\n\n")
            f.write(f"{len(kept)} of {len(rows)} applied patches are kept and applied by the "
                    "build (see `series`); the rest are CloudLinux/LiteSpeed/EA4 runtime or "
                    "build-packaging patches we do not use (full list + reason in `MANIFEST.tsv`).\n\n")
            f.write("| category | kept | skipped |\n|---|---|---|\n")
            cats = sorted({r[4] for r in rows})
            for c in cats:
                f.write(f"| {c} | {by_cat.get((c,True),0)} | {by_cat.get((c,False),0)} |\n")
            f.write(f"\n## CVEs covered ({len(cves)})\n\n")
            f.write(", ".join(cves) + "\n\n")
            f.write(f"## Skipped ({len(skipped)})\n\n")
            for r in sorted(skipped, key=lambda r: r[2].lower()):
                f.write(f"- `{r[2]}` — {r[6]}\n")

        print(f"source   : {srpm_name} ({srpm_release})")
        print(f"applied  : {len(rows)}   kept: {len(kept)}   skipped: {len(rows)-len(kept)}")
        print(f"CVEs     : {len(cves)}")
        print(f"written  : {out}/ (series, MANIFEST.tsv, SOURCE, README.md, {len(kept)} .patch)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
