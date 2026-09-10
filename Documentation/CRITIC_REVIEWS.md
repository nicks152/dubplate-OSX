# Critic reviews

Six rounds of independent review after the first complete implementation. Each round
was carried out by a separate reviewing agent with no stake in the code, given the
brief's prompt verbatim and read-only access to the repository, the documentation and
the design renderings in `design/renders/`.

Every round records what was found, **what was implemented, what was rejected and
why**. A review that produces only agreement is not a review, and a review where
every finding is accepted is not one either.

Rounds 1, 3 and 4 were gathered concurrently to save wall-clock time; their findings
were then implemented in order, and rounds 2, 5 and 6 each ran against the code as it
stood after the previous round's changes. Nothing was implemented before the round
that found it.

## Standing constraint on every round

There is no Apple toolchain in this environment. No round could build or run the
application; every round reviewed source, copy, flows and — for the design round —
renderings redrawn from the design system's own values. `Tools/swiftcheck.py` and
`Tools/pbxcheck.py` were re-run after every round's changes, and are the only
mechanical verification available. See `QA.md`.

---
