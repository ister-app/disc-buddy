import 'dart:convert';

/// Extracts the first `{...}` object from an LLM reply. Tries strict JSON
/// first, then a repaired variant (see [repairJson]). `mode` tells which one
/// succeeded.
({String mode, Map<String, dynamic> obj})? parseJsonWithMode(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'```[a-zA-Z]*'), '').trim();
  final start = cleaned.indexOf('{');
  final end = cleaned.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final slice = cleaned.substring(start, end + 1);

  Map<String, dynamic>? tryParse(String s) {
    try {
      final obj = jsonDecode(s);
      return obj is Map<String, dynamic> ? obj : null;
    } catch (_) {
      return null;
    }
  }

  final strict = tryParse(slice);
  if (strict != null) return (mode: 'strict', obj: strict);
  final repaired = tryParse(repairJson(slice));
  if (repaired != null) return (mode: 'recovered', obj: repaired);
  return null;
}

/// [parseJsonWithMode] without the mode.
Map<String, dynamic>? parseJsonObject(String raw) => parseJsonWithMode(raw)?.obj;

/// Fixes the usual LLM JSON slips: smart quotes, Python literals, a missing
/// quote after a key, trailing commas.
String repairJson(String raw) {
  var out = raw
      .replaceAll("\\'", "'")   // invalid JSON escape: \' → '
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAllMapped(
        RegExp(r'(?<![A-Za-z_])None(?![A-Za-z_])'),
        (_) => 'null',
      )
      .replaceAllMapped(
        RegExp(r'(?<![A-Za-z_])True(?![A-Za-z_])'),
        (_) => 'true',
      )
      .replaceAllMapped(
        RegExp(r'(?<![A-Za-z_])False(?![A-Za-z_])'),
        (_) => 'false',
      );
  out = out.replaceAllMapped(
    RegExp(r'([{,]\s*)"(\w+):\s*(null|true|false|-?\d|\[|\{|")'),
    (m) => '${m.group(1)}"${m.group(2)}": ${m.group(3)}',
  );
  // Note: String.replaceAll takes a literal replacement (no `$1`), so the
  // trailing-comma fix needs replaceAllMapped.
  out = out.replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m.group(1)!);
  return out;
}

/// Reads an integer field that the LLM may have returned as a string.
int jsonInt(dynamic v) => v is int ? v : int.tryParse('$v') ?? 0;
