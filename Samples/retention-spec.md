---
title: Data Retention Specification
status: draft
owner: Platform
---

# Data Retention Specification

## 1. Scope

This document covers **personal data** and *operational data* held by the platform. It
does not cover backups, which are governed by [the backup policy](https://example.com/bk)
--- a separate document with a separate retention rule.

## 2. Definitions

Collection event
: The moment a record first reaches a Worker log.

Deletion
: Removal from primary storage and from every replica, such that `SELECT` cannot return
  the row.

## 3. Retention periods

### 3.1 Personal data

All personal data is **retained for a period of ninety (90) days** from the date of
collection, after which it is deleted on the next scheduled sweep. The sweep runs daily
at 03:00 UTC and `MAX_AGE` is not configurable at runtime.[^sweep]

Records covered:

- Email addresses and *display names*
- Session tokens, including refresh tokens
- ~~Legacy audit rows~~ (removed in v4)

[^sweep]: A sweep that fails is retried once. A second failure pages the on-call engineer.

| Field | Days | Notes |
|---|---|---|
| Email address | 90 | From last contact |
| Session token | 1 | Rotated on each sign-in |
| Audit row | 365 | See §3.3 |

> Deletion is irreversible. There is no restore path, and support cannot recover a record
> once the sweep has run.

### 3.2 Operational data

All operational data is retained for a period of ninety (90) days from the date of
collection --- deliberately the same sentence as §3.1, and a good test of whether a
review can tell two identical passages apart.

### 3.3 Audit data

Audit rows are kept for one year. Anything not named in §3 is out of scope and continues
to be held indefinitely.

## 4. Requests

- [x] Erasure requests are honoured within 30 days
- [ ] Portability requests are not yet implemented

```python
def purge(older_than_days: int = 90) -> int:
    """Delete records past the retention window. Returns the number removed."""
    return store.delete(age_gt=older_than_days)
```
