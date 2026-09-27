# unbreak

Repairs terminal-wrapped clipboard commands from agent CLIs so they paste as clean shell
commands. macOS only. Product spec: `docs/PRDv2.md`; usage: README.md.

Verify with `make build` and `make test`, the chain the pre-push hook and `.gitlab-ci.yml` run.

GitLab is the source of truth. GitHub carries a read-only push mirror with Actions off: add no
`.github/workflows/`, and never push there. Setup: seor `design/github-mirror.md`.
