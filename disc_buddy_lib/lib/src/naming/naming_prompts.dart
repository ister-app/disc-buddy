// System prompts used by the auto-namer, in one place so wording changes
// don't touch matching logic.

const String summarySystemPrompt =
    'Summarize this subtitle to identify which specific TV episode it is. '
    'Output STRICT JSON only. No markdown, no code fences.\n\n'
    'Schema: {"summary":"identifying description","titleGuess":"title or empty string"}\n\n'
    'Rules:\n'
    '- summary: 4-6 sentences. Focus on SPECIFIC UNIQUE events that '
    'distinguish this episode from all others in the series: '
    'character deaths or near-deaths, marriages or proposals, '
    'key objects (e.g. a specific pie, a shoe, a ring), '
    'first meetings or final confrontations, '
    'specific crimes or revelations, '
    'memorable dialogue quotes.\n'
    '- titleGuess: show or movie title if recognisable, else "".\n'
    '- DVD bonus material: if the text is a blooper/outtake reel '
    '(directions like "cut", "action", "take two", flubbed lines), a '
    'featurette, interviews or commentary rather than an episode, say so '
    'in the first sentence and describe the material; do NOT invent an '
    'episode plot.\n'
    '- On failure return exactly: {}';

/// One LLM call assigns [n] subtitle files to [m] episodes.
String batchAssignSystemPrompt(int n, int m) =>
    'Match each subtitle file (1..$n) to the episode (1..$m) '
    'it belongs to.\n'
    'Rules:\n'
    '- Each file belongs to AT MOST one episode. Use ep=0 if no '
    'confident match is found. Episodes may go unassigned.\n'
    '- File position numbers and any filenames carry NO information '
    'about episode order — files may be arbitrarily ordered.\n'
    '- DO NOT use any prior knowledge of the show. '
    'Decide ONLY by matching subtitle content against the episode '
    'descriptions provided below.\n'
    '- If a summary is available, use it as the PRIMARY signal.\n'
    '- If only raw subtitle text is available, find a specific line '
    'in the excerpt that matches a phrase in an episode description '
    '— that quote is your evidence.\n'
    '- For files marked ⚠️ Non-English, use the summary ONLY — '
    'do NOT quote subtitle text.\n'
    '- For files marked ⚠️ Weak summary, rely more on subtitle text.\n'
    '- Consider all files together: prefer consistent season '
    'progression and avoid contradictory assignments.\n'
    'In your reasoning: for each file write '
    '"File N: [evidence] → matches ep M because [reason]" '
    'or "File N: no confident match".\n'
    'Then output JSON.\n'
    'Output format (confidence is 0.0–1.0, ep=0 means unassigned):\n'
    '{"reasoning":"evidence for every file",'
    '"assignments":{"1":{"ep":N,"confidence":0.0},...}}';

/// Single-file episode match; wording depends on whether a summary exists.
String episodeMatchSystemPrompt({
  required bool hasSummary,
  bool bonus = false,
}) =>
    'You identify which TV episode a subtitle belongs to.\n'
    '${hasSummary ? 'Use the plot summary as the primary signal and '
        'the subtitle excerpt as supporting evidence.\n' : 'Read the '
        'subtitle excerpt and match it to the episode description.\n'}'
    'Output STRICT JSON only: {"pick":N} (1-based).\n'
    '${bonus ? 'The candidates are DVD bonus features (featurettes, '
        'blooper reels, interviews, inside looks). Pick one only when its '
        'description clearly fits the material; an inside look at '
        'episode X is not episode X itself. Otherwise {"pick":0}.' : 'Always pick the closest match. '
        'Use {"pick":0} only if completely unrecognisable.'}';

/// Picks one of [count] title candidates when deterministic scoring is weak.
String titleFallbackSystemPrompt(String kind, int count) =>
    'Pick the best matching $kind based on the summary. '
    'Output STRICT JSON: {"pick":N} with N in 1..$count, '
    'or {"pick":0} if none clearly fit.';

/// Blind re-match of a summary against the episode list.
const String verifyPickSystemPrompt =
    'You identify which TV episode a plot summary describes.\n'
    'Output STRICT JSON: {"pick":N} (1-based index into the '
    'episode list), or {"pick":0} when unsure.';

/// Two summaries claimed the same episode; place each one.
String stemConflictSystemPrompt(
        {required String contestedTitle, required String contestedStem}) =>
    'Two subtitle summaries were both matched to episode '
    '"$contestedTitle" ($contestedStem), but each summary '
    'belongs to a DIFFERENT episode — at most one of them is that '
    'episode. Assign each summary to the episode it really '
    'describes, choosing from the numbered list.\n'
    'Output STRICT JSON: {"first":N,"second":M} (1-based indices '
    'into the episode list, 0 = cannot place). first and second '
    'must differ unless both are 0.';
