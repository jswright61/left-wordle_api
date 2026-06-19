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
  "commit": "a1b2c3d4",
  "release": 12
}
```

- `commit` — first 8 characters of the git SHA from the `REVISION` file; `null` if the file is absent
- `release` — number of entries in `revisions.log`; `null` if the file is absent

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

### POST /api/v1/game/guess

Evaluates a guess against the puzzle answer for a given date.

**Request Body** (`application/json`)

```json
{
  "date": "2021-06-19",
  "guess": "crane",
  "row_index": 0
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `date` | string | Yes | ISO 8601 date — `YYYY-MM-DD` |
| `guess` | string | Yes | 5-letter word; case-insensitive |
| `row_index` | integer | No | Zero-based guess attempt number (0–5); defaults to `0` |

**Response 200**

```json
{
  "date": "2021-06-19",
  "evaluation": ["absent", "present", "correct", "absent", "absent"],
  "game_status": "IN_PROGRESS",
  "puzzle_num": 0,
  "guess_number": 1,
  "solution": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `date` | string | Echoes the requested date |
| `evaluation` | array of strings | Per-letter result; one entry per letter (see below) |
| `game_status` | string | Current game state (see below) |
| `puzzle_num` | integer | Days since puzzle epoch |
| `guess_number` | integer | The ordinal guess number (1–6); 1 = first guess |
| `solution` | string or null | The answer word; only revealed on `WIN` or `FAIL`, otherwise `null` |

**Evaluation values**

| Value | Meaning |
|-------|---------|
| `"correct"` | Letter is in the correct position |
| `"present"` | Letter is in the answer but in the wrong position |
| `"absent"` | Letter is not in the answer |

Duplicate letters are handled correctly — a letter is only marked `present` or `correct` as many times as it appears in the answer.

**Game status values**

| Value | Meaning |
|-------|---------|
| `"IN_PROGRESS"` | Game is still active (guess was not a win and `row_index` < 5) |
| `"WIN"` | All 5 letters are `correct` |
| `"FAIL"` | Sixth guess (`row_index` 5) was not a win |

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
