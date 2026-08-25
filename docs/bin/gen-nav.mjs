#!/usr/bin/env node
/**
 * Builds the site's navigation from the content directory.
 *
 *   node bin/gen-nav.mjs
 *
 * Writes `src/generated/nav.json`, which `astro.config.mjs` uses verbatim as
 * its `sidebar`. Adding a page is therefore just adding a file — there is no
 * second place to register it.
 *
 * Starlight's own `autogenerate` was the obvious candidate and does not fit:
 * it takes a group's label from the raw directory name, so readable labels
 * would mean directories called `Core Features`, and that lands in the URL.
 * Generating the tree here keeps the grouping in the filesystem while leaving
 * both the labels and the URLs clean.
 *
 * The API reference is not walked here — it is generated from Ruby source by
 * `gen-reference.rb`, which writes its own sidebar. This merges that in so the
 * config has a single thing to import.
 */
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const DOCS_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CONTENT = join(DOCS_ROOT, 'src', 'content');

/**
 * Reads the frontmatter keys the navigation cares about.
 *
 * Deliberately not a YAML parse: `title` and `sidebar.order` are the only
 * fields read, both are scalars on their own line, and a dependency-free
 * build script is worth more here than generality.
 */
function frontmatter(file) {
	const source = readFileSync(file, 'utf8');
	const block = source.match(/^---\r?\n([\s\S]*?)\r?\n---/);
	if (!block) throw new Error(`${file}: no frontmatter`);

	const title = block[1].match(/^title:\s*(.+?)\s*$/m)?.[1];
	if (!title) throw new Error(`${file}: no title`);

	const order = block[1].match(/^sidebar:\s*\r?\n(?:\s+.*\r?\n)*?\s+order:\s*(-?\d+)/m)?.[1];

	return {
		// Quoted titles are common once a title contains a colon.
		title: title.replace(/^(['"])(.*)\1$/, '$2'),
		order: order === undefined ? Number.MAX_SAFE_INTEGER : Number(order),
	};
}

/** Pages sort by `sidebar.order`, then by slug so the result is stable. */
const byOrderThenSlug = (a, b) => a.order - b.order || a.slug.localeCompare(b.slug);

/**
 * One page's sidebar entry. `slug` is the route Starlight will serve it at,
 * which is the path with the group directory removed — see `generateId` in
 * src/content.config.ts.
 */
function pageEntry(section, group, file) {
	const { title, order } = frontmatter(join(CONTENT, section, group, file));
	const name = file.replace(/\.mdx?$/, '');

	return { label: title, slug: `${section}/${name}`, order };
}

/**
 * Walks one section directory. Loose pages come first, then each subdirectory
 * as a group, labelled and ordered by its `_group.json`.
 */
function section(name) {
	const dir = join(CONTENT, name);
	const listing = readdirSync(dir, { withFileTypes: true });

	const pages = listing
		.filter((e) => e.isFile() && /\.mdx?$/.test(e.name) && !e.name.startsWith('_'))
		.map((e) => {
			const { title, order } = frontmatter(join(dir, e.name));
			const base = e.name.replace(/\.mdx?$/, '');
			// `index` is the section's own landing page, served at `/<section>/`.
			const slug = base === 'index' ? name : `${name}/${base}`;
			return { label: title, slug, order };
		})
		.sort(byOrderThenSlug);

	const groups = listing
		.filter((e) => e.isDirectory())
		.map((e) => {
			const meta = join(dir, e.name, '_group.json');
			if (!existsSync(meta)) throw new Error(`${name}/${e.name}: missing _group.json`);
			const { label, order = Number.MAX_SAFE_INTEGER } = JSON.parse(readFileSync(meta, 'utf8'));

			const items = readdirSync(join(dir, e.name))
				.filter((f) => /\.mdx?$/.test(f) && !f.startsWith('_'))
				.map((f) => pageEntry(name, e.name, f))
				.sort(byOrderThenSlug);

			return { label, order, items: items.map(({ order: _, ...item }) => item) };
		})
		.sort((a, b) => a.order - b.order || a.label.localeCompare(b.label));

	return [
		...pages.map(({ order: _, ...page }) => page),
		...groups.map(({ order: _, ...group }) => group),
	];
}

const reference = JSON.parse(
	readFileSync(join(DOCS_ROOT, 'src', 'generated', 'reference-sidebar.json'), 'utf8')
);

// The four sections, in the order they appear as tabs in the header.
const nav = [
	{ label: 'Home', slug: 'index' },
	{ label: 'Docs', items: section('docs') },
	{ label: 'Reference', items: reference },
	{ label: 'Examples', items: section('examples') },
];

const out = join(DOCS_ROOT, 'src', 'generated', 'nav.json');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify(nav, null, 2)}\n`);

const count = (entries) =>
	entries.reduce((n, e) => n + (e.items ? count(e.items) : 1), 0);
console.error(`nav: ${nav.length} sections, ${count(nav)} entries -> ${out}`);
