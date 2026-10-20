# CLAUDE.md -- cancho-mqtt-client

Read `docs/design.md` before changing anything; it is written before the code and every claim in it is measured, read from a named
file, or marked as a choice or open. The rules that matter most:

- **A library, not a program.** It declares no authority of its own: the program that uses it carries the `net_out` row. A change that
  makes the library reach for a file, a clock it was not handed, or a process is wrong (design section 3).
- **Total decoders.** No input reaches a panic; every refusal is a value with a rule tag `client.<name>`; a malformed packet from a
  broker is data, never a trap.
- **The gate:** the one in design section 9, fixed before the code it judges and shown failing against a broken variant.
- **No file over 2,000 lines. Measured claims only.** A claim found false is corrected in place, in the document that made it.
- Commit trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; PRs stay draft until the maintainer says merge; no
  force-push.
