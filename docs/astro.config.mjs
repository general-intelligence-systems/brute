// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

import tailwindcss from '@tailwindcss/vite';

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
          // Slugs are flat so the URLs match the previous Jekyll site exactly
          // (its collections used a `/:name/` permalink).
          sidebar: [
              {
                  label: 'Start Here',
                  items: [{ label: 'Getting Started', slug: 'getting-started' }],
              },
              {
                  label: 'Core Features',
                  items: [
                      { label: 'The Agent Pipeline', slug: 'agents' },
                      { label: 'Messages', slug: 'messages' },
                      { label: 'Message Transports', slug: 'message-transports' },
                      { label: 'Tools', slug: 'tools' },
                      { label: 'Middleware', slug: 'middleware' },
                  ],
              },
              {
                  label: 'Advanced',
                  items: [
                      { label: 'Sub-Agents', slug: 'sub-agents' },
                      { label: 'Sessions', slug: 'sessions' },
                      { label: 'Skills', slug: 'skills' },
                      { label: 'Events', slug: 'events' },
                      { label: 'Serving over HTTP', slug: 'rack' },
                  ],
              },
              {
                  label: 'Examples',
                  items: [{ label: 'Runnable Examples', slug: 'examples' }],
              },
          ],
      }),
	],

  vite: {
    plugins: [tailwindcss()],
  },
});