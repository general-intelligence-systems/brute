// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

import tailwindcss from '@tailwindcss/vite';

// The whole navigation, built from the content directory by bin/gen-nav.mjs
// (which folds in the Ruby-generated reference tree). Checked in so a plain
// `astro build` works without a Ruby toolchain.
import nav from './src/generated/nav.json' with { type: 'json' };

const repo = 'https://github.com/general-intelligence-systems/brute';

// https://astro.build/config
export default defineConfig({
  site: 'https://general-intelligence-systems.github.io',
  base: '/brute',
  trailingSlash: 'always',

  integrations: [
      starlight({
          title: 'brute',
          description:
              'A framework-agnostic coding agent for Ruby. Rack-style middleware pipelines for agent turns, built-in tools, session persistence — bring your own LLM library.',
          social: [{ icon: 'github', label: 'GitHub', href: repo }],
          editLink: { baseUrl: `${repo}/edit/trench/docs/` },
          lastUpdated: true,
          // Tailwind base must come first.
          customCss: ['./src/styles/global.css'],
          // Code blocks sit directly on the page rather than in a framed
          // panel, at the same 14px/24px metrics as the rest of the page.
          // Expressive Code resolves colours at build time to derive shades,
          // so these are literals rather than CSS custom properties. The hex
          // matches --color-gray-800 in the Tailwind theme.
          expressiveCode: {
              styleOverrides: {
                  borderWidth: '0',
                  borderRadius: '0.5rem',
                  codeFontSize: '0.875rem',
                  codeLineHeight: '1.7143',
                  codeBackground: '#1c1615',
              },
          },
          // The site's chrome is rendered by our own components so it can be
          // styled with utility classes. The behavioural components — Search,
          // ThemeSelect, ThemeProvider, Head, PageFrame — stay Starlight's.
          components: {
              ContentPanel: './src/components/ContentPanel.astro',
              Footer: './src/components/Footer.astro',
              Header: './src/components/Header.astro',
              PageSidebar: './src/components/PageSidebar.astro',
              PageTitle: './src/components/PageTitle.astro',
              Sidebar: './src/components/Sidebar.astro',
              SiteTitle: './src/components/SiteTitle.astro',
              TableOfContents: './src/components/TableOfContents.astro',
              TwoColumnContent: './src/components/TwoColumnContent.astro',
          },
          // The site's four sections — Home, Docs, Reference, Examples.
          // Each top-level entry is one tab in the header and owns the whole
          // sidebar while you are inside it: Header.astro derives the tabs
          // from this list, and Sidebar.astro renders only the current
          // section. The tree itself is generated; see bin/gen-nav.mjs.
          sidebar: nav,
      }),
	],

  vite: {
    plugins: [tailwindcss()],
  },
});