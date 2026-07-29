# Left Wordle API Interface

Base path: `/api/v1`

All responses use `Content-Type: application/json` and `Cache-Control: no-store`. All error bodies use a `detail` field.

---

## CORS

Browser requests must include an `Origin` header that matches one of the values in the `CORS_ORIGINS` environment variable (comma-separated list of exact origins). If the origin is recognized, it is echoed back in `Access-Control-Allow-Origin`. If unrecognized, the request is rejected with 403. Server-to-server requests without an `Origin` header are always allowed.

All responses include `Vary: Origin` to prevent cache mixing.

---

## Endpoints

### GET /api/v1/health

Returns a simple availability check.

**Response 200**
```json
{ "status": "ok" }
```

---

### GET /api/v1/version

Returns application version information.

**Response 200**
```json
{
  "version": "v1.2.3",
  "commit": "a1b2c3d4",
  "release": 12
}
```

- `version` — git release tag (e.g. `v1.2.3`) written to `VERSION` at deploy time; `null` if the file is absent
- `commit` — first 8 characters of the git SHA from the `REVISION` file; `null` if the file is absent
- `release` — number of entries in `revisions.log`; `null` if the file is absent

---

### GET /api/v1/game/answer

Returns an encrypted representation of the puzzle answer for a given date. The answer is XOR-encrypted with a shared key so that the plaintext is not stored in client game state.

