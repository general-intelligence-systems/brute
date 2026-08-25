// Validate every internal link in the built site.
//
// starlight-links-validator cannot help here: the docs use directory-relative
// links so the content stays independent of the `base` the site deploys under,
// and that plugin skips relative links rather than resolving them.
//
//   node bin/check-links.mjs [dist-dir]

import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const dist = resolve(process.argv[2] ?? join(here, '..', 'dist'));

// `dist/` is the root of the deployed site, so absolute links carry the base
// while paths inside dist/ do not. Read as text rather than imported: importing
// astro.config.mjs pulls Starlight's TypeScript in, which Node will not strip.
const configSource = await readFile(join(here, '..', 'astro.config.mjs'), 'utf8');
const configuredBase = configSource.match(/^\s*base:\s*['"]([^'"]*)['"]/m)?.[1] ?? '';
const base = configuredBase ? `/${configuredBase.replace(/^\/|\/$/g, '')}/` : '/';
const stripBase = (path) =>
	base !== '/' && path.startsWith(base) ? path.slice(base.length - 1) : path;

async function htmlFiles(dir) {
	const found = [];

	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) found.push(...(await htmlFiles(path)));
		else if (entry.name.endsWith('.html')) found.push(path);
	}

	return found;
}

const pages = await htmlFiles(dist);

// The set of URL paths the built site actually serves.
const served = new Set();
for (const page of pages) {
	const url = '/' + relative(dist, page).replaceAll('\\', '/');
	served.add(url);
	if (url.endsWith('/index.html')) served.add(url.slice(0, -'index.html'.length));
}

// Non-HTML output (raw .md, sitemap, assets) counts as servable too.
async function addAssets(dir) {
	for (const entry of await readdir(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) await addAssets(path);
		else served.add('/' + relative(dist, path).replaceAll('\\', '/'));
	}
}
await addAssets(dist);

const idsOf = (html) => {
	const ids = new Set();
	for (const [, id] of html.matchAll(/\bid="([^"]+)"/g)) ids.add(id);
	return ids;
};

const failures = [];

for (const page of pages) {
	const html = await readFile(page, 'utf8');
	const pageUrl = '/' + relative(dist, page).replaceAll('\\', '/');
	const dirUrl = pageUrl.replace(/[^/]*$/, '');
	const ids = idsOf(html);

	for (const [, href] of html.matchAll(/\bhref="([^"]*)"/g)) {
		if (!href || /^(?:[a-z]+:|\/\/|mailto:|tel:|data:)/i.test(href)) continue;

		const [rawPath, hash] = href.split('#');

		// A bare "#hash" points inside the current page.
		if (!rawPath) {
			if (hash && !ids.has(decodeURIComponent(hash))) {
				failures.push(`${pageUrl}  ->  ${href}  (no such anchor on this page)`);
			}
			continue;
		}

		// Relative hrefs resolve to a dist-relative path already; absolute ones
		// carry the base, so it comes back off.
		const target = stripBase(new URL(rawPath, `http://x${dirUrl}`).pathname);
		const candidates = [target, target.endsWith('/') ? `${target}index.html` : `${target}/index.html`];

		if (!candidates.some((c) => served.has(c))) {
			failures.push(`${pageUrl}  ->  ${href}  (no such page)`);
			continue;
		}

		if (!hash) continue;

		const targetFile = candidates.find((c) => c.endsWith('.html') && served.has(c));
		if (!targetFile) continue;

		const targetIds = idsOf(await readFile(join(dist, targetFile.slice(1)), 'utf8'));
		if (!targetIds.has(decodeURIComponent(hash))) {
			failures.push(`${pageUrl}  ->  ${href}  (no such anchor)`);
		}
	}
}

if (failures.length > 0) {
	console.error(`\n${failures.length} broken link(s):\n`);
	for (const failure of failures) console.error(`  ${failure}`);
	process.exit(1);
}

console.log(`✓ all internal links resolve (${pages.length} pages)`);
