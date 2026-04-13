# Repository Guidelines

## Project Structure & Module Organization
- `codeloom/` contains the backend application (FastAPI entrypoints in `api/`, core logic in `core/`, UI helpers in `ui/`, settings in `setting/`).
- `frontend/` contains the React + Vite TypeScript client (`src/pages`, `src/components`, `src/hooks`, `src/services`).
- `codeloom/tests/` holds backend/unit and integration tests; `tests/e2e/` holds Playwright end-to-end specs.
- `alembic/` and `alembic.ini` manage DB migrations; migration files live in `alembic/versions/`.
- `docs/`, `tasks/`, and `tools/` store architecture notes, planning docs, and optional parser/enrichment tools.

## Build, Test, and Development Commands
```bash
# Linux/macOS
./dev.sh local          # start backend + frontend
./dev.sh build          # build frontend, sync deps, run migrations

# Windows PowerShell
.\dev.ps1 local         # start backend + frontend
.\dev.ps1 build         # build frontend, sync deps, run migrations

# Database
alembic upgrade head    # apply latest schema

# Backend tests
pytest -v -x

# Frontend (from frontend/)
npm run dev
npm run build
npm run lint

# E2E (repo root)
npx playwright test
```

## Coding Style & Naming Conventions
- Python: 4-space indentation, type hints where practical, `snake_case` for functions/modules, `PascalCase` for classes.
- TypeScript/React: components in `PascalCase` (`ProjectView.tsx`), hooks prefixed with `use` (`useProjects.ts`), utility/service files in descriptive `camelCase` or domain names.
- Keep route modules grouped by domain (`codeloom/api/routes/*.py`) and avoid cross-layer imports when a service exists in `core/services/`.
- Run `npm run lint` in `frontend/` before submitting UI changes.

## Testing Guidelines
- Backend tests follow `test_*.py` naming; place new tests near related modules in `codeloom/tests/`.
- E2E tests use `*.spec.ts` under `tests/e2e/`; prefer scenario-driven names (example: `upload_and_chat.spec.ts`).
- Add or update tests for behavior changes in API routes, ingestion, migration, and UI workflows.

## Commit & Pull Request Guidelines
- Follow the existing Conventional Commit style visible in history: `feat: ...`, `fix(scope): ...`, `refactor: ...`, `chore: ...`.
- Keep commits focused and scoped to one change set.
- PRs should include:
  - What changed and why.
  - Any schema/env changes (`alembic` revision, new `.env` keys).
  - Test evidence (for example: `pytest -v -x`, `npx playwright test`, or screenshots for UI updates).

## Security & Configuration Tips
- Copy `.env.example` to `.env`; never commit secrets.
- Ensure `PGVECTOR_EMBED_DIM` matches the selected embedding model before ingesting projects.
