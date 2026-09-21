#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("outfit", ROOT / "scripts" / "outfit.py")
assert SPEC is not None and SPEC.loader is not None
OUTFIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OUTFIT)


class OutfitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = json.loads((ROOT / "demo" / "fixtures" / "example.json").read_text())

    def test_editor_is_tiled_and_service_survives_plugin_rescan(self) -> None:
        manifest = json.loads((ROOT / "manifest.json").read_text())
        editor = (ROOT / "ui" / "OutfitApp.qml").read_text()
        widget = (ROOT / "BarWidget.qml").read_text()

        self.assertTrue(manifest["keepLoaded"])
        self.assertNotIn("fullscreenRequest", editor)
        self.assertNotIn("window.fullscreen", editor)
        self.assertNotIn("Panel.qml", widget)
        self.assertFalse((ROOT / "Panel.qml").exists())

    def test_opening_starts_independent_checks_and_network_controls_are_settings(self) -> None:
        editor = (ROOT / "ui" / "OutfitApp.qml").read_text()
        service = (ROOT / "Service.qml").read_text()
        settings_page = editor.index("id: settingsPage")

        self.assertIn("root.startInventoryCheck()", service)
        self.assertIn("root.refreshCatalog(true)", service)
        self.assertIn("root.preferences.watchHardware !== false && !root.hasAnalyzed", service)
        self.assertIn('backgroundRequest("analyze"', service)
        self.assertIn('accessibleLabel: "Settings"', editor)
        self.assertIn('text: "Back"', editor)
        self.assertGreater(editor.index('label: "Watch hardware every 60 seconds"'), settings_page)
        self.assertGreater(editor.index('label: "Use GitHub READMEs and previews"'), settings_page)

    def test_editor_is_two_columns_without_personalization_rail(self) -> None:
        editor = (ROOT / "ui" / "OutfitApp.qml").read_text()
        service = (ROOT / "Service.qml").read_text()

        self.assertNotIn("WORKFLOW GOALS", editor)
        self.assertNotIn("SOFTWARE YOU CARE ABOUT", editor)
        self.assertNotIn("SHORT FIT NOTE", editor)
        self.assertIn("id: resultList", editor)
        self.assertIn("id: detailSurface", editor)
        self.assertIn("anchors.fill: parent", editor)
        self.assertIn("ToggleSwitch {", editor)
        self.assertIn('root.requestAction("install", resultCard.modelData)', editor)
        self.assertIn('root.requestAction("remove", resultCard.modelData)', editor)
        self.assertIn("property var pluginOperations", service)
        self.assertIn("property var mutationQueue", service)
        self.assertIn("id: mutationWorker", service)
        self.assertIn('command: ["/usr/bin/python3", "-I", "-B", root.helperPath, "--serve"]', service)
        self.assertIn("function effectiveEnabled", service)
        self.assertIn("function applyMutationResponse", service)
        self.assertIn("busy: root.operationPending(resultCard.modelData)", editor)
        self.assertIn("id: queryLaunchDeadline", service)
        self.assertIn("id: mutationLaunchDeadline", service)
        self.assertIn("id: operationReconcile", service)
        self.assertIn('text: root.effectiveInstalled(resultCard.modelData)', editor)
        self.assertIn('? "MOVE WIDGET TO" : "INSTALL LOCATION"', editor)
        self.assertIn('section: "left"', editor)
        self.assertIn('section: "center"', editor)
        self.assertIn('section: "right"', editor)
        self.assertIn('visible: resultCard.index === root.selectedIndex', editor)
        self.assertIn('property string selectedId: ""', editor)
        self.assertIn('workspace.width < Style.space(900)', editor)

        detail = editor[editor.index("id: detailSurface"):editor.index("id: settingsPage")]
        self.assertNotIn('requestAction("install"', detail)
        self.assertNotIn('requestAction("remove"', detail)
        self.assertNotIn("togglePlugin(", detail)
        self.assertIn("openMarketplace(root.selectedRow)", detail)
        self.assertIn("openSource(root.selectedRow)", detail)
        self.assertIn('text: "FROM README"', detail)
        self.assertIn("model: root.detailStatuses(root.selectedRow)", detail)

        result_actions = editor[editor.index("id: resultList"):editor.index("id: detailSurface")]
        self.assertNotIn("openMarketplace(", result_actions)
        self.assertNotIn("openSource(", result_actions)

    def test_quick_scan_unifies_filters_details_and_batch_progress(self) -> None:
        editor = (ROOT / "ui" / "OutfitApp.qml").read_text()
        service = (ROOT / "Service.qml").read_text()

        self.assertIn('"OUTFIT"', editor)
        self.assertNotIn('text: "Fit board"', editor)
        self.assertIn("id: setupBrowsePage", editor)
        self.assertIn("id: setupReviewPage", editor)
        self.assertIn("id: setupProgressPage", editor)
        self.assertIn('text: "Review batch install ("', editor)
        self.assertIn('confirmText: "Install all"', editor)
        self.assertIn("property var setupSelection", service)
        self.assertIn("function startSetupBatch", service)
        self.assertIn("function stopSetupBatch", service)
        self.assertIn("function retrySetupBatch", service)
        self.assertIn("property var pendingSetup", service)
        self.assertIn("property string pendingReadmeId", service)
        self.assertIn("property var readmeMedia", service)
        self.assertIn("function cancelPendingReadme", service)
        self.assertIn("root.pendingSetup = payload", service)
        self.assertIn("setup.setupServices, setup.setupServiceFilter", service)
        self.assertIn('path: root.batchJournalPath', service)
        self.assertIn("function restoreBatchJournal", service)
        self.assertIn("function scheduleBatchAdvance", service)
        self.assertIn("property var serviceOptions", service)
        self.assertIn("function saveServiceChoices", service)
        self.assertIn('result.errorCode === "inventory-unavailable"', service)
        self.assertIn("attempts: attempts + 1", service)
        self.assertNotIn("scheduleBatchAdvance(8000)", service)
        self.assertIn("id: setupCandidateGrid", editor)
        self.assertIn("component SetupPluginCard", editor)
        self.assertIn("component SetupDetailPanel", editor)
        self.assertIn("component ReadmeMediaPreview", editor)
        video = (ROOT / "ui" / "DemoVideo.qml").read_text()
        self.assertNotIn("import QtMultimedia", editor)
        self.assertIn("import QtMultimedia", video)
        self.assertIn('"Play demo"', editor)
        self.assertIn("autoPlay: true", video)
        self.assertIn("muted: true", video)
        self.assertIn("root.trustedPreviewUrl", editor)
        self.assertIn("root.trustedLocalPreviewUrl", editor)
        self.assertNotIn("AnimatedImage", editor)
        self.assertIn("property string requestedReadmeId", service)
        self.assertIn("setupDetailPanel.stopMedia()", editor)
        self.assertIn("acceptedButtons: Qt.AllButtons", editor)
        self.assertIn("setupDetailPanel.takeFocus()", editor)
        self.assertIn("property bool setupDetailFocusPending", editor)
        self.assertIn("function restoreSetupDetailFocus", editor)
        self.assertIn("id: setupDetailPanel", editor)
        self.assertIn("id: setupInspectorScroll", editor)
        self.assertGreaterEqual(editor.count("anchors.leftMargin: Style.space(16)"), 1)
        self.assertGreaterEqual(editor.count("anchors.rightMargin: Style.space(16)"), 1)
        self.assertIn("function openSetupDetail", editor)
        self.assertIn('root.activeView === "setup" && root.setupDetailId', editor)
        self.assertIn('String(setupReviewCard.modelData.category || "Other")', editor)
        analyzed_handler = editor[
            editor.index("function onCacheLoadedChanged()"):
            editor.index("function onBatchRunningChanged()")
        ]
        self.assertNotIn("!root.service.busy", analyzed_handler)
        self.assertIn("root.service.setupQuery", analyzed_handler)
        self.assertIn("root.service.setupSort", analyzed_handler)
        self.assertIn("id: setupServicesPage", editor)
        self.assertIn("component ServiceChoiceCard", editor)
        self.assertIn('text: "Setup & interests…"', editor)
        self.assertNotIn('text: "All selected"', editor)

        selection_block = service[
            service.index("function setSetupSelected"):
            service.index("function setupSelected")
        ]
        readme_block = service[
            service.index("function loadReadme"):
            service.index("function safeEditorPayload")
        ]
        self.assertNotIn("requestedReadmeId", selection_block)
        self.assertIn("root.requestedReadmeId = identity", readme_block)
        self.assertIn('root.activeAction === "readme-plugin"', readme_block)
        self.assertIn("worker.running = false", readme_block)

        cancel_action = editor[
            editor.index("function cancelAction"):
            editor.index("function confirmAction")
        ]
        search_shortcut = editor[
            editor.index("event.key === Qt.Key_F"):
            editor.index("id: workspace", editor.index("event.key === Qt.Key_F"))
        ]
        self.assertIn("setupDetailPanel.takeFocus()", cancel_action)
        self.assertIn("root.closeSetupDetail()", search_shortcut)
        self.assertIn('text: "Cancel"', editor)
        self.assertIn("id: setupCatalogScroll", editor)
        self.assertIn("width: setupCatalogScroll.availableWidth", editor)
        self.assertIn("id: setupFilterSidebar", editor)
        self.assertIn("id: setupActiveFilters", editor)
        self.assertIn("id: setupStatusMessage", editor)
        self.assertIn("id: quickSetupStatusText", editor)
        self.assertIn('text: root.service ? root.service.error : ""', editor)
        self.assertIn('text: "Browse all"', editor)
        self.assertIn('root.chooseSetupFilters("installed", "")', editor)
        self.assertIn('root.chooseSetupFilters("", "first-party")', editor)
        self.assertIn("function toggleSetupService", editor)
        self.assertIn("function chooseSetupHardware", editor)
        self.assertIn("function chooseSetupCategory", editor)
        self.assertIn("var activeServices = []", editor)
        self.assertIn("service.placementChoices = next", editor)
        self.assertIn("state.actualSection === section", editor)
        self.assertIn('"ON THIS COMPUTER"', editor)
        self.assertIn('"Remove from batch" : "Add to batch install"', editor)
        self.assertIn('root.requestAction("remove", setupInspector.row)', editor)
        self.assertIn("property var setupFilterCounts", service)
        self.assertIn("setup.setupInstallFilter, setup.setupPartyFilter", service)
        self.assertIn("property bool setupHardwareOnly", service)
        self.assertIn("property string setupCategory", service)
        self.assertIn('property string setupDetailId: ""', service)
        self.assertIn("property var placementChoices", service)
        self.assertIn("commandFailed: true", service)
        self.assertIn("operation.commandFailed === true", service)
        self.assertIn("property string setupRefreshNotice", service)
        self.assertIn("property string setupRefreshError", service)
        self.assertIn("partialOutcome: true", service)
        self.assertIn('"refresh", "readme-plugin"', service)
        self.assertIn("root.setupServiceIds = selectedServices", service)
        header_actions = editor[editor.index("id: headerActions"):editor.index("id: filters")]
        self.assertNotIn('root.activeView === "fit"', header_actions)
        self.assertNotIn("root.queueCurrentSetup()", header_actions)
        self.assertIn('root.service.rescan(false)', header_actions)
        self.assertIn('root.service.refresh(root.service.currentQuery, root.service.currentCategory)', header_actions)

        widget = (ROOT / "BarWidget.qml").read_text()
        self.assertIn('view: "setup"', widget)
        self.assertIn("setupServices: fitService ? fitService.setupServiceIds : []", widget)
        self.assertIn("selectedId: fitService ? fitService.setupDetailId", widget)

        helper = (ROOT / "scripts" / "outfit.py").read_text()
        self.assertIn('environment["OMARCHY_SHELL_IPC_TIMEOUT"] = "30s"', helper)

        progress = editor[editor.index("id: setupProgressPage"):editor.index("id: actionConfirm")]
        self.assertGreaterEqual(progress.count("focusable: true"), 4)

    def test_catalog_normalization_and_ranking(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        rows = OUTFIT.ranked_rows(items, self.fixture["profile"], set(), "", "")

        self.assertEqual(generated, "2026-01-15T12:00:00Z")
        self.assertEqual(len(items), 3)
        self.assertEqual(rows[0]["id"], "example.dock-helper")
        self.assertEqual(rows[0]["reviewState"], "reviewed snapshot")
        self.assertTrue(rows[0]["installAvailable"])
        self.assertTrue(rows[0]["barWidget"])
        self.assertEqual(rows[0]["barSection"], "")
        self.assertEqual(rows[0]["repo"], "https://github.com/example/dock-helper")
        self.assertEqual(
            rows[0]["installNote"],
            "Connect the fictional dock before opening the widget.",
        )

    def test_catalog_cache_round_trip_preserves_commits(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                restored, fetched_at, restored_generated = OUTFIT.load_catalog(store)
            finally:
                store.close()

        self.assertEqual(restored, items)
        self.assertEqual(fetched_at, 1234.5)
        self.assertEqual(restored_generated, generated)
        self.assertEqual(restored[0]["listingCommit"], "a" * 40)

    def test_catalog_is_prepared_once_per_helper_session(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                first = OUTFIT.load_catalog(store)
                with mock.patch.object(store, "read", wraps=store.read) as read:
                    second = OUTFIT.load_catalog(store)
            finally:
                store.close()

        read.assert_not_called()
        self.assertIs(first, second)

    def test_query_ranking_scores_only_matching_plugins(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with mock.patch.object(
            OUTFIT, "recommendation_details", wraps=OUTFIT.recommendation_details,
        ) as recommendation:
            rows = OUTFIT.ranked_rows(
                items, self.fixture["profile"], set(), "no-such-plugin-term", "",
            )

        self.assertEqual(rows, [])
        recommendation.assert_not_called()

    def test_quick_setup_groups_zero_fit_plugins_and_exposes_rank_parts(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])

        setup = OUTFIT.setup_catalog(items, self.fixture["profile"], set())

        rows = {row["id"]: row for row in setup["rows"]}
        self.assertFalse(setup["overview"])
        self.assertIn("example.quiet-hours", rows)
        self.assertEqual(rows["example.quiet-hours"]["score"], 0)
        self.assertGreater(rows["example.quiet-hours"]["popularityScore"], 0)
        self.assertEqual(rows["example.quiet-hours"]["setupGroup"], "productivity")
        self.assertEqual(rows["example.dock-helper"]["setupGroup"], "hardware")
        self.assertGreater(rows["example.dock-helper"]["recommendationScore"], 0)
        self.assertTrue(rows["example.dock-helper"]["selectable"])

    def test_service_registry_is_unique_bounded_and_has_catalog_coverage(self) -> None:
        services = OUTFIT.load_service_registry()

        self.assertEqual(len(services), 38)
        self.assertEqual(len({service["id"] for service in services}), len(services))
        self.assertEqual(services[0]["id"], "spotify")
        self.assertIn("Network & privacy", {service["category"] for service in services})

    def test_service_matching_uses_curated_fields_and_exceptions(self) -> None:
        spotify = {
            "id": "example.spotify-controls",
            "name": "Media Controls",
            "description": "Playback controls for Spotify and other players.",
            "tags": ["music"],
            "category": "Media",
        }
        unrelated_github_id = {
            "id": "io.github.example.weather",
            "name": "Weather",
            "description": "A ten-day forecast.",
            "tags": ["weather"],
            "category": "System",
        }
        outlook = {
            "id": "example.weather-outlook",
            "name": "Weather Outlook",
            "description": "Tomorrow's weather outlook.",
            "tags": ["weather"],
            "category": "System",
        }
        slack_style = {
            "id": "io.github.joshferrara.quick-emoji",
            "name": "Quick Emoji",
            "description": "Slack-style emoji completion.",
            "tags": ["emoji"],
            "category": "Productivity",
        }
        steam_pun = {
            "id": "io.github.ejuro.blow-off-some-steam",
            "name": "Blow off some steam",
            "description": "Wreck a frozen desktop snapshot.",
            "tags": ["fun"],
            "category": "Games",
        }
        split_google_calendar = {
            "id": "example.google-calendar-words",
            "name": "Google",
            "description": "A generic search helper.",
            "tags": ["calendar"],
            "category": "Productivity",
        }

        self.assertEqual(
            [match["id"] for match in OUTFIT.service_matches(spotify)], ["spotify"],
        )
        self.assertNotIn("github", {match["id"] for match in OUTFIT.service_matches(unrelated_github_id)})
        self.assertNotIn("outlook", {match["id"] for match in OUTFIT.service_matches(outlook)})
        self.assertNotIn("slack", {match["id"] for match in OUTFIT.service_matches(slack_style)})
        self.assertNotIn("steam", {match["id"] for match in OUTFIT.service_matches(steam_pun)})
        self.assertNotIn(
            "google-calendar",
            {match["id"] for match in OUTFIT.service_matches(split_google_calendar)},
        )

    def test_service_setup_is_deduplicated_popular_and_focusable(self) -> None:
        def plugin(
            identity: str, name: str, description: str, stars: int, installable: bool,
        ) -> dict[str, object]:
            return {
                "id": identity,
                "name": name,
                "description": description,
                "author": "Fixture",
                "version": "1.0.0",
                "category": "Productivity",
                "tags": [],
                "kind": "Panel",
                "status": "Install" if installable else "Manual setup",
                "repo": f"https://github.com/example/{identity}",
                "sourceType": "community",
                "listingValidatedCommit": (identity[0] * 40)[:40],
                "installAvailable": installable,
                "stars": stars,
            }

        catalog = {
            "generatedAt": "2026-01-01T00:00:00Z",
            "plugins": [
                plugin("aaa.spotify", "Spotify Desktop", "Spotify player.", 200, False),
                plugin("bbb.todoist", "Todoist", "Todoist tasks.", 50, True),
                plugin("ccc.bridge", "Daily Bridge", "Spotify playback and Todoist tasks.", 20, True),
            ],
        }
        items, _generated = OUTFIT.normalize_catalog(catalog)

        combined = OUTFIT.setup_catalog(
            items, [], set(), sort="stars", service_ids=["spotify", "todoist"],
        )
        focused = OUTFIT.setup_catalog(
            items, [], set(), sort="stars",
            service_ids=["spotify", "todoist"], service_filter="todoist",
        )

        self.assertTrue(combined["serviceMode"])
        self.assertFalse(combined["overview"])
        self.assertEqual(
            [row["id"] for row in combined["rows"]],
            ["aaa.spotify", "bbb.todoist", "ccc.bridge"],
        )
        shared = next(row for row in combined["rows"] if row["id"] == "ccc.bridge")
        self.assertEqual(
            [match["id"] for match in shared["matchedServices"]],
            ["spotify", "todoist"],
        )
        self.assertEqual(
            [row["id"] for row in focused["rows"]], ["bbb.todoist", "ccc.bridge"],
        )
        self.assertEqual(focused["selectedServices"], ["todoist"])
        self.assertEqual(focused["serviceFilter"], "")

    def test_service_popularity_ties_use_name_not_hardware_fit(self) -> None:
        catalog = {
            "generatedAt": "2026-01-01T00:00:00Z",
            "plugins": [
                {
                    "id": "example.alpha",
                    "name": "Alpha Spotify",
                    "description": "Spotify controls.",
                    "category": "Media",
                    "tags": [],
                    "kind": "Panel",
                    "sourceType": "community",
                    "repo": "https://github.com/example/alpha",
                    "listingValidatedCommit": "a" * 40,
                    "installAvailable": True,
                    "stars": 10,
                },
                {
                    "id": "example.zulu",
                    "name": "Zulu Spotify Dock",
                    "description": "Spotify controls for a USB-C dock.",
                    "category": "Media",
                    "tags": ["dock"],
                    "kind": "Panel",
                    "sourceType": "community",
                    "repo": "https://github.com/example/zulu",
                    "listingValidatedCommit": "b" * 40,
                    "installAvailable": True,
                    "stars": 10,
                },
            ],
        }
        items, _generated = OUTFIT.normalize_catalog(catalog)

        result = OUTFIT.setup_catalog(
            items, self.fixture["profile"], set(), sort="stars", service_ids=["spotify"],
        )

        self.assertGreater(result["rows"][1]["score"], result["rows"][0]["score"])
        self.assertEqual([row["id"] for row in result["rows"]], ["example.alpha", "example.zulu"])

    def test_service_match_cache_survives_inventory_merge(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        items[0]["description"] += " Spotify playback."
        first = OUTFIT.service_matches(items[0])

        merged = OUTFIT.merge_inventory(items, [])
        with mock.patch.object(OUTFIT, "_service_term_pattern") as pattern:
            second = OUTFIT.service_matches(merged[0])

        self.assertEqual(second, first)
        pattern.assert_not_called()

    def test_preference_save_returns_without_catalog_or_ranking_work(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            preferences_store = OUTFIT.Store(Path(directory) / "config")
            try:
                with (
                    mock.patch.object(OUTFIT, "load_catalog") as load_catalog,
                    mock.patch.object(OUTFIT, "ranked_rows") as ranked_rows,
                ):
                    result = OUTFIT.run({
                        "action": "save-preferences",
                        "preferences": {
                            "services": ["spotify"],
                            "servicesOnboardingComplete": True,
                        },
                    }, store, now=2000, preferences_store=preferences_store)
            finally:
                store.close()
                preferences_store.close()

        self.assertEqual(result["responseKind"], "preferences")
        self.assertEqual(result["preferences"]["services"], ["spotify"])
        load_catalog.assert_not_called()
        ranked_rows.assert_not_called()

    def test_quick_setup_keeps_saved_services_inactive_by_default(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        items[0]["description"] += " Includes Spotify playback controls."
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            preferences_store = OUTFIT.Store(Path(directory) / "config")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                OUTFIT.save_preferences(preferences_store, {
                    **OUTFIT.DEFAULT_PREFERENCES,
                    "services": ["spotify"],
                    "servicesOnboardingComplete": True,
                })
                result = OUTFIT.run(
                    {"action": "quick-setup", "profile": [], "inventory": []},
                    store, now=2000, preferences_store=preferences_store,
                )
            finally:
                store.close()
                preferences_store.close()

        self.assertFalse(result["setup"]["serviceMode"])
        self.assertEqual(result["setup"]["selectedServices"], [])
        self.assertEqual(
            next(
                service["id"] for service in result["setup"]["services"]
                if service["id"] == "spotify"
            ),
            "spotify",
        )

    def test_quick_setup_classifies_each_catalog_row_once(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        eligible = sum(
            item.get("localOnly") is not True and item.get("party") != "first-party"
            for item in items
        )
        with mock.patch.object(OUTFIT, "setup_group", wraps=OUTFIT.setup_group) as group:
            OUTFIT.setup_catalog(items, self.fixture["profile"], set())

        self.assertEqual(group.call_count, eligible)

    def test_quick_setup_group_pagination_and_search_are_deterministic(self) -> None:
        catalog = {
            "generatedAt": "2026-01-01T00:00:00Z",
            "plugins": [{
                "id": f"example.productivity-{index:02d}",
                "name": f"Task Helper {index:02d}",
                "description": "Task and calendar helper.",
                "author": "Fixture",
                "version": "1.0.0",
                "category": "Productivity",
                "tags": ["tasks"],
                "kind": "Panel",
                "status": "Install",
                "repo": f"https://github.com/example/task-helper-{index:02d}",
                "sourceType": "community",
                "listingValidatedCommit": f"{index + 1:040x}",
                "installAvailable": True,
                "stars": index,
            } for index in range(45)],
        }
        items, _generated = OUTFIT.normalize_catalog(catalog)

        first = OUTFIT.setup_catalog(
            items, [], set(), group="productivity", sort="stars", page=1, page_size=12,
        )
        second = OUTFIT.setup_catalog(
            items, [], set(), group="productivity", sort="stars", page=2, page_size=12,
        )
        overview = OUTFIT.setup_catalog(items, [], set(), sort="stars")
        searched = OUTFIT.setup_catalog(
            items, [], set(), query="Task Helper 07", sort="recommended",
        )
        popular_search = OUTFIT.setup_catalog(
            items, [], set(), query="Task Helper", group="productivity", sort="stars",
        )

        self.assertEqual(first["pageCount"], 4)
        self.assertEqual(first["rows"][0]["id"], "example.productivity-44")
        self.assertEqual(second["rows"][0]["id"], "example.productivity-32")
        self.assertEqual(len(overview["rows"]), OUTFIT.SETUP_PAGE_SIZE)
        # Complete word coverage determines membership before the chosen sort.
        self.assertEqual(searched["total"], 1)
        self.assertEqual(searched["rows"][0]["id"], "example.productivity-07")
        self.assertEqual(popular_search["rows"][0]["id"], "example.productivity-44")

    def test_quick_setup_can_classify_purpose_from_cached_readme(self) -> None:
        item = {
            "id": "example.companion",
            "name": "Companion",
            "description": "A useful extension.",
            "category": "Other",
            "tags": [],
            "_readme": "A VPN dashboard with network privacy controls.",
        }

        self.assertEqual(OUTFIT.setup_group(item), "other")
        self.assertEqual(OUTFIT.setup_group(item, include_readme=True), "network-privacy")

    def test_quick_setup_filters_merged_inventory_by_status_and_source(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        inventory = OUTFIT.validate_inventory([
            {
                "id": "example.dock-helper",
                "name": "Dock Helper",
                "kinds": ["bar-widget"],
                "enabled": True,
                "active": True,
                "canDisable": True,
                "firstParty": True,
            },
            {
                "id": "example.quiet-hours",
                "name": "Quiet Hours",
                "kinds": ["service"],
                "enabled": True,
                "active": True,
                "canDisable": True,
                "firstParty": False,
            },
            {
                "id": "omarchy.audio",
                "name": "Audio",
                "kinds": ["bar-widget"],
                "enabled": True,
                "active": True,
                "canDisable": False,
                "firstParty": True,
            },
        ])
        merged = OUTFIT.merge_inventory(items, inventory)
        installed = {item["id"] for item in inventory}

        first_party = OUTFIT.setup_catalog(
            merged, [], installed, sort="name", party_filter="first-party",
        )
        installed_rows = OUTFIT.setup_catalog(
            merged, [], installed, sort="name", install_filter="installed",
        )
        available = OUTFIT.setup_catalog(
            merged, [], installed, sort="name", install_filter="available",
        )

        self.assertFalse(first_party["overview"])
        self.assertEqual(first_party["partyFilter"], "first-party")
        self.assertEqual(
            {row["id"] for row in first_party["rows"]},
            {"example.dock-helper", "omarchy.audio"},
        )
        self.assertTrue(all(row["firstParty"] for row in first_party["rows"]))
        self.assertEqual(len(installed_rows["rows"]), 3)
        self.assertEqual(
            [row["id"] for row in available["rows"]], ["example.workspace-map"],
        )
        self.assertEqual(first_party["filterCounts"], {
            "all": 2,
            "installed": 2,
            "available": 0,
            "firstParty": 2,
            "thirdParty": 2,
        })
        self.assertEqual(available["filterCounts"], {
            "all": 4,
            "installed": 3,
            "available": 1,
            "firstParty": 0,
            "thirdParty": 1,
        })

    def test_quick_scan_combines_purpose_category_and_hardware_filters(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])

        hardware = OUTFIT.setup_catalog(
            items, self.fixture["profile"], set(), sort="name", hardware_only=True,
        )
        category = OUTFIT.setup_catalog(
            items, self.fixture["profile"], set(), sort="name", category="Hardware",
        )
        purpose_and_category = OUTFIT.setup_catalog(
            items, self.fixture["profile"], set(), sort="name",
            group="hardware", category="Hardware", hardware_only=True,
        )

        self.assertEqual(
            [row["id"] for row in hardware["rows"]],
            ["example.dock-helper", "example.workspace-map"],
        )
        self.assertEqual(hardware["hardwareMatchCount"], 2)
        self.assertTrue(hardware["hardwareOnly"])
        self.assertEqual(
            [row["id"] for row in category["rows"]], ["example.dock-helper"],
        )
        self.assertEqual(category["category"], "Hardware")
        self.assertEqual(
            [row["id"] for row in purpose_and_category["rows"]],
            ["example.dock-helper"],
        )

    def test_quick_setup_exposes_cached_readme_details(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                OUTFIT.save_readmes(store, {
                    "example.dock-helper": {
                        "commit": "a" * 40,
                        "summary": "A cached detail summary.",
                        "content": "Full cached detail text.",
                        "contentVersion": OUTFIT.README_CONTENT_VERSION,
                        "fetchedAt": 1234.5,
                    },
                })
                result = OUTFIT.run({
                    "action": "quick-setup",
                    "profile": self.fixture["profile"],
                    "inventory": [],
                }, store, now=2000)
                searched = OUTFIT.run({
                    "action": "quick-setup",
                    "profile": self.fixture["profile"],
                    "inventory": [],
                    "setupQuery": "Full cached detail text",
                }, store, now=2000)
            finally:
                store.close()

        row = next(row for row in result["setup"]["rows"] if row["id"] == "example.dock-helper")
        self.assertTrue(row["readmeAvailable"])
        self.assertTrue(row["readmeMediaIndexed"])
        self.assertEqual(row["readmeMedia"], [])
        self.assertEqual(row["readmeSummary"], "A cached detail summary.")
        self.assertEqual(
            [row["id"] for row in searched["setup"]["rows"]],
            ["example.dock-helper"],
        )

    def test_search_request_uses_saved_profile_without_scanning(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with mock.patch.object(OUTFIT, "enrich_readmes", return_value=0) as enrich:
                    result = OUTFIT.run({
                        "action": "search",
                        "generation": 7,
                        "profile": self.fixture["profile"],
                        "installed": [],
                        "query": "dock",
                    }, store, now=2000)
            finally:
                store.close()

        self.assertTrue(result["ok"])
        self.assertEqual(result["generation"], 7)
        self.assertEqual(result["rows"][0]["id"], "example.dock-helper")
        self.assertEqual(result["readmesFetched"], 0)
        enrich.assert_not_called()

    def test_error_response_preserves_request_correlation_and_retryability(self) -> None:
        result = OUTFIT.error_response(
            ValueError("Outfit could not verify authoritative plugin inventory."),
            {"action": "enable-plugin", "generation": 19},
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["action"], "enable-plugin")
        self.assertEqual(result["generation"], 19)
        self.assertEqual(result["errorCode"], "inventory-unavailable")
        self.assertTrue(result["retryable"])

    def test_oversized_request_read_is_bounded_without_draining_the_stream(self) -> None:
        next_request = b'{"action":"load","generation":2}\n'
        stream = io.BytesIO(b"x" * (OUTFIT.MAX_REQUEST_BYTES + 32) + b"\n" + next_request)

        oversized = OUTFIT.read_request(stream)
        self.assertGreater(len(oversized), OUTFIT.MAX_REQUEST_BYTES)
        self.assertEqual(stream.tell(), OUTFIT.MAX_REQUEST_BYTES + 1)
        # serve() terminates this invalid framing instead of draining forever.

    def test_protocol_response_escapes_unicode_for_bounded_chunk_framing(self) -> None:
        stream = io.BytesIO()
        stdout = mock.Mock(buffer=stream)

        with mock.patch.object(OUTFIT.sys, "stdout", stdout):
            OUTFIT.write_response({
                "ok": True,
                "generation": 3,
                "action": "verify-inventory",
                "message": "界",
            })

        output = stream.getvalue()
        self.assertTrue(output.isascii())
        self.assertIn(b"\\u754c", output)
        self.assertEqual(json.loads(output)["message"], "界")
        self.assertTrue(json.loads(output)["ok"])

    def test_protocol_response_escapes_lone_unicode_surrogates(self) -> None:
        stream = io.BytesIO()
        stdout = mock.Mock(buffer=stream)

        with mock.patch.object(OUTFIT.sys, "stdout", stdout):
            OUTFIT.write_response({"ok": True, "message": "\ud800"})

        self.assertEqual(json.loads(stream.getvalue())["message"], "\ud800")

    def test_readme_can_supply_the_match_reason(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        quiet_hours = next(item for item in items if item["id"] == "example.quiet-hours")
        quiet_hours["_readme"] = "Designed for USB-C dock controls and docking stations."

        score, reason = OUTFIT.recommendation_score(quiet_hours, self.fixture["profile"])

        self.assertGreater(score, 0)
        self.assertIn("README", reason)

    def test_readme_content_is_clean_structured_plain_text(self) -> None:
        source = """---
private: metadata
---
# Dock Helper

[![build](https://badges.example/build.svg)](https://badges.example)

Controls USB-C and Thunderbolt docking stations from a compact Omarchy widget.
It keeps display and device state visible without opening another application.

## Features

- Detects connected docks
- Shows display state

## Installation

```bash
omarchy plugin add https://github.com/example/dock-helper
```
"""
        content = OUTFIT.markdown_content(source)
        summary = OUTFIT.readme_summary(content, "Dock Helper")

        self.assertNotIn("private: metadata", content)
        self.assertNotIn("badges.example", content)
        self.assertNotIn("```", content)
        self.assertIn("Controls USB-C", content)
        self.assertIn("- Detects connected docks", content)
        self.assertIn("$ omarchy plugin add", content)
        self.assertTrue(summary.startswith("Controls USB-C"))
        self.assertNotIn("Installation", summary)

    def test_readme_media_keeps_useful_images_and_pins_repository_paths(self) -> None:
        item = {
            "owner": "example",
            "repoName": "dock-helper",
            "listingCommit": "a" * 40,
        }
        source = """
[![build](https://img.shields.io/badge/build-passing.svg)](https://example.com)
![Main plugin preview](preview.png)
<img src="https://github.com/example/dock-helper/blob/main/docs/screenshot.webp" alt="Settings screenshot">
<img src="tiny-icon.png" alt="status icon" width="64">
![Traversal](../private.png)
![External screenshot](https://tracking.example/screenshot.png)
"""

        media = OUTFIT.readme_media(source, item)

        self.assertEqual([entry["kind"] for entry in media], ["image", "image"])
        self.assertEqual(
            {entry["url"] for entry in media},
            {
                "https://raw.githubusercontent.com/example/dock-helper/"
                + "a" * 40 + "/preview.png",
                "https://raw.githubusercontent.com/example/dock-helper/"
                + "a" * 40 + "/docs/screenshot.webp",
            },
        )

    def test_readme_media_supports_inline_and_external_video(self) -> None:
        item = {
            "owner": "example",
            "repoName": "dock-helper",
            "listingCommit": "b" * 40,
        }
        attachment = "https://github.com/user-attachments/assets/12345678-1234-1234-1234-123456789abc"
        source = f"""
[![Demo preview](docs/poster.webp)](docs/demo.mp4)
{attachment}
[Watch the walkthrough](https://youtu.be/AbCdEf12345)
"""

        media = OUTFIT.readme_media(source, item)

        inline = next(entry for entry in media if entry["url"].endswith("/docs/demo.mp4"))
        self.assertEqual(inline["kind"], "video")
        self.assertTrue(inline["poster"].endswith("/docs/poster.webp"))
        self.assertIn(
            {"kind": "video", "url": attachment, "poster": "", "label": "Demo video"},
            media,
        )
        self.assertIn(
            {
                "kind": "external-video",
                "url": "https://www.youtube.com/watch?v=AbCdEf12345",
                "poster": "",
                "label": "Watch the walkthrough",
            },
            media,
        )

    def test_readme_media_is_bounded_and_cache_urls_are_revalidated(self) -> None:
        item = {
            "owner": "example",
            "repoName": "dock-helper",
            "listingCommit": "c" * 40,
        }
        source = "\n".join(
            f"![Preview {index}](docs/preview-{index}.png)" for index in range(10)
        )
        media = OUTFIT.readme_media(source, item)
        restored = OUTFIT.validate_readme_media(media + [{
            "kind": "image",
            "url": "https://tracking.example/pixel.png",
            "label": "Tracker",
        }])

        self.assertEqual(len(media), OUTFIT.MAX_README_MEDIA)
        self.assertEqual(restored, media)

    def test_readme_media_decodes_paths_once_and_pins_branch_urls(self) -> None:
        item = {
            "owner": "example",
            "repoName": "dock-helper",
            "listingCommit": "d" * 40,
        }

        relative = OUTFIT._readme_media_url("docs/preview%20shot.png", item, "image")
        branch = OUTFIT._readme_media_url(
            "https://raw.githubusercontent.com/example/dock-helper/refs/heads/main/"
            "docs/preview%20shot.png",
            item,
            "image",
        )
        traversal = OUTFIT._readme_media_url("docs/%2e%2e/private.png", item, "image")

        expected = "https://raw.githubusercontent.com/example/dock-helper/" \
            + "d" * 40 + "/docs/preview%20shot.png"
        self.assertEqual(relative, ("image", expected))
        self.assertEqual(branch, ("image", expected))
        self.assertIsNone(traversal)

    def test_malformed_readme_markup_is_bounded_and_drops_open_comments(self) -> None:
        item = {
            "owner": "example",
            "repoName": "dock-helper",
            "listingCommit": "e" * 40,
        }
        malformed = ("<video " * 30_000) + "<!-- hidden text"
        malformed_markdown = "![" * 60_000
        malformed_destinations = "![preview](" * 20_000

        self.assertEqual(OUTFIT.readme_media(malformed, item), [])
        self.assertEqual(OUTFIT.readme_media(malformed_markdown, item), [])
        self.assertEqual(OUTFIT.readme_media(malformed_destinations, item), [])
        self.assertTrue(OUTFIT.markdown_text(malformed_markdown))
        self.assertTrue(OUTFIT.markdown_content(malformed_markdown))
        self.assertNotIn("hidden text", OUTFIT.markdown_content("Visible\n<!-- hidden text"))

    def test_preview_redirect_accepts_github_asset_host_and_rejects_other_hops(self) -> None:
        handler = OUTFIT.RestrictedMediaRedirect("github.com")
        attachment = OUTFIT.urllib.request.Request(
            "https://github.com/user-attachments/assets/12345678-1234-1234-1234-123456789abc",
        )
        asset_url = "https://github-production-user-asset-6210df.s3.amazonaws.com/asset.png"

        redirected = handler.redirect_request(attachment, None, 302, "Found", {}, asset_url)

        self.assertEqual(redirected.full_url, asset_url)
        asset_request = OUTFIT.urllib.request.Request(asset_url)
        with self.assertRaisesRegex(ValueError, "approved host"):
            handler.redirect_request(
                asset_request, None, 302, "Found", {}, "https://tracking.example/asset.png",
            )

    def test_preview_images_are_bounded_and_materialized_with_fresh_local_urls(self) -> None:
        width = 800
        height = 450
        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 \
            + width.to_bytes(4, "big") + height.to_bytes(4, "big")
        media = [{
            "kind": "image",
            "url": "https://raw.githubusercontent.com/example/dock-helper/"
                + "a" * 40 + "/preview.png",
            "poster": "",
            "label": "Dock Helper preview",
        }]
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache"
            store = OUTFIT.Store(cache)
            try:
                with mock.patch.object(
                    OUTFIT, "fetch_preview_image", return_value=(png, "png"),
                ):
                    first = OUTFIT.materialize_readme_media(store, media)
                    second = OUTFIT.materialize_readme_media(store, media)
                files = [path.name for path in cache.iterdir() if path.name.startswith("preview-")]
            finally:
                store.close()

        self.assertRegex(first[0]["localSource"], r"/preview-0-[0-9a-f]{12}\.png$")
        self.assertRegex(second[0]["localSource"], r"/preview-0-[0-9a-f]{12}\.png$")
        self.assertNotEqual(first[0]["localSource"], second[0]["localSource"])
        self.assertEqual(len(files), 1)

        oversized = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 \
            + (3000).to_bytes(4, "big") + (3000).to_bytes(4, "big")
        opener = mock.MagicMock()
        response = mock.MagicMock()
        response.headers = {"Content-Length": str(len(oversized))}
        response.read.side_effect = [oversized, b""]
        opener.open.return_value.__enter__.return_value = response
        with mock.patch.object(OUTFIT.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "dimensions"):
                OUTFIT.fetch_preview_image(media[0]["url"])

    def test_legacy_readme_cache_remains_searchable_and_gains_a_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                store.write("readmes.json", {
                    "schema": OUTFIT.README_SCHEMA,
                    "entries": {
                        "example.dock-helper": {
                            "commit": "a" * 40,
                            "text": "Dock Helper controls USB-C docking stations with useful display status.",
                            "fetchedAt": 1234.5,
                        },
                    },
                }, OUTFIT.MAX_CACHE_BYTES)
                restored = OUTFIT.load_readmes(store)
            finally:
                store.close()

        entry = restored["example.dock-helper"]
        self.assertEqual(entry["contentVersion"], 0)
        self.assertEqual(entry["media"], [])
        self.assertIn("USB-C docking", entry["text"])
        self.assertIn("USB-C docking", entry["summary"])

    def test_current_readme_cache_round_trip_preserves_search_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_readmes(store, {
                    "example.dock-helper": {
                        "commit": "a" * 40,
                        "text": "Searchable USB-C dock controls.",
                        "content": "Readable dock controls.",
                        "summary": "Readable dock controls.",
                        "media": [],
                        "contentVersion": OUTFIT.README_CONTENT_VERSION,
                        "fetchedAt": 1234.5,
                    },
                })
                restored = OUTFIT.load_readmes(store)
            finally:
                store.close()

        self.assertEqual(
            restored["example.dock-helper"]["text"],
            "Searchable USB-C dock controls.",
        )

    def test_failed_readme_enrichment_preserves_retryable_legacy_cache(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        target = next(item for item in items if item["id"] == "example.dock-helper")
        entries = {
            target["id"]: {
                "commit": target["listingCommit"],
                "text": "Legacy searchable dock text.",
                "content": "Legacy searchable dock text.",
                "summary": "Legacy searchable dock text.",
                "media": [],
                "contentVersion": 0,
                "fetchedAt": 1234.5,
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_readmes(store, entries)
                before = store.stamp("readmes.json")
                with mock.patch.object(OUTFIT, "fetch_readme", return_value={"ok": False}):
                    fetched = OUTFIT.enrich_readmes(store, [target], entries)
                restored = OUTFIT.load_readmes(store)
                self.assertEqual(store.stamp("readmes.json"), before)
            finally:
                store.close()

        self.assertEqual(fetched, 0)
        self.assertEqual(entries[target["id"]]["text"], "Legacy searchable dock text.")
        self.assertEqual(restored[target["id"]]["text"], "Legacy searchable dock text.")

    def test_readme_action_fetches_only_the_validated_selected_revision(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        document = {
            "ok": True,
            "text": "Dock Helper controls connected docks.",
            "content": "Dock Helper\n\nControls connected docks with a compact status widget.",
            "summary": "Controls connected docks with a compact status widget.",
            "media": [{
                "kind": "image",
                "url": "https://raw.githubusercontent.com/example/dock-helper/"
                    + "a" * 40 + "/preview.png",
                "poster": "",
                "label": "Dock Helper preview",
            }],
        }
        materialized = [{**document["media"][0], "localSource": "file:///safe/preview.png"}]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with mock.patch.object(OUTFIT, "fetch_readme", return_value=document) as fetch, \
                        mock.patch.object(
                            OUTFIT, "materialize_readme_media", return_value=materialized,
                        ):
                    result = OUTFIT.run({
                        "action": "readme-plugin",
                        "pluginId": "example.dock-helper",
                        "query": "dock helper",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        fetch.assert_called_once()
        self.assertEqual(fetch.call_args.args[0]["id"], "example.dock-helper")
        self.assertEqual(fetch.call_args.args[0]["listingCommit"], "a" * 40)
        self.assertEqual(result["readmePluginId"], "example.dock-helper")
        self.assertEqual(result["readmeContent"], document["content"])
        self.assertEqual(result["readmeMedia"], materialized)
        self.assertTrue(result["readmeMediaIndexed"])
        row = next(row for row in result["rows"] if row["id"] == "example.dock-helper")
        self.assertTrue(row["readmeAvailable"])
        self.assertEqual(row["readmeSummary"], document["summary"])
        self.assertEqual(row["readmeMedia"], document["media"])
        self.assertTrue(row["readmeMediaIndexed"])

    def test_readme_action_respects_disabled_enrichment(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            preferences_store = OUTFIT.Store(Path(directory) / "config")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                OUTFIT.save_preferences(preferences_store, {
                    **OUTFIT.DEFAULT_PREFERENCES,
                    "readmeEnrichment": False,
                })
                with mock.patch.object(OUTFIT, "fetch_readme") as fetch:
                    with self.assertRaisesRegex(ValueError, "disabled"):
                        OUTFIT.run({
                            "action": "readme-plugin",
                            "pluginId": "example.dock-helper",
                        }, store, now=2000, preferences_store=preferences_store)
            finally:
                store.close()
                preferences_store.close()

        fetch.assert_not_called()

    def test_installed_matches_remain_visible_and_are_marked(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        rows = OUTFIT.ranked_rows(
            items,
            self.fixture["profile"],
            {"example.dock-helper"},
            "",
            "",
        )

        self.assertEqual(rows[0]["id"], "example.dock-helper")
        self.assertTrue(rows[0]["installed"])
        self.assertTrue(rows[0]["installAvailable"])

    def test_remote_text_is_cleaned_before_output(self) -> None:
        self.assertEqual(OUTFIT.one_line("safe\u202eevil\nlabel"), "safeevil label")

    def test_structural_values_are_rejected_instead_of_truncated(self) -> None:
        self.assertEqual(OUTFIT.full_sha("a" * 40 + "suffix"), "")
        self.assertEqual(OUTFIT.plugin_id("a" * 129), "")
        self.assertIsNone(OUTFIT.github_repo("https://github.com:invalid/example/repo"))

    def test_preferences_are_bounded_validated_and_private(self) -> None:
        preferences = OUTFIT.validate_preferences({
            "goals": ["gaming", "unknown", "gaming"],
            "software": ["steam", "unknown"],
            "services": ["spotify", "unknown", "spotify", "todoist"],
            "servicesOnboardingComplete": True,
            "notes": "Controller support\nwith safe defaults",
            "watchHardware": False,
            "readmeEnrichment": False,
        })
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "config"
            store = OUTFIT.Store(root)
            try:
                OUTFIT.save_preferences(store, preferences)
                restored = OUTFIT.load_preferences(store)
            finally:
                store.close()

            self.assertEqual(os.stat(root / "preferences.json").st_mode & 0o777, 0o600)

        self.assertEqual(restored["goals"], ["gaming"])
        self.assertEqual(restored["software"], ["steam"])
        self.assertEqual(restored["services"], ["spotify", "todoist"])
        self.assertTrue(restored["servicesOnboardingComplete"])
        self.assertEqual(restored["notes"], "Controller support with safe defaults")
        self.assertFalse(restored["watchHardware"])
        self.assertFalse(restored["readmeEnrichment"])
        self.assertEqual(restored["notFit"], [])
        self.assertEqual(OUTFIT.validate_preferences({"software": ["steam"]})["services"], [])

    def test_saved_legacy_fit_inputs_do_not_affect_the_active_profile(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            preferences_store = OUTFIT.Store(Path(directory) / "config")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                result = OUTFIT.run({
                    "action": "save-preferences",
                    "profile": self.fixture["profile"],
                    "preferences": {"goals": ["remote-work"], "software": [], "notes": ""},
                }, store, now=2000, preferences_store=preferences_store)
            finally:
                store.close()
                preferences_store.close()

        self.assertEqual(result["preferences"]["goals"], ["remote-work"])
        self.assertTrue(result["profile"])
        self.assertTrue(all(item["source"] == "hardware" for item in result["profile"]))
        self.assertEqual(result["notice"], "Your Outfit settings were saved locally.")

    def test_rescan_is_local_only_and_reports_hardware_changes(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        old_profile = [OUTFIT._signal("old-device", "Old device", {"old": 10})]
        new_profile = [OUTFIT._signal("new-device", "New device", {"new": 10})]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_profile", return_value=(new_profile, [], set())),
                    mock.patch.object(OUTFIT, "fetch_catalog") as fetch_catalog,
                    mock.patch.object(OUTFIT, "enrich_readmes") as enrich_readmes,
                ):
                    result = OUTFIT.run({
                        "action": "rescan",
                        "previousProfile": old_profile,
                    }, store, now=2000)
            finally:
                store.close()

        fetch_catalog.assert_not_called()
        enrich_readmes.assert_not_called()
        self.assertEqual(result["changes"], {"added": ["New device"], "removed": ["Old device"]})

    def test_bluetooth_audio_is_detected_from_device_metadata(self) -> None:
        signal = OUTFIT._known_bluetooth(
            "Living Room Device",
            "Icon: audio-headset\nUUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)",
        )

        self.assertEqual(signal["id"], "bluetooth-headphones")
        self.assertEqual(signal["label"], "Living Room Device")

    def test_hardware_change_detects_a_changed_device_label(self) -> None:
        before = [OUTFIT._signal("multi-monitor", "2 displays", {"display": 5})]
        after = [OUTFIT._signal("multi-monitor", "3 displays", {"display": 5})]

        self.assertEqual(OUTFIT.profile_changes(before, after), {
            "added": ["3 displays"],
            "removed": ["2 displays"],
        })

    def test_recommendations_expose_each_matching_score_channel(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        dock = next(item for item in items if item["id"] == "example.dock-helper")
        profile = [
            OUTFIT._signal("dock", "Dock", {"dock": 20}),
            OUTFIT._signal("gaming", "Gaming", {"dock": 15}, source="workflow"),
            OUTFIT._signal("steam", "Steam", {"dock": 12}, source="software"),
        ]

        details = OUTFIT.recommendation_details(dock, profile)

        self.assertGreater(details["scores"]["hardware"], 0)
        self.assertGreater(details["scores"]["workflow"], 0)
        self.assertGreater(details["scores"]["software"], 0)
        self.assertEqual(details["confidence"], "high")

    def test_inventory_probe_retains_omarchy_session_path(self) -> None:
        self.assertIn("OMARCHY_PATH", OUTFIT.SAFE_ENV_KEYS)

    def test_inventory_merges_first_and_third_party_installs(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        inventory = OUTFIT.validate_inventory([
            {
                "id": "omarchy.audio",
                "name": "Audio",
                "kinds": ["bar-widget"],
                "enabled": True,
                "canDisable": True,
                "firstParty": True,
            },
            {
                "id": "example.dock-helper",
                "name": "Dock Helper",
                "kinds": ["bar-widget"],
                "enabled": False,
                "canDisable": True,
                "firstParty": False,
            },
        ])
        merged = OUTFIT.merge_inventory(items, inventory)
        installed = {item["id"] for item in inventory}

        builtin = next(item for item in merged if item["id"] == "omarchy.audio")
        dock = next(item for item in merged if item["id"] == "example.dock-helper")
        self.assertEqual(builtin["party"], "first-party")
        self.assertTrue(builtin["localOnly"])
        self.assertEqual(dock["party"], "third-party")
        self.assertFalse(dock["enabled"])
        self.assertTrue(dock["canDisable"])
        self.assertEqual(OUTFIT.filter_counts(merged, installed)["installed"], 2)

        rows = OUTFIT.ranked_rows(
            merged, self.fixture["profile"], installed, "", "",
            install_filter="installed", party_filter="first-party",
        )
        self.assertEqual([row["id"] for row in rows], ["omarchy.audio"])
        self.assertTrue(rows[0]["firstParty"])
        self.assertTrue(rows[0]["canDisable"])
        self.assertFalse(rows[0]["removable"])
        self.assertEqual(rows[0]["marketplaceUrl"], "")
        self.assertFalse(rows[0]["installAvailable"])

    def test_bar_section_scan_uses_live_shell_layout(self) -> None:
        shell_config = {
            "bar": {
                "layout": {
                    "left": ["omarchy.workspace"],
                    "center": [{"id": "example.dock-helper", "instanceId": "primary"}],
                    "right": ["io.github.ctl0v0.outfit"],
                },
            },
        }
        with mock.patch.object(
            OUTFIT, "run_command", return_value=json.dumps(shell_config).encode()
        ) as command:
            sections = OUTFIT.scan_bar_sections()

        command.assert_called_once_with(
            [OUTFIT.COMMANDS["omarchy-shell"], "shell", "listShellConfig"],
            5, 2 * 1024 * 1024,
        )
        self.assertEqual(sections["omarchy.workspace"], "left")
        self.assertEqual(sections["example.dock-helper"], "center")
        self.assertEqual(sections["io.github.ctl0v0.outfit"], "right")

    def test_bar_section_scan_treats_malformed_layout_as_unknown(self) -> None:
        malformed_configs = [
            {},
            {"bar": []},
            {"bar": {"layout": []}},
            {"bar": {"layout": {"left": {}}}},
        ]

        for config in malformed_configs:
            with self.subTest(config=config), mock.patch.object(
                OUTFIT, "run_command", return_value=json.dumps(config).encode(),
            ):
                self.assertIsNone(OUTFIT.scan_bar_sections())

    def test_inventory_marks_bar_sections_unknown_when_shell_probe_fails(self) -> None:
        plugins = [{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "kinds": ["bar-widget"],
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }]
        with mock.patch.object(
            OUTFIT, "run_command",
            side_effect=[json.dumps(plugins).encode(), ValueError("shell unavailable")],
        ):
            inventory, unavailable = OUTFIT.scan_inventory()

        self.assertFalse(unavailable)
        self.assertFalse(inventory[0]["barSectionKnown"])
        self.assertEqual(inventory[0]["barSection"], "")

    def test_inventory_verification_skips_catalog_and_ranking_work(self) -> None:
        inventory = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": True,
            "barSectionKnown": True,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(inventory, False)),
                    mock.patch.object(OUTFIT, "load_catalog") as load_catalog,
                    mock.patch.object(OUTFIT, "ranked_rows") as ranked_rows,
                ):
                    result = OUTFIT.run({
                        "action": "verify-inventory",
                        "generation": 8,
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        self.assertTrue(result["ok"])
        self.assertEqual(result["responseKind"], "inventory")
        self.assertTrue(result["inventoryAuthoritative"])
        load_catalog.assert_not_called()
        ranked_rows.assert_not_called()

    def test_enable_observation_requires_the_requested_bar_section(self) -> None:
        inventory = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "kinds": ["bar-widget"],
            "enabled": True,
            "barSection": "left",
            "barSectionKnown": True,
        }])

        observed = OUTFIT.mutation_observed(
            "enable-plugin", {"barSection": "right"},
            "example.dock-helper", inventory,
        )

        self.assertFalse(observed)

    def test_wait_for_plugin_inventory_retries_until_discovery(self) -> None:
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "kinds": ["bar-widget"],
            "enabled": False,
        }])
        with (
            mock.patch.object(
                OUTFIT, "scan_inventory",
                side_effect=[([], True), ([], False), (installed, False)],
            ),
            mock.patch.object(OUTFIT.time, "sleep") as sleep,
        ):
            result = OUTFIT.wait_for_plugin_inventory("example.dock-helper")

        self.assertEqual(result, installed[0])
        self.assertEqual(sleep.call_count, 2)

    def test_install_action_uses_validated_catalog_repo_and_leaves_plugin_off(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "installedRevision": "a" * 40,
            "enabled": False,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", side_effect=[([], False), (installed, False)]),
                    mock.patch.object(OUTFIT, "install_reviewed_plugin", return_value=b"Added example.dock-helper") as command,
                    mock.patch.object(OUTFIT, "fetch_catalog") as fetch_catalog,
                    mock.patch.object(OUTFIT, "enrich_readmes") as enrich_readmes,
                ):
                    result = OUTFIT.run({
                        "action": "install-plugin",
                        "pluginId": "example.dock-helper",
                        "reviewedRevision": "a" * 40,
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        self.assertEqual(command.call_args.args[0]["repo"], "https://github.com/example/dock-helper")
        self.assertEqual(command.call_args.args[1], "a" * 40)
        self.assertEqual(command.call_count, 1)
        fetch_catalog.assert_not_called()
        enrich_readmes.assert_not_called()
        local = next(row for row in result["inventory"] if row["id"] == "example.dock-helper")
        self.assertEqual(result["responseKind"], "mutation")
        self.assertTrue(result["inventoryAuthoritative"])
        self.assertTrue(result["operation"]["observed"])
        self.assertFalse(local["enabled"])

    def test_install_action_places_and_enables_a_bar_widget(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "installedRevision": "a" * 40,
            "kinds": ["bar-widget"],
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
            "barSection": "center",
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(
                        OUTFIT, "scan_inventory", side_effect=[([], False),
                            ([dict(installed[0], enabled=False, barSection="")], False), (installed, False)]
                    ),
                    mock.patch.object(OUTFIT, "install_reviewed_plugin", return_value=b"Added example.dock-helper"),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Enabled example.dock-helper") as command,
                ):
                    result = OUTFIT.run({
                        "action": "install-plugin",
                        "pluginId": "example.dock-helper",
                        "reviewedRevision": "a" * 40,
                        "barSection": "center",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        self.assertEqual(command.call_args_list, [
            mock.call(
                [OUTFIT.COMMANDS["omarchy"], "plugin", "enable", "example.dock-helper", "center"],
                35, 32 * 1024,
            ),
        ])
        local = next(row for row in result["inventory"] if row["id"] == "example.dock-helper")
        self.assertTrue(local["enabled"])
        self.assertEqual(local["barSection"], "center")
        self.assertTrue(result["operation"]["observed"])
        self.assertEqual(result["notice"], "Plugin installed and placed in the center section.")

    def test_batch_install_option_enables_an_ordinary_plugin(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.quiet-hours",
            "name": "Quiet Hours",
            "installedRevision": "c" * 40,
            "kinds": ["service"],
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(
                        OUTFIT, "scan_inventory", side_effect=[([], False),
                            ([dict(installed[0], enabled=False)], False), (installed, False)]
                    ),
                    mock.patch.object(OUTFIT, "install_reviewed_plugin", return_value=b"Added example.quiet-hours"),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Enabled example.quiet-hours") as command,
                    mock.patch.object(OUTFIT, "installed_revision", return_value="c" * 40),
                ):
                    result = OUTFIT.run({
                        "action": "install-plugin",
                        "pluginId": "example.quiet-hours",
                        "reviewedRevision": "c" * 40,
                        "enableAfter": True,
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        self.assertEqual(command.call_args_list, [
            mock.call(
                [OUTFIT.COMMANDS["omarchy"], "plugin", "enable", "example.quiet-hours"],
                35, 32 * 1024,
            ),
        ])
        self.assertEqual(result["operation"]["status"], "completed")
        self.assertEqual(result["operation"]["installedRevision"], "c" * 40)
        self.assertEqual(result["operation"]["reviewedRevision"], "c" * 40)
        self.assertEqual(result["notice"], "Plugin installed and enabled.")

    def test_installed_revision_uses_only_the_validated_plugin_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            plugin_root = Path(directory) / "omarchy" / "plugins" / "example.plugin"
            plugin_root.mkdir(parents=True)
            (plugin_root / ".git").mkdir()
            with (
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}),
                mock.patch.object(OUTFIT, "run_command", return_value=("e" * 40 + "\n").encode()) as command,
            ):
                revision = OUTFIT.installed_revision("example.plugin")

        self.assertEqual(revision, "e" * 40)
        command.assert_called_once_with(
            [OUTFIT.COMMANDS["git"], "--no-optional-locks", "-C", str(plugin_root), "rev-parse", "--verify", "HEAD"],
            5,
            256,
        )

    def test_activation_failure_is_reported_as_partial_without_reinstalling(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.quiet-hours",
            "name": "Quiet Hours",
            "kinds": ["service"],
            "enabled": False,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(
                        OUTFIT, "scan_inventory", side_effect=[([], False)] + [(installed, False)] * 5
                    ),
                    mock.patch.object(
                        OUTFIT, "run_command",
                        side_effect=[
                            ValueError("enable failed"),
                            ValueError("enable failed"),
                            ValueError("enable failed"),
                        ],
                    ),
                    mock.patch.object(OUTFIT, "install_reviewed_plugin", return_value=b"Added example.quiet-hours"),
                    mock.patch.object(OUTFIT.time, "sleep"),
                ):
                    result = OUTFIT.run({
                        "action": "install-plugin",
                        "pluginId": "example.quiet-hours",
                        "reviewedRevision": "c" * 40,
                        "enableAfter": True,
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        self.assertTrue(result["ok"])
        self.assertEqual(result["operation"]["status"], "partial")
        self.assertIn("installed but", result["error"])
        self.assertIn("example.quiet-hours", result["installed"])

    def test_enable_action_uses_fixed_command_and_refreshes_inventory(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        disabled = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": False,
            "canDisable": True,
            "firstParty": False,
        }])
        enabled = [dict(disabled[0], enabled=True)]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", side_effect=[(disabled, False), (enabled, False)]),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Enabled example.dock-helper") as command,
                ):
                    result = OUTFIT.run({
                        "action": "enable-plugin",
                        "pluginId": "example.dock-helper",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        command.assert_called_once_with(
            [OUTFIT.COMMANDS["omarchy"], "plugin", "enable", "example.dock-helper"],
            35, 32 * 1024,
        )
        local = next(row for row in result["inventory"] if row["id"] == "example.dock-helper")
        self.assertTrue(local["enabled"])
        self.assertTrue(result["operation"]["observed"])

    def test_place_action_uses_fixed_enable_command_and_refreshes_section(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "kinds": ["bar-widget"],
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
            "barSection": "left",
        }])
        moved = [dict(installed[0], barSection="right")]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", side_effect=[(installed, False), (moved, False)]),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Enabled example.dock-helper") as command,
                ):
                    result = OUTFIT.run({
                        "action": "place-plugin",
                        "pluginId": "example.dock-helper",
                        "barSection": "right",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        command.assert_called_once_with(
            [OUTFIT.COMMANDS["omarchy"], "plugin", "enable", "example.dock-helper", "right"],
            35, 32 * 1024,
        )
        local = next(row for row in result["inventory"] if row["id"] == "example.dock-helper")
        self.assertEqual(local["barSection"], "right")
        self.assertTrue(result["operation"]["observed"])
        self.assertEqual(result["notice"], "Plugin moved to the right section.")

    def test_place_action_rejects_non_bar_plugins(self) -> None:
        installed = OUTFIT.validate_inventory([{
            "id": "example.panel",
            "name": "Example Panel",
            "kinds": ["panel"],
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(installed, False)),
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "bar-widget"):
                        OUTFIT.run({
                            "action": "place-plugin",
                            "pluginId": "example.panel",
                            "barSection": "left",
                        }, store, now=2000)
            finally:
                store.close()

        command.assert_not_called()

    def test_install_action_rejects_an_already_installed_plugin(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": False,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(installed, False)),
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "already installed"):
                        OUTFIT.run({
                            "action": "install-plugin",
                            "pluginId": "example.dock-helper",
                            "reviewedRevision": "a" * 40,
                        }, store, now=2000)
            finally:
                store.close()

        command.assert_not_called()

    def test_install_action_requires_the_reviewed_catalog_revision(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory") as scan,
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "listing changed"):
                        OUTFIT.run({
                            "action": "install-plugin",
                            "pluginId": "example.dock-helper",
                            "reviewedRevision": "f" * 40,
                        }, store, now=2000)
            finally:
                store.close()

        scan.assert_not_called()
        command.assert_not_called()

    def test_enable_action_rejects_a_plugin_without_an_off_state(self) -> None:
        active_bar = OUTFIT.validate_inventory([{
            "id": "example.bar",
            "name": "Example Bar",
            "enabled": True,
            "canDisable": False,
            "firstParty": False,
        }])
        disabled_bar = [dict(active_bar[0], enabled=False)]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(disabled_bar, False)),
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "on/off toggle"):
                        OUTFIT.run({
                            "action": "enable-plugin",
                            "pluginId": "example.bar",
                        }, store, now=2000)
            finally:
                store.close()

        command.assert_not_called()

    def test_management_refuses_fallback_inventory(self) -> None:
        fallback = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(fallback, True)),
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "authoritative"):
                        OUTFIT.run({
                            "action": "disable-plugin",
                            "pluginId": "example.dock-helper",
                        }, store, now=2000)
            finally:
                store.close()

        command.assert_not_called()

    def test_disable_action_uses_fixed_command_and_refreshes_inventory(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }])
        disabled = [dict(installed[0], enabled=False)]
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", side_effect=[(installed, False), (disabled, False)]),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Disabled example.dock-helper") as command,
                    mock.patch.object(OUTFIT, "fetch_catalog") as fetch_catalog,
                    mock.patch.object(OUTFIT, "enrich_readmes") as enrich_readmes,
                    mock.patch.object(OUTFIT, "ranked_rows") as ranked_rows,
                    mock.patch.object(OUTFIT, "load_readmes") as load_readmes,
                ):
                    result = OUTFIT.run({
                        "action": "disable-plugin",
                        "pluginId": "example.dock-helper",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        command.assert_called_once_with(
            [OUTFIT.COMMANDS["omarchy"], "plugin", "disable", "example.dock-helper"],
            35, 32 * 1024,
        )
        fetch_catalog.assert_not_called()
        enrich_readmes.assert_not_called()
        ranked_rows.assert_not_called()
        load_readmes.assert_not_called()
        local = next(row for row in result["inventory"] if row["id"] == "example.dock-helper")
        self.assertFalse(local["enabled"])
        self.assertTrue(result["operation"]["observed"])

    def test_remove_action_confirms_yes_and_makes_catalog_plugin_available(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        installed = OUTFIT.validate_inventory([{
            "id": "example.dock-helper",
            "name": "Dock Helper",
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", side_effect=[(installed, False), ([], False)]),
                    mock.patch.object(OUTFIT, "run_command", return_value=b"Removed example.dock-helper.") as command,
                ):
                    result = OUTFIT.run({
                        "action": "remove-plugin",
                        "pluginId": "example.dock-helper",
                        "profile": self.fixture["profile"],
                    }, store, now=2000)
            finally:
                store.close()

        command.assert_called_once_with(
            [OUTFIT.COMMANDS["omarchy"], "plugin", "remove", "example.dock-helper", "--yes"],
            35, 64 * 1024,
        )
        self.assertNotIn("example.dock-helper", result["installed"])
        self.assertTrue(result["operation"]["observed"])
        self.assertEqual(result["notice"], "Removed example.dock-helper.")

    def test_remove_action_rejects_first_party_plugin(self) -> None:
        builtin = OUTFIT.validate_inventory([{
            "id": "omarchy.audio",
            "name": "Audio",
            "enabled": True,
            "canDisable": True,
            "firstParty": True,
        }])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            try:
                with (
                    mock.patch.object(OUTFIT, "scan_inventory", return_value=(builtin, False)),
                    mock.patch.object(OUTFIT, "run_command") as command,
                ):
                    with self.assertRaisesRegex(ValueError, "First-party"):
                        OUTFIT.run({
                            "action": "remove-plugin",
                            "pluginId": "omarchy.audio",
                        }, store, now=2000)
            finally:
                store.close()

        command.assert_not_called()

    def test_legacy_feedback_is_inert_without_hiding_evidence(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        normal = OUTFIT.ranked_rows(items, self.fixture["profile"], set(), "", "")
        lowered = OUTFIT.ranked_rows(
            items, self.fixture["profile"], set(), "", "",
            not_fit={"example.dock-helper"},
        )
        normal_dock = next(row for row in normal if row["id"] == "example.dock-helper")
        lowered_dock = next(row for row in lowered if row["id"] == "example.dock-helper")

        self.assertEqual(lowered_dock["baseScore"], normal_dock["score"])
        self.assertEqual(lowered_dock["adjustment"], 0)
        self.assertEqual(lowered_dock["score"], normal_dock["score"])
        self.assertFalse(lowered_dock["notFit"])
        self.assertTrue(lowered_dock["evidence"]["hardware"])

        search_rows = OUTFIT.ranked_rows(
            items, self.fixture["profile"], set(), "dock helper", "",
            not_fit={"example.dock-helper"},
        )
        self.assertEqual(search_rows[0]["id"], "example.dock-helper")
        self.assertFalse(search_rows[0]["notFit"])

    def test_exact_search_keeps_a_zero_fit_local_plugin_visible(self) -> None:
        local = OUTFIT.merge_inventory([], OUTFIT.validate_inventory([{
            "id": "example.removal-smoke",
            "name": "Removal Smoke Fixture",
            "enabled": True,
            "canDisable": True,
            "firstParty": False,
        }]))

        rows = OUTFIT.ranked_rows(
            local, [], {"example.removal-smoke"}, "Removal Smoke Fixture", "",
        )

        self.assertEqual([row["id"] for row in rows], ["example.removal-smoke"])
        self.assertEqual(rows[0]["score"], 0)
        self.assertTrue(rows[0]["removable"])

    def test_retired_feedback_action_cannot_mutate_legacy_preferences(self) -> None:
        items, generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        with tempfile.TemporaryDirectory() as directory:
            store = OUTFIT.Store(Path(directory) / "cache")
            preferences_store = OUTFIT.Store(Path(directory) / "config")
            try:
                OUTFIT.save_catalog(store, items, generated, 1234.5)
                OUTFIT.save_preferences(preferences_store, {**OUTFIT.DEFAULT_PREFERENCES,
                    "notFit":["example.dock-helper"], "notes":"keep this note"})
                with (
                    mock.patch.object(OUTFIT, "fetch_catalog") as fetch_catalog,
                    mock.patch.object(OUTFIT, "enrich_readmes") as enrich_readmes,
                ):
                    with self.assertRaisesRegex(ValueError, "retired"):
                        OUTFIT.run({"action":"set-feedback", "pluginId":"example.dock-helper", "notFit":False},
                                   store, now=2000, preferences_store=preferences_store)
                    restored = OUTFIT.run({
                        "action": "save-preferences",
                        "preferences": {**{key:value for key,value in OUTFIT.DEFAULT_PREFERENCES.items() if key != "notFit"},
                                        "notes":"keep this note", "watchHardware":False},
                    }, store, now=2000, preferences_store=preferences_store)
            finally:
                store.close()
                preferences_store.close()

        fetch_catalog.assert_not_called()
        enrich_readmes.assert_not_called()
        self.assertEqual(restored["preferences"]["notes"], "keep this note")
        self.assertIn("example.dock-helper", restored["preferences"]["notFit"])

    def test_installed_filter_runs_before_result_limit(self) -> None:
        items, _generated = OUTFIT.normalize_catalog(self.fixture["catalog"])
        dock = next(item for item in items if item["id"] == "example.dock-helper")
        crowded = []
        for index in range(70):
            row = dict(dock)
            row["id"] = f"example.available-{index:02d}"
            row["name"] = f"Available {index:02d}"
            crowded.append(row)
        installed_row = dict(dock)
        installed_row["id"] = "example.installed-last"
        installed_row["name"] = "Installed Last"
        crowded.append(installed_row)

        rows = OUTFIT.ranked_rows(
            crowded,
            self.fixture["profile"],
            {"example.installed-last"},
            "",
            "",
            install_filter="installed",
        )

        self.assertEqual([row["id"] for row in rows], ["example.installed-last"])


if __name__ == "__main__":
    unittest.main()
