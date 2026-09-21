#!/usr/bin/env python3
"""Build a public, licensed README corpus. Python standard library only.

Never opens Outfit's user stores or invokes its runtime/desktop entry points.
See docs/SEARCH_PACK.md for the wire format and conservative license policy.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
import concurrent.futures
from datetime import datetime, timezone
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "ctl0v0/outfit"
RELEASE_BASE = f"https://github.com/{REPOSITORY}/releases/download/"
LATEST_URL = RELEASE_BASE + "search-pack/latest.json"
CATALOG_URL = "https://plugins.omarchy.org/catalog.json"
LICENSES = frozenset({"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC"})
POLICY_VERSION = 1
MAX_CATALOG = 16 * 1024 * 1024
MAX_ASSET = 64 * 1024 * 1024
MAX_UNCOMPRESSED = 256 * 1024 * 1024
MAX_LINE = 1024 * 1024
MAX_LEGAL = 128 * 1024
VERSION_RE = r"[0-9]{8}T[0-9]{6}Z"
SHA_RE = r"[0-9a-f]{64}"
_backend = None
_backend_source_sha = ""
BUILDER_SHA = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def backend():
    """Only import definitions; runtime helpers are deliberately not called."""
    global _backend, _backend_source_sha
    if _backend is None:
        source = ROOT / "scripts/outfit.py"
        before = digest(source.read_bytes())
        spec = importlib.util.spec_from_file_location("outfit_pack_normalizer", source)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        if digest(source.read_bytes()) != before:
            raise BuildError("Normalizer changed during import; retry with stable sources")
        _backend = module
        _backend_source_sha = before
    return _backend


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode()


def encoded_catalog(snapshot):
    # One bounded listing per line keeps bootstrap updates reviewable without verbose indentation.
    return (b'{"generatedAt":' + encoded(snapshot["generatedAt"]).rstrip(b"\n") + b',"plugins":[\n' +
            b",\n".join(encoded(row).rstrip(b"\n") for row in snapshot["plugins"]) +
            b'\n],"provenance":' + encoded(snapshot["provenance"]).rstrip(b"\n") + b"}\n")


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


def atomic_write(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


class BuildError(Exception):
    pass


class RateLimited(BuildError):
    pass


class Missing(Exception):
    pass


class Unavailable(Exception):
    pass


class AssetRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlsplit(newurl)
        if (parts.scheme != "https" or parts.hostname not in {
                "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}
                or parts.port not in (None, 443) or parts.username or parts.password):
            raise BuildError("Unapproved release redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise Unavailable("Source redirected; catalog identity needs review")


class PublicClient:
    def __init__(self, token=""):
        self.token = token
        self.requests = 0
        self.remaining = None
        self.graphql_remaining = None
        self.preloaded = {}

    def get(self, url, maximum, *, release=False, payload=None):
        parts = urllib.parse.urlsplit(url)
        if (parts.scheme != "https" or parts.port not in (None, 443) or parts.username or parts.password
                or parts.hostname not in {"api.github.com", "plugins.omarchy.org", "github.com", "raw.githubusercontent.com"}
                or (parts.hostname == "github.com" and (not release or not url.startswith(RELEASE_BASE)))):
            raise BuildError("Unapproved public source URL")
        headers = {"User-Agent": "Outfit-public-search-pack/1", "Accept": "application/vnd.github+json"}
        if parts.hostname == "api.github.com":
            remaining = self.graphql_remaining if parts.path == "/graphql" else self.remaining
            if remaining is not None and remaining < 20:
                raise RateLimited("GitHub API budget below 20 requests; resume public state after reset.")
            headers["X-GitHub-Api-Version"] = "2022-11-28"
            if self.token:
                headers["Authorization"] = "Bearer " + self.token
        if payload is not None:
            headers["Content-Type"] = "application/json"
        opener = urllib.request.build_opener(AssetRedirect() if release else NoRedirect())
        for attempt in range(3):
            self.requests += 1
            try:
                with opener.open(urllib.request.Request(url, data=payload, headers=headers), timeout=45) as response:
                    remaining = response.headers.get("X-RateLimit-Remaining")
                    if remaining and remaining.isdigit():
                        if parts.path == "/graphql":
                            self.graphql_remaining = int(remaining)
                        else:
                            self.remaining = int(remaining)
                    data = response.read(maximum + 1)
                    if len(data) > maximum:
                        raise Unavailable("Source exceeds size bound")
                    return data
            except urllib.error.HTTPError as error:
                status = error.code
                reset = error.headers.get("X-RateLimit-Reset", "unknown")
                error.close()
                if status in {403, 429}:
                    raise RateLimited(f"GitHub denied/rate-limited request (HTTP {status}); reset epoch {reset}. Resume public state later.") from None
                if status in {404, 410, 451}:
                    raise Missing() from None
                if status >= 500 and attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise Unavailable(f"Source HTTP {status}") from None
            except (TimeoutError, OSError, urllib.error.URLError):
                if attempt < 2:
                    time.sleep(2 ** attempt)
                    continue
                raise Unavailable("Public source network failure") from None

    def api(self, route):
        if route in self.preloaded:
            result = self.preloaded[route]
            if result is None:
                raise Missing()
            return result
        try:
            return json.loads(self.get("https://api.github.com" + route, 2 * 1024 * 1024))
        except (ValueError, UnicodeError):
            raise Unavailable("Invalid GitHub JSON") from None

    def graphql(self, query):
        value = json.loads(self.get("https://api.github.com/graphql", 8 * 1024 * 1024,
                                    payload=encoded({"query": "query { " + query + " }"})))
        errors = value.get("errors", [])
        if any(error.get("type") != "NOT_FOUND" for error in errors):
            raise BuildError("GitHub public metadata batch failed; no source content accepted")
        if not isinstance(value.get("data"), dict):
            raise BuildError("GitHub public metadata batch is missing")
        return value["data"]

    def preflight(self, items):
        """Batch public visibility first, then pinned root metadata; no private file queries.

        SPDX detection still comes from each pinned REST license response. Batching
        metadata and using public raw text avoids spending four REST requests per repo.
        """
        if not self.token:
            return  # REST-only mode remains useful for small anonymous smoke builds.
        for start in range(0, len(items), 25):
            batch = items[start:start + 25]
            queries = []
            for i, item in enumerate(batch):
                owner, name, _ = backend().github_repo(item["repo"])
                queries.append(f'r{i}: repository(owner:{json.dumps(owner)},name:{json.dumps(name)}) '
                               '{ nameWithOwner isPrivate visibility }')
            metadata = self.graphql(" ".join(queries))
            public = []
            for i, item in enumerate(batch):
                owner, name, _ = backend().github_repo(item["repo"])
                route = f"/repos/{owner}/{name}"
                value = metadata.get(f"r{i}")
                self.preloaded[route] = None if value is None else {
                    "private": value.get("isPrivate"), "visibility": value.get("visibility", "").lower(),
                    "full_name": value.get("nameWithOwner", "")}
                if (value and value.get("isPrivate") is False and value.get("visibility") == "PUBLIC"
                        and value.get("nameWithOwner", "").lower() == f"{owner}/{name}".lower()):
                    public.append((i, item, owner, name, route))
            queries = [f'r{i}: repository(owner:{json.dumps(owner)},name:{json.dumps(name)}) '
                       '{ object(expression:' + json.dumps(item["listingCommit"] + ":") + ') '
                       '{ ... on Tree { entries { name type oid mode } } } }'
                       for i, item, owner, name, route in public]
            trees = self.graphql(" ".join(queries)) if queries else {}
            for i, item, _, _, route in public:
                tree = (trees.get(f"r{i}") or {}).get("object")
                entries = tree.get("entries") if isinstance(tree, dict) else None
                self.preloaded[route + "/contents/?ref=" + item["listingCommit"]] = None if entries is None else [
                    {"name": entry["name"], "sha": entry["oid"],
                     "type": "file" if entry.get("type") == "blob" and entry.get("mode") in {33188, 33261} else "other"}
                    for entry in entries]

    def file(self, route, path, commit, expected_sha, maximum):
        repo = route.removeprefix("/repos/")
        raw = self.get(f"https://raw.githubusercontent.com/{repo}/{commit}/" + urllib.parse.quote(path, safe=""), maximum)
        return {"type": "file", "path": path, "encoding": "base64", "size": len(raw), "sha": expected_sha,
                "content": base64.b64encode(raw).decode("ascii")}


def catalog_snapshot(raw, fetched_at):
    """Round-trip only bounded public listing fields, in the official raw shape."""
    runtime = backend()
    rows, generated = runtime.normalize_catalog(json.loads(raw))
    fields = ("id", "name", "description", "author", "version", "category", "tags", "kind", "kinds",
              "status", "repo", "installNote", "verificationCommit", "verificationStatus",
              "verificationSnapshotStatus", "verificationCoverage", "verificationMethod", "repositoryLayout",
              "installAvailable", "stars", "listedAt", "versionUpdatedAt", "repositoryUpdatedAt",
              "previewThumbnail", "previewImage", "previewThumbnailWidth", "previewThumbnailHeight",
              "previewWidth", "previewHeight")
    plugins = []
    for row in rows:
        item = {key: row[key] for key in fields if row.get(key) not in (None, "", [], False)}
        item.update(sourceType="community", listingValidatedCommit=row["listingCommit"])
        plugins.append(item)
    snapshot = {"generatedAt": generated, "plugins": plugins,
                "provenance": {"url": CATALOG_URL, "fetchedAt": fetched_at, "sha256": digest(raw)}}
    if len(encoded(snapshot)) > MAX_CATALOG:
        raise BuildError("Bootstrap catalog exceeds bound")
    runtime.normalize_catalog(snapshot)
    return snapshot


def content_file(value, maximum):
    if (not isinstance(value, dict) or value.get("type") != "file" or value.get("encoding") != "base64"
            or not isinstance(value.get("content"), str) or value.get("size", maximum + 1) > maximum):
        raise Unavailable("Source is not a bounded ordinary text file")
    try:
        raw = base64.b64decode(re.sub(r"\s", "", value["content"]), validate=True)
        if len(raw) > maximum or len(raw) != value.get("size"):
            raise ValueError()
        text = raw.decode("utf-8-sig")
        if any(ord(c) < 32 and c not in "\n\r\t" for c in text):
            raise ValueError()
        # Verify the exact Git blob returned by GitHub, as well as our SHA-256 provenance.
        if hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() != value.get("sha"):
            raise ValueError()
        return raw, text
    except (ValueError, UnicodeError):
        raise Unavailable("Invalid source text/blob digest") from None


def initial_record(item):
    return {"key": backend().readme_key(item), "repo": item["repo"], "commit": item["listingCommit"],
            "path": "", "body": "", "state": "excluded", "version": backend().SEARCH_INDEX_VERSION,
            "truncated": False, "license": "", "sourceSha256": "", "reason": ""}


def collect_record(client, item):
    record = initial_record(item)
    repo = backend().github_repo(item["repo"])
    route = f"/repos/{repo[0]}/{repo[1]}"
    ref = "?ref=" + item["listingCommit"]
    try:
        metadata = client.api(route)
        if (metadata.get("private") is not False or metadata.get("visibility") != "public"
                or metadata.get("full_name", "").lower() != f"{repo[0]}/{repo[1]}".lower()):
            record["reason"] = "not-public"
            return record
        try:
            license_info = client.api(route + "/license" + ref)
        except Missing:
            record["reason"] = "license-missing"
            return record
        spdx = (license_info.get("license") or {}).get("spdx_id", "")
        record["license"] = spdx if isinstance(spdx, str) and len(spdx) <= 100 else ""
        if spdx not in LICENSES:
            record["reason"] = "license-unsupported-or-unknown"
            return record
        license_path = license_info.get("path", "")
        if not re.fullmatch(r"(?i)(?:licen[sc]e|copying)(?:[._-][a-z0-9.-]+)?", license_path):
            record["reason"] = "license-scope-unsupported"
            return record
        license_raw, license_text = content_file(license_info, MAX_LEGAL)
        if not license_text.strip():
            record["reason"] = "license-empty"
            return record
        # Inspect root once: no recursive tree, executable fetch, or content guessing.
        entries = client.api(route + "/contents/" + ref)
        if not isinstance(entries, list) or len(entries) >= 1000:
            raise Unavailable("Root directory is unavailable or truncated")
        names = {entry.get("name"): entry for entry in entries if isinstance(entry, dict)}
        if (license_path not in names or names[license_path].get("type") != "file"
                or names[license_path].get("sha") != license_info.get("sha")):
            raise Unavailable("License evidence does not match pinned root tree")
        # A second license can alter the grant; leave ambiguous/multi-license trees to review.
        other_licenses = [name for name in names if isinstance(name, str) and
                          re.match(r"(?i)^(?:licen[sc]e|copying)(?:[._-]|$)", name) and name != license_path]
        if other_licenses:
            record["reason"] = "multiple-license-files"
            return record
        notices = []
        for name in sorted(names):
            if re.match(r"(?i)^(?:notice|authors|copyright)(?:[._-]|$)", name):
                if names[name].get("type") != "file":
                    raise Unavailable("Legal notice is not an ordinary file")
                value = client.file(route, name, item["listingCommit"], names[name].get("sha"), MAX_LEGAL)
                notice_raw, text = content_file(value, MAX_LEGAL)
                notices.append({"path": name, "text": text, "sha256": digest(notice_raw)})
        if sum(len(n["text"].encode()) for n in notices) + len(license_raw) > 512 * 1024:
            raise Unavailable("Legal notices exceed combined bound")
        path = next((name for name in ("README.md", "readme.md", "README.MD", "README.rst", "README")
                     if name in names and names[name].get("type") == "file"), "")
        if not path:
            record.update(state="unavailable", reason="root-readme-missing")
            return record
        value = client.file(route, path, item["listingCommit"], names[path].get("sha"), backend().MAX_README_BYTES)
        raw, text = content_file(value, backend().MAX_README_BYTES)
        if value.get("sha") != names[path].get("sha"):
            raise Unavailable("README does not match pinned root tree")
        # Separate documentation grants require human scope review, even with a permissive root license.
        if re.search(r"(?is)(?:readme|documentation|this document).{0,100}(?:licensed under|license is|copyright|all rights reserved)", text):
            record["reason"] = "documentation-license-review"
            return record
        content = backend().markdown_content(text)
        body = backend().normalized(content)[:24_000]
        if not body:
            record.update(state="unavailable", reason="readme-empty")
            return record
        record.update(path=path, body=body, state="indexed", reason="licensed", license=spdx,
                      sourceSha256=digest(raw), truncated=len(content) >= 24_000 or len(backend().normalized(content)) > 24_000,
                      sourceLicenseText=license_text, sourceLicensePath=license_path,
                      sourceLicenseSha256=digest(license_raw), sourceNotices=notices,
                      licenseEvidenceUrl="https://api.github.com" + route + "/license" + ref,
                      modifications="README converted to normalized plain search text; may be truncated.")
    except Missing:
        record.update(state="unavailable", reason="source-missing")
    except Unavailable:
        record.update(state="unavailable", reason="source-unavailable")
    return record


def validate_record(record):
    runtime = backend()
    if not isinstance(record, dict):
        raise BuildError("Record must be an object")
    expected = runtime.readme_key({"repo": record.get("repo"), "listingCommit": record.get("commit")})
    if not expected or record.get("key") != expected:
        raise BuildError("Record identity mismatch")
    if type(record.get("version")) is not int or record["version"] != runtime.SEARCH_INDEX_VERSION:
        raise BuildError("Record data version mismatch")
    body = record.get("body")
    if (not isinstance(body, str) or len(body) > 24_000 or runtime.normalized(body) != body
            or type(record.get("truncated")) is not bool or not isinstance(record.get("reason"), str)
            or not isinstance(record.get("path"), str) or not isinstance(record.get("license"), str)):
        raise BuildError("Invalid record fields")
    if record.get("state") == "indexed":
        if (not body or record.get("license") not in LICENSES
                or not re.fullmatch(SHA_RE, record.get("sourceSha256", ""))
                or not record.get("sourceLicenseText") or not record.get("sourceLicensePath")
                or not re.fullmatch(SHA_RE, record.get("sourceLicenseSha256", ""))
                or not isinstance(record.get("sourceNotices"), list)):
            raise BuildError("Indexed record lacks license/source provenance")
        if (record["path"] not in {"README.md", "readme.md", "README.MD", "README.rst", "README"}
                or not isinstance(record["sourceLicenseText"], str)
                or len(record["sourceLicenseText"].encode()) > MAX_LEGAL
                or not re.fullmatch(r"(?i)(?:licen[sc]e|copying)(?:[._-][a-z0-9.-]+)?", record["sourceLicensePath"])):
            raise BuildError("Invalid legal provenance")
        for notice in record["sourceNotices"]:
            if (not isinstance(notice, dict) or not isinstance(notice.get("text"), str)
                    or len(notice["text"].encode()) > MAX_LEGAL or not isinstance(notice.get("path"), str)
                    or "/" in notice["path"] or not re.fullmatch(SHA_RE, notice.get("sha256", ""))):
                raise BuildError("Invalid preserved notice")
    elif record.get("state") not in {"unavailable", "excluded"} or body or record.get("sourceSha256"):
        raise BuildError("Invalid empty record")
    if len(encoded(record)) > MAX_LINE:
        raise BuildError("Record exceeds line bound")


def policy_fingerprint():
    # Any builder/normalizer change rechecks license evidence rather than inheriting stale policy.
    backend()
    return digest((str(POLICY_VERSION) + BUILDER_SHA + _backend_source_sha).encode())


def validate_pack(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "latest.json").read_bytes())
    version = manifest.get("version", "")
    if (manifest.get("schemaVersion") != 1 or manifest.get("format") != "jsonl-gzip"
            or manifest.get("dataVersion") != backend().SEARCH_INDEX_VERSION
            or not re.fullmatch(VERSION_RE, version)):
        raise BuildError("Invalid manifest schema/version")
    name = f"search-pack-{version}.jsonl.gz"
    if manifest.get("assetUrl") != RELEASE_BASE + f"search-pack-{version}/{name}":
        raise BuildError("Asset must be the immutable own-repository release URL")
    asset = (directory / name).read_bytes()
    if (len(asset) > MAX_ASSET or len(asset) != manifest.get("compressedBytes")
            or digest(asset) != manifest.get("sha256")):
        raise BuildError("Compressed asset digest/length mismatch")
    records = []
    total = 0
    keys = set()
    with gzip.GzipFile(fileobj=io.BytesIO(asset)) as stream:
        while line := stream.readline(MAX_LINE + 1):
            total += len(line)
            if len(line) > MAX_LINE or total > MAX_UNCOMPRESSED or not line.endswith(b"\n"):
                raise BuildError("Uncompressed corpus exceeds bounds")
            row = json.loads(line)
            validate_record(row)
            if row["key"] in keys:
                raise BuildError("Duplicate record key")
            keys.add(row["key"])
            records.append(row)
            if len(records) > backend().MAX_CATALOG_ROWS:
                raise BuildError("Too many records")
    if total != manifest.get("uncompressedBytes") or len(records) != manifest.get("docCount"):
        raise BuildError("Uncompressed count/length mismatch")
    states = dict(Counter(row["state"] for row in records))
    reasons = dict(Counter(row["reason"] for row in records))
    if states != manifest.get("stateCounts") or reasons != manifest.get("reasonCounts"):
        raise BuildError("Coverage counters mismatch")
    provenance = manifest.get("provenance", {})
    if (provenance.get("sourceRepository") != "https://github.com/" + REPOSITORY
            or not re.fullmatch(r"[0-9a-f]{40}", provenance.get("sourceCommit", ""))
            or provenance.get("catalogUrl") != CATALOG_URL
            or provenance.get("licensePolicyVersion") != POLICY_VERSION
            or type(provenance.get("sourceDirty")) is not bool
            or any(not re.fullmatch(SHA_RE, provenance.get(field, "")) for field in (
                "builderSha256", "normalizerSha256", "catalogSha256", "catalogSnapshotSha256", "policyFingerprint"))):
        raise BuildError("Manifest lacks source/catalog provenance")
    for field in ("generatedAt", "catalogGeneratedAt"):
        if not isinstance(manifest.get(field), str) or not manifest[field].endswith("Z"):
            raise BuildError("Invalid manifest timestamp")
        datetime.fromisoformat(manifest[field].replace("Z", "+00:00"))
    if datetime.fromisoformat(manifest["generatedAt"].replace("Z", "+00:00")).strftime("%Y%m%dT%H%M%SZ") != version:
        raise BuildError("Version is not the build timestamp")
    if (directory / "catalog.json").exists():
        snapshot = (directory / "catalog.json").read_bytes()
        if len(snapshot) > MAX_CATALOG or digest(snapshot) != provenance["catalogSnapshotSha256"]:
            raise BuildError("Catalog snapshot digest mismatch")
        items, generated = backend().normalize_catalog(json.loads(snapshot))
        candidate_keys = {backend().readme_key(item) for item in items if backend().readme_key(item)}
        if (not keys <= candidate_keys or manifest.get("candidateCount") != len(candidate_keys)
                or manifest.get("catalogCount") != len(items) or generated != manifest["catalogGeneratedAt"]
                or (manifest.get("complete") is True and keys != candidate_keys)):
            raise BuildError("Pack is incoherent with catalog snapshot")
    return manifest, records


def check_coverage(records, candidate_count, previous=None, *, minimum=0.1, complete=True):
    indexed = sum(row["state"] == "indexed" for row in records)
    unavailable = sum(row["state"] == "unavailable" for row in records)
    if not records or not indexed:
        raise BuildError("Refusing empty indexed corpus")
    if not complete or len(records) != candidate_count:
        raise BuildError("Partial/test build is not publishable")
    if indexed / candidate_count < minimum:
        raise BuildError("Indexed coverage below minimum")
    if unavailable / candidate_count > 0.2:
        raise BuildError("More than 20% of sources unavailable")
    if previous:
        old_count = previous["docCount"]
        old_indexed = previous["stateCounts"].get("indexed", 0)
        if (candidate_count < old_count * 0.8 or indexed < old_indexed * 0.8
                or indexed / candidate_count < (old_indexed / max(1, old_count)) * 0.8):
            raise BuildError("Coverage collapsed by more than 20% versus current public pack")


def previous_pack(client, directory):
    try:
        data = client.get(LATEST_URL, MAX_LINE, release=True)
    except Missing:
        return None, []
    manifest = json.loads(data)
    version = manifest.get("version", "")
    name = f"search-pack-{version}.jsonl.gz"
    if (not re.fullmatch(VERSION_RE, version)
            or manifest.get("assetUrl") != RELEASE_BASE + f"search-pack-{version}/{name}"):
        raise BuildError("Untrusted previous pack URL")
    directory.mkdir(parents=True, exist_ok=True)
    atomic_write(directory / name, client.get(manifest["assetUrl"], MAX_ASSET, release=True))
    atomic_write(directory / "latest.json", data)
    return validate_pack(directory)


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True, check=False)
    if result.returncode:
        raise BuildError("GitHub publication command failed; existing release data retained")
    return result.stdout


def rename_asset(asset_id, name):
    gh("api", "--method", "PATCH", f"repos/{REPOSITORY}/releases/assets/{asset_id}", "-f", "name=" + name)


def promote_manifest(old, staged, version):
    """GitHub has no atomic replace; preserve the old asset and roll back rename failures."""
    backup = f"previous-before-{version}.json"
    try:
        if old:
            rename_asset(old["id"], backup)
        rename_asset(staged["id"], "latest.json")
    except BuildError:
        # Handle ambiguous responses (e.g. a successful PATCH with a lost response).
        release = json.loads(gh("api", f"repos/{REPOSITORY}/releases/tags/search-pack"))
        latest = next((a for a in release["assets"] if a["name"] == "latest.json"), None)
        if latest and latest["id"] == staged["id"]:
            return
        if old and latest is None:
            for attempt in range(3):
                try:
                    rename_asset(old["id"], "latest.json")
                    break
                except BuildError:
                    if attempt == 2:
                        raise BuildError(f"Promotion rollback needs retry: preserved old manifest asset {old['id']} is named {backup}") from None
                    time.sleep(2 ** attempt)
        raise


def publish(directory):
    """Explicit publisher, used only by the contents:write workflow job."""
    directory = Path(directory).resolve()
    manifest, records = validate_pack(directory)
    if (manifest.get("publishable") is not True or manifest["provenance"]["sourceDirty"]
            or manifest["provenance"]["policyFingerprint"] != policy_fingerprint()
            or not (directory / "catalog.json").is_file()):
        raise BuildError("Publication requires a coherent pack from these committed sources")
    client = PublicClient(os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""))
    previous, _ = previous_pack(client, directory / "promotion-baseline")
    check_coverage(records, manifest["candidateCount"], previous, complete=manifest.get("complete") is True)
    version = manifest["version"]
    tag = "search-pack-" + version
    name = tag + ".jsonl.gz"
    # No --clobber on immutable releases. A retry verifies any already-created release byte-for-byte.
    try:
        existing = client.api(f"/repos/{REPOSITORY}/releases/tags/{tag}")
    except Missing:
        existing = None
    if existing is None:
        gh("release", "create", tag, str(directory / name), str(directory / "latest.json"),
           str(directory / "catalog.json"), "--repo", REPOSITORY, "--target", manifest["provenance"]["sourceCommit"],
           "--title", "Public README search pack " + version, "--latest=false", "--notes",
           "Public pinned README search text and catalog. Each indexed record preserves its source license and notices. "
           "License policy and schema: docs/SEARCH_PACK.md. Source commit: " + manifest["provenance"]["sourceCommit"])
    # Verify the actual public bytes, not just upload command exit status, before alias mutation.
    if client.get(manifest["assetUrl"], MAX_ASSET, release=True) != (directory / name).read_bytes():
        raise BuildError("Published immutable asset does not match validated pack")
    for filename in ("latest.json", "catalog.json"):
        if client.get(RELEASE_BASE + tag + "/" + filename, MAX_CATALOG, release=True) != (directory / filename).read_bytes():
            raise BuildError("Published immutable provenance does not match validated pack")
    try:
        client.api(f"/repos/{REPOSITORY}/releases/tags/search-pack")
    except Missing:
        gh("release", "create", "search-pack", "--repo", REPOSITORY, "--target", manifest["provenance"]["sourceCommit"],
           "--title", "Current public README search pack", "--latest=false", "--notes",
           "latest.json points to a validated immutable search-pack release. Previous manifests are retained for recovery.")
    staged_name = f"candidate-{version}.json"
    staged_path = directory / staged_name
    atomic_write(staged_path, (directory / "latest.json").read_bytes())
    gh("release", "upload", "search-pack", str(staged_path), "--repo", REPOSITORY)
    if client.get(RELEASE_BASE + "search-pack/" + staged_name, MAX_LINE, release=True) != staged_path.read_bytes():
        raise BuildError("Staged manifest upload verification failed")
    release = json.loads(gh("api", f"repos/{REPOSITORY}/releases/tags/search-pack"))
    old = next((a for a in release["assets"] if a["name"] == "latest.json"), None)
    staged = next(a for a in release["assets"] if a["name"] == staged_name)
    promote_manifest(old, staged, version)
    print(json.dumps({"published": True, "manifestUrl": LATEST_URL, "version": version}))


def build(args):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
    if args.use_gh_auth and not token:
        result = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=False)
        if result.returncode:
            raise BuildError("gh authentication unavailable")
        token = result.stdout.strip()
    client = PublicClient(token)
    now = utc_now()
    if args.catalog:
        raw_snapshot = Path(args.catalog).read_bytes()
        if len(raw_snapshot) > MAX_CATALOG:
            raise BuildError("Catalog exceeds bound")
        snapshot = json.loads(raw_snapshot)
        backend().normalize_catalog(snapshot)
    else:
        snapshot = catalog_snapshot(client.get(CATALOG_URL, MAX_CATALOG), iso(now))
    snapshot_bytes = encoded_catalog(snapshot)
    if args.write_catalog:
        atomic_write(Path(args.write_catalog), snapshot_bytes)
    if args.catalog_only:
        items, _ = backend().normalize_catalog(snapshot)
        print(json.dumps({"catalogRows": len(snapshot["plugins"]), "catalogGeneratedAt": snapshot["generatedAt"],
                          "pinnedKeys": len({backend().readme_key(item) for item in items if backend().readme_key(item)}),
                          "repositories": len({item["repo"].lower() for item in items}),
                          "bytes": len(snapshot_bytes), "sha256": digest(snapshot_bytes)}))
        return
    if not args.output:
        raise BuildError("--output is required")
    output = Path(args.output).resolve()
    if output.is_relative_to(ROOT):
        raise BuildError("Build artifacts must live outside the source worktree")
    output.mkdir(parents=True, exist_ok=True)
    if (output / "latest.json").exists():
        raise BuildError("Output already contains a pack; choose a new output directory")
    fingerprint = policy_fingerprint()
    previous, previous_rows = (None, [])
    if args.previous_public:
        previous, previous_rows = previous_pack(client, output / "previous")
    prior = {row["key"]: row for row in previous_rows if row["state"] != "unavailable"} if (
        previous and previous.get("provenance", {}).get("policyFingerprint") == fingerprint) else {}
    state_dir = Path(args.state_dir).resolve() if args.state_dir else None
    if state_dir:
        if state_dir.is_relative_to(ROOT):
            raise BuildError("Public resume state must live outside the source worktree")
        state_dir.mkdir(parents=True, exist_ok=True)
    items, generated = backend().normalize_catalog(snapshot)
    candidates = {backend().readme_key(item): item for item in items if backend().readme_key(item)}
    selected = list(sorted(candidates.items()))[:args.max_documents or None]
    if state_dir:
        for key, _ in selected:
            state_path = state_dir / f"{key}.json"
            if key in prior or not state_path.exists():
                continue
            if state_path.stat().st_size > MAX_LINE + 256:
                raise BuildError("Public state record exceeds bound")
            cached = json.loads(state_path.read_bytes())
            if cached.get("policyFingerprint") == fingerprint:
                row = cached["record"]
                validate_record(row)
                if row["key"] != key:
                    raise BuildError("Public state identity mismatch")
                prior[key] = row
    client.preflight([item for key, item in selected if key not in prior])

    def resolve(pair):
        key, item = pair
        row = prior.get(key)
        state_path = state_dir / f"{key}.json" if state_dir else None
        if row is None:
            row = collect_record(client, item)
        validate_record(row)
        if state_path and row["state"] != "unavailable":
            atomic_write(state_path, encoded({"policyFingerprint": fingerprint, "record": row}))
        return row

    records = []
    halted = ""
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=args.workers)
    futures = {executor.submit(resolve, pair): pair[0] for pair in selected}
    try:
        for future in concurrent.futures.as_completed(futures):
            try:
                records.append(future.result())
            except RateLimited as error:
                halted = str(error)
                for pending in futures:
                    pending.cancel()
            except concurrent.futures.CancelledError:
                continue
            if records and len(records) % 100 == 0 and not halted:
                print(json.dumps({"processed": len(records), "candidates": len(candidates),
                                  "states": dict(Counter(r["state"] for r in records)),
                                  "requests": client.requests, "apiRemaining": client.remaining}), flush=True)
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    records.sort(key=lambda row: row["key"])
    complete = not halted and len(records) == len(candidates) and args.max_documents is None
    version = now.strftime("%Y%m%dT%H%M%SZ")
    name = f"search-pack-{version}.jsonl.gz"
    raw = b"".join(encoded(row) for row in records)
    if len(raw) > MAX_UNCOMPRESSED:
        raise BuildError("Corpus exceeds uncompressed limit")
    asset = gzip.compress(raw, compresslevel=9, mtime=0)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--", "scripts/build_search_pack.py",
                 "scripts/outfit.py", ".github/workflows/search-pack.yml", "data/bootstrap-catalog.json"], cwd=ROOT))
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise BuildError("Builder source commit unavailable")
    provenance = snapshot.get("provenance", {})
    if provenance.get("url") != CATALOG_URL or not re.fullmatch(SHA_RE, provenance.get("sha256", "")):
        raise BuildError("Catalog must carry original public-source provenance")
    manifest = {"schemaVersion": 1, "format": "jsonl-gzip", "dataVersion": backend().SEARCH_INDEX_VERSION,
                "version": version, "generatedAt": iso(now), "catalogGeneratedAt": generated,
                "docCount": len(records), "compressedBytes": len(asset), "uncompressedBytes": len(raw),
                "sha256": digest(asset), "assetUrl": RELEASE_BASE + f"search-pack-{version}/{name}",
                "complete": complete, "catalogCount": len(items), "candidateCount": len(candidates),
                "unpinnedCount": sum(not backend().readme_key(item) for item in items),
                "stateCounts": dict(Counter(row["state"] for row in records)),
                "reasonCounts": dict(Counter(row["reason"] for row in records)),
                "requests": client.requests, "apiRemaining": client.remaining,
                "provenance": {"sourceRepository": "https://github.com/" + REPOSITORY, "sourceCommit": commit,
                               "sourceDirty": dirty, "builderSha256": BUILDER_SHA,
                               "normalizerSha256": _backend_source_sha,
                               "catalogUrl": CATALOG_URL, "catalogSha256": provenance["sha256"],
                               "catalogSnapshotSha256": digest(snapshot_bytes),
                               "catalogFetchedAt": provenance["fetchedAt"], "licensePolicyVersion": POLICY_VERSION,
                               "policyFingerprint": fingerprint}}
    try:
        check_coverage(records, len(candidates), previous, minimum=args.min_coverage, complete=complete)
        manifest["publishable"] = True
    except BuildError as error:
        manifest.update(publishable=False, publicationBlocked=str(error))
    if halted:
        manifest.update(publishable=False, publicationBlocked=halted)
    atomic_write(output / name, asset)
    atomic_write(output / "catalog.json", snapshot_bytes)
    atomic_write(output / "latest.json", encoded(manifest))
    validate_pack(output)
    print(json.dumps(manifest, indent=2))
    if not manifest["publishable"] and not args.max_documents:
        raise BuildError(manifest["publicationBlocked"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New external artifact directory")
    parser.add_argument("--state-dir", help="Explicit public-only resumable state directory (never a user cache)")
    parser.add_argument("--catalog", help="Use a previously fetched bootstrap catalog")
    parser.add_argument("--write-catalog", help="Write minimal official-format JSON snapshot")
    parser.add_argument("--catalog-only", action="store_true")
    parser.add_argument("--previous-public", action="store_true", help="Validate/reuse the own-repository public pack")
    parser.add_argument("--use-gh-auth", action="store_true", help="Read gh's token in memory; never print or persist it")
    parser.add_argument("--max-documents", type=int, help="Test-only partial corpus; never publishable")
    parser.add_argument("--min-coverage", type=float, default=0.1)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--validate", metavar="DIRECTORY", help="Validate a generated pack without fetching sources")
    parser.add_argument("--require-publishable", action="store_true")
    parser.add_argument("--publish", metavar="DIRECTORY", help="Explicitly publish a validated committed-source pack (writes GitHub releases)")
    args = parser.parse_args()
    if args.max_documents is not None and args.max_documents < 1:
        parser.error("--max-documents must be positive")
    if not 0.1 <= args.min_coverage <= 1:
        parser.error("--min-coverage must be between 0.1 and 1")
    if not 1 <= args.workers <= 8:
        parser.error("--workers must be between 1 and 8")
    try:
        if args.publish:
            publish(args.publish)
        elif args.validate:
            manifest, records = validate_pack(args.validate)
            if args.require_publishable:
                check_coverage(records, manifest["candidateCount"], minimum=args.min_coverage,
                               complete=manifest.get("complete") is True)
                if manifest.get("publishable") is not True or manifest["provenance"].get("sourceDirty"):
                    raise BuildError("Pack is blocked or built from uncommitted sources")
            print(json.dumps({"valid": True, "docCount": len(records), "version": manifest["version"]}))
        else:
            build(args)
    except (BuildError, Unavailable, Missing, ValueError, OSError, KeyError) as error:
        print(f"Search pack build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
