from __future__ import annotations

import concurrent.futures
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app, ROOT


class InterestTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.store = app.Store(Path(directory.name) / "cache")
        self.preferences = app.Store(Path(directory.name) / "config")
        self.addCleanup(self.store.close)
        self.addCleanup(self.preferences.close)
        fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
        self.base = app.normalize_catalog(fixture["catalog"])[0][0]
        self.items = [self.item("one", "Quiet companion"), self.item("two", "Plain timer")]
        self.catalog()
        for function in ("fetch_bytes", "scan_profile", "scan_inventory", "run_command"):
            patch = mock.patch.object(app, function, side_effect=AssertionError("Unexpected live operation: " + function))
            patch.start()
            self.addCleanup(patch.stop)

    def item(self, suffix, name, **kwargs):
        return {**self.base, "id": "example." + suffix, "name": name, "description": "A fictional utility.",
                "tags": [], "category": "Utility", "stars": 0, "repo": "https://github.com/example/" + suffix,
                **kwargs}

    def catalog(self):
        app.save_catalog(self.store, self.items, "fictional", 100)

    def run_action(self, action, **values):
        return app.run({"action": action, **values}, self.store, now=200,
                       preferences_store=self.preferences)

    def criterion(self, term="orbital widgets", **values):
        return {"id": "", "kind": "topic", "label": term.title(), "terms": [term], "enabled": True, **values}

    def save(self, criteria, **values):
        context = self.run_action("context")["inputs"]
        return self.run_action("save-interests", revision=context["revision"], criteria=criteria,
                               ignoredSignals=values.pop("ignoredSignals", []), **values)

    def index(self, item, text):
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(item), {"ok": True, "searchText": text}, 100)

    def test_custom_and_hardware_sidebar_filters_union_with_services_without_saving(self):
        self.items = [self.item("midi", "MIDI keyboard", stars=20),
                      self.item("mail", "Microsoft Outlook", stars=10),
                      self.item("air", "AirPods controls", stars=30),
                      self.item("unrelated", "Humidifier", stars=40)]
        self.catalog()
        before = self.run_action("context")["inputs"]
        midi, air = "interest-" + "a" * 32, "interest-" + "b" * 32
        filters = [{"key": midi, "criterion": self.criterion("midi")},
                   {"key": air, "criterion": self.criterion(kind="hardware", featureId="bluetooth-airpods")}]
        result = self.run_action("quick-setup", setupServices=[midi, "outlook", air],
                                 setupInterestCriteria=filters, setupSort="stars")["setup"]
        self.assertEqual([row["id"] for row in result["rows"]], ["example.air", "example.midi", "example.mail"])
        self.assertEqual({row["id"]: row["total"] for row in result["services"] if row["id"] in (midi, air)},
                         {midi: 1, air: 1})
        self.assertEqual(self.run_action("context")["inputs"], before)
        self.assertTrue(all(not row["matchedInterests"] for row in result["rows"]),
                        "Draft filter evidence does not change saved-interest recommendations")
        narrowed = self.run_action("quick-setup", setupServices=[midi, "outlook"],
            setupInterestCriteria=filters, setupQuery="keyboard")["setup"]
        self.assertEqual([row["id"] for row in narrowed["rows"]], ["example.midi"])

    def test_interest_filter_uses_current_cached_readme_and_missing_filter_does_not_broaden(self):
        key = "interest-" + "c" * 32
        self.index(self.items[0], "Supports MIDI controllers")
        criterion = self.criterion("midi")
        result = self.run_action("quick-setup", setupServices=[key],
            setupInterestCriteria=[{"key": key, "criterion": criterion}])["setup"]
        self.assertEqual([row["id"] for row in result["rows"]], ["example.one"])
        self.assertIn("README", result["rows"][0]["serviceReason"])
        missing = self.run_action("quick-setup", setupServices=[key])["setup"]
        self.assertEqual(missing["total"], 0)
        self.assertEqual(missing["selectedServices"], [key])
        for invalid in (None, [{"key": "../bad", "criterion": criterion}],
                        [{"key": key, "criterion": self.criterion(terms=["x" * 65])}]):
            with self.assertRaises(ValueError):
                self.run_action("quick-setup", setupInterestCriteria=invalid)

    def test_migrates_only_active_services_and_keeps_legacy_fields_inert(self):
        original = {**app.DEFAULT_PREFERENCES, "services": ["spotify", "github"],
                    "goals": ["gaming"], "software": ["steam"], "notes": "orbital widgets",
                    "notFit": ["example.one"], "future": {"keep": 1}}
        app.save_preferences(self.preferences, original)
        inputs = self.run_action("context")["inputs"]
        self.assertEqual(inputs["revision"], 1)
        self.assertEqual([row["id"] for row in inputs["criteria"]], ["service.spotify", "service.github"])
        self.assertTrue(all(row["origin"] == "user" for row in inputs["criteria"]))
        self.assertEqual(self.preferences.read("preferences.json", 65536, {}), original)
        self.assertEqual(self.run_action("context")["inputs"], inputs)
        self.assertEqual(self.run_action("matches")["matches"]["total"], 0)

    def test_sidebar_filter_union_is_anded_with_query_status_and_category(self):
        self.items = [self.item("midi", "MIDI keyboard", category="Music"),
                      self.item("mail", "Microsoft Outlook keyboard", category="Music"),
                      self.item("other", "MIDI keyboard", category="Utility"),
                      self.item("uninstalled", "MIDI keyboard", category="Music"),
                      self.item("noquery", "MIDI sequencer", category="Music")]
        self.catalog()
        key = "interest-" + "d" * 32
        result = self.run_action("quick-setup", setupServices=[key, "outlook"],
            setupInterestCriteria=[{"key": key, "criterion": self.criterion("midi")}],
            setupQuery="keyboard", setupCategory="Music", setupInstallFilter="installed",
            installed=[item["id"] for item in self.items if item["id"] != "example.uninstalled"])["setup"]
        self.assertEqual({row["id"] for row in result["rows"]}, {"example.midi", "example.mail"})

    def test_sidebar_literal_filter_never_injects_search_and_leaves_saved_scores_intact(self):
        self.items = [self.item("literal", "Literal [midi.*] device"), self.item("other", "MIDI device")]
        self.catalog()
        self.save([self.criterion("device")])
        baseline = self.run_action("quick-setup")["setup"]["rows"]
        key = "interest-" + "e" * 32
        filters = [{"key": key, "criterion": self.criterion("[midi.*]")}]
        unselected = self.run_action("quick-setup", setupInterestCriteria=filters)["setup"]["rows"]
        self.assertEqual(unselected, baseline, "Unselected draft evidence cannot change saved scores or reasons")
        selected = self.run_action("quick-setup", setupServices=[key], setupInterestCriteria=filters)["setup"]
        self.assertEqual([row["id"] for row in selected["rows"]], ["example.literal"])
        self.assertEqual(selected["rows"][0]["matchedInterests"],
                         next(row for row in baseline if row["id"] == "example.literal")["matchedInterests"])
        self.assertEqual(self.run_action("context")["inputs"]["criteria"][0]["terms"], ["device"])

    def test_sidebar_filter_payload_is_bounded_and_rejects_duplicate_or_service_keys(self):
        key = "interest-" + "f" * 32
        entry = {"key": key, "criterion": self.criterion("midi")}
        for filters in ([entry] * 129, [entry, entry],
                        [{"key": key, "criterion": {"kind": "service", "serviceId": "spotify"}}]):
            with self.subTest(filters=len(filters)), self.assertRaises(ValueError):
                self.run_action("quick-setup", setupServices=[key], setupInterestCriteria=filters)
        paused = {"key": key, "criterion": self.criterion("midi", enabled=False)}
        result = self.run_action("quick-setup", setupServices=[key], setupInterestCriteria=[paused])["setup"]
        self.assertEqual(result["total"], 0)
        self.assertEqual(result["selectedServices"], [key])

    def test_scoped_saves_preserve_settings_unknown_fields_criteria_and_revision(self):
        app.save_preferences(self.preferences, {**app.DEFAULT_PREFERENCES, "future": {"keep": True}})
        result = self.save([self.criterion(), {"kind": "service", "serviceId": "spotify"}])
        before = result["inputs"]
        self.assertEqual(result["preferences"]["services"], ["spotify"])
        self.run_action("save-density", browseDensity="dense")
        self.run_action("save-preferences", preferences={"watchHardware": False, "services": [], "browseDensity": "list"})
        prefs = app.load_preferences(self.preferences)
        self.assertEqual(prefs["browseDensity"], "dense")
        self.assertFalse(prefs["watchHardware"])
        self.assertEqual(prefs["services"], ["spotify"])
        self.assertEqual(self.run_action("context")["inputs"], before)
        self.assertEqual(self.preferences.read("preferences.json", 65536, {})["future"], {"keep": True})
        document = self.preferences.read("interests.json", app.MAX_INTEREST_STATE, {})
        self.preferences.write("interests.json", {**document, "future": {"retain": 1}}, app.MAX_INTEREST_STATE)
        self.save(before["criteria"])
        self.assertEqual(self.preferences.read("interests.json", app.MAX_INTEREST_STATE, {})["future"], {"retain": 1})
        self.assertEqual((self.preferences.base / "interests.json").stat().st_mode & 0o777, 0o600)

    def test_unknown_schemas_are_preserved(self):
        for filename in ("interests.json", "preferences.json"):
            with self.subTest(filename=filename):
                document = {"schema": 999, "future": "preserve me"}
                self.preferences.write(filename, document, app.MAX_INTEREST_STATE)
                with self.assertRaises(ValueError):
                    self.run_action("save-interests", revision=0, criteria=[], ignoredSignals=[])
                self.assertEqual(self.preferences.read(filename, app.MAX_INTEREST_STATE, {}), document)
                (self.preferences.base / filename).unlink()

    def test_invalid_persisted_interests_never_get_silent_new_ids_or_enabled_defaults(self):
        saved = self.save([self.criterion()])["inputs"]["criteria"][0]
        for criterion in ({**saved, "id": ""}, {key: value for key, value in saved.items() if key != "enabled"}, None):
            document = {"schema": 1, "revision": 9, "criteria": [criterion], "ignoredSignals": [], "review": {}}
            self.preferences.write("interests.json", document, app.MAX_INTEREST_STATE)
            for action in ("context", "matches", "save-interests"):
                with self.subTest(action=action, criterion=criterion), self.assertRaises(ValueError):
                    self.run_action(action, revision=9, criteria=[], ignoredSignals=[])
            self.assertEqual(self.preferences.read("interests.json", app.MAX_INTEREST_STATE, {}), document)

    def test_revision_validation_ids_limits_and_aliases(self):
        result = self.save([{"kind": "hardware", "featureId": "bluetooth-airpods"}])
        saved = result["inputs"]["criteria"][0]
        self.assertTrue(saved["id"].startswith("interest."))
        self.assertEqual(saved["terms"], ["airpods", "apple headphones"])
        self.assertEqual(saved["origin"], "user")
        with self.assertRaisesRegex(ValueError, "stale revision"):
            self.run_action("save-interests", revision=0, criteria=[], ignoredSignals=[])
        for invalid in (
                self.criterion(id="interest." + "f" * 32), self.criterion(id="../bad"), self.criterion(id=[]),
                self.criterion(label="x" * 81), self.criterion(terms=["x" * 65]),
                self.criterion(terms=["one", "two", "three", "four", "five"]),
                self.criterion(featureId="missing"), self.criterion(kind="service", serviceId="missing"),
                self.criterion(serviceId=[]), self.criterion(featureId=None),
                self.criterion(enabled="yes"), self.criterion(terms=[])):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.save([invalid])
        with self.assertRaises(ValueError):
            self.save([self.criterion()] * 65)
        with self.assertRaisesRegex(ValueError, "override"):
            self.save([saved], ignoredSignals=["unknown-hardware"])
        self.assertEqual(self.run_action("context")["inputs"]["criteria"], [saved])

    def test_context_survives_scoped_save_in_memory_and_revision_errors_are_identifiable(self):
        profile = [app._signal("battery", "Fictional battery", {"battery": 24})]
        before = self.run_action("context", scan={"state": "success", "checkedAt": 100, "observations": profile},
                                 hasAnalyzed=True)["inputs"]
        self.assertEqual(before["detected"][0]["id"], "battery")
        after = self.save([self.criterion()])["inputs"]
        self.assertEqual(before["detected"], after["detected"])
        result = app.process_request(json.dumps({"action": "save-interests", "revision": 0,
                    "criteria": [], "ignoredSignals": []}).encode(), self.store, self.preferences)
        self.assertEqual(result["errorCode"], "stale-revision")

    def test_scan_aliases_preserve_stale_probe_metadata_and_recommendation_context(self):
        signal = {**app._signal("camera", "Fictional camera", {"webcam": 24}), "stale": True, "checkedAt": 100}
        scan = {"state": "partial", "checkedAt": 200, "observations": [signal],
                "probes": [{"id": "USB devices", "state": "stale", "checkState": "failed", "reason": "Probe unavailable"}]}
        for field in ("scan", "previousScan"):
            inputs = self.run_action("context", **{field: scan})["inputs"]
            self.assertEqual(inputs["detected"][0]["checkedAt"], 100)
            self.assertEqual(inputs["checkedAt"], 200)
            self.assertEqual(inputs["probes"][0]["checkState"], "failed")
        self.items[0]["name"] = "Webcam tools"
        self.catalog()
        result = self.run_action("quick-setup", scan=scan, setupSort="recommended")
        self.assertGreater(result["setup"]["rows"][0]["scores"]["hardware"], 0)
        self.assertEqual(result["profile"][0]["id"], "camera")
        self.assertEqual(self.run_action("discover", scan=scan)["criteriaRevision"], 0)

    def test_legacy_manual_profile_channels_cannot_return_as_stale_detections(self):
        legacy = [app._signal("software-steam", "Legacy Steam choice", {"steam": 24}, source="software"),
                  app._signal("goal-gaming", "Legacy gaming goal", {"gaming": 24}, source="workflow")]
        self.assertEqual(self.run_action("context", profile=legacy)["inputs"]["detected"], [])
        report = app.accepted_scan(([], ["USB devices"], []), {}, legacy, 200)
        self.assertEqual(report["observations"], [])

    def test_concurrent_scoped_saves_compare_the_authoritative_revision(self):
        def save_one(term):
            local = app.Store(self.preferences.base)
            try:
                return app.run({"action": "save-interests", "revision": 0, "criteria": [self.criterion(term)],
                                "ignoredSignals": []}, self.store, now=200, preferences_store=local)
            except ValueError as error:
                return str(error)
            finally:
                local.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(save_one, ["orbit", "galaxy"]))
        self.assertEqual(sum(isinstance(result, dict) for result in results), 1)
        self.assertTrue(any("stale revision" in result for result in results if isinstance(result, str)))
        self.assertEqual(self.run_action("context")["criteriaRevision"], 1)

    def test_literal_phrases_boundaries_unicode_and_no_partial_claims(self):
        self.items = [self.item("one", "Orbital widgets"), self.item("two", "orbital widgetsmith"),
                      self.item("three", "orbital useful widgets"), self.item("four", "préorbital widgets"),
                      self.item("five", "C++ kit"), self.item("six", "C++ kitsmith"),
                      self.item("seven", "Plain", tags=["orbital", "widgets"])]
        self.catalog()
        preview = self.run_action("preview-interest", criterion=self.criterion())["preview"]
        self.assertEqual([row["id"] for row in preview["rows"]], ["example.one"])
        self.assertIn("exact phrase", preview["rows"][0]["reason"])
        preview = self.run_action("preview-interest", criterion=self.criterion("C++ kit"))["preview"]
        self.assertEqual([row["id"] for row in preview["rows"]], ["example.five"])
        self.assertIsNone(self.preferences.stamp("interests.json"))

    def test_curated_scope_and_exceptions_apply_to_full_readme(self):
        self.items = [self.item("one", "Plain utility"), self.item("two", "Linear"),
                      self.item("three", "A utility", description="A linear animation on github."),
                      self.item("four", "Slack", id="io.github.joshferrara.quick-emoji")]
        self.catalog()
        self.index(self.items[0], "Hosted on github. Linear animation. Slack compatibility.")
        self.index(self.items[3], "Slack integration")
        for service, expected in (("github", []), ("linear", ["example.two"]), ("slack", ["example.one"])):
            preview = self.run_action("preview-interest", criterion={"kind": "service", "serviceId": service})["preview"]
            self.assertEqual([row["id"] for row in preview["rows"]], expected)
        self.index(self.items[0], "GitHub notifications with linear inbox")
        for service in ("github", "linear"):
            rows = self.run_action("preview-interest", criterion={"kind": "service", "serviceId": service})["preview"]["rows"]
            evidence = next(row for row in rows if row["id"] == "example.one")["matchedInterests"][0]
            self.assertEqual(evidence["field"], "README")
            self.assertEqual(evidence["revision"], self.items[0]["listingCommit"])

    def test_initial_baseline_duplicate_refresh_ack_restart_and_no_detected_alerts(self):
        self.items[0]["name"] = "Orbital widgets"
        self.catalog()
        self.assertEqual(self.save([self.criterion()])["matches"]["unread"], 0)
        self.items.append(self.item("new", "More orbital widgets"))
        self.catalog()
        matches = self.run_action("matches", profile=[app._signal("battery", "Private detected name", {"timer": 30})])["matches"]
        self.assertEqual(matches["unread"], 1)
        self.assertEqual(matches["rows"][0]["matchCause"], "new-listing")
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        self.assertEqual(self.run_action("matches", unreadOnly=True)["matches"]["total"], 1)
        self.run_action("review-matches", pluginIds=["example.one"])
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        self.run_action("review-matches", pluginIds=["example.new"])
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)
        reopened = app.Store(self.preferences.base)
        try:
            reply = app.run({"action": "matches"}, self.store, now=201, preferences_store=reopened)
            self.assertEqual(reply["matches"]["unread"], 0)
        finally:
            reopened.close()
        text = (self.preferences.base / "interests.json").read_text()
        self.assertNotIn("Private detected", text)
        self.assertNotIn("timer", text)

    def test_listing_changes_readme_matches_and_stale_commits(self):
        self.save([self.criterion()])
        self.items[0]["description"] = "Orbital widgets integration."
        self.catalog()
        matches = self.run_action("matches")["matches"]
        self.assertEqual(matches["rows"][0]["matchCause"], "listing-changed")
        self.assertEqual(matches["unread"], 1)
        self.run_action("review-matches", all=True)
        self.index(self.items[1], "Orbital widgets deep in README")
        matches = self.run_action("matches")["matches"]
        self.assertEqual(matches["unread"], 1)
        evidence = matches["rows"][0]["matchedInterests"][0]
        self.assertEqual(evidence["field"], "README")
        self.assertEqual(evidence["term"], "orbital widgets")
        self.assertEqual(matches["rows"][0]["matchCause"], "readme-match")
        self.run_action("review-matches", all=True)
        self.items[1]["listingCommit"] = "f" * 40
        self.catalog()
        matches = self.run_action("matches")["matches"]
        self.assertNotIn("example.two", [row["id"] for row in matches["rows"]])
        self.assertTrue(matches["partial"])
        self.index(self.items[1], "Orbital widgets again")
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)

    def test_edit_baselines_only_changed_interests_and_preserves_other_unread(self):
        saved = self.save([self.criterion(), self.criterion("planet")])["inputs"]["criteria"]
        self.items.append(self.item("new", "Orbital widgets planet"))
        self.catalog()
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        changed = [{**saved[0], "terms": ["timer"], "label": "Timer"}, saved[1]]
        self.assertEqual(self.save(changed)["matches"]["unread"], 1)
        self.run_action("review-matches", all=True)
        self.assertEqual(self.save(changed)["matches"]["unread"], 0)
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)

    def test_missing_failed_catalog_and_corrupt_index_never_false_baseline(self):
        (self.store.base / "catalog.json").unlink()
        reply = self.save([self.criterion()])
        self.assertTrue(reply["matches"]["partial"])
        self.items[0]["name"] = "Orbital widgets"
        self.catalog()
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)
        self.items.append(self.item("new", "Orbital widgets"))
        self.catalog()
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        self.store.write("catalog.json", {"schema": 999}, app.MAX_CACHE_BYTES)
        self.assertTrue(self.run_action("matches")["matches"]["partial"])
        self.catalog()
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        (self.store.base / "readme-search.sqlite").write_bytes(b"invalid SQLite")
        self.save([self.criterion("planet")])
        self.assertTrue(self.run_action("matches")["matches"]["partial"])
        (self.store.base / "readme-search.sqlite").unlink()
        self.index(self.items[0], "planet")
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)

    def test_readme_toggle_failure_and_truncation_do_not_repeat_alerts(self):
        self.save([self.criterion()])
        self.index(self.items[0], "orbital widgets")
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        self.run_action("review-matches", all=True)
        self.run_action("save-preferences", preferences={"readmeEnrichment": False})
        self.assertEqual(self.run_action("matches")["matches"]["total"], 0)
        self.run_action("save-preferences", preferences={"readmeEnrichment": True})
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[0]), {"ok": False}, 300)
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 0)
        self.assertTrue(self.run_action("matches")["matches"]["partial"])

    def test_failed_initial_document_check_defers_baseline_and_preserves_unrelated_checks(self):
        with app.ReadmeIndex(self.store, create=True) as index:
            index.put(app.readme_key(self.items[0]), {"ok": False}, 100)
        self.save([self.criterion()])
        self.items.append(self.item("new", "Orbital widgets"))
        self.catalog()
        self.assertEqual(self.run_action("matches")["matches"]["unread"], 1)
        self.index(self.items[0], "Orbital widgets recovered")
        reply = self.run_action("matches")["matches"]
        self.assertEqual(reply["unread"], 1)
        self.assertFalse(next(row for row in reply["rows"] if row["id"] == "example.one")["unread"])

    def test_saving_with_readmes_disabled_baselines_existing_cached_matches_when_enabled(self):
        self.index(self.items[0], "Orbital widgets")
        self.run_action("save-preferences", preferences={"readmeEnrichment": False})
        self.save([self.criterion()])
        self.run_action("save-preferences", preferences={"readmeEnrichment": True})
        result = self.run_action("matches")["matches"]
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["unread"], 0)

    def test_both_inputs_deduplicate_effects_but_keep_provenance_and_hardware_truthful(self):
        self.items[0]["name"] = "AirPods"
        self.catalog()
        profile = [app._signal("bluetooth-airpods", "AirPods", {"airpods": 24})]
        before = self.run_action("quick-setup", profile=profile, setupSort="recommended")["setup"]["rows"][0]
        self.save([self.criterion("airpods", kind="hardware"), self.criterion("airpods")])
        after = self.run_action("quick-setup", profile=profile, setupSort="recommended")["setup"]["rows"][0]
        self.assertEqual(before["score"], after["score"])
        self.assertTrue(after["evidence"]["hardware"])
        self.assertEqual(len(after["matchedInterests"]), 2)
        self.assertEqual({entry["origin"] for entry in after["evidence"]["interests"]}, {"user"})
        saved = self.run_action("context")["inputs"]["criteria"]
        self.save(saved, ignoredSignals=["bluetooth-airpods"])
        result = self.run_action("quick-setup", profile=profile, setupSort="recommended")["setup"]
        self.assertEqual(result["hardwareMatchCount"], 0)
        self.assertGreater(result["rows"][0]["scores"]["interests"], 0)
        context = self.run_action("context", profile=profile)["inputs"]
        self.assertFalse(context["detected"][0]["enabled"])
        self.assertEqual(context["detected"][0]["method"], "bluetooth")

    def test_index_only_recommendations_have_actual_readme_evidence_and_no_hardware_fit(self):
        self.index(self.items[0], "Introduction. " * 100 + "Orbital widgets")
        self.save([self.criterion()])
        result = self.run_action("quick-setup", setupSort="recommended")["setup"]
        self.assertEqual(result["rows"][0]["id"], self.items[0]["id"])
        self.assertEqual(result["rows"][0]["scores"]["hardware"], 0)
        self.assertEqual(result["rows"][0]["matchedInterests"][0]["field"], "README")
        discover = self.run_action("discover")["discovery"]
        self.assertTrue(any(row["matchedInterests"] for row in discover["rows"]))
        self.assertTrue(all(row["stars"] == 0 for row in discover["rows"]))

    def test_detected_related_terms_are_never_claimed_exact(self):
        item = self.item("one", "Headphones utility")
        details = app.recommendation_details(item, [app._signal("bluetooth-airpods", "AirPods", {"apple headphones": 24})])
        self.assertEqual(details["evidence"]["hardware"][0]["matchType"], "related")
        self.assertIn("related terms", details["reason"])

    def test_shared_detected_software_and_user_effect_use_strongest_evidence_once(self):
        item = self.item("one", "NVIDIA")
        hardware = app._signal("graphics-nvidia", "NVIDIA hardware", {"nvidia": 20})
        software = app._signal("capability-nvidia", "NVIDIA executable", {"nvidia": 10}, source="software")
        first = app.recommendation_details(item, [hardware])
        combined = app.recommendation_details(item, [hardware, software])
        self.assertEqual(first["score"], combined["score"])
        self.assertGreater(combined["scores"]["hardware"], 0)
        self.assertGreater(combined["scores"]["software"], 0)
        item["_interestCriteria"] = [app.validate_criterion(self.criterion("nvidia"))]
        manual = app.recommendation_details(item, [])
        together = app.recommendation_details(item, [hardware, software])
        self.assertEqual(together["score"], max(first["score"], manual["score"]))
        self.assertEqual(len(together["matchedInterests"]), 1)

    def test_pagination_and_realistic_bounded_corpus(self):
        self.items = [self.item(str(index), "Fictional utility " + str(index), listingCommit=f"{index + 1:040x}")
                      for index in range(600)]
        self.catalog()
        criteria = [self.criterion("interest phrase " + str(index), terms=["interest phrase " + str(index),
                    "alternate phrase " + str(index), "service phrase " + str(index), "hardware phrase " + str(index)])
                    for index in range(64)]
        with app.ReadmeIndex(self.store, create=True) as index:
            for item in self.items:
                index.put(app.readme_key(item), {"ok": True, "searchText": "Fictional documentation. " * 600 + " interest phrase 0"}, 100)
        started = time.monotonic()
        result = self.save(criteria)
        self.assertLess(time.monotonic() - started, 12)
        self.assertEqual(result["matches"]["total"], 600)
        self.assertEqual(len(result["matches"]["rows"]), 50)
        self.assertEqual(result["matches"]["pageCount"], 12)
        self.assertEqual(self.run_action("matches", page=999)["matches"]["page"], 12)
        self.assertLess((self.preferences.base / "interests.json").stat().st_size, 200_000)


