---
name: detailed-pr-description
description: Assess test coverage or draft/update GitHub PR descriptions with self-contained context, risks, follow-up work, focused code references, and validation results.
---

# Detailed PR Description

## Resolve the outcome

- **Assessment:** judge whether branch tests are strong enough; do not draft or update a PR body.
- **Draft:** produce a proposed body locally or in the response; do not mutate GitHub.
- **Update/post:** draft and update GitHub only when explicitly asked to update, edit, post, or publish.

Perform each requested outcome when combined. CLI access is never authorization to mutate a PR.

## Workflow

1. Identify the PR and base. Prefer `gh pr view --json number,title,body,baseRefName,headRefName,url`; without a PR, compare against the user-provided or repository default base. Fetch before relying on stale refs.
2. Establish evidence from `git status --short`, diff stats and names, relevant commits, changed files, tests, docs, migrations, config, and generated artifacts. Treat `.context/` as scratch and restate any useful fact because it is untracked. Do not rely on chat or memory for behavioral claims.
3. Determine the problem, approach, outcome, deliberate exclusions, risk, compatibility, edge cases, operational gotchas, migrations, flags, cleanup, and reviewer focus. For close-review items, give a precise file/line reference and explanation. Every PR body must include one fenced excerpt of actual changed code, configuration, or documentation from the most review-critical hunk, capped at 15 lines; a link-only review section is insufficient.
4. Inventory affected and added tests. Run the narrowest reliable checks, then documented broader validation when feasible. Classify coverage as sufficient, partially sufficient, or insufficient; name regressions it catches, important gaps, and concrete follow-up tests. Never claim confidence from unrun or irrelevant tests.
5. Deliver only the authorized outcome:
   - Assessment: report evidence and coverage judgment without creating a body.
   - Draft: return the body or write `.context/pr-description.md`; never call `gh pr edit`.
   - Update/post: write `.context/pr-description.md`, then use `gh pr edit <number> --body-file .context/pr-description.md`. If posting fails, preserve the draft and explain why.

## PR body

For draft/update work, load `assets/pr-body.md.tmpl` unless the repository has a stronger template. The body must stand alone without chat or local notes. Prefer high-signal context; add screenshots, rollout, migrations, flags, performance, accessibility, security, or release notes only when relevant. Remove an empty section only when it genuinely does not apply; use `Not applicable` when omitting it could hide an important review dimension.

## Quality bar

- Ground claims in code, tests, docs, commits, or command output; distinguish facts from assumptions and judgment.
- Preserve the existing title and useful body content unless replacement is clearer.
- Name behavior instead of saying “various fixes” or “improves behavior.”
- Cite precise file/line references for close-review items. Include one actual changed excerpt in a fenced code block; it must be materially helpful and at most 15 lines.
- Include failed, skipped, and unavailable validation with reasons.
- Do not make unrelated code changes unless explicitly asked.

## Final response

Report the PR URL when one exists, whether the outcome was an assessment, local draft, or posted update, validation commands/results, and the bottom-line coverage assessment. If an authorized post failed, report the draft path.
