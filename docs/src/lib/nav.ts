import type { SidebarEntry } from '@astrojs/starlight/types';

/**
 * The site is divided into sections — Home, Docs, Reference, Examples — and
 * each top-level entry of the configured sidebar is one of them.
 *
 * A section is a tab in the header and owns the sidebar while you are inside
 * it. Both `Header.astro` and `Sidebar.astro` need to agree on which section
 * the current page belongs to, so that decision lives here rather than being
 * made twice.
 */
export interface Section {
	label: string;
	/** Where the tab points: the section's own page, or its first page. */
	href: string;
	isCurrent: boolean;
	/** The sidebar for this section. Empty for a section that is a single page. */
	entries: SidebarEntry[];
}

/** The first reachable page in a subtree, used as a section's destination. */
function firstLink(entries: SidebarEntry[]): string | undefined {
	for (const entry of entries) {
		if (entry.type === 'link') return entry.href;
		const nested = firstLink(entry.entries);
		if (nested) return nested;
	}
	return undefined;
}

/** True when the page being viewed lives anywhere in this subtree. */
export function containsCurrent(entries: SidebarEntry[]): boolean {
	return entries.some((entry) =>
		entry.type === 'link' ? entry.isCurrent : containsCurrent(entry.entries)
	);
}

/** The sections of the site, in configured order. */
export function sections(sidebar: SidebarEntry[]): Section[] {
	return sidebar.flatMap((entry) => {
		// A section that is a single page — Home — is configured as a plain
		// link rather than a group, and carries no sidebar of its own.
		if (entry.type === 'link') {
			return [{ label: entry.label, href: entry.href, isCurrent: entry.isCurrent, entries: [] }];
		}

		const href = firstLink(entry.entries);
		if (!href) return [];

		return [
			{
				label: entry.label,
				href,
				isCurrent: containsCurrent(entry.entries),
				entries: entry.entries,
			},
		];
	});
}

/**
 * The section the current page belongs to, or undefined when the page is not
 * in the navigation at all — which is possible for a page that exists in the
 * content collection but was never added to a section.
 */
export function currentSection(sidebar: SidebarEntry[]): Section | undefined {
	return sections(sidebar).find((section) => section.isCurrent);
}
