.PHONY: install lint fmt test run migrate revision

install:
	uv sync

fmt:
	uv run isort src tests
	uv run black src tests

lint:
	uv run pylint src
	uv run mypy src

test:
	uv run pytest

run:
	uv run okolica

migrate:
	uv run alembic -c src/okolica/db/alembic.ini upgrade head

revision:
	uv run alembic -c src/okolica/db/alembic.ini revision --autogenerate -m "$(m)"
