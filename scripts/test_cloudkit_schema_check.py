#!/usr/bin/env python3
"""cloudkit_schema_check 的离线自测：python3 scripts/test_cloudkit_schema_check.py"""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cloudkit_schema_check as c

SCHEMA = '''DEFINE SCHEMA

    RECORD TYPE CD_PlanBlock (
        CD_title              STRING QUERYABLE,
        CD_start              TIMESTAMP QUERYABLE SORTABLE,
        "___createTime"       TIMESTAMP,
        GRANT WRITE TO "_creator"
    );
'''
MODEL = '''import SwiftData
@Model
final class PlanBlock {
    var title: String = ""
    var start: Date = Date.now
    var isDone: Bool { false }
    init() {}
}
'''

class T(unittest.TestCase):
    def test_parse(self):
        s = c.parse_schema(SCHEMA)
        self.assertEqual(s, {'CD_PlanBlock': {'CD_title': 'STRING', 'CD_start': 'TIMESTAMP'}})
        m = c.parse_models({'a': MODEL})
        self.assertEqual(m, {'PlanBlock': {'title': 'String', 'start': 'Date'}})

    def test_clean(self):
        s = c.parse_schema(SCHEMA); m = c.parse_models({'a': MODEL})
        self.assertEqual(c.check(s, s, m, m)[0], [])

    def test_undeployed_field_blocks(self):
        prod = c.parse_schema(SCHEMA); dev = c.parse_schema(SCHEMA.replace('CD_title ', 'CD_note STRING,\n        CD_title '))
        b, _ = c.check(prod, dev, c.parse_models({'a': MODEL}), None)
        self.assertTrue(any('CD_note' in x and 'Deploy' in x for x in b))

    def test_removed_property_blocks(self):
        base = c.parse_models({'a': MODEL}); now = c.parse_models({'a': MODEL.replace('    var start: Date = Date.now\n', '')})
        b, _ = c.check(c.parse_schema(SCHEMA), c.parse_schema(SCHEMA), now, base)
        self.assertTrue(any('PlanBlock.start' in x and '只加不改' in x for x in b))

    def test_type_change_blocks(self):
        base = c.parse_models({'a': MODEL}); now = c.parse_models({'a': MODEL.replace('var start: Date', 'var start: String')})
        b, _ = c.check(c.parse_schema(SCHEMA), c.parse_schema(SCHEMA), now, base)
        self.assertTrue(any('类型从' in x for x in b))

    def test_field_missing_in_production_is_flagged(self):
        now = c.parse_models({'a': MODEL.replace('    init', '    var memo: String?\n    init')})
        _, n = c.check(c.parse_schema(SCHEMA), c.parse_schema(SCHEMA), now, None)
        self.assertTrue(any('PlanBlock.memo' in x for x in n))

if __name__ == '__main__':
    unittest.main()
