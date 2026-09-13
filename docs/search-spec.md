# Launcher search spec (contract for `Packages/Search`)

`Packages/Search` covers four things:
- fuzzy matching
- the zoxide frecency store
- ranking
- Raycast script-header parsing and splitting of inline arguments

It is pure Swift with Foundation only. The launcher UI calls `Ranker.rank` on every keystroke, so ranking 500 items must take under 2 ms.

## Items

```swift
public struct SearchItem: Hashable, Sendable {
    public var id: String              // stable frecency key: "app:/Applications/Safari.app", "script:/path", "command:<title>"
    public var title: String
    public var keywords: [String]      // secondary match strings: bundle name, file name
    public var aliases: [String]       // exact shortcuts from config or `@alauncher.alias`
    public var subtitle: String?
    public var kind: Kind              // app, script, command
    public var argumentCount: Int?     // nil: takes no arguments; 0: undeclared (inline text becomes $1); N: declared
}
```

## Fuzzy matching: `FuzzyMatcher.match(_ query:, in candidate:) -> FuzzyMatch?`

**Normalization**
- Case-insensitive and diacritic-insensitive: `cafe` matches `Café`.
- Spaces in the query are ignored for matching: `vs code` matches `Visual Studio Code`.
- The result is nil unless every query character appears in the candidate, in order.

**Word starts**
- Index 0.
- After a space, `-`, `_`, `.`, `/`, `(`.
- At a lowercase→uppercase transition (`iTerm` → `T`).
- At a letter↔digit transition.

**Tiers** (match score = tier × 100 + fine score, where the fine score is 0–99):

| Tier | Name | Rule |
|---|---|---|
| 5 | exact | normalized candidate == normalized query |
| 4 | prefix | candidate starts with the query |
| 3 | word | the query is a prefix of a later word (`code` in `Visual Studio Code`), or every query character lands on a word start in order (acronym: `vsc`, `am` → Activity Monitor) |
| 2 | substring | a contiguous match anywhere |
| 1 | subsequence | scattered |

**Fine score** (deterministic)
- Better for shorter candidates, earlier first match, longer consecutive runs, and more matched characters on word starts.

**Positions**
- `positions` are the `Character` offsets of the chosen match in the original candidate, used for highlighting.

## Keywords and aliases

**Keywords**
- Each item's title and each keyword is matched, and the best score wins.
- A keyword match scores 50 less than the same tier on the title, and `titlePositions` is empty for it.

**Aliases**
- An alias that equals the whole normalized query is an alias hit, and ranks above everything else.
- An alias the query is a prefix of scores as a tier-4 keyword match.

## Frecency: zoxide's algorithm, `FrecencyStore`

**Storage**
- JSON: `{"version": 1, "entries": {"<id>": {"rank": 3.0, "last": 1789310000}}}`, where `last` is in epoch seconds.
- Written atomically after each change.
- A missing or corrupt file starts empty and is never an error.

**`recordLaunch(of:now:)`**
- `rank += 1` (a new entry starts at 1), then `last = now`.
- Then age the store: if Σrank > `maxAge`, multiply every rank by `0.9 × maxAge / Σrank` and drop entries whose rank falls below 1.
- These are zoxide's `src/db/mod.rs` `add` and `age`. `maxAge` defaults to 10,000.

**`score(for:now:)`**
- rank × 4 if `now − last` is under 1 hour, × 2 under 1 day, × 0.5 under 1 week, × 0.25 otherwise. This is zoxide's `src/db/dir.rs` `score`.
- An unknown id scores 0.

**Threading**
- Thread-safe through an internal lock, so the type is `Sendable` without `@unchecked` tricks leaking into callers.

## Ranking: `Ranker.rank(_ query:, in items:, limit:, now:) -> [RankedItem]`

**Empty query**
- Items with frecency > 0, highest first. Ties break by title, then id. Up to `limit`.

**Inline invocation, checked first**
- Applies when the query is `<word> <rest>`, `<word>` exactly equals an alias of an item whose `argumentCount != nil`, and `<rest>` is not empty after trimming.
- That item comes first with `arguments = InlineArguments.split(rest, declaredCount: argumentCount!)`.
- The other items are ranked against the whole query as usual and follow it.

**Otherwise**
1. Alias hits come first, in frecency order.
2. Every other matching item gets `final = matchScore + min(150, weight × 40 × ln(1 + frecency))`.
3. An exact title match (tier 5) gets a further +1,000, so no fuzzy match can outrank it.
4. Sort by `final` (descending), then title (case-insensitive, ascending), then id.

## Inline arguments: `InlineArguments.split(_ text:, declaredCount:) -> [String]`

- **`declaredCount` ≤ 1:** the whole trimmed text is argument 1.
- **`declaredCount` = N ≥ 2:** shell-style tokenizing.
  - Single and double quotes and backslash escapes are respected.
  - The first N−1 tokens become arguments 1…N−1.
  - The rest of the original text becomes argument N, trimmed with quotes preserved.
  - With fewer tokens than N, the result is shorter; the launcher prompts for the missing ones.

## Script headers: `ScriptCommandParser`

**Reading**
- Read at most the first 16 KB, as UTF-8 with lossy fallback.

**Header lines**
- Optional whitespace, then a comment marker, then `@raycast.<key>` or `@alauncher.<key>`, then whitespace and a value running to the end of the line (trimmed).
- Comment markers: `#`, `//`, `--`, `;`, `%`, `'`, `REM`.

**Keys**

| Key | Meaning |
|---|---|
| `title` | Required; without it, return nil |
| `mode` | `silent`, `compact`, `fullOutput` or `inline`; missing or unknown means `compact` |
| `packageName`, `icon`, `description` | Stored |
| `needsConfirmation` | `true`/`false` |
| `currentDirectoryPath` | `~` expanded |
| `argument1` … `argument3` | JSON objects: `{"type": "text"\|"password"\|"dropdown", "placeholder": "…", "optional": bool, "percentEncoded": bool, "data": [{"title": "…", "value": "…"}]}`. Malformed JSON skips that argument |
| `@alauncher.alias` | Repeatable, and may be comma-separated. Becomes `aliases` |
| anything else | Ignored, including `schemaVersion`, `author`, `authorURL`, `iconDark`, `refreshTime` |

## Tests (Swift Testing)

- **Matching:** each tier; diacritics; camelCase and acronyms; that `positions` is correct.
- **Frecency:** the zoxide formulas exactly (score buckets, aging threshold, dropping below 1), persistence round-trip, and corrupt-file recovery.
- **Ranking:** alias first; exact title protected; frecency moving an item up at most about one tier; the empty query; deterministic ties; the performance budget.
- **Inline arguments:** `gh foo bar` → `["foo bar"]` with 1 declared; quoting with 2 or 3 declared; aliases that are prefixes of other words.
- **Headers:** a sample Raycast script (`Fixtures/pass-choose.sh`), plus headers in several comment styles.
