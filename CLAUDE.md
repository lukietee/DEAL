# DEAL: notes for Claude (and every subagent)

## Commits
- Commit regularly: after each working, tested unit of change. Don't let work pile up uncommitted.
- Every commit message ends with BOTH trailers, in this order, no exceptions (subagents too):

```
Co-Authored-By: lukietee <lucasnotlukie@gmail.com>
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

- When spawning a subagent that may commit, repeat this rule in its prompt.
- Don't push without Lucas's OK.
