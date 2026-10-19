# cornil-gateway. Run `make help` to list targets.
# Routine targets use SSH as the service user and NO sudo. Only the three targets marked [SUDO] ask for
# the sudo password, and each one says what it changes in its playbook header.
VENV      := .venv-infra
ANSIBLE   := ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i local/inventory.ini $(if $(wildcard local/vars.yml),-e @local/vars.yml) $(if $(HTTP_PORT),-e gateway_http_port=$(HTTP_PORT)) $(if $(HTTPS_PORT),-e gateway_https_port=$(HTTPS_PORT))

.PHONY: quadlet-dryrun deploy-check help hooks ansible-setup syntax check test secrets-scan render deploy status backup-caddy-data root-cert smoke bootstrap-ports cutover rollback-legacy

help:  ## Show this list
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

hooks:  ## Turn on the pre-commit secret scan for this clone
	git config core.hooksPath scripts/hooks

ansible-setup:  ## Once on your Mac: install Ansible into a private folder (.venv-infra)
	python3 -m venv $(VENV) && $(VENV)/bin/pip install --quiet ansible-core

secrets-scan:  ## Scan the whole git history and working tree for secrets
	gitleaks git --redact --verbose .
	gitleaks dir --redact --verbose .

syntax:  ## Check that every playbook is well-formed; changes nothing
	for p in deploy backup-caddy-data status root-cert bootstrap-ports cutover rollback-legacy render; do \
	  ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i local/inventory.example.ini --syntax-check ansible/$$p.yml || exit 1; done

test:  ## Run the tests on the real rendered files (needs a local caddy: brew install caddy)
	scripts/test.sh

check: secrets-scan test  ## All checks: secret scan + tests

render:  ## Write the rendered Caddyfile and unit files to ./build for inspection
	ANSIBLE_CONFIG=ansible/ansible.cfg $(VENV)/bin/ansible-playbook -i localhost, ansible/render.yml -e @ansible/group_vars/all.yml

deploy:  ## Deploy or update Caddy on the server (no sudo). Trial ports: make deploy HTTP_PORT=8080 HTTPS_PORT=8443
	$(ANSIBLE) ansible/deploy.yml

deploy-check:  ## Rehearse a deploy without changing anything (ansible --check --diff)
	$(ANSIBLE) ansible/deploy.yml --check --diff

status:  ## Read-only overview of the gateway on the server
	$(ANSIBLE) ansible/status.yml

backup-caddy-data:  ## Back up Caddy's data dir (the CA, private key included) on the server
	$(ANSIBLE) ansible/backup-caddy-data.yml

root-cert:  ## Fetch Caddy's PUBLIC root certificate to local/cornil-root.crt
	$(ANSIBLE) ansible/root-cert.yml
	scripts/root-cert.sh local/cornil-root.crt

smoke:  ## Check the gateway end to end. Trial ports: make smoke HTTPS_PORT=8443 HTTP_PORT=8080
	HTTPS_PORT=$(or $(HTTPS_PORT),443) HTTP_PORT=$(or $(HTTP_PORT),80) scripts/smoke.sh

bootstrap-ports:  ## [SUDO, once] Allow ordinary users to listen on port 80 and up
	$(ANSIBLE) -K -l admin ansible/bootstrap-ports.yml

cutover:  ## [SUDO] Back up and stop the legacy Caddy so the new one can take ports 80/443
	$(ANSIBLE) -K -l admin ansible/cutover.yml

rollback-legacy:  ## [SUDO] Put the legacy Caddy back and stop the new one
	$(ANSIBLE) -K ansible/rollback-legacy.yml

quadlet-dryrun:  ## Ask the server's Quadlet generator to translate our unit files (prints only)
	scripts/quadlet-dryrun.sh
