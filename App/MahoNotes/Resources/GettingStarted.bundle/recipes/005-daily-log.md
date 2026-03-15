---
title: "Recipe: Daily Log"
tags: [recipe]
created: 2026-03-15T00:00:00-05:00
updated: 2026-03-15T00:00:00-05:00
public: false
---

# Daily Log / Bullet Journal

Use Maho Notes as a simple daily journal. One note per day, plain markdown, no fuss.

## Daily Log Template

---

### 📅 Saturday, March 15, 2026

#### 🌅 Morning

- [x] Review pull requests
- [x] Reply to emails
- [ ] Read chapter 5 of DDIA

#### 🔬 Research

- Ran simulation batch #42 — results look promising
- Found a bug in the boundary condition: $\rho \to 0$ at the outer edge
- Need to check if the EOS table covers $T < 10^8$ K

$$
\frac{\partial \rho}{\partial t} + \nabla \cdot (\rho \mathbf{v}) = 0
$$

#### 💡 Ideas

> Idea: what if we use adaptive mesh refinement only in the shock region?
> Could save 60% compute time. Worth prototyping next week.

#### 📖 Reading

- "The Art of Doing Science and Engineering" — Ch. 3: good reminder that most learning is self-taught

#### 🌙 End of Day

Today was productive. Simulation results are encouraging — if the boundary fix works, we might have a paper draft by end of month.

**Mood:** 😊 | **Energy:** ⚡⚡⚡⚡

---

## Weekly Review Template

---

### 📊 Week of March 10–16, 2026

#### Wins 🎉
- Shipped v0.6.0 of Maho Notes
- Finished reading 2 papers on neutrino transport

#### Challenges
- Build server was down for 2 days
- Still stuck on the convergence issue in the MHD solver

#### Next Week
- [ ] Fix convergence issue (try smaller CFL number)
- [ ] Submit conference abstract
- [ ] Start writing introduction section

---

## Tips

> [!tip]
> **File naming:** Use `YYYY-MM-DD.md` (e.g., `2026-03-15.md`) for daily logs. They'll sort perfectly in your collection.

> [!note]
> You don't need to fill every section every day. Skip what doesn't apply — the template is a guide, not a requirement. Some days are just a few bullet points, and that's fine.
