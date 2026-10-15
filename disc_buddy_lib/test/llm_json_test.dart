import 'package:disc_buddy/src/naming/llm_json.dart';
import 'package:test/test.dart';

void main() {
  group('parseJsonWithMode', () {
    test('strikte JSON → mode strict', () {
      final r = parseJsonWithMode('{"pick": 3}');
      expect(r!.mode, 'strict');
      expect(r.obj['pick'], 3);
    });

    test('code fences en tekst eromheen worden genegeerd', () {
      final r = parseJsonWithMode('Sure!\n```json\n{"pick":2}\n```\nDone.');
      expect(r!.obj['pick'], 2);
    });

    test('gerepareerde JSON → mode recovered', () {
      final r = parseJsonWithMode('{"first": 1, "second": None,}');
      expect(r!.mode, 'recovered');
      expect(r.obj['first'], 1);
      expect(r.obj['second'], isNull);
    });

    test('geen object → null', () {
      expect(parseJsonWithMode('no json here'), isNull);
      expect(parseJsonWithMode('}{'), isNull);
    });

    test('array i.p.v. object → null', () {
      expect(parseJsonObject('[1,2,3]'), isNull);
    });
  });

  group('repairJson', () {
    test('smart quotes en Python-literals', () {
      final fixed = repairJson('{“ok”: True, "x": False, "y": None}');
      expect(fixed, '{"ok": true, "x": false, "y": null}');
    });

    test('ontbrekende aanhalingsteken na sleutel', () {
      expect(repairJson('{"pick: 1}'), '{"pick": 1}');
    });

    test('trailing comma', () {
      expect(repairJson('{"a": [1,2,],}'), '{"a": [1,2]}');
    });

    test('ongeldige escape \\\' wordt \'', () {
      expect(repairJson('{"s": "it\\\'s"}'), '{"s": "it\'s"}');
    });

    test('None binnen een woord blijft staan', () {
      expect(repairJson('{"s": "NoneSuch"}'), '{"s": "NoneSuch"}');
    });
  });

  group('jsonInt', () {
    test('int, string en rommel', () {
      expect(jsonInt(4), 4);
      expect(jsonInt('7'), 7);
      expect(jsonInt('x'), 0);
      expect(jsonInt(null), 0);
    });
  });
}