class DetailedScanTests(unittest.TestCase):
    def setUp(self):
        # Every probe is fictional, including sysfs and executable checks.
        for target, value in (("_read_small", "Fictional"), ("scan_inventory", ([], False))):
            patch = mock.patch.object(app, target, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        for target, value in (("glob", []), ("is_dir", True)):
            patch = mock.patch.object(Path, target, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(app.os.path, "isfile", return_value=False)
        patch.start()
        self.addCleanup(patch.stop)
        patch = mock.patch.object(app.os, "access", return_value=True)
        patch.start()
        self.addCleanup(patch.stop)

    def command(self, argv, *_args):
        if argv[0] == app.COMMANDS["hyprctl"]:
            return b'[{"name":"fictional-one"},{"name":"fictional-two"}]' if argv[-1] == "monitors" else b'{"mice":[{"name":"touchpad"}]}'
        return b""

    def test_success_partial_stale_recovery_and_tuple_compatibility(self):
        with mock.patch.object(app, "run_command", side_effect=self.command):
            result = app.scan_profile()
        signals, unavailable, inventory = result
        self.assertEqual(len(result), 3)
        self.assertEqual(unavailable, [])
        before = app.accepted_scan(result, {}, [], 100)
        self.assertEqual(before["state"], "success")
        def failed(argv, *args):
            if argv[-1] == "monitors":
                raise TimeoutError()
            if argv[-1] == "devices":
                return b'{"mice":[]}'
            return self.command(argv, *args)
        with mock.patch.object(app, "run_command", side_effect=failed):
            partial = app.accepted_scan(app.scan_profile(), before, [], 200)
        self.assertEqual(partial["state"], "partial")
        self.assertEqual([item["id"] for item in partial["observations"]], ["multi-monitor"])
        self.assertTrue(partial["observations"][0]["stale"])
        self.assertEqual(next(probe for probe in partial["probes"] if probe["id"] == "displays")["state"], "stale")
        self.assertEqual(partial["observations"][0]["checkedAt"], 100)
        with mock.patch.object(app, "run_command", side_effect=self.command):
            recovered = app.accepted_scan(app.scan_profile(), partial, [], 300)
        self.assertFalse(any(item["stale"] for item in recovered["observations"]))
        empty = app.accepted_scan(([], [], []), recovered, [], 400)
        self.assertEqual(empty["observations"], [])

    def test_invalid_json_roots_are_failures_and_capabilities_are_software(self):
        def malformed(argv, *_args):
            if argv[0] == app.COMMANDS["hyprctl"]:
                return b'{}' if argv[-1] == "monitors" else b'[]'
            return b""
        with mock.patch.object(app, "run_command", side_effect=malformed), \
                mock.patch.object(app.os.path, "isfile", return_value=True), \
                mock.patch.object(app.os, "access", return_value=True):
            result = app.scan_profile()
        self.assertIn("displays", result[1])
        self.assertIn("input devices", result[1])
        self.assertTrue(all(item["source"] == "software" and item["domain"] == "software" for item in result[0]))
        self.assertTrue(all(item["method"] == "installed-executable" for item in result[0]))

    def test_bluetooth_partial_and_inferred_dock_dependencies(self):
        def partial(argv, *args):
            if argv[0] == app.COMMANDS["bluetoothctl"]:
                if "info" in argv:
                    raise TimeoutError()
                return b"Device 00:11:22:33:44:55 AirPods\n"
            return self.command(argv, *args)
        with mock.patch.object(app, "run_command", side_effect=partial):
            result = app.scan_profile()
        self.assertEqual(next(row for row in result.probes if row["id"] == "Bluetooth")["state"], "partial")
        before = [app._signal("dock-like", "Dock-like setup (inferred)", {"usb-c dock": 20})]
        retained = app.accepted_scan(([], ["displays"], []), {}, before, 200)
        self.assertTrue(retained["observations"][0]["stale"])
        self.assertEqual(retained["observations"][0]["method"], "inferred")

    def test_bluetooth_notifications_do_not_count_as_connected_devices(self):
        calls = []
        def noisy(argv, *args):
            if argv[0] == app.COMMANDS["bluetoothctl"]:
                if "info" in argv:
                    calls.append(argv[-1])
                    return b"Connected: yes\n"
                return (b"[CHG] Controller 00:00:00:00:00:00 Class: 0x000000\n" * 900
                        + b"\x1b[0;32mDevice 00:11:22:33:44:55 AirPods\x1b[0m\n" * 2)
            return self.command(argv, *args)
        with mock.patch.object(app, "run_command", side_effect=noisy):
            result = app.scan_profile()
        self.assertEqual(calls, ["00:11:22:33:44:55"])
        self.assertEqual(next(p for p in result.probes if p["id"] == "Bluetooth")["state"], "success")

    def test_no_bluetooth_controller_is_not_a_successful_empty_scan(self):
        def absent(argv, *args):
            return b"No default controller available\n" if argv[0] == app.COMMANDS["bluetoothctl"] else self.command(argv, *args)
        with mock.patch.object(app, "run_command", side_effect=absent):
            result = app.scan_profile()
        self.assertIn("Bluetooth", result[1])

    def test_bluetooth_only_unique_device_rows_consume_the_eight_device_budget(self):
        calls = []
        def noisy(argv, *args):
            if argv[0] != app.COMMANDS["bluetoothctl"]:
                return self.command(argv, *args)
            if "info" in argv:
                calls.append(argv[-1])
                return b"Connected: yes\n"
            return (b"[NEW] Device AB:11:22:33:44:FF Notification only\n" * 300
                    + b"Device ab:11:22:33:44:00 AirPods\n"
                    + b"Device AB:11:22:33:44:00 AirPods\n"
                    + b"Device bad-address Ignore\n"
                    + b"".join(f"Device AB:11:22:33:44:{i:02X} Controller\n".encode() for i in range(1, 9)))
        with mock.patch.object(app, "run_command", side_effect=noisy):
            result = app.scan_profile()
        self.assertEqual(calls, [f"AB:11:22:33:44:{i:02X}" for i in range(8)])
        self.assertEqual(next(p for p in result.probes if p["id"] == "Bluetooth")["state"], "partial")

    def test_analyze_adds_memory_only_scan_and_accepts_tuple_mocks(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            self.addCleanup(store.close)
            signal = app._signal("battery", "Fictional battery", {"battery": 20})
            with mock.patch.object(app, "scan_profile", return_value=([signal], [], [])), \
                    mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("No network")):
                reply = app.run({"action": "analyze", "localOnly": True}, store, now=100)
            self.assertEqual(reply["scan"]["state"], "success")
            self.assertEqual(reply["scan"]["observations"][0]["id"], "battery")
            with mock.patch.object(app, "scan_profile", return_value=([], ["power"], [])):
                reply = app.run({"action": "rescan", "localOnly": True, "previousScan": reply["scan"]}, store, now=200)
            self.assertTrue(reply["profile"][0]["stale"])
            self.assertFalse(any(path.name.endswith(".json") for path in store.base.iterdir()))

    def test_rescan_accepts_either_scan_field_and_null_placeholders_do_not_clear_observations(self):
        signal = {**app._signal("battery", "Fictional battery", {"battery": 20}), "checkedAt": 100}
        scan = {"state": "success", "checkedAt": 100, "probes": [], "observations": [signal]}
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            self.addCleanup(store.close)
            for payload in ({"scan": scan}, {"previousScan": scan}, {"previousScan": None, "scan": scan},
                            {"previousScan": {}, "scan": scan}, {"profile": [signal]}):
                store.memory.clear()
                with mock.patch.object(app, "scan_profile", return_value=([], ["power"], [])), \
                        mock.patch.object(app, "fetch_bytes", side_effect=AssertionError("No network")):
                    reply = app.run({"action": "rescan", "localOnly": True, **payload}, store, now=200)
                self.assertEqual(reply["profile"][0]["id"], "battery")
                self.assertTrue(reply["profile"][0]["stale"])
                self.assertEqual(reply["profile"][0]["checkedAt"], 100)
                self.assertEqual(reply["scan"]["checkedAt"], 200)


class MutationProgressTests(unittest.TestCase):
    def test_inventory_rejects_malformed_roots_and_entries(self):
        for raw in (b"{}", b"null", b'[{}]', b'["bad"]'):
            with mock.patch.object(app, "run_command", return_value=raw), \
                    mock.patch.object(Path, "iterdir", return_value=iter([])):
                self.assertTrue(app.scan_inventory()[1])

    def test_ambiguous_failure_reconciles_before_retry_and_stops_if_unknown(self):
        command = [app.COMMANDS["omarchy"], "plugin", "enable", "example.widget", "right"]
        target = app.validate_inventory([{"id": "example.widget", "enabled": True, "barSection": "right"}])
        with mock.patch.object(app, "run_command", side_effect=TimeoutError()) as run, \
                mock.patch.object(app, "scan_inventory", return_value=(target, False)) as scan:
            self.assertEqual(app.run_activation_command(command), b"")
            run.assert_called_once()
            scan.assert_called_once()
        with mock.patch.object(app, "run_command", side_effect=TimeoutError()) as run, \
                mock.patch.object(app, "scan_inventory", return_value=([], True)):
            with self.assertRaises(TimeoutError):
                app.run_activation_command(command)
            run.assert_called_once()
        with mock.patch.object(app, "run_command") as run:
            app.run_activation_command(command, target[0])
            run.assert_not_called()
        unknown = [{**target[0], "barSectionKnown": False}]
        with mock.patch.object(app, "run_command", side_effect=TimeoutError()) as run, \
                mock.patch.object(app, "scan_inventory", return_value=(unknown, False)):
            with self.assertRaises(TimeoutError):
                app.run_activation_command(command)
            run.assert_called_once()

    def test_retries_only_after_authoritative_unsatisfied_state(self):
        command = [app.COMMANDS["omarchy"], "plugin", "enable", "example.widget", "right"]
        target = app.validate_inventory([{"id": "example.widget", "enabled": True, "barSection": "left"}])
        with mock.patch.object(app, "run_command", side_effect=[TimeoutError(), b"ok"]) as run, \
                mock.patch.object(app, "scan_inventory", return_value=(target, False)) as scan, \
                mock.patch.object(app.time, "sleep"):
            self.assertEqual(app.run_activation_command(command), b"ok")
            self.assertEqual(run.call_count, 2)
            scan.assert_called_once()

    def test_stream_is_opt_in_bounded_tagged_and_final_identifiable(self):
        with tempfile.TemporaryDirectory() as directory:
            store = app.Store(Path(directory))
            self.addCleanup(store.close)
            target = app.validate_inventory([{"id": "example.widget", "kinds": ["bar-widget"],
                        "enabled": True, "barSection": "right", "canDisable": True}])
            request = {"action": "place-plugin", "pluginId": "example.widget", "barSection": "right", "generation": 123}
            with mock.patch.object(app, "scan_inventory", return_value=(target, False)), \
                    mock.patch.object(app, "installed_revision", return_value=""), \
                    mock.patch.object(app, "run_command") as command, \
                    mock.patch.object(app, "write_response") as progress:
                reply = app.process_request(json.dumps(request).encode(), store, store)
                progress.assert_not_called()
                self.assertNotIn("event", reply)
                request["streamProgress"] = True
                reply = app.process_request(json.dumps(request).encode(), store, store)
                events = [call.args[0] for call in progress.call_args_list]
                self.assertEqual([event["phase"] for event in events], ["checking", "verifying"])
                self.assertTrue(all(event["generation"] == 123 and event["event"] == "progress" for event in events))
                self.assertEqual(reply["event"], "result")
                self.assertTrue(reply["final"])
                command.assert_not_called()
            with mock.patch.object(app, "scan_inventory", return_value=([], True)), \
                    mock.patch.object(app, "write_response"):
                reply = app.process_request(json.dumps(request).encode(), store, store)
            self.assertFalse(reply["ok"])
            self.assertTrue(reply["final"])
