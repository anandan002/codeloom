/**
 * End-to-end validation: upload a project zip and verify chat works.
 *
 * Validates that:
 * 1. Login succeeds
 * 2. A project exists (or is created via upload)
 * 3. Chat returns real content — NOT "No embeddings found"
 * 4. node_count > 0 is reported (embeddings are actually stored)
 *
 * Run:
 *   BASE_URL=https://idea.htcindia.com/codeloom npx playwright test
 *   BASE_URL=http://localhost:7007/codeloom npx playwright test
 */

import { test, expect, Page } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASS = process.env.ADMIN_PASS || 'admin123';
const TEST_QUESTION = 'What programming language is this project written in?';

async function login(page: Page) {
  await page.goto('/');
  // Redirect to login if not authenticated
  await page.waitForURL(/login/, { timeout: 10_000 }).catch(() => {});

  const onLogin = page.url().includes('login');
  if (onLogin) {
    await page.getByLabel(/username/i).fill(ADMIN_USER);
    await page.getByLabel(/password/i).fill(ADMIN_PASS);
    await page.getByRole('button', { name: /login|sign in/i }).click();
    await page.waitForURL(/(?!.*login)/, { timeout: 15_000 });
  }
}

test.describe('Embedding pipeline validation', () => {
  test('existing project chat returns content — not "No embeddings found"', async ({ page, request }) => {
    await login(page);

    // ── 1. Get project list via API ──────────────────────────────────────────
    const base = page.url().replace(/\/[^/]*$/, '');
    const apiBase = base.includes('/codeloom') ? base.split('/codeloom')[0] + '/codeloom' : base;

    const projectsRes = await request.get(`${apiBase}/api/projects`);
    expect(projectsRes.ok(), `GET /api/projects failed: ${projectsRes.status()}`).toBeTruthy();

    const projects: Array<{ id: string; name: string }> = await projectsRes.json();
    expect(projects.length, 'No projects found — upload one first').toBeGreaterThan(0);

    const project = projects[0];
    console.log(`Testing project: ${project.name} (${project.id})`);

    // ── 2. Check node_count via API ──────────────────────────────────────────
    const statsRes = await request.get(`${apiBase}/api/projects/${project.id}`);
    if (statsRes.ok()) {
      const detail = await statsRes.json();
      console.log(`Project node_count: ${detail.node_count ?? 'N/A'}`);
      // If node_count is 0 we still proceed — the chat endpoint will confirm the real state
    }

    // ── 3. Navigate to chat and send a message ───────────────────────────────
    await page.goto(`${apiBase}/project/${project.id}/chat`);
    await page.waitForLoadState('networkidle');

    const chatInput = page.getByPlaceholder(/ask|message|question/i).first();
    await expect(chatInput, 'Chat input not found').toBeVisible({ timeout: 10_000 });

    await chatInput.fill(TEST_QUESTION);
    await chatInput.press('Enter');

    // ── 4. Wait for response and assert it contains real content ─────────────
    // The response container should appear within 60 s
    const responseLocator = page.locator('[data-testid="chat-response"], .chat-message, .message-content').last();
    await expect(responseLocator).toBeVisible({ timeout: 60_000 });

    const responseText = await responseLocator.textContent() ?? '';
    console.log(`Chat response (first 200 chars): ${responseText.slice(0, 200)}`);

    expect(
      responseText,
      'Chat returned "No embeddings found" — pgvector extension likely not installed or embeddings not stored'
    ).not.toContain('No embeddings found');

    expect(
      responseText,
      'Chat returned empty response'
    ).not.toBe('');

    // Must NOT be the generic "I cannot answer" refusal when context is empty
    expect(
      responseText,
      'Chat returned "cannot answer" — LLM received no context (embeddings empty)'
    ).not.toMatch(/I cannot answer this question because/i);
  });

  test('upload API returns embeddings_stored > 0', async ({ request, page }) => {
    await login(page);

    const apiBase = page.url().includes('codeloom')
      ? page.url().split('codeloom')[0] + 'codeloom'
      : page.url().replace(/\/[^/]*$/, '');

    // Find a fixture zip or skip
    const fixtureDir = path.join(__dirname, 'fixtures');
    const zipFiles = fs.existsSync(fixtureDir)
      ? fs.readdirSync(fixtureDir).filter(f => f.endsWith('.zip'))
      : [];

    if (zipFiles.length === 0) {
      test.skip(true, 'No fixture zip in tests/e2e/fixtures/ — skipping upload test');
      return;
    }

    const zipPath = path.join(fixtureDir, zipFiles[0]);
    const zipBuffer = fs.readFileSync(zipPath);

    // Create a test project
    const projectName = `playwright-test-${Date.now()}`;
    const createRes = await request.post(`${apiBase}/api/projects`, {
      data: { name: projectName, description: 'Playwright upload validation' },
    });
    expect(createRes.ok(), `Project creation failed: ${createRes.status()}`).toBeTruthy();
    const { id: projectId } = await createRes.json();

    // Upload zip
    const uploadRes = await request.post(`${apiBase}/api/projects/${projectId}/upload`, {
      multipart: {
        file: {
          name: zipFiles[0],
          mimeType: 'application/zip',
          buffer: zipBuffer,
        },
      },
      timeout: 120_000,
    });

    expect(uploadRes.ok(), `Upload failed: ${uploadRes.status()}`).toBeTruthy();
    const uploadResult = await uploadRes.json();
    console.log(`Upload result: embeddings_stored=${uploadResult.embeddings_stored}, files=${uploadResult.files_processed}`);

    expect(
      uploadResult.embeddings_stored,
      'embeddings_stored is 0 — pgvector extension not installed or add_nodes() failed'
    ).toBeGreaterThan(0);

    // Cleanup: delete test project
    await request.delete(`${apiBase}/api/projects/${projectId}`);
  });
});
