---
title: "Recipe: Meeting Notes"
tags: [recipe]
created: 2026-03-15T00:00:00-05:00
updated: 2026-03-15T00:00:00-05:00
public: false
---

# Meeting Notes

A simple, repeatable format for capturing meetings. Since Maho Notes files are just markdown, you can search across all your meetings later.

## Template

---

### 📅 Weekly Sync — March 15, 2026

**Attendees:** Alice, Bob, Carol
**Duration:** 30 min

#### Agenda

1. Sprint progress review
2. API redesign proposal
3. Conference deadline

#### Discussion

**Sprint progress:**
- Backend API is 80% complete, frontend blocked on design review
- Performance test showed 2x improvement after caching layer

**API redesign:**
- Agreed to use REST for public API, gRPC for internal services
- Carol will draft the new schema by Friday

> [!warning]
> The old `/v1/users` endpoint will be deprecated April 1st. All clients need to migrate.

**Conference:**
- Paper deadline extended to March 28
- Need to finalize figures this week

#### Action Items

- [ ] Carol: Draft new API schema (by March 21)
- [ ] Bob: Update client SDK for v2 endpoints
- [ ] Alice: Finalize conference paper figures
- [x] Everyone: Review last week's action items ✅

#### Decisions

| Decision | Rationale |
|----------|-----------|
| REST for public API | Better tooling, wider adoption |
| gRPC for internal | Performance, type safety |
| Extend paper deadline | Extra week for polish |

---

## Tips

> [!tip]
> **Naming convention:** Use dates in filenames like `2026-03-15-weekly-sync.md` — they'll sort chronologically in your collection.

> [!note]
> Put meeting notes in their own collection (e.g., `meetings/`). With Maho Notes' search, you can quickly find "that meeting where we decided to use gRPC" months later.