**Query Parameters**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD` |

**Response 200**
```json
{
  "encrypted_answer": "1b38500c3c",
  "puzzle_num": 0,
  "date": "2021-06-19"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `encrypted_answer` | string | Hex-encoded XOR-encrypted answer; decryptable client-side with the shared key |
| `puzzle_num` | integer | Days since puzzle epoch |
| `date` | string | Echoes the requested date |

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Date is required` | `date` param missing |
| 400 | `Date must use YYYY-MM-DD format` | Unparseable date string |
| 400 | `Date must be a valid calendar date` | Structurally valid but impossible date |
| 400 | `Date cannot be later than YYYY-MM-DD` | Date is in the future |

---

### POST /api/v1/game/remaining_counts

Returns the number of possible answers remaining after each guess in a completed game, for use in share text. Accepts the full list of guesses and evaluations and computes remaining counts cumulatively.

**Request Body** (`application/json`)

```json
{
  "date": "2021-06-19",
  "guesses": [["crane", "01200"], ["slate", "00110"]]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD` |
| `guesses` | array | Yes | Array of `[word, pattern]` pairs for all guesses. Each pattern is a 5-character digit string (`0`=absent, `1`=present, `2`=correct). |

**Response 200**
```json
{
  "date": "2021-06-19",
  "remaining_counts": [145, 23]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `date` | string | Echoes the requested date |
| `remaining_counts` | array | Integer count of possible answers remaining after each guess, in the same order as the request |

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Date is required` | `date` field missing |
| 400 | `Date must use YYYY-MM-DD format` | Unparseable date string |
| 400 | `Date must be a valid calendar date` | Impossible calendar date |
| 400 | `Date cannot be later than YYYY-MM-DD` | Future date |
| 400 | `guesses must be an array of [word, pattern] pairs` | `guesses` is malformed |
| 400 | `guesses cannot have more than 6 entries` | More guess pairs than a game can contain |

---

### GET /api/v1/game/puzzle

Returns puzzle metadata for a given date.

**Query Parameters**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD` |

**Response 200**
```json
{
  "puzzle_num": 0,
  "date": "2021-06-19",
  "word_length": 5
}
```

- `puzzle_num` — days since the puzzle epoch (`2021-06-19`); puzzle 0 is the first puzzle
- `date` — echoes the requested date
- `word_length` — always `5`

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Date is required` | `date` param missing |
| 400 | `Date must use YYYY-MM-DD format` | Unparseable date string |
| 400 | `Date must be a valid calendar date` | Structurally valid but impossible date (e.g. Feb 30) |
| 400 | `Date cannot be later than YYYY-MM-DD` | Date is in the future beyond the latest available puzzle date |

The latest available date is determined by the current time at UTC+14 (the world's furthest-ahead timezone), so all time zones have access to the same puzzle on the intended calendar day.

---

### POST /api/v1/diagnostics

Accepts a client settings snapshot as a JSON body and emails it to the developers as an attachment for troubleshooting.

**Request Body** (`application/json`)

Any valid JSON object. Typically a full dump of the client's localStorage, keyed by storage key name.

**Response 200**
```json
{ "status": "sent" }
```

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Request body is required` | Empty body |
| 400 | `Request body must be valid JSON` | Body is not parseable JSON |
| 503 | `Diagnostics email is not configured` | `smtp_username` or `smtp_password` missing from server config |

---

### POST /api/v1/game/guess

Evaluates a guess against the puzzle answer for a given date, enforcing mode rules and optionally returning the number of answers still possible.

**Request Body** (`application/json`)

```json
{
  "date": "2021-06-19",
  "guess": "crane",
  "row_index": 2,
  "mode": "hard",
  "prev_guesses": [["slate", "01200"], ["crate", "02200"]],
  "return_remaining_count": true
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD` |
| `guess` | string | Yes | 5-letter word; case-insensitive |
| `row_index` | integer | No | Zero-based guess attempt number (0–5); defaults to `0` |
| `mode` | string | No | Game mode: `"regular"`, `"hard"`, or `"insane"`; defaults to `"regular"` |
| `prev_guesses` | array | No | Array of `[word, pattern]` pairs for all prior guesses in order. Each pattern is a 5-character digit string (`0`=absent, `1`=present, `2`=correct). Defaults to `[]`. Required for mode validation when `mode` is `"hard"` or `"insane"`. |
| `return_remaining_count` | boolean | No | When `true`, include `answers_remaining` in the response; defaults to `false` |

**Response 200**

```json
{
  "date": "2021-06-19",
  "evaluation": "01020",
  "game_status": "IN_PROGRESS",
  "puzzle_num": 0,
  "guess_number": 3,
  "solution": null,
  "answers_remaining": 12
}
```

| Field | Type | Description |
|-------|------|-------------|
| `date` | string | Echoes the requested date |
| `evaluation` | string | Per-letter result as a 5-character digit string: `0`=absent, `1`=present, `2`=correct |
| `game_status` | string | Current game state (see below) |
| `puzzle_num` | integer | Days since puzzle epoch |
| `guess_number` | integer | The ordinal guess number (1–6); 1 = first guess |
| `solution` | string or null | The answer word; only revealed on `WIN` or `FAIL`, otherwise `null` |
| `answers_remaining` | integer | Number of possible answers remaining after this guess (includes current guess in filter); only present when `return_remaining_count` is `true` |

**Evaluation digit values**

| Digit | Meaning |
|-------|---------|
| `"2"` | Letter is in the correct position |
| `"1"` | Letter is in the answer but in the wrong position |
| `"0"` | Letter is not in the answer |

Duplicate letters are handled correctly — a letter is only marked `1` or `2` as many times as it appears in the answer.

**Game status values**

| Value | Meaning |
|-------|---------|
| `"IN_PROGRESS"` | Game is still active (guess was not a win and `row_index` < 5) |
| `"WIN"` | All 5 letters are correct |
| `"FAIL"` | Sixth guess (`row_index` 5) was not a win |

**Mode rules**

Mode validation runs before evaluation. A 400 is returned if the guess violates the rules for the active mode.

*Hard mode* — based on the most recent entry in `prev_guesses`:
- Letters marked correct (`2`) must appear in the same position.
- Letters marked correct or present (`1` or `2`) must appear at least as many times as they were found.

*Insane mode* — all hard mode rules apply, plus cumulative constraints across all `prev_guesses`:
- A letter marked present (`1`) may never reappear in that same position in any subsequent guess.
- A letter marked absent (`0`) is banned entirely, unless the same letter was also marked present or correct in the same row (double-letter case); then the exact count from that row becomes the maximum allowed.

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Request body must be valid JSON` | Body is not parseable JSON |
| 400 | `Request body must be a JSON object` | Body parses but is not an object |
| 400 | `Date is required` | `date` field missing |
| 400 | `Date must use YYYY-MM-DD format` | Unparseable date string |
| 400 | `Date must be a valid calendar date` | Impossible calendar date |
| 400 | `Date cannot be later than YYYY-MM-DD` | Future date |
| 400 | `Guess must be 5 letters` | `guess` is not exactly 5 alphabetic characters |
| 400 | `Not in word list` | `guess` is 5 letters but not a recognized word |
| 400 | `Row index must be an integer` | `row_index` is present but not an integer |
| 400 | `Row index must be between 0 and 5` | `row_index` is outside the valid range |
| 400 | `Mode must be regular, hard, or insane` | `mode` is present but not a recognized value |
| 400 | `prev_guesses must be an array of [word, pattern] pairs` | `prev_guesses` is not an array, or any element is not a `[5-letter-word, 5-digit-pattern]` pair |
| 400 | `prev_guesses cannot have more than 6 entries` | More prior guess pairs than a game can contain |
| 400 | `{N}th letter must be {X}` | Hard/insane: correct-position letter not reused (e.g. `"1st letter must be C"`) |
| 400 | `Guess must contain {X}` | Hard/insane: required letter (correct or present) is missing from the guess |
| 400 | `{X} can't be in {N}th position` | Insane: present letter reused in a previously forbidden position |
| 400 | `Guess cannot contain {X}` | Insane: absent letter appears in the guess |
| 400 | `Too many {X}s` | Insane: letter appears more times than allowed by the exact-count constraint |

---

### GET /api/v1/ref/legal_words

Returns the complete sorted list of words accepted as valid guesses.

**Response 200**
```json
["aback", "abase", "abash", ...]
```

A JSON array of lowercase 5-letter strings, sorted alphabetically. This list is the superset of the answer list — every answer is a legal word, but not every legal word is an answer.

---

### GET /api/v1/ref/answers

Returns the complete sorted answer list, regardless of whether each word has already been used as a daily puzzle.

**Response 200**
```json
["abbey", "alien", "cigar", ...]
```

A JSON array of lowercase 5-letter strings, sorted alphabetically.

---

### GET /api/v1/ref/prev_answers

Returns all past puzzle answers up to (but not including) the puzzle for the given date.

**Query Parameters**

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD`. Results include all puzzles before this date. |

**Response 200**
```json
[
  { "puzzle_number": 0, "date": "2021-06-19", "word": "cigar" },
  { "puzzle_number": 1, "date": "2021-06-20", "word": "rebut" }
]
```

The array is ordered by `puzzle_number` ascending. An empty array is returned when `date` is the puzzle epoch (no prior puzzles exist).

| Field | Type | Description |
|-------|------|-------------|
| `puzzle_number` | integer | Zero-based puzzle index |
| `date` | string | ISO 8601 date of that puzzle |
| `word` | string | The answer for that puzzle |

**Error Responses**

| Status | `detail` | Condition |
|--------|----------|-----------|
| 400 | `Date is required` | `date` param missing |
| 400 | `Date must use YYYY-MM-DD format` | Unparseable date string |
| 400 | `Date must be a valid calendar date` | Impossible calendar date |
| 400 | `Date cannot be later than YYYY-MM-DD` | Future date |

---

### OPTIONS *

Handles CORS preflight for all routes.

**Response 204** (no body)

```
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
Access-Control-Allow-Origin: <origin> (if recognized)
```

---

## Common Error Responses

| Status | `detail` | Condition |
|--------|----------|-----------|
| 403 | `Origin not allowed` | `Origin` header present but not in `CORS_ORIGINS` |
| 404 | — | Route does not exist |
| 500 | `Internal server error` | Unhandled server exception |

---

## Game Constants

| Constant | Value |
|----------|-------|
| Word length | 5 |
| Max guesses | 6 |
| Puzzle epoch | 2021-06-19 (puzzle 0) |
