import { writeFile } from 'node:fs/promises';

const configuredUrl = process.env.API_BASE_URL?.trim();
const apiBaseUrl = configuredUrl || 'http://localhost:9090';

if (!configuredUrl && process.env.VERCEL === '1') {
  throw new Error('Set API_BASE_URL in the Vercel project environment variables.');
}

let parsedUrl;
try {
  parsedUrl = new URL(apiBaseUrl);
} catch {
  throw new Error('API_BASE_URL must be an absolute HTTP or HTTPS URL.');
}

if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
  throw new Error('API_BASE_URL must use HTTP or HTTPS.');
}

if (process.env.VERCEL === '1' && parsedUrl.protocol !== 'https:') {
  throw new Error('API_BASE_URL must use HTTPS on Vercel.');
}

const normalizedUrl = apiBaseUrl.replace(/\/+$/, '');
const outputPath = new URL('../dist/frontend/browser/app-config.js', import.meta.url);
await writeFile(
  outputPath,
  `window.__KNOT_CONFIG__ = Object.freeze({ apiBaseUrl: ${JSON.stringify(normalizedUrl)} });\n`,
  'utf8'
);

console.log(`Wrote runtime API configuration to ${outputPath.pathname}`);