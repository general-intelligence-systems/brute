import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

/**
 * The site is organised into four sections, each with its own top-level nav tab
 * and its own sidebar: `home`, `docs`, `reference` and `examples`.
 *
 * Starlight requires exactly one collection named `docs`, and its own
 * `docsLoader()` hard-codes the base to `src/content/docs/` — which would make
 * one section's directory the home of all four. It is a thin wrapper over
 * Astro's `glob()`, so this points a glob at `src/content/` instead and lets
 * the section directories sit as siblings.
 */
export const collections = {
	docs: defineCollection({
		loader: glob({
			base: './src/content',
			pattern: '{home,docs,reference,examples}/**/[^_]*.{md,mdx}',
			/**
			 * A page's section is its URL prefix; anything below that is
			 * grouping, not routing.
			 *
			 * `docs/core-features/agents.md` therefore serves `/docs/agents/`:
			 * the group directory is what puts the page under "Core Features"
			 * in the sidebar (see bin/gen-nav.mjs), and keeping it out of the
			 * URL means a page can be regrouped without breaking its links.
			 *
			 * Two further cases mirror how Starlight names routes: a trailing
			 * `index` is dropped, so `examples/index.md` serves `/examples/`;
			 * and `home/` is dropped entirely, being the site root rather than
			 * a section you navigate into, so its page is `index` and serves
			 * `/`.
			 */
			generateId: ({ entry }) => {
				const path = entry.replace(/\.mdx?$/, '').replace(/(?:^|\/)index$/, '');
				const [section, ...rest] = path.split('/');

				if (section === 'home') return 'index';
				// The reference is generated as a deep tree that *is* its URL
				// structure, so it keeps every segment.
				if (section === 'reference' || rest.length === 0) return path;

				return `${section}/${rest[rest.length - 1]}`;
			},
		}),
		schema: docsSchema(),
	}),
};
