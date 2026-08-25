import type { APIRoute, GetStaticPaths } from 'astro';
import { getCollection } from 'astro:content';

/**
 * Emits the raw Markdown source of every docs page at `<slug>.md`.
 *
 * This backs the "View as Markdown" link and the "Copy page" button, which
 * fetches from here rather than embedding a second copy of every page's
 * source in its HTML.
 */
export const getStaticPaths: GetStaticPaths = async () => {
	const docs = await getCollection('docs');

	return docs.map((entry) => ({
		// The docs loader gives the home page the id `index`, which is also the
		// path we want for it, so ids map to route params as-is.
		params: { slug: entry.id },
		props: { body: entry.body ?? '', title: entry.data.title },
	}));
};

// Starlight renders the title from frontmatter rather than a body heading, so
// re-attach it — a copied page should not arrive untitled.
const leadingH1 = /^\s*#\s+\S/;

export const GET: APIRoute = ({ props }) => {
	const { body, title } = props as { body: string; title: string };
	const markdown = leadingH1.test(body) ? body : `# ${title}\n\n${body}`;

	return new Response(markdown, {
		headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
	});
};
