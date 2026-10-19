# cornil-gateway. Run `make help` to list targets.
.PHONY: help hooks check secrets-scan

help:  ## Show this list
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

hooks:  ## Turn on the pre-commit secret scan for this clone
	git config core.hooksPath scripts/hooks

secrets-scan:  ## Scan the whole git history and working tree for secrets
	gitleaks git --redact --verbose .
	gitleaks dir --redact --verbose .

check: secrets-scan  ## All checks (more are added in G2: syntax-check, caddy validate)
