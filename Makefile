.PHONY: lint test check deploy

lint:
	shellcheck -x scripts/*.sh scripts/lib/*.sh
	flake8 python tests
	cd ansible && ansible-playbook site.yml lab-setup.yml --syntax-check

test:
	pytest -v

check: lint test

deploy:
	cd ansible && ansible-playbook site.yml
