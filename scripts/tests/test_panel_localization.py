"""Guard the shipped language catalogs and registries without a JavaScript toolchain.

Every language the app ships is declared in three places that must agree:
`AppLanguage.supported` (Swift), the `catalogs` registry in `WebUI/i18n.js`
(one module per language under `WebUI/locales/`), and the locales present in
`App/Resources/*.xcstrings`. See docs/localization.md.
"""
import ast
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
LITERAL = r"'(?:[^'\\\n]|\\.)*'"
SOURCE_LANGUAGE = "en"
LOCALES = ROOT / "WebUI/locales"
XCSTRINGS = [ROOT / "App/Resources/Localizable.xcstrings", ROOT / "App/Resources/InfoPlist.xcstrings"]


class StaticKeys(HTMLParser):
    def __init__(self):
        super().__init__()
        self.keys = set()

    def handle_starttag(self, tag, attrs):
        self.keys.update(value for name, value in attrs
                         if name in ("data-i18n", "data-i18n-label"))


def catalog_entries(path):
    """(key, value) pairs of a `WebUI/locales/<tag>.js` module, in file order."""
    source = path.read_text()
    return [(ast.literal_eval(key), ast.literal_eval(value))
            for key, value in re.findall(rf"^  ({LITERAL}): ({LITERAL}),$", source, re.MULTILINE)]


def swift_languages():
    source = (ROOT / "App/Services/Localization/AppLanguage.swift").read_text()
    body = source[source.index("static let supported"):]
    body = body[body.index("= [") + 3:]
    body = body[:body.index("]")]
    tags = []
    for line in body.splitlines():
        if re.match(r"\s*english,", line):
            tags.append(SOURCE_LANGUAGE)
        tags.extend(re.findall(r'AppLanguage\(tag: "([^"]+)"', line))
    return tags


def web_languages():
    source = (ROOT / "WebUI/i18n.js").read_text()
    imports = dict(re.findall(r"^import (\w+) from './locales/([\w-]+)\.js';$", source, re.MULTILINE))
    registry = source[source.index("const catalogs = {"):]
    registry = registry[:registry.index("};")]
    tags = {}
    for tag, binding in re.findall(rf"^  ({LITERAL}): (\w+),$", registry, re.MULTILINE):
        tags[ast.literal_eval(tag)] = binding
    return imports, tags


def xcstrings_languages(path):
    """Locales that appear anywhere in a catalog, and the keys each one leaves untranslated."""
    data = json.loads(path.read_text())
    languages = {}
    for key, entry in data["strings"].items():
        for tag, unit in entry.get("localizations", {}).items():
            languages.setdefault(tag, set())
            state = unit.get("stringUnit", {}).get("state")
            if state is not None and state != "translated":
                languages[tag].add(key)
    return data.get("sourceLanguage"), data["strings"].keys(), languages


class PanelLocalizationTests(unittest.TestCase):
    def setUp(self):
        self.catalogs = {path.stem: catalog_entries(path) for path in sorted(LOCALES.glob("*.js"))}
        self.assertTrue(self.catalogs, "no catalog modules under WebUI/locales")

    def test_every_shipped_language_is_registered_everywhere(self):
        swift = swift_languages()
        self.assertEqual(swift[0], SOURCE_LANGUAGE, "English is the source language and stays first")
        self.assertEqual(len(swift), len(set(swift)), "Duplicate language in AppLanguage.supported")
        translated = set(swift) - {SOURCE_LANGUAGE}
        imports, registry = web_languages()
        self.assertEqual(set(registry), translated, "WebUI/i18n.js registry disagrees with AppLanguage.supported")
        self.assertEqual(set(self.catalogs), translated, "WebUI/locales modules disagree with AppLanguage.supported")
        for tag, binding in registry.items():
            with self.subTest(tag=tag):
                self.assertEqual(imports.get(binding), tag, f"{tag} must be imported from ./locales/{tag}.js")
        for path in XCSTRINGS:
            source, keys, languages = xcstrings_languages(path)
            with self.subTest(catalog=path.name):
                self.assertEqual(source, SOURCE_LANGUAGE)
                self.assertTrue(translated <= set(languages), f"{path.name} lacks {sorted(translated - set(languages))}")
                self.assertTrue(set(languages) <= set(swift), f"{path.name} carries unregistered {sorted(set(languages) - set(swift))}")
        source, keys, languages = xcstrings_languages(XCSTRINGS[0])
        for tag in translated:
            with self.subTest(tag=tag):
                data = json.loads(XCSTRINGS[0].read_text())["strings"]
                missing = sorted(key for key, entry in data.items() if tag not in entry.get("localizations", {}))
                self.assertEqual(missing, [], f"{tag}: native strings without a translation")
                self.assertEqual(sorted(languages[tag]), [], f"{tag}: native strings not marked translated")

    def test_catalog_has_no_duplicates_or_empty_translations(self):
        for tag, entries in self.catalogs.items():
            with self.subTest(tag=tag):
                self.assertGreater(len(entries), 500)
                self.assertEqual(len(entries), len(dict(entries)), "Duplicate catalog key")
                for key, value in entries:
                    with self.subTest(tag=tag, key=key):
                        self.assertTrue(value.strip())

    def test_interpolation_preserves_every_placeholder(self):
        for tag, entries in self.catalogs.items():
            for key, value in entries:
                with self.subTest(tag=tag, key=key):
                    self.assertEqual(Counter(re.findall(r"\{\w+\}", key)),
                                     Counter(re.findall(r"\{\w+\}", value)))

    def test_literal_calls_and_static_markup_have_translations(self):
        # Dynamic enum/table keys are exercised by offscreen WebKit tests. This
        # check covers direct t('...') calls, not arbitrary JavaScript parsing.
        keys = set()
        for name in ("panel.js", "settings.js", "welcome.js"):
            source = (ROOT / "WebUI" / name).read_text()
            keys.update(ast.literal_eval(key) for key in re.findall(
                rf"\bt\(\s*({LITERAL})", source))
        markup = StaticKeys()
        markup.feed((ROOT / "WebUI/index.html").read_text())
        keys.update(markup.keys)
        for tag, entries in self.catalogs.items():
            with self.subTest(tag=tag):
                self.assertEqual(sorted(keys - dict(entries).keys()), [])

    def test_every_catalog_covers_the_same_keys(self):
        # A shipped language is complete: a key any catalog knows, every catalog knows.
        union = set()
        for entries in self.catalogs.values():
            union.update(key for key, _ in entries)
        for tag, entries in self.catalogs.items():
            with self.subTest(tag=tag):
                self.assertEqual(sorted(union - dict(entries).keys()), [])


if __name__ == "__main__":
    unittest.main()
