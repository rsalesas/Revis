---
title: Data Retention
status: draft
---

# Data Retention Specification

## 2. Definitions

**Collection event** --- the moment a record first reaches a Worker log.

## 3. Retention periods

### 3.1 Personal data

All personal data is **retained for a period of ninety (90) days** from the date of
collection --- see [the retention policy](https://example.com/policy) for the rules
that apply, and note that `MAX_AGE` is not configurable at runtime.

Records covered:

- Email addresses and *display names*
- Session tokens[^tok]
- ~~Legacy audit rows~~

[^tok]: Tokens are rotated on each sign-in.

| Field | Days | Notes |
|---|---|---|
| Email | 90 | From last contact |
| Token | 1 | Rotated |

> Deletion is irreversible. There is no restore path.

### 3.2 Operational data

All operational data is retained for a period of ninety (90) days from the date of
collection, which is a different rule that happens to read the same.
