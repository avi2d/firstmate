# 0007: Firstmate home role and publication consent contract

Date: 2026-10-20.
Status: accepted.

## Context

The publication consent contract lived as a 65 line header in bin/fm-role-lib.sh.
Comment discipline moves long rationale to the record whole, so the header now lives here and the code keeps one invariant line.
This record carries the upstream sync resolution: the publication target prefers the first remote whose remote.<name>.gh-resolved is base, then one naming an explicit owner/repo on its own host, then legacy remote order.

## Decision

Every Firstmate home runs as a user/operator by default.
It may consume firstmate, change its gitignored operational state, and repair the installation locally, but nothing it does publishes to the firstmate repository's upstream.
Upstream publication, such as a pushed branch, pull request, issue, comment, or fork, requires an explicit home-local grant.
The grant is either the maintainer opt-in the operator writes into config/firstmate-role, or a bounded per-task consent recorded at dispatch.
Role is never inferred from gh identity, permissions, remotes, environment, or CI.
docs/configuration.md "Firstmate role" owns the operator-facing schema.
The library owns parsing, repository-identity normalization, self-repository detection, and the fail-closed gate the dispatch surfaces share.
Everything resolves from files and local git plumbing only, and nothing calls gh or the network.
The role file holds one directive line, with blank lines and full-line # comments ignored.
`user` is the default and may be omitted.
`maintainer <host>/<owner>/<repo>` declares this home develops firstmate for the named upstream.
A scope names the publication target repository where a PR lands, not a push destination.
In a secondmate home, marked by .fm-secondmate-home, a role file authorizes nothing on its own.
It is trusted only when the existing config-inheritance receipt config/.fm-inherit-firstmate-role.generation proves the exact bytes the parent last published there, so a stale or unproven grant is dead on arrival.
The parent publishes its resolved role through fm_role_inherit_payload, never its raw file, so a child never gains through supported propagation a grant the parent does not resolve.
The receipt proves consistency, not provenance: it prevents accidental publication through supported paths and is not a security boundary against a process that deliberately forges local records.
Self-repository detection compares the task's project dir against the running code root by repository lineage, offline.
A shared git common dir covers linked worktrees and the code root itself, and a project holding a root commit of the code root's history covers any fork, the parent, and any clone of either.
Lineage that cannot be determined, through missing code root history or a shallow side sharing no root, refuses rather than permits.
The publication target is compared only against a maintainer scope or task consent.
It is the first remote whose remote.<name>.gh-resolved is base, else one whose gh-resolved names an explicit owner/repo on its own host, otherwise the first remote named upstream, github, or origin, in the order gh prefers when resolving a default repository, reduced to lowercase host/owner/repo.
A local-path remote is resolved one hop through that repository's own origin, and left as path:<abs> when unreadable.
An unknown target never permits.
The library exposes fm_role_file, fm_role_scope_valid, fm_role_scope_norm, fm_role_remote_identity, fm_role_publication_target, fm_role_self_repo, fm_role_parse_file, fm_role_resolve, fm_role_inherit_payload, and fm_role_gate_self_publish.
Its global outputs are FM_ROLE, FM_ROLE_SCOPE, FM_ROLE_SOURCE, FM_ROLE_DIAG, FM_ROLE_PUB_TARGET, FM_ROLE_PUB_AUTHORITY, and FM_ROLE_PUB_DENIAL.

## Consequences

Undeterminable lineage or publication target refuses rather than permits, even under task consent.
An unreadable or URL-less marked remote is not replaced by a fallback remote.
A secondmate home without a matching receipt authorizes nothing.
