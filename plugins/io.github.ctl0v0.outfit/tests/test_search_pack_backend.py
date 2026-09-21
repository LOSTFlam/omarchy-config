"""Offline startup/seed-import contract tests; never access a personal cache."""
import gzip
import fcntl
from collections import Counter
from datetime import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.request

from tests.test_outfit import OUTFIT as app, ROOT


def builder_module():
    spec = importlib.util.spec_from_file_location("search_pack_builder_contract", ROOT / "scripts/build_search_pack.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SearchPackBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = app.Store(Path(self.temp.name) / "cache")
        self.prefs = app.Store(Path(self.temp.name) / "config")
        self.addCleanup(self.store.close)
        self.addCleanup(self.prefs.close)
        self.raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]
        self.items, self.generated = app.normalize_catalog(self.raw)
        app.save_catalog(self.store, self.items, self.generated, 100)
        self.now = 1800000000
        self.network = mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("Unexpected network"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def record(self, item=None, **changes):
        item = item or self.items[0]
        record = json.loads((ROOT / "tests/fixtures/search-pack-record.json").read_text())
        record.update(key=app.readme_key(item), repo=item["repo"], commit=item["listingCommit"],
                      licenseEvidenceUrl=f"https://api.github.com/repos/{item['owner']}/{item['repoName']}/license?ref={item['listingCommit']}")
        if changes.get("state") in ("excluded", "unavailable"):
            record = {key: record[key] for key in ("key", "repo", "commit", "version", "truncated")}
            record.update(path="", body="", license="", sourceSha256="", reason="license-unsupported-or-unknown")
        record.update(changes)
        return record

    def pack(self, records=None, **changes):
        records = [self.record()] if records is None else records
        expanded = b"".join(json.dumps(record).encode() + b"\n" for record in records)
        packed = gzip.compress(expanded, mtime=0)
        generated = changes.get("generatedAt", "2026-09-18T00:00:00Z")
        version = (datetime.fromisoformat(generated.replace("Z", "+00:00")).strftime("%Y%m%dT%H%M%SZ")
                   if app.listing_date(generated) else "20260918T000000Z")
        manifest = {"schemaVersion": 1, "version": version, "dataVersion": app.SEARCH_INDEX_VERSION, "format": "jsonl-gzip",
                    "generatedAt": "2026-09-18T00:00:00Z", "catalogGeneratedAt": "2026-09-17T00:00:00Z",
                    "docCount": len(records), "compressedBytes": len(packed),
                    "uncompressedBytes": len(expanded), "sha256": hashlib.sha256(packed).hexdigest(),
                    "assetUrl": f"https://github.com/ctl0v0/outfit/releases/download/search-pack-{version}/search-pack-{version}.jsonl.gz",
                    "complete": True, "publishable": True, "candidateCount": len(records), "catalogCount": len(records),
                    "unpinnedCount": 0,
                    "provenance": {"sourceRepository": "https://github.com/ctl0v0/outfit", "sourceCommit": "f" * 40,
                                   "sourceDirty": False, "catalogUrl": app.CATALOG_URL,
                                   "catalogFetchedAt": "2026-09-17T00:01:00Z", "licensePolicyVersion": 1,
                                   **{field: "a" * 64 for field in ("builderSha256", "normalizerSha256", "catalogSha256",
                                                                   "catalogSnapshotSha256", "policyFingerprint")}},
                    **changes}
        for field, record_field in (("stateCounts", "state"), ("reasonCounts", "reason")):
            if all(isinstance(record.get(record_field), str) for record in records):
                manifest.setdefault(field, dict(Counter(record[record_field] for record in records)))
        return manifest, packed

    def prepare(self, records=None, changes=None, progress=None):
        manifest, packed = self.pack(records, **(changes or {}))
        with mock.patch.object(app, "fetch_search_pack", side_effect=[json.dumps(manifest).encode(), packed]) as fetch:
            result = app.run({"action": "prepare-search", "generation": 17,
                              "streamProgress": progress is not None}, self.store, now=self.now,
                             preferences_store=self.prefs, progress=progress)
        return result, fetch

    def bodies(self):
        with app.ReadmeIndex(self.store) as index:
            return dict(index.db.execute("SELECT key,body FROM documents")) if index.db else {}

    def test_import_is_searchable_atomic_receipt_and_settings_immutable(self):
        app.save_preferences(self.prefs, {"notes": "private setup", "goals": ["gaming"]})
        before = (self.prefs.base / "preferences.json").read_bytes()
        events = []
        result, fetch = self.prepare(progress=events.append)
        self.assertEqual(result["searchPack"]["state"], "ready")
        self.assertEqual(result["searchPack"]["generatedAt"], "2026-09-18T00:00:00Z")
        self.assertEqual(result["searchPack"]["importedAt"], self.now)
        self.assertEqual(result["readmeIndex"]["documents"]["indexed"], 1)
        self.assertEqual(before, (self.prefs.base / "preferences.json").read_bytes())
        self.assertFalse((self.prefs.base / "interests.json").exists())
        self.assertEqual(fetch.call_args_list[0].args[0], app.SEARCH_PACK_URL)
        with app.ReadmeIndex(self.store) as index:
            self.assertIn(app.readme_key(self.items[0]), index.matches("orbitalwidgets"))
        self.assertEqual(events[-1]["phase"], "commit")
        self.assertEqual(events[-1]["committed"], 1)
        self.assertEqual([e["sequence"] for e in events], list(range(1, len(events) + 1)))
        self.assertTrue(all(e["generation"] == 17 and e["action"] == "prepare-search"
                            and e["responseKind"] == "progress" and e["final"] is False for e in events))

    def test_unchanged_asset_skips_download_only_with_current_catalog_coverage(self):
        records = [self.record(self.items[0]), self.record(self.items[1])]
        app.save_catalog(self.store, self.items[:1], self.generated, 100)
        first, fetch = self.prepare(records)
        self.assertEqual(fetch.call_count, 2)
        self.now += 86401
        second, fetch = self.prepare(records)
        self.assertEqual(second["searchPack"]["state"], "ready")
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(second["searchPack"]["importedAt"], first["searchPack"]["importedAt"])
        # Identical release, newly relevant key: must re-read the asset that was
        # intentionally filtered against the earlier catalog.
        app.save_catalog(self.store, self.items[:2], self.generated, 200)
        self.now += 86401
        result, fetch = self.prepare(records)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "ready")
        self.assertTrue(self.bodies()[app.readme_key(self.items[1])])

    def test_pruning_removes_pack_attribution_and_invalidates_coverage(self):
        self.prepare([self.record(self.items[0]), self.record(self.items[1])])
        with app.ReadmeIndex(self.store, create=True) as index:
            index.sync(self.items[1:], {}, self.now)
            keys = {row[0] for row in index.db.execute("SELECT key FROM search_pack_sources")}
            self.assertNotIn(app.readme_key(self.items[0]), keys)
            self.assertIn(app.readme_key(self.items[1]), keys)
        # Catalog is still the original set, but a seed document was pruned.
        # The same asset must restore it instead of trusting an old receipt.
        self.now += 86401
        result, fetch = self.prepare([self.record(self.items[0]), self.record(self.items[1])])
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "ready")
        self.assertTrue(self.bodies()[app.readme_key(self.items[0])])

    def test_matching_asset_digest_does_not_bypass_changed_manifest_validation(self):
        self.prepare()
        self.now += 86401
        result, fetch = self.prepare(changes={"docCount": 2, "candidateCount": 2,
            "stateCounts": {"indexed": 2}, "reasonCounts": {self.record()["reason"]: 2}})
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "error")

    def test_pack_validation_does_not_hold_general_cache_lock(self):
        other = app.Store(self.store.base)
        self.addCleanup(other.close)
        original = app.pack_records

        def records(*args):
            for record in original(*args):
                with other.scoped_lock():
                    pass
                yield record

        with mock.patch.object(app, "pack_records", side_effect=records):
            result, _ = self.prepare()
        self.assertEqual(result["searchPack"]["state"], "ready")

    def test_bad_manifests_are_rejected_before_asset_download(self):
        bad = [{"version": 2}, {"schemaVersion": 2}, {"schemaVersion": True}, {"version": "20260919T000000Z"},
               {"dataVersion": 999}, {"format": "sqlite"}, {"generatedAt": ""},
               {"catalogGeneratedAt": "yesterday"}, {"compressedBytes": app.MAX_PACK_BYTES + 1},
               {"uncompressedBytes": app.MAX_PACK_EXPANDED + 1}, {"docCount": 10001},
               {"compressedBytes": True}, {"sha256": ""},
               {"assetUrl": "https://github.com/attacker/outfit/releases/download/seed/documents.gz"},
               {"assetUrl": "http://github.com/ctl0v0/outfit/releases/download/seed/documents.gz"},
               {"assetUrl": "https://github.com/ctl0v0/outfit/releases/download/seed/documents.gz?url=evil"}]
        for values in bad:
            with self.subTest(values=values):
                result, fetch = self.prepare(changes=values)
                self.assertEqual(result["searchPack"]["state"], "error")
                self.assertEqual(fetch.call_count, 1)
                self.assertFalse(self.bodies())
                self.now += 86401

    def test_checksum_decompression_and_line_caps(self):
        manifest, packed = self.pack()
        with self.assertRaises(ValueError):
            list(app.pack_records(packed + b"bad", manifest))
        for name, value in (("MAX_PACK_BYTES", 1), ("MAX_PACK_EXPANDED", 20), ("MAX_PACK_RECORD_BYTES", 20)):
            with self.subTest(cap=name), mock.patch.object(app, name, value), self.assertRaises(ValueError):
                list(app.pack_records(packed, manifest))
        for changes in ({"uncompressedBytes": 1}, {"uncompressedBytes": manifest["uncompressedBytes"] + 1},
                        {"docCount": 0}, {"docCount": 2}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                list(app.pack_records(packed, {**manifest, **changes}))
        invalid = b"not gzip"
        with self.assertRaises(ValueError):
            list(app.pack_records(invalid, {**manifest, "compressedBytes": len(invalid),
                                           "sha256": hashlib.sha256(invalid).hexdigest()}))

    def test_malformed_tail_rolls_back_documents_and_receipt(self):
        self.prepare()
        before = self.bodies()
        old_receipt = app.search_pack_state(self.store)
        self.now += 86401
        result, _ = self.prepare([self.record(self.items[1]), self.record(self.items[2], body=["bad"])],
                                 changes={"generatedAt": "2026-09-19T00:00:00Z"})
        self.assertEqual(result["searchPack"]["state"], "error")
        self.assertEqual(result["searchPack"]["importedAt"], old_receipt["importedAt"])
        self.assertEqual(result["searchPack"]["generatedAt"], old_receipt["generatedAt"])
        self.assertEqual(self.bodies(), before)

    def test_malformed_shapes_and_provenance(self):
        for changes in ({"state": []}, {"body": "x" * 24001}, {"path": "../README"},
                        {"truncated": "yes"}, {"license": "unknown"}, {"sourceSha256": "not a digest"},
                        {"sourceLicenseText": ""}, {"sourceLicensePath": "../LICENSE"},
                        {"licenseEvidenceUrl": "https://evil.example/LICENSE"}, {"sourceNotices": {}},
                        {"sourceNotices": [{"path": "../NOTICE", "text": "attribution", "sha256": "a" * 64}]},
                        {"license": "GPL-3.0-only"}, {"state": "excluded", "body": "must not be included"}):
            with self.subTest(changes=changes):
                manifest, packed = self.pack([self.record(**changes)])
                with self.assertRaises(ValueError):
                    list(app.pack_records(packed, manifest))

    def test_builder_format_fixture_and_attribution_are_retained(self):
        fixture = json.loads((ROOT / "tests/fixtures/search-pack-record.json").read_text())
        builder = builder_module()
        builder.validate_record(fixture)
        app.validate_pack_legal(fixture, app.github_repo(fixture["repo"]), fixture["commit"])
        record = self.record()
        manifest, packed = self.pack([record])
        output = Path(self.temp.name) / "builder-fixture"
        output.mkdir()
        (output / "latest.json").write_text(json.dumps(manifest))
        (output / f"search-pack-{manifest['version']}.jsonl.gz").write_bytes(packed)
        _manifest, builder_records = builder.validate_pack(output)
        self.assertEqual(list(app.pack_records(packed, manifest)), builder_records)
        self.prepare([record])
        with app.ReadmeIndex(self.store) as index:
            attribution = json.loads(index.db.execute("SELECT attribution FROM search_pack_sources WHERE key=?",
                                                     (record["key"],)).fetchone()[0])
        self.assertEqual(attribution["sourceLicenseText"], record["sourceLicenseText"])
        self.assertEqual(attribution["sourceNotices"], record["sourceNotices"])
        self.assertEqual(attribution["sourceSha256"], record["sourceSha256"])

    def test_large_apache_notice_record_fits_builder_line_limit(self):
        record = self.record(license="Apache-2.0", sourceLicenseText="Apache License, Version 2.0\n" * 4000,
                             sourceNotices=[{"path": name, "text": "Original attribution retained.\n" * 3000,
                                             "sha256": "a" * 64} for name in ("NOTICE", "AUTHORS")])
        manifest, packed = self.pack([record])
        self.assertGreater(manifest["uncompressedBytes"], 256 * 1024)
        builder_module().validate_record(record)
        self.assertEqual(list(app.pack_records(packed, manifest)), [record])
        for changes in ({"sourceLicenseText": "x" * (app.MAX_PACK_LEGAL_BYTES + 1)},
                        {"sourceNotices": [{"path": "NOTICE", "text": "x" * (app.MAX_PACK_LEGAL_BYTES + 1),
                                            "sha256": "a" * 64}]},
                        {"sourceNotices": [{"path": f"NOTICE-{n}", "text": "x" * app.MAX_PACK_LEGAL_BYTES,
                                            "sha256": "a" * 64} for n in range(4)]}):
            bad_manifest, bad_packed = self.pack([{**record, **changes}])
            with self.assertRaises(ValueError):
                list(app.pack_records(bad_packed, bad_manifest))

    def test_legacy_wire_names_and_misreported_coverage_are_rejected(self):
        manifest, packed = self.pack()
        for new, old in (("schemaVersion", "schema"), ("docCount", "documentCount"), ("assetUrl", "assetURL")):
            legacy = dict(manifest)
            legacy[old] = legacy.pop(new)
            with self.subTest(field=new), self.assertRaises(ValueError):
                app.validate_pack_manifest(legacy)
        for changes in ({"stateCounts": {"excluded": 1}}, {"reasonCounts": {"different": 1}},
                        {"stateCounts": {"indexed": True}}, {"candidateCount": 2},
                        {"provenance": {**manifest["provenance"], "catalogUrl": "https://evil.example/catalog.json"}}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                list(app.pack_records(packed, {**manifest, **changes}))

    def test_skips_incompatible_records_and_keeps_excluded_due_locally(self):
        result, _ = self.prepare([self.record(version=99), self.record(self.items[1], key="b" * 64),
                                 self.record(self.items[2], state="excluded", license="unknown")])
        self.assertEqual(result["searchPack"]["skipped"], 2)
        self.assertEqual(self.bodies(), {app.readme_key(self.items[2]): ""})
        self.assertEqual(result["readmeIndex"]["documents"]["skipped"], 1)
        self.assertGreater(result["readmeIndex"]["due"], 0)
        excluded_status = app.readme_index_data(self.store, [self.items[2]], now=self.now)
        self.assertEqual(excluded_status["due"], 1)
        self.assertEqual(excluded_status["documents"]["pending"], 1)
        self.assertEqual(excluded_status["documents"]["processed"], 0)
        with mock.patch.object(app, "fetch_search_readme", return_value={"ok": True, "searchText": "local only"}):
            app.index_readmes(self.store, [self.items[2]], self.now)
        self.assertEqual(self.bodies()[app.readme_key(self.items[2])], "local only")

    def test_newer_local_data_and_unrelated_revisions_are_preserved(self):
        newer = {**self.items[0], "listingCommit": "f" * 40}
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[0]), {"ok": True, "searchText": "richer local content"}, self.now)
            index.put(app.readme_key(newer), {"ok": True, "searchText": "new revision"}, self.now)
        result, _ = self.prepare()
        self.assertEqual(result["searchPack"]["imported"], 0)
        self.assertEqual(self.bodies()[app.readme_key(self.items[0])], "richer local content")
        self.assertEqual(self.bodies()[app.readme_key(newer)], "new revision")

    def test_future_index_version_is_not_downgraded(self):
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[0]), {"ok": True, "searchText": "future local content"}, self.now)
            with index.db:
                index.db.execute("UPDATE documents SET version=?", (app.SEARCH_INDEX_VERSION + 1,))
        result, _ = self.prepare()
        self.assertEqual(result["searchPack"]["imported"], 0)
        self.assertEqual(self.bodies()[app.readme_key(self.items[0])], "future local content")

    def test_retained_history_cannot_hide_or_replace_current_keys(self):
        key = app.readme_key(self.items[0])
        with app.ReadmeIndex(self.store, create=True) as index:
            with index.db:
                index.db.executemany("INSERT INTO documents(key,body,state,version) VALUES(?,?,'indexed',?)",
                                     ((f"{number:064x}", "orbitalwidgets historical text", app.SEARCH_INDEX_VERSION)
                                      for number in range(10001)))
                index.db.execute("INSERT INTO readme_fts(readme_fts) VALUES('rebuild')")
            index.put(key, {"ok": True, "searchText": "orbitalwidgets current local content"}, self.now)
        result, _ = self.prepare()
        self.assertEqual(result["searchPack"]["imported"], 0)
        self.assertEqual(result["readmeIndex"]["documents"]["indexed"], 1)
        self.assertEqual(self.bodies()[key], "orbitalwidgets current local content")
        status = app.readme_index_data(self.store, self.items, "orbitalwidgets", self.now)
        self.assertEqual(status["documents"]["indexed"], 1)
        self.assertGreater(app.search_score(self.items[0], "orbitalwidgets")[0], 0)

    def test_import_and_normal_index_share_lock_and_reject_symlinks(self):
        path = self.store.base / ".readme-index.lock"
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with mock.patch.object(app, "fetch_search_pack", side_effect=AssertionError("Index already busy")):
                self.assertTrue(app.prepare_search(self.store, self.now)["busy"])
        finally:
            os.close(descriptor)
        path.unlink()
        path.symlink_to(self.store.base / "catalog.json")
        with self.assertRaises(OSError):
            app.prepare_search(self.store, self.now)

    def test_rechecks_current_catalog_after_download(self):
        manifest, packed = self.pack()
        def fetch(url, *_args):
            if url == app.SEARCH_PACK_URL:
                return json.dumps(manifest).encode()
            app.save_catalog(self.store, self.items[1:], self.generated, self.now)
            return packed
        with mock.patch.object(app, "fetch_search_pack", side_effect=fetch):
            result = app.prepare_search(self.store, self.now)
        self.assertEqual(result["imported"], 0)
        self.assertEqual(result["skipped"], 1)

    def test_cancel_rolls_back_and_new_worker_resumes_immediately(self):
        manifest, packed = self.pack()
        records = app.pack_records
        def cancelled(*args):
            yield from records(*args)
            raise SystemExit(143)
        with mock.patch.object(app, "fetch_search_pack", side_effect=[json.dumps(manifest).encode(), packed]), \
                mock.patch.object(app, "pack_records", side_effect=cancelled), self.assertRaises(SystemExit):
            app.prepare_search(self.store, self.now)
        self.assertFalse(self.bodies())
        receipt = app.search_pack_state(self.store, self.now)
        self.assertEqual(receipt["importedAt"], 0)
        self.assertEqual(receipt["lastAttemptAt"], self.now)
        self.assertEqual(receipt["state"], "preparing")
        self.assertFalse(receipt["due"])
        self.assertEqual(receipt["error"], "")
        self.assertEqual(receipt["nextCheckAt"], self.now + 300)
        with mock.patch.object(app, "fetch_search_pack", side_effect=[json.dumps(manifest).encode(), packed]) as fetch:
            reopened = app.Store(self.store.base)
            try:
                result = app.run({"action": "prepare-search", "generation": 2}, reopened, now=self.now + 1,
                                 preferences_store=self.prefs)
            finally:
                reopened.close()
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["generation"], 2)
        self.assertEqual(result["searchPack"]["state"], "ready")
        self.assertEqual(result["searchPack"]["lastAttemptAt"], self.now + 1)
        self.assertEqual(result["searchPack"]["nextCheckAt"], self.now + 1 + app.SEARCH_PACK_INTERVAL)
        self.assertFalse(result["searchPack"]["due"])
        self.assertEqual(result["error"], "")
        self.assertEqual(result["readmeIndex"]["documents"]["indexed"], 1)

    def test_download_cancellation_readers_and_busy_workers_do_not_claim_interruption(self):
        manifest, packed = self.pack()
        snapshots = []
        def interrupted_download(url, maximum, progress=None):
            if url == app.SEARCH_PACK_URL:
                return json.dumps(manifest).encode()
            snapshots.append(app.search_pack_state(self.store, self.now))
            other = app.Store(self.store.base)
            try:
                snapshots.append(app.prepare_search(other, self.now + 1))
            finally:
                other.close()
            progress(bytesReceived=len(packed) // 2)
            raise SystemExit(143)
        with mock.patch.object(app, "fetch_search_pack", side_effect=interrupted_download) as fetch, self.assertRaises(SystemExit):
            app.run({"action": "prepare-search", "streamProgress": True}, self.store, now=self.now,
                    preferences_store=self.prefs, progress=lambda _event: None)
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual([state["state"] for state in snapshots], ["preparing", "preparing"])
        self.assertEqual([state["interruptedAttempts"] for state in snapshots], [0, 0])
        self.assertTrue(snapshots[1]["busy"])
        for _ in range(3):
            self.assertEqual(app.search_pack_state(self.store, self.now), snapshots[0])
        self.now += 1
        result, fetch = self.prepare()
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "ready")

    def test_interrupted_refresh_then_offline_preserves_last_good_data_and_backoff(self):
        ready, _ = self.prepare()
        receipt = ready["searchPack"]
        bodies = self.bodies()
        self.now += app.SEARCH_PACK_INTERVAL + 1
        with mock.patch.object(app, "fetch_search_pack", side_effect=SystemExit(143)), self.assertRaises(SystemExit):
            app.prepare_search(self.store, self.now)
        preparing = app.search_pack_state(self.store, self.now)
        self.assertEqual(preparing["state"], "preparing")
        self.assertEqual(preparing["error"], "")
        self.assertFalse(preparing["due"])
        self.now += 1
        with mock.patch.object(app, "fetch_search_pack", side_effect=OSError("offline")) as fetch:
            failed = app.run({"action": "prepare-search"}, self.store, now=self.now, preferences_store=self.prefs)
        fetch.assert_called_once()
        self.assertEqual(failed["searchPack"]["state"], "error")
        self.assertEqual(failed["searchPack"]["failures"], 1)
        self.assertEqual(failed["searchPack"]["nextCheckAt"], self.now + 300)
        self.assertFalse(failed["searchPack"]["due"])
        self.assertTrue(failed["error"])
        self.assertEqual(self.bodies(), bodies)
        for field in ("generatedAt", "catalogGeneratedAt", "importedAt", "version", "sha256", "docCount"):
            self.assertEqual(preparing[field], receipt[field])
            self.assertEqual(failed["searchPack"][field], receipt[field])
        with mock.patch.object(app, "fetch_search_pack") as fetch:
            for offset in (1, 2, 299):
                result = app.run({"action": "prepare-search"}, self.store, now=self.now + offset,
                                 preferences_store=self.prefs)
                self.assertEqual(result["searchPack"], failed["searchPack"])
                self.assertTrue(result["error"])
            fetch.assert_not_called()
        with mock.patch.object(app, "fetch_search_pack", side_effect=OSError("still offline")) as fetch:
            retried = app.prepare_search(self.store, self.now + 300)
        fetch.assert_called_once()
        self.assertEqual(retried["failures"], 2)
        self.assertEqual(retried["nextCheckAt"], self.now + 900)

    def test_disabled_preferences_and_local_only_do_not_resume_interrupted_attempt(self):
        with mock.patch.object(app, "fetch_search_pack", side_effect=SystemExit(143)), self.assertRaises(SystemExit):
            app.prepare_search(self.store, self.now)
        receipt = app.search_pack_state(self.store, self.now)
        for flag in ("readmeEnrichment", "readmeIndexing", "localOnly"):
            app.save_preferences(self.prefs, {**app.DEFAULT_PREFERENCES, **({flag: False} if flag != "localOnly" else {})})
            before = (self.prefs.base / "preferences.json").read_bytes()
            with mock.patch.object(app, "fetch_search_pack") as fetch:
                result = app.run({"action": "prepare-search", "localOnly": flag == "localOnly"}, self.store,
                                 now=self.now + 1, preferences_store=self.prefs)
                fetch.assert_not_called()
            self.assertEqual(result["searchPack"]["state"], "preparing")
            self.assertEqual(result["searchPack"]["enabled"], flag == "localOnly")
            self.assertEqual(app.search_pack_state(self.store, self.now + 1), receipt)
            self.assertEqual((self.prefs.base / "preferences.json").read_bytes(), before)

    def test_repeated_abrupt_crashes_get_bounded_visible_backoff(self):
        for attempt in range(app.SEARCH_PACK_INTERRUPTED_RETRIES + 1):
            with mock.patch.object(app, "fetch_search_pack", side_effect=SystemExit(137)) as fetch, self.assertRaises(SystemExit):
                app.prepare_search(self.store, self.now)
            fetch.assert_called_once()
            self.assertEqual(app.search_pack_state(self.store, self.now)["interruptedAttempts"], attempt)
            self.now += 1
        with mock.patch.object(app, "fetch_search_pack") as fetch:
            result = app.run({"action": "prepare-search"}, self.store, now=self.now, preferences_store=self.prefs)
            fetch.assert_not_called()
        state = result["searchPack"]
        self.assertEqual(state["state"], "error")
        self.assertIn("repeatedly interrupted", result["error"])
        self.assertEqual(state["nextCheckAt"], self.now + 300)
        self.assertFalse(state["due"])
        with mock.patch.object(app, "fetch_search_pack") as fetch:
            retry = app.run({"action": "prepare-search"}, self.store, now=self.now + 1, preferences_store=self.prefs)
            self.assertEqual(retry["searchPack"], state)
            fetch.assert_not_called()
        self.now += 300
        result, fetch = self.prepare()
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "ready")
        self.assertEqual(result["searchPack"]["interruptedAttempts"], 0)

    def test_unexpected_exception_is_a_failure_not_an_immediate_crash_loop(self):
        with mock.patch.object(app, "fetch_search_pack", side_effect=RuntimeError("unexpected transport failure")):
            state = app.prepare_search(self.store, self.now)
        self.assertEqual(state["state"], "error")
        self.assertEqual(state["failures"], 1)
        self.assertFalse(state["due"])
        with mock.patch.object(app, "fetch_search_pack") as fetch:
            self.assertEqual(app.prepare_search(self.store, self.now + 1), state)
            fetch.assert_not_called()

    def test_legacy_cold_attempt_marker_is_recovered_without_waiting(self):
        with mock.patch.object(app, "fetch_search_pack", side_effect=SystemExit(143)), self.assertRaises(SystemExit):
            app.prepare_search(self.store, self.now)
        legacy = app.search_pack_state(self.store, self.now)
        legacy["state"] = "none"
        legacy.pop("interruptedAttempts")
        with app.ReadmeIndex(self.store, create=True) as index, index.db:
            index.db.execute("UPDATE search_pack_state SET value=? WHERE id=1", (json.dumps(legacy),))
        self.now += 1
        result, fetch = self.prepare()
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(result["searchPack"]["state"], "ready")

    def test_daily_check_backoff_offline_and_delta_fill(self):
        self.prepare()
        self.now += 1
        with mock.patch.object(app, "fetch_search_pack", side_effect=AssertionError("Daily check too early")):
            app.prepare_search(self.store, self.now)
        self.now += 86400
        with mock.patch.object(app, "fetch_search_pack", side_effect=OSError("offline")):
            state = app.prepare_search(self.store, self.now)
        self.assertEqual(state["nextCheckAt"], self.now + 300)
        self.assertTrue(self.bodies())
        self.now += 301
        result, _ = self.prepare([self.record(), self.record(self.items[1])],
                                 changes={"generatedAt": "2026-09-19T00:00:00Z"})
        self.assertEqual(result["searchPack"]["imported"], 1)
        self.assertEqual(result["searchPack"]["skipped"], 1)
        self.now += 86401
        result, fetch = self.prepare(changes={"generatedAt": "2026-09-17T00:00:00Z"})
        self.assertEqual(result["searchPack"]["state"], "error")
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(len(self.bodies()), 2)

    def test_preferences_and_local_only_prevent_downloads(self):
        with mock.patch.object(app, "fetch_search_pack", side_effect=AssertionError("No downloads")):
            app.run({"action": "prepare-search", "localOnly": True}, self.store, preferences_store=self.prefs)
            for flag in ("readmeEnrichment", "readmeIndexing"):
                app.save_preferences(self.prefs, {**app.DEFAULT_PREFERENCES, flag: False})
                result = app.run({"action": "prepare-search"}, self.store, preferences_store=self.prefs)
                self.assertFalse(result["searchPack"]["enabled"])
        self.assertIsNone(self.store.stamp("readme-search.sqlite"))

    def test_unique_document_counts_and_committed_local_progress(self):
        duplicate = {**self.items[0], "id": "example.alias"}
        items = self.items[:3] + [duplicate]
        events = []
        def fetch(item):
            return ({"ok": True, "searchText": "local"} if item == items[0] else
                    {"ok": False, "unavailable": True} if item == items[1] else {"ok": False})
        with mock.patch.object(app, "fetch_search_readme", side_effect=fetch):
            result = app.index_readmes(self.store, items, self.now,
                                      lambda phase, message, **counts: events.append(counts))
        self.assertEqual(result["documents"], {"total": 3, "indexed": 1, "processed": 3, "pending": 0,
                                               "unavailable": 1, "failed": 1, "skipped": 0})
        self.assertEqual(result["indexed"], 2)  # Compatibility: old fields are per listing.
        self.assertEqual([e["committed"] for e in events], [1, 2, 3])
        self.assertEqual(events[-1]["documents"], result["documents"])

    def test_release_redirect_allowlist_is_separate(self):
        redirect = app.SearchPackRedirect()
        request = urllib.request.Request(app.SEARCH_PACK_URL)
        good = "https://release-assets.githubusercontent.com/github-production-release-asset/123/file?sig=a%2Fb&sp=r"
        self.assertEqual(redirect.redirect_request(request, None, 302, "Found", {}, good).full_url, good)
        for url in ("http://release-assets.githubusercontent.com/github-production-release-asset/a",
                    "https://evil.example/file", "https://release-assets.githubusercontent.com.evil.example/file",
                    "https://github.com/other/project/releases/download/x/file.gz",
                    "https://user@release-assets.githubusercontent.com/github-production-release-asset/a",
                    "https://release-assets.githubusercontent.com:444/github-production-release-asset/a"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                redirect.redirect_request(request, None, 302, "Found", {}, url)
        with self.assertRaises(ValueError):
            app.RestrictedRedirect("github.com").redirect_request(request, None, 302, "Found", {}, good)

    def test_catalog_refresh_only_updates_public_metadata_and_falls_back(self):
        app.save_preferences(self.prefs, {"notes": "untouched"})
        before = (self.prefs.base / "preferences.json").read_bytes()
        with mock.patch.object(app, "fetch_catalog", return_value=(self.items[:2], self.generated)), \
                mock.patch.object(app, "update_engagement", return_value=({}, self.now, "")), \
                mock.patch.object(app, "scan_profile", side_effect=AssertionError("No probes")), \
                mock.patch.object(app, "scan_inventory", side_effect=AssertionError("No inventory")):
            result = app.run({"action": "catalog-refresh"}, self.store, now=self.now, preferences_store=self.prefs)
        self.assertEqual(result["catalogCount"], 2)
        self.assertEqual(result["catalogSource"], "cache")
        self.assertEqual(result["likesFetchedAt"], self.now)
        self.assertEqual(before, (self.prefs.base / "preferences.json").read_bytes())
        with mock.patch.object(app, "fetch_catalog", side_effect=OSError("offline")), \
                mock.patch.object(app, "update_engagement", return_value=({}, self.now, "")):
            fallback = app.run({"action": "catalog-refresh"}, self.store, now=self.now + 1)
        self.assertEqual(fallback["catalogCount"], 2)
        self.assertEqual(fallback["fetchedAt"], self.now)
        self.assertTrue(fallback["error"])

    def test_inventory_before_analysis_and_stream_opt_in(self):
        with mock.patch.object(app, "scan_inventory", return_value=([], False)) as scan:
            result = app.run({"action": "verify-inventory", "hasAnalyzed": False}, self.store)
        self.assertTrue(result["inventoryAuthoritative"])
        scan.assert_called_once()
        events = []
        manifest, packed = self.pack()
        with mock.patch.object(app, "fetch_search_pack", side_effect=[json.dumps(manifest).encode(), packed]):
            app.run({"action": "prepare-search"}, self.store, now=self.now, progress=events.append)
        self.assertEqual(events, [])

    def test_process_request_correlates_progress_and_final_and_errors(self):
        manifest, packed = self.pack()
        request = {"action": "prepare-search", "generation": 27, "streamProgress": True}
        with mock.patch.object(app, "fetch_search_pack", side_effect=[json.dumps(manifest).encode(), packed]), \
                mock.patch.object(app, "write_response") as writer:
            result = app.process_request(json.dumps(request).encode(), self.store, self.prefs)
        self.assertTrue(result["final"])
        self.assertEqual(result["generation"], 27)
        self.assertGreater(writer.call_count, 0)
        self.assertTrue(app.error_response(ValueError("bad"), request)["final"])

    def test_bounded_download_reports_bytes_without_inventing_total(self):
        for headers in ({}, {"Content-Length": "7"}):
            response = io.BytesIO(b"content")
            response.headers = headers
            events = []
            self.assertEqual(app.read_bounded_response(response, 100, app.time.monotonic() + 3,
                             lambda **counts: events.append(counts)), b"content")
            self.assertEqual(events[-1]["bytesReceived"], 7)
            self.assertEqual("bytesTotal" in events[-1], bool(headers))

    def test_bootstrap_readonly_catalog_cache_wins_no_package_mutation(self):
        package = Path(self.temp.name) / "package"
        package.mkdir()
        path = package / "bootstrap-catalog.json"
        raw = {**self.raw, "generatedAt": "2026-09-17T00:00:00Z"}
        path.write_text(json.dumps({**raw, "provenance": {"url": app.CATALOG_URL,
                                                       "fetchedAt": "2026-09-17T00:01:00Z", "sha256": "a" * 64}}))
        path.chmod(0o444)
        package.chmod(0o555)
        self.addCleanup(package.chmod, 0o755)
        with mock.patch.object(app, "BOOTSTRAP_CATALOG_PATH", path):
            self.assertEqual(app.run({"action": "load"}, self.store)["catalogSource"], "cache")
            (self.store.base / "catalog.json").unlink()
            result = app.run({"action": "load"}, self.store)
            self.assertEqual(result["catalogSource"], "bundled")
            self.assertEqual(result["catalogBuiltAt"], raw["generatedAt"])
            self.assertEqual(result["fetchedAt"], 0)
            self.assertEqual(result["catalogCount"], len(self.items))
            self.assertIsNone(self.store.stamp("catalog.json"))
            (self.store.base / "catalog.json").write_text("broken cache")
            self.assertEqual(app.run({"action": "load"}, self.store)["catalogSource"], "bundled")
            self.assertEqual((self.store.base / "catalog.json").read_text(), "broken cache")
        self.assertEqual(package.stat().st_mode & 0o777, 0o555)
        self.assertEqual(path.stat().st_mode & 0o777, 0o444)
        self.assertEqual(list(package.iterdir()), [path])

    def test_missing_invalid_or_oversized_bootstrap_has_no_catalog(self):
        (self.store.base / "catalog.json").unlink()
        path = Path(self.temp.name) / "bootstrap.json"
        with mock.patch.object(app, "BOOTSTRAP_CATALOG_PATH", path):
            self.assertEqual(app.run({"action": "load"}, self.store)["catalogSource"], "none")
            for value in ({"plugins": self.raw["plugins"]}, {**self.raw, "generatedAt": "bad"}):
                path.write_text(json.dumps(value))
                self.store.memory.clear()
                self.assertEqual(app.load_catalog(self.store)[0], [])
            path.write_bytes(b"x" * 101)
            self.store.memory.clear()
            with mock.patch.object(app, "MAX_CATALOG_BYTES", 100):
                self.assertEqual(app.load_catalog(self.store)[0], [])

    def test_bundled_catalog_never_prunes_newer_local_revision(self):
        newer = {**self.items[0], "listingCommit": "f" * 40}
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(newer), {"ok": True, "searchText": "newer local"}, self.now)
        self.store.memory["catalogSource"] = "bundled"
        with mock.patch.object(app, "fetch_search_readme", return_value={"ok": False}):
            app.index_readmes(self.store, self.items[:1], self.now)
        self.assertEqual(self.bodies()[app.readme_key(newer)], "newer local")

    def test_scan_progress_has_eleven_finished_checks_no_device_names(self):
        events = []
        with mock.patch.object(app, "run_command", side_effect=OSError("fixture")), \
                mock.patch.object(app, "_read_small", return_value="PRIVATE-DEVICE-NAME"), \
                mock.patch.object(app, "scan_inventory", return_value=([], False)):
            result = app.scan_profile(lambda phase, message, **counts: events.append((phase, message, counts)))
        self.assertEqual(len(result), 3)
        self.assertEqual([e[2]["checksFinished"] for e in events], list(range(1, 12)))
        self.assertTrue(all(e[2]["checksTotal"] == 11 for e in events))
        self.assertNotIn("PRIVATE-DEVICE-NAME", json.dumps(events))


class ActualSearchPackAcceptanceTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("OUTFIT_TEST_SEARCH_PACK"), "Optional local builder artifact not requested")
    def test_actual_builder_artifact_in_temporary_store(self):
        directory = Path(os.environ["OUTFIT_TEST_SEARCH_PACK"])
        manifest = json.loads((directory / "latest.json").read_bytes())
        packed = (directory / f"search-pack-{manifest['version']}.jsonl.gz").read_bytes()
        records = list(app.pack_records(packed, manifest))
        self.assertTrue(all(record is not None for record in records))
        counts = dict(Counter(record["state"] for record in records))
        self.assertEqual(counts, manifest["stateCounts"])
        self.assertEqual(len(records), manifest["docCount"])
        _, builder_records = builder_module().validate_pack(directory)
        self.assertEqual(records, builder_records)
        with gzip.GzipFile(fileobj=io.BytesIO(packed)) as stream:
            largest_line = max(len(line) for line in stream)
        asset_requests = 0
        def transport(url, maximum, progress=None):
            nonlocal asset_requests
            if url == app.SEARCH_PACK_URL:
                return json.dumps(manifest).encode()
            self.assertEqual(url, manifest["assetUrl"])
            asset_requests += 1
            if asset_requests == 1:
                progress(bytesReceived=min(len(packed), 512 * 1024))
                raise SystemExit(143)
            return packed
        with tempfile.TemporaryDirectory(prefix="outfit-pack-acceptance-", dir="/tmp/opencode") as temporary:
            store = app.Store(Path(temporary) / "cache")
            config = app.Store(Path(temporary) / "config")
            try:
                with mock.patch.object(app, "BOOTSTRAP_CATALOG_PATH", directory / "catalog.json"), \
                        mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("Acceptance is offline")), \
                        mock.patch.object(app, "fetch_search_pack", side_effect=transport):
                    initial = app.run({"action": "load"}, store, preferences_store=config)
                    self.assertEqual(initial["catalogSource"], "bundled")
                    self.assertEqual(initial["catalogCount"], manifest["catalogCount"])
                    started = app.time.time()
                    with self.assertRaises(SystemExit):
                        app.run({"action": "prepare-search"}, store, now=started, preferences_store=config)
                    self.assertEqual(app.search_pack_state(store, started)["state"], "preparing")
                    self.assertFalse(app.search_pack_state(store, started)["due"])
                    self.assertEqual(app.readme_index_data(store, app.load_catalog(store)[0])["documents"]["indexed"], 0)
                    reopened = app.Store(store.base)
                    store.close()
                    store = reopened
                    prepared = app.run({"action": "prepare-search"}, store, now=started + 1, preferences_store=config)
                    self.assertEqual(asset_requests, 2)
                    self.assertEqual(prepared["searchPack"]["state"], "ready", prepared.get("error"))
                    self.assertEqual(prepared["searchPack"]["generatedAt"], manifest["generatedAt"])
                    self.assertEqual(prepared["searchPack"]["version"], manifest["version"])
                    self.assertEqual(prepared["searchPack"]["docCount"], len(records))
                    self.assertEqual(prepared["searchPack"]["imported"], len(records))
                    documents = prepared["readmeIndex"]["documents"]
                    self.assertEqual(documents, {"total": len(records), "indexed": counts["indexed"],
                                                "processed": len(records) - counts.get("excluded", 0),
                                                "pending": counts.get("excluded", 0), "failed": 0,
                                                "unavailable": counts.get("unavailable", 0), "skipped": counts.get("excluded", 0)})
                    items = app.load_catalog(store)[0]
                    excluded_keys = {record["key"] for record in records if record["state"] == "excluded"}
                    excluded = {app.readme_key(item): item for item in items if app.readme_key(item) in excluded_keys}
                    excluded_status = app.readme_index_data(store, list(excluded.values()))
                    self.assertEqual(excluded_status["due"], counts.get("excluded", 0))
                    with mock.patch.object(app, "fetch_search_readme", return_value={"ok": True, "searchText": "local followup"}) as fetch:
                        app.index_readmes(store, list(excluded.values()), app.time.time())
                    self.assertEqual(fetch.call_count, min(app.README_FETCH_LIMIT, len(excluded)))
                    self.assertIsNone(config.stamp("preferences.json"))
                    self.assertIsNone(config.stamp("interests.json"))
            finally:
                store.close()
                config.close()
        print("\nActual search pack accepted:", json.dumps({"version": manifest["version"], "docCount": len(records),
              "stateCounts": counts, "compressedBytes": len(packed), "uncompressedBytes": manifest["uncompressedBytes"],
              "largestLineBytes": largest_line, "sha256": manifest["sha256"]}, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
