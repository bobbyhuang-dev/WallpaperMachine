"""Guard the bundled panel catalog without requiring a JavaScript toolchain."""
import ast
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
LITERAL = r"'(?:[^'\\\n]|\\.)*'"


class StaticKeys(HTMLParser):
    def __init__(self):
        super().__init__()
        self.keys = set()

    def handle_starttag(self, tag, attrs):
        self.keys.update(value for name, value in attrs
                         if name in ("data-i18n", "data-i18n-label"))


class PanelLocalizationTests(unittest.TestCase):
    def setUp(self):
        source = (ROOT / "WebUI/i18n.js").read_text()
        self.entries = [(ast.literal_eval(key), ast.literal_eval(value))
                        for key, value in re.findall(
                            rf"^    ({LITERAL}): ({LITERAL}),$", source, re.MULTILINE)]
        self.catalog = dict(self.entries)

    def test_catalog_has_no_duplicates_or_empty_translations(self):
        self.assertGreater(len(self.entries), 500)
        self.assertEqual(len(self.entries), len(self.catalog), "Duplicate catalog key")
        for key, value in self.entries:
            with self.subTest(key=key):
                self.assertTrue(value.strip())

    def test_interpolation_preserves_every_placeholder(self):
        for key, value in self.entries:
            with self.subTest(key=key):
                self.assertEqual(Counter(re.findall(r"\{\w+\}", key)),
                                 Counter(re.findall(r"\{\w+\}", value)))

    def test_literal_calls_and_static_markup_have_translations(self):
        # Dynamic enum/table keys are exercised by offscreen WebKit tests. This
        # check covers direct t('...') calls, not arbitrary JavaScript parsing.
        keys = set()
        for name in ("panel.js", "settings.js"):
            source = (ROOT / "WebUI" / name).read_text()
            keys.update(ast.literal_eval(key) for key in re.findall(
                rf"\bt\(\s*({LITERAL})", source))
        markup = StaticKeys()
        markup.feed((ROOT / "WebUI/index.html").read_text())
        keys.update(markup.keys)
        self.assertEqual(sorted(keys - self.catalog.keys()), [])


if __name__ == "__main__":
    unittest.main()
