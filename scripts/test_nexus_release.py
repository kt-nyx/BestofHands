# SPDX-License-Identifier: Unlicense
"""Focused checks for preservation and post-upload verification of Nexus metadata."""

import copy
from pathlib import Path
import tempfile
import unittest

from nexus_release_metadata import prepare, verify, write_output


class NexusMetadataTests(unittest.TestCase):
    def setUp(self):
        self.description = "[b]Read the install instructions[/b]\nManual DLL installation required."
        self.responses = {
            "/v3/mod-files/7663598/versions": {"data": {"versions": [
                {"id": "100", "file": {"id": "7663598"}, "game_scoped_id": "1000",
                 "version": "9.9.9", "category": "main", "position": "8"},
                {"id": "101", "file": {"id": "7663598"}, "game_scoped_id": "1001",
                 "version": "2.3.1", "category": "main", "position": "10"},
                {"id": "99", "file": {"id": "7663598"}, "game_scoped_id": "999",
                 "version": "3.0.0", "category": "archived", "position": "11"},
            ]}},
            "/v1/games/baldursgate3/mods/23881/files/1001.json": {
                "file_id": 1001, "description": self.description,
            },
        }

    def read(self, path):
        return copy.deepcopy(self.responses[path])

    def published(self):
        snapshot = prepare("7663598", "2.3.2", self.read)
        self.responses.update({
            "/v3/mod-file-versions/102": {"data": {
                "file": {"id": "7663598"}, "game_scoped_id": "1002",
                "version": "2.3.2", "category": "main",
            }},
            "/v3/mod-file-versions/101": {"data": {"category": "old_version"}},
            "/v1/games/baldursgate3/mods/23881/files/1002.json": {
                "file_id": 1002, "description": self.description, "changelog_html": "",
            },
        })
        return snapshot

    def test_latest_active_position_and_exact_multiline_description(self):
        snapshot = prepare("7663598", "2.3.2", self.read)
        self.assertEqual("101", snapshot["previous_version_id"])
        self.assertEqual(self.description, snapshot["description"])

    def test_empty_description_and_duplicate_version_stop_before_upload(self):
        details = self.responses["/v1/games/baldursgate3/mods/23881/files/1001.json"]
        details["description"] = " "
        with self.assertRaisesRegex(ValueError, "empty"):
            prepare("7663598", "2.3.2", self.read)
        with self.assertRaisesRegex(ValueError, "already exists"):
            prepare("7663598", "2.3.1", self.read)

    def test_other_file_identity_cannot_supply_description(self):
        self.responses["/v3/mod-files/7663598/versions"]["data"]["versions"][1]["file"]["id"] = "123"
        with self.assertRaisesRegex(ValueError, "another Nexus file"):
            prepare("7663598", "2.3.2", self.read)

    def test_rendered_html_and_plain_text_are_not_accepted_as_bbcode(self):
        for description in ("Read the instructions", "<b>Read the instructions</b>"):
            with self.subTest(description=description):
                self.responses["/v1/games/baldursgate3/mods/23881/files/1001.json"]["description"] = description
                with self.assertRaisesRegex(ValueError, "raw BBCode"):
                    prepare("7663598", "2.3.2", self.read)

    def test_github_output_preserves_multiline_content_as_one_value(self):
        value = self.description + "\n::warning::text\nother_output=not-an-output"
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "outputs"
            write_output(output, "description", value)
            text = output.read_text(encoding="utf-8")
        opening, body = text.split("\n", 1)
        delimiter = opening.split("<<", 1)[1]
        self.assertEqual(value + "\n" + delimiter + "\n", body)

    def test_success_verifies_old_category_description_and_blank_changelog(self):
        result = verify(self.published(), "102", self.read)
        self.assertEqual("old_version", result["previous_category"])
        self.assertTrue(result["changelog_blank"])
        self.assertTrue(result["bbcode_preserved"])

    def test_wrong_publication_metadata_cannot_report_success(self):
        snapshot = self.published()
        paths = [
            ("/v3/mod-file-versions/101", "category", "archived", "old version"),
            ("/v1/games/baldursgate3/mods/23881/files/1002.json", "description", "changed", "description"),
            ("/v1/games/baldursgate3/mods/23881/files/1002.json", "changelog_html", "notes", "changelog"),
        ]
        original = copy.deepcopy(self.responses)
        for path, field, value, error in paths:
            with self.subTest(field=field):
                self.responses = copy.deepcopy(original)
                target = self.responses[path].get("data", self.responses[path])
                target[field] = value
                with self.assertRaisesRegex(ValueError, error):
                    verify(snapshot, "102", self.read)


if __name__ == "__main__":
    unittest.main()
