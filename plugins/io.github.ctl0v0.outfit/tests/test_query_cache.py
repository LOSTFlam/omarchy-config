"""Semantic cache coverage through real JSON-shaped app.run requests."""
import copy
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class QueryCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.store = app.Store(Path(temporary.name) / "cache")
        self.preferences = app.Store(Path(temporary.name) / "config")
        self.addCleanup(self.store.close)
        self.addCleanup(self.preferences.close)
        for name in ("fetch_bytes", "fetch_catalog", "run_command", "scan_profile", "scan_inventory"):
            patch = mock.patch.object(app, name, side_effect=AssertionError("Live operation forbidden: " + name))
            patch.start()
            self.addCleanup(patch.stop)
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]["plugins"][0]
        catalog = {"plugins": [{**fixture, "id": f"example.fixture-{i}", "name": f"Battery utility {i}",
                    "description": ("alpha support" if i % 2 == 0 else "omega support"), "tags": [],
                    "listingValidatedCommit": f"{i + 1:040x}", "stars": i} for i in range(24)]}
        self.items, generated = app.normalize_catalog(catalog)
        app.save_catalog(self.store, self.items, generated, 100)
        self.profile = [app._signal("battery", "Battery", {"battery": 20}),
                        app._signal("capability-docker", "Docker executable", {"docker": 12}, source="software")]
        with app.ReadmeIndex(self.store, create=True) as index:
            for item in self.items:
                index.put(app.readme_key(item), {"ok": True, "searchText": "Fictional instructions. " * 100 + " docker orbitalwidget"}, 100)
        text = "Cached inspector prose. " * 500
        app.save_readmes(self.store, {self.items[0]["id"]: {"commit": self.items[0]["listingCommit"],
                          "contentVersion": app.README_CONTENT_VERSION, "content": text, "text": text, "fetchedAt": 100}})
        self.criteria = self.call("save-interests", revision=0, ignoredSignals=[], criteria=[
            {"id": "", "kind": "topic", "label": "Alpha", "terms": ["alpha"]},
            {"id": "service.spotify", "kind": "service", "serviceId": "spotify"},
        ])["inputs"]["criteria"]
        self.query()

    def call(self, action, **values):
        request = json.loads(json.dumps({"action": action, "localOnly": True, "generation": 9, **values}))
        response = app.run(request, self.store, now=200, preferences_store=self.preferences)
        return json.loads(json.dumps(response))

    def query(self, **values):
        request = {"profile": self.profile, "setupPageSize": 60, "setupSort": "name", **values}
        return self.call("quick-setup", **request)

    def rows(self, response):
        return {row["id"]: row for row in response["setup"]["rows"]}

    def assert_fresh_equivalent(self, response, **values):
        cache, preferences = app.Store(self.store.base), app.Store(self.preferences.base)
        try:
            request = {"action": "quick-setup", "localOnly": True, "generation": 9, "profile": self.profile,
                       "setupPageSize": 60, "setupSort": "name", **values}
            fresh = app.run(json.loads(json.dumps(request)), cache, now=200, preferences_store=preferences)
            self.assertEqual(response, json.loads(json.dumps(fresh)))
        finally:
            cache.close()
            preferences.close()

    def save(self, criteria=None, ignored=None):
        inputs = self.call("context")["inputs"]
        return self.call("save-interests", revision=inputs["revision"],
                         criteria=self.criteria if criteria is None else criteria,
                         ignoredSignals=[] if ignored is None else ignored)

    def assert_inbox_metrics_match_browse(self, inbox, browse):
        browse_rows = self.rows(browse)
        self.assertTrue(inbox["rows"])
        for row in inbox["rows"]:
            expected = browse_rows[row["id"]]
            self.assertEqual(row["score"], row["scores"]["hardware"])
            self.assertEqual(expected["score"], expected["scores"]["hardware"])
            for field in ("score", "baseScore", "scores", "evidence", "confidence", "reason", "matchedInterests",
                          "recommendationScore", "popularityScore", "setupGroup"):
                self.assertEqual(row[field], expected[field], (row["id"], field))

    def test_manual_dock_interest_boosts_recommendations_without_changing_hardware_fit_or_order(self):
        # The dock's detected evidence is in its description, below the
        # controller's hardware fit, so a combined-score sort would move it.
        descriptions = [
            ("display", "Display controller", "Monitor tools", 1),
            ("dock-context", "USB-C dock controls", "Display and monitor controls", 0),
            ("dock-manual", "USB-C dock", "Physical docking controls", 0),
            ("neutral", "Neutral utility", "An unrelated utility", 0),
        ]
        raw = [{**self.items[0], "id": "example." + identity, "name": name, "description": description,
                "repo": f"https://github.com/owner{index}/plugin", "sourceType": "community", "tags": [],
                "listingValidatedCommit": f"{index + 50:040x}", "stars": stars}
               for index, (identity, name, description, stars) in enumerate(descriptions)]
        self.items, generated = app.normalize_catalog({"plugins": raw})
        app.save_catalog(self.store, self.items, generated, 150)
        self.profile = [app._signal("multi-monitor", "Two displays", {"display": 20, "monitor": 20})]
        self.save(criteria=[])
        before = self.query(setupSort="fit")
        before_rows = self.rows(before)
        hardware_before = self.query(setupSort="fit", setupHardwareOnly=True)
        self.assertEqual(before_rows["example.dock-context"]["score"], 40)
        self.assertEqual(before_rows["example.dock-manual"]["score"], 0)

        self.criteria = self.save(criteria=[{"kind": "hardware", "featureId": "hardware-dock"}])["inputs"]["criteria"]
        after = self.query(setupSort="fit")
        after_rows = self.rows(after)
        self.assertEqual([row["id"] for row in after["setup"]["rows"]], [row["id"] for row in before["setup"]["rows"]])
        self.assertEqual({row["id"]: row["score"] for row in after["setup"]["rows"]},
                         {row["id"]: row["score"] for row in before["setup"]["rows"]})
        self.assertEqual(after_rows["example.dock-context"]["baseScore"], 100)
        self.assertEqual(after_rows["example.dock-context"]["score"], 40)
        self.assertEqual(after_rows["example.dock-manual"]["score"], 0)
        for identity in ("example.dock-context", "example.dock-manual"):
            self.assertGreater(after_rows[identity]["baseScore"], before_rows[identity]["baseScore"])
            self.assertGreater(after_rows[identity]["recommendationScore"], before_rows[identity]["recommendationScore"])
            self.assertIn("Saved interest", after_rows[identity]["reason"])
            self.assertTrue(after_rows[identity]["matchedInterests"])
            self.assertEqual(after_rows[identity]["score"], after_rows[identity]["scores"]["hardware"])
        hardware_after = self.query(setupSort="fit", setupHardwareOnly=True)
        self.assertEqual([row["id"] for row in hardware_after["setup"]["rows"]],
                         [row["id"] for row in hardware_before["setup"]["rows"]])
        self.assertEqual(after["setup"]["hardwareMatchCount"], before["setup"]["hardwareMatchCount"])

        inbox = self.call("matches", profile=self.profile, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(inbox, after)
        self.assertEqual(inbox["unread"], 0)
        legacy = self.call("search", profile=self.profile)["rows"]
        self.assertEqual(legacy[0]["id"], "example.dock-context")  # Combined relevance still ranks legacy results.
        self.assertIn("example.dock-manual", {row["id"] for row in legacy})
        discovery = self.call("discover", profile=self.profile)["discovery"]["rows"]
        self.assertTrue(any(row["matchedInterests"] for row in discovery))
        for row in legacy + discovery:
            self.assertEqual(row["score"], before_rows[row["id"]]["scores"]["hardware"])
            self.assertEqual(row["baseScore"], after_rows[row["id"]]["baseScore"])
        with mock.patch.object(app, "_term_match_strength", side_effect=AssertionError("Warm hardware metrics rescored")), \
                mock.patch.object(app, "ReadmeIndex", side_effect=AssertionError("Warm metrics reopened README index")):
            self.assertEqual(self.query(setupSort="fit")["setup"], after["setup"])

    def test_software_and_saved_interest_relevance_remain_eligible_but_never_count_as_hardware_fit(self):
        profile = [self.profile[1]]  # Docker executable, without any detected hardware.
        browse = self.query(profile=profile, setupSort="recommended")
        self.assertEqual(browse["setup"]["hardwareMatchCount"], 0)
        self.assertTrue(all(row["score"] == 0 and row["baseScore"] > 0 for row in browse["setup"]["rows"]))
        self.assertTrue(all(row["scores"]["software"] > 0 for row in browse["setup"]["rows"]))
        self.assertEqual(self.query(profile=profile, setupHardwareOnly=True)["setup"]["total"], 0)
        legacy = self.call("search", profile=profile)["rows"]
        self.assertEqual(len(legacy), len(self.items))
        self.assertTrue(all(row["score"] == 0 and row["baseScore"] > 0 for row in legacy))
        inbox = self.call("matches", profile=profile, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(inbox, browse)

    def test_popular_fallback_without_context_cannot_display_stars_as_hardware_fit(self):
        self.save(criteria=[])
        fallback = self.call("search", profile=[])["rows"]
        self.assertGreater(fallback[0]["stars"], 0)
        self.assertTrue(all(row["score"] == row["scores"]["hardware"] == 0 for row in fallback))
        self.assertTrue(all(row["baseScore"] == 0 for row in fallback))

    def test_inbox_fit_and_recommendation_metrics_match_browse_current_context(self):
        browse = self.query()
        inbox = self.call("matches", profile=self.profile, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(inbox, browse)
        self.assertTrue(all(row["scores"]["hardware"] > 0 for row in inbox["rows"]))
        self.assertTrue(all(row["evidence"]["hardware"][0]["origin"] == "detected" for row in inbox["rows"]))
        self.assertTrue(all(row["matchedInterests"][0]["origin"] == "user" for row in inbox["rows"]))
        self.assertEqual(inbox["unread"], 0)
        # The highest-star catalog peer is not an interest match. Inbox must use
        # Browse's full reference population rather than rescaling its subset.
        self.assertNotIn(self.items[-1]["id"], {row["id"] for row in inbox["rows"]})
        self.save(ignored=["battery"])
        ignored = self.call("matches", profile=self.profile, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(ignored, self.query())
        self.assertTrue(all(row["scores"]["hardware"] == 0 for row in ignored["rows"]))
        self.assertEqual(ignored["unread"], 0)

    def test_readme_only_detected_evidence_and_stale_provenance_survive_inbox_scan_context(self):
        self.items[2]["name"] = "Neutral utility"
        app.save_catalog(self.store, self.items, "readme-context", 150)
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[2]), {"ok": True, "searchText": "Charge limit integration"}, 150)
        profile = [{**app._signal("battery", "System battery", {"charge limit": 24}), "stale": True, "checkedAt": 100}]
        scan = {"state": "partial", "checkedAt": 200, "observations": profile,
                "probes": [{"id": "power", "state": "stale", "checkState": "failed", "reason": "Fictional failed probe"}]}
        browse = self.query(profile=profile, scan=scan)
        inbox = self.call("matches", scan=scan, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(inbox, browse)
        row = next(row for row in inbox["rows"] if row["id"] == self.items[2]["id"])
        evidence = row["evidence"]["hardware"][0]
        self.assertGreater(row["scores"]["hardware"], 0)
        self.assertEqual((evidence["field"], evidence["term"], evidence["revision"]),
                         ("README", "charge limit", self.items[2]["listingCommit"]))
        self.assertTrue(evidence["stale"])
        self.assertEqual(evidence["origin"], "detected")
        self.assertEqual(inbox["unread"], 0)
        self.save(ignored=["battery"])
        ignored = self.call("matches", scan=scan, hasAnalyzed=True)["matches"]
        self.assert_inbox_metrics_match_browse(ignored, self.query(profile=profile, scan=scan))
        self.assertTrue(all(row["scores"]["hardware"] == 0 for row in ignored["rows"]))
        self.assertEqual(ignored["unread"], 0)

    def test_detected_devices_or_context_only_readme_changes_cannot_create_inbox_entries(self):
        baseline = self.call("matches", profile=[])["matches"]
        identities = {row["id"] for row in baseline["rows"]}
        current = self.call("matches", profile=self.profile)["matches"]
        self.assertEqual({row["id"] for row in current["rows"]}, identities)
        self.assertEqual(current["unread"], 0)
        hardware_only = {**copy.deepcopy(self.items[1]), "id": "example.hardware-only", "name": "Battery and Docker utility",
                         "description": "A standalone device tool", "stars": 999, "listingCommit": "e" * 40}
        self.items.append(hardware_only)
        app.save_catalog(self.store, self.items, "hardware-only-arrival", 150)
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[3]), {"ok": True, "searchText": "Battery controls"}, 150)
        current = self.call("matches", profile=self.profile)["matches"]
        self.assertEqual({row["id"] for row in current["rows"]}, identities)
        self.assertEqual(current["unread"], 0)
        browse = self.query()
        self.assertGreater(self.rows(browse)[hardware_only["id"]]["scores"]["hardware"], 0)
        self.assert_inbox_metrics_match_browse(current, browse)
        self.save(criteria=[])
        empty = self.call("matches", profile=self.profile)["matches"]
        self.assertEqual((empty["rows"], empty["total"], empty["unread"]), ([], 0, 0))

    def test_inbox_recommendation_is_stable_across_unread_filter_and_acknowledgement(self):
        newcomer = {**copy.deepcopy(self.items[1]), "id": "example.newcomer", "name": "New battery utility",
                    "description": "alpha support", "stars": 0, "listingCommit": "e" * 40}
        self.items.append(newcomer)
        app.save_catalog(self.store, self.items, "saved-interest-arrival", 150)
        all_matches = self.call("matches", profile=self.profile)["matches"]
        self.assertEqual(all_matches["unread"], 1)
        unread = self.call("matches", profile=self.profile, unreadOnly=True)["matches"]
        self.assertEqual(unread["total"], 1)
        self.assertEqual(unread["rows"][0]["id"], newcomer["id"])
        self.assertEqual(unread["rows"][0]["matchCause"], "new-listing")
        self.assertEqual(unread["rows"][0]["popularityScore"], 0)
        self.assertGreater(unread["rows"][0]["recommendationScore"], 0)
        self.assert_inbox_metrics_match_browse(unread, self.query())
        reviewed = self.call("review-matches", profile=self.profile, pluginIds=[newcomer["id"]])["matches"]
        self.assertEqual(reviewed["unread"], 0)
        row = next(row for row in reviewed["rows"] if row["id"] == newcomer["id"])
        self.assertEqual(row["recommendationScore"], unread["rows"][0]["recommendationScore"])
        self.assertEqual(row["score"], unread["rows"][0]["score"])

    def test_browse_and_inbox_with_same_context_reuse_warm_scoring_and_readme_caches(self):
        browse = self.query()
        with mock.patch.object(app, "_term_match_strength", side_effect=AssertionError("Inbox rescored warm Browse context")), \
                mock.patch.object(app, "literal_pattern", side_effect=AssertionError("Inbox rematched identical evidence")), \
                mock.patch.object(app, "ReadmeIndex", side_effect=AssertionError("Inbox reopened identical README corpus")):
            for action, values in (("matches", {}), ("review-matches", {"all": True}), ("matches", {})):
                inbox = self.call(action, profile=self.profile, hasAnalyzed=True, **values)["matches"]
                self.assert_inbox_metrics_match_browse(inbox, browse)
            self.assertEqual(self.query()["setup"], browse["setup"])

    def test_warm_protocol_queries_do_not_rescore_reread_state_or_reopen_sqlite(self):
        for query in ("", "alpha", "spotify", "orbitalwidget"):
            self.query(setupQuery=query)
        with mock.patch.object(app, "_term_match_strength", side_effect=AssertionError("Warm scoring cache missed")), \
                mock.patch.object(app, "literal_pattern", side_effect=AssertionError("Warm interest evidence missed")), \
                mock.patch.object(app, "ReadmeIndex", side_effect=AssertionError("Unchanged SQLite corpus reopened")), \
                mock.patch.object(app, "validate_review", side_effect=AssertionError("Unchanged review state revalidated")), \
                mock.patch.object(self.preferences, "read", wraps=self.preferences.read) as read:
            for query in ("alpha", "", "orbitalwidget", "spotify", ""):
                result = self.query(setupQuery=query, setupPage=2)
                self.assertTrue(result["ok"])
                self.assertEqual(result["criteriaRevision"], 1)
            read.assert_not_called()

    def test_recreated_criteria_review_only_updates_and_inbox_queries_keep_scoring_warm(self):
        self.call("matches")
        self.query()  # The inbox's profile-free scoring/evidence context must not evict this context.
        with app.ReadmeIndex(self.store) as index:
            self.assertEqual(len(index.states()), 24)  # Read-only SHM activity is not a content edit.
        document = self.preferences.read("interests.json", app.MAX_INTEREST_STATE, {})
        document["review"]["lastCheckedAt"] = 201
        external = app.Store(self.preferences.base)
        try:
            external.write("interests.json", document, app.MAX_INTEREST_STATE)
        finally:
            external.close()
        with mock.patch.object(app, "_term_match_strength", side_effect=AssertionError("Review acknowledgement rescored")), \
                mock.patch.object(app, "literal_pattern", side_effect=AssertionError("Equivalent recreated criteria missed")):
            self.query()
            self.call("save-density", browseDensity="dense")
            self.assertEqual(self.query()["preferences"]["browseDensity"], "dense")

    def test_same_id_phrase_edits_pause_and_criteria_revision_invalidate(self):
        first = self.rows(self.query())
        self.assertTrue(first[self.items[0]["id"]]["matchedInterests"])
        edited = copy.deepcopy(self.criteria)
        edited[0]["terms"] = ["omega"]
        self.save(edited)
        after = self.query()
        self.assertEqual(after["criteriaRevision"], 2)
        self.assertEqual(self.rows(after)[self.items[0]["id"]]["matchedInterests"], [])
        self.assertEqual(self.rows(after)[self.items[1]["id"]]["matchedInterests"][0]["term"], "omega")
        self.assert_fresh_equivalent(after)
        edited[0]["enabled"] = False
        self.save(edited)
        after = self.query()
        self.assertTrue(all(not row["matchedInterests"] for row in after["setup"]["rows"]))
        self.assert_fresh_equivalent(after)
        # Even a same-content explicit save advances the canonical revision;
        # it must not accidentally address an old revision's memo entries.
        self.save(edited)
        with mock.patch.object(app, "_term_match_strength", wraps=app._term_match_strength) as score:
            current = self.query()
            self.assertGreater(score.call_count, 0)
        self.assertEqual(current["criteriaRevision"], 4)

    def test_ignored_inputs_and_profile_weights_labels_terms_and_staleness_invalidate(self):
        self.save(ignored=["battery"])
        ignored = self.query()
        self.assertEqual(ignored["setup"]["hardwareMatchCount"], 0)
        self.assert_fresh_equivalent(ignored)
        self.save(ignored=[])
        baseline = self.query()
        self.assertGreater(baseline["setup"]["hardwareMatchCount"], 0)
        changed = copy.deepcopy(self.profile)
        changed[0].update(label="Changed detected label", stale=True)
        changed[0]["terms"][0]["weight"] = 2
        result = self.query(profile=changed)
        row = result["setup"]["rows"][0]
        self.assertLess(row["scores"]["hardware"], baseline["setup"]["rows"][0]["scores"]["hardware"])
        self.assertEqual(row["evidence"]["hardware"][0]["signal"], "Changed detected label")
        self.assertTrue(row["evidence"]["hardware"][0]["stale"])
        self.assert_fresh_equivalent(result, profile=changed)
        changed[0]["terms"] = [{"value": "never-present", "weight": 20}]
        self.assertEqual(self.query(profile=changed)["setup"]["hardwareMatchCount"], 0)

    def test_same_revision_readme_edits_only_rescore_affected_rows_and_expire_query_matches(self):
        self.query(setupQuery="spotify")
        with app.ReadmeIndex(self.store, create=True) as writer:
            writer.put(app.readme_key(self.items[2]), {"ok": True, "searchText": "Spotify integration"}, 200)
            with mock.patch.object(app, "_term_match_strength", wraps=app._term_match_strength) as score:
                after = self.query()
                self.assertGreater(score.call_count, 0)
                self.assertLess(score.call_count, 40)  # One changed row, not all 24 listings.
            row = self.rows(after)[self.items[2]["id"]]
            self.assertEqual(row["matchedInterests"][-1]["field"], "README")
            self.assertEqual(row["matchedInterests"][-1]["term"], "spotify")
            self.assertEqual(row["scores"]["software"], 0)
            matches = self.query(setupQuery="spotify")
            self.assertEqual(matches["setup"]["total"], 1)
            self.assert_fresh_equivalent(after)
            # Another connection writes WAL while its main database file remains unchanged.
            writer.put(app.readme_key(self.items[2]), {"ok": True, "searchText": "Nothing related"}, 201)
            self.assertEqual(self.query(setupQuery="spotify")["setup"]["total"], 0)
            self.assert_fresh_equivalent(self.query())

    def test_catalog_refresh_reuses_semantic_scores_but_updates_listing_revision_and_metadata(self):
        before = self.query()
        app.save_catalog(self.store, copy.deepcopy(self.items), "new-refresh", 150)
        with mock.patch.object(app, "_term_match_strength", side_effect=AssertionError("Identical catalog rescored")), \
                mock.patch.object(app, "literal_pattern", side_effect=AssertionError("Identical catalog rematched")):
            unchanged = self.query()
        self.assertEqual(before["setup"], unchanged["setup"])
        changed = copy.deepcopy(self.items)
        changed[0].update(name="Changed alpha utility", description="Spotify integration", stars=2000,
                          listingCommit="f" * 40)
        app.save_catalog(self.store, changed, "changed-listing", 160)
        result = self.query()
        row = self.rows(result)[changed[0]["id"]]
        self.assertEqual(row["stars"], 2000)
        self.assertEqual(row["scores"]["hardware"], 0)
        self.assertEqual(row["scores"]["software"], 0)  # Old-revision README is no evidence.
        self.assertEqual({match["revision"] for match in row["matchedInterests"]}, {"f" * 40})
        self.assert_fresh_equivalent(result)

    def test_external_catalog_replacement_and_index_file_replacement_are_not_hidden_by_memos(self):
        external = app.Store(self.store.base)
        try:
            changed = copy.deepcopy(self.items)
            changed[0]["description"] = "omega only"
            app.save_catalog(external, changed, "external-catalog", 180)
        finally:
            external.close()
        self.assertEqual(self.rows(self.query())[changed[0]["id"]]["matchedInterests"], [])
        for suffix in ("-wal", "-shm", ""):
            (self.store.base / ("readme-search.sqlite" + suffix)).unlink(missing_ok=True)
        after = self.query()
        self.assertTrue(all(row["scores"]["software"] == 0 for row in after["setup"]["rows"]))
        self.assert_fresh_equivalent(after)

    def test_preferences_toggle_and_inspector_readme_cache_invalidate_independently(self):
        self.call("save-preferences", preferences={"readmeEnrichment": False})
        result = self.query()
        self.assertTrue(all(row["scores"]["software"] == 0 for row in result["setup"]["rows"]))
        self.assert_fresh_equivalent(result)
        self.call("save-preferences", preferences={"readmeEnrichment": True})
        app.save_readmes(self.store, {self.items[0]["id"]: {"commit": self.items[0]["listingCommit"],
             "contentVersion": app.README_CONTENT_VERSION, "content": "Spotify full cached prose", "text": "Spotify full cached prose", "fetchedAt": 200}})
        result = self.query()
        self.assertIn("service.spotify", {match["id"] for match in self.rows(result)[self.items[0]["id"]]["matchedInterests"]})
        self.assert_fresh_equivalent(result)

    def test_in_place_state_edits_with_restored_mtime_are_detected_and_future_schema_is_preserved(self):
        path = self.preferences.base / "interests.json"
        old_stat = path.stat()
        document = json.loads(path.read_text())
        document["criteria"][0]["terms"] = ["omega"]
        # Exercise ctime invalidation: same inode, size and restored mtime.
        path.write_text(json.dumps(document, ensure_ascii=True, separators=(",", ":")))
        os.utime(path, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
        self.assertEqual(path.stat().st_size, old_stat.st_size)
        result = self.query()
        self.assertEqual(result["criteriaRevision"], 1)
        self.assertEqual(self.rows(result)[self.items[0]["id"]]["matchedInterests"], [])
        self.assert_fresh_equivalent(result)
        document["schema"] = 999
        self.preferences.write("interests.json", document, app.MAX_INTEREST_STATE)
        with self.assertRaises(ValueError):
            self.query()
        self.assertEqual(json.loads(path.read_text()), document)

    def test_public_response_mutations_do_not_modify_internal_state_or_score_snapshots(self):
        inputs = app.run({"action": "context"}, self.store, preferences_store=self.preferences)["inputs"]
        inputs["criteria"][0]["terms"][:] = ["must not be persisted"]
        inputs["ignoredSignals"].append("battery")
        current = self.call("context")["inputs"]
        self.assertEqual(current["criteria"][0]["terms"], ["alpha"])
        self.assertEqual(current["ignoredSignals"], [])
        result = app.run({"action": "quick-setup", "profile": self.profile}, self.store, now=200,
                         preferences_store=self.preferences)
        row = result["setup"]["rows"][0]
        row["scores"]["hardware"] = -999
        row["evidence"]["hardware"][0]["signal"] = "mutated response"
        if row["matchedInterests"]:
            row["matchedInterests"][0]["label"] = "mutated response"
        self.assert_fresh_equivalent(self.query())

    def test_transient_index_failure_does_not_become_a_permanent_empty_cache(self):
        self.store.memory.pop("interestReadmes", None)
        self.store.memory.pop("indexSnapshot", None)
        with mock.patch.object(app, "ReadmeIndex", side_effect=sqlite3.OperationalError("database is locked")):
            partial = self.query()
        self.assertTrue(partial["readmeIndex"]["error"])
        restored = self.query()
        self.assertFalse(restored["readmeIndex"]["error"])
        self.assertGreater(restored["setup"]["rows"][0]["scores"]["software"], 0)
        self.assert_fresh_equivalent(restored)

    def test_memos_remain_bounded_through_many_edits_and_queries(self):
        for index in range(7):
            profile = copy.deepcopy(self.profile)
            profile[0]["label"] = f"Fictional battery {index}"
            self.query(profile=profile, setupQuery=f"query-{index}")
        for item in app.load_catalog(self.store)[0]:
            self.assertLessEqual(len(item["_recommendationCache"]), 4)
            self.assertLessEqual(len(item["_interestMatchCache"]), 4)
        self.assertLessEqual(len(self.store.memory["indexQueries"]), 4)
        self.assertLessEqual(len(self.store.memory["interestReadmes"]), 4)
        self.assertLessEqual(len(self.preferences.memory["stateSnapshots"]), 2)
